//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if os(Windows)
private import Foundation
#else
public import Foundation
#endif

import SwiftDriver
import TSCBasic

public import SWBUtil

private extension Path {
    init(_ virtualPath: TypedVirtualPath) throws {
        switch virtualPath.file {
        case let .absolute(absPath): self = Path(absPath.pathString)
        case .standardInput, .standardOutput, .fileList, .relative, .temporary, .temporaryWithKnownContents:
            fallthrough
        @unknown default:
            throw StubError.error("Cannot build Path from \(virtualPath); unimplemented path type.")
        }
    }
}

/// Describes one single job invocation planned by the Swift driver
public struct SwiftDriverJob: Serializable, CustomDebugStringConvertible {
    public enum Kind: Serializable {
        case target, explicitModule(uniqueID: Int)

        public func serialize<T>(to serializer: T) where T : Serializer {
            serializer.serializeAggregate(2) {
                switch self {
                case .target:
                    serializer.serialize(0)
                    serializer.serializeNil()
                case .explicitModule(let uniqueID):
                    serializer.serialize(1)
                    serializer.serialize(uniqueID)
                }
            }
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            switch try deserializer.deserialize() as Int {
            case 0:
                self = .target
                try deserializer.deserializeNilThrow()
            case 1:
                self = .explicitModule(uniqueID: try deserializer.deserialize())
            default:
                throw StubError.error("Unexpected Swift driver job kind.")
            }
        }
    }
    /// Explicit module builds will contain an uniqueID that is expensive to calculate for all jobs
    public let kind: Kind
    /// A `String` to be used as the ruleInfo type ('Compile', 'Merge-Modules', …)
    public let ruleInfoType: String
    /// The name of the module this job is part of
    public let moduleName: String
    /// All file inputs for this job
    public let inputs: [Path]
    /// All file inputs that should be shown in the build log
    public let displayInputs: [Path]
    /// Description to use for execDescription
    public let descriptionForLifecycle: String
    /// All file outputs this job produces
    public let outputs: [Path]
    /// The command line to execute for this job
    public let commandLine: [SWBUtil.ByteString]
    /// A signature which uniquely identifies the job.
    public let signature: SWBUtil.ByteString
    /// Cache keys for the swift-frontend invocation (one key per output producing input)
    public let cacheKeys: [String]

    fileprivate init(job: SwiftDriver.Job, resolver: ArgsResolver, explicitModulesResolver: ArgsResolver) throws {
        let categorizer = SwiftDriverJobCategorizer(job)
        self.ruleInfoType = categorizer.ruleInfoType()
        self.moduleName = job.moduleName
        self.inputs = try job.inputs.map { try Path(resolver.resolve(.path($0.file))) }
        self.displayInputs = try job.displayInputs.map { try Path(resolver.resolve(.path($0.file))) }
        self.outputs = try job.outputs.map { try Path(resolver.resolve(.path($0.file))) }
        self.descriptionForLifecycle = job.descriptionForLifecycle
        if categorizer.isExplicitDependencyBuild {
            self.commandLine = try explicitModulesResolver.resolveArgumentList(for: job, useResponseFiles: .heuristic).map { ByteString(encodingAsUTF8: $0) }
            self.kind = .explicitModule(uniqueID: commandLine.hashValue)
        } else {
            self.commandLine = try resolver.resolveArgumentList(for: job, useResponseFiles: .heuristic).map { ByteString(encodingAsUTF8: $0) }
            self.kind = .target
        }
        self.cacheKeys = job.outputCacheKeys.reduce(into: [String]()) { result, key in
            result.append(key.value)
        }.sorted()
        let md5 = InsecureHashContext()
        for arg in commandLine {
            md5.add(bytes: arg)
        }
        self.signature = md5.signature
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(10) {
            serializer.serialize(kind)
            serializer.serialize(ruleInfoType)
            serializer.serialize(moduleName)
            serializer.serialize(inputs)
            serializer.serialize(displayInputs)
            serializer.serialize(outputs)
            serializer.serialize(commandLine)
            serializer.serialize(descriptionForLifecycle)
            serializer.serialize(signature)
            serializer.serialize(cacheKeys)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(10)
        try self.kind = deserializer.deserialize()
        try self.ruleInfoType = deserializer.deserialize()
        try self.moduleName = deserializer.deserialize()
        try self.inputs = deserializer.deserialize()
        try self.displayInputs = deserializer.deserialize()
        try self.outputs = deserializer.deserialize()
        try self.commandLine = deserializer.deserialize()
        try self.descriptionForLifecycle = deserializer.deserialize()
        try self.signature = deserializer.deserialize()
        try self.cacheKeys = deserializer.deserialize()
    }

    public var debugDescription: String {
        ([ruleInfoType, moduleName] + displayInputs.map(\.basename)).joined(separator: " ")
    }
}


extension LibSwiftDriver {

    public final class PlannedBuild {
        public enum Errors: Swift.Error, CustomStringConvertible {
            case multipleProducers(output: Path, jobs: [SwiftDriverJob])

            public var description: String {
                switch self {
                case let .multipleProducers(output, jobs):
                    return "Multiple jobs produce \(output): \(jobs)"
                }
            }

            public var localizedDescription: String {
                description
            }
        }

        /// A Swift driver job with access to its dependencies
        public struct PlannedSwiftDriverJob: Serializable, CustomStringConvertible, CustomDebugStringConvertible {
            /// An identifier of this job which is unique inside the containing build
            public let key: JobKey
            /// Access to all information about the job itself
            public let driverJob: SwiftDriverJob
            /// Keys to all dependencies of this job
            public let dependencies: [JobKey]
            /// Working directory for running this job
            public let workingDirectory: Path

            internal init(key: JobKey, driverJob: SwiftDriverJob, dependencies: [JobKey], workingDirectory: Path) {
                self.key = key
                self.driverJob = driverJob
                self.dependencies = dependencies
                self.workingDirectory = workingDirectory
            }

            public func serialize<T>(to serializer: T) where T : Serializer {
                serializer.serializeAggregate(4) {
                    serializer.serialize(key)
                    serializer.serialize(driverJob)
                    serializer.serialize(dependencies)
                    serializer.serialize(workingDirectory)
                }
            }

            public init(from deserializer: any Deserializer) throws {
                try deserializer.beginAggregate(4)
                try key = deserializer.deserialize()
                try driverJob = deserializer.deserialize()
                try dependencies = deserializer.deserialize()
                try workingDirectory = deserializer.deserialize()
            }

            public func addingDependencies(_ newDependencies: [JobKey]) -> PlannedSwiftDriverJob {
                PlannedSwiftDriverJob(key: key, driverJob: driverJob, dependencies: dependencies + newDependencies, workingDirectory: workingDirectory)
            }

            public var description: String {
                driverJob.descriptionForLifecycle
            }

            public var debugDescription: String {
                let keyStrConverter: (_ key: JobKey) -> String = { key in
                    let keyStr: String
                    switch key {
                        case .explicitDependencyJob(let index):
                            keyStr = ("explicit(\(index))")
                        case .targetJob(let index):
                            keyStr = ("target(\(index))")

                    }
                    return keyStr
                }
                return "<PlannedSwiftDriverJob [\(keyStrConverter(key))]:\(driverJob.debugDescription) dependencies=\(dependencies.map { keyStrConverter($0) })>"
            }
        }

        /// All target jobs to build (does not include jobs to build explicit dependencies)
        private var plannedTargetJobs: [PlannedSwiftDriverJob]

        /// The references to the original SwiftDriver jobs, needed for dependency discovery
        /// Must have the same count as `plannedTargetJobs`.
        var driverTargetJobs: [SwiftDriver.Job]

        let argsResolver: ArgsResolver
        let explicitModulesResolver: ArgsResolver
        let jobExecutionDelegate: (any JobExecutionDelegate)?
        /// Protect the PlannedBuild's shared state
        let dispatchQueue: SWBQueue
        let eagerCompilationEnabled: Bool
        /// State for incremental compilation
        private weak var incrementalCompilationState: IncrementalCompilationState?
        /// Mapping from filePaths to the index of the job producing the file at this path
        private(set) var producerMap: [Path: JobKey]
        /// Indices for jobs that build explicit modules
        let explicitModuleBuildJobKeys: Set<JobKey>
        /// Indices for jobs that unblock downstream targets' compilation
        let compilationRequirementsIndices: Range<JobIndex>
        /// Indices for jobs that perform unblocking compilation
        let compilationIndices: Range<JobIndex>
        /// Indices for jobs to run after compilation
        let afterCompilationIndices: Range<JobIndex>
        /// Indices for jobs that require produced files as input
        let verificationIndices: Range<JobIndex>
        /// Global store of de-duplicated explicit module dependency build jobs
        weak var globalExplicitDependencyJobGraph: (any SwiftGlobalExplicitDependencyGraph)?
        /// Working directory for compilation jobs in this build
        let workingDirectory: Path

        private var jobsUnfinished: Set<JobKey>

        internal init(workload: SwiftDriver.DriverExecutorWorkload, argsResolver: ArgsResolver, explicitModulesResolver: ArgsResolver, jobExecutionDelegate: (any JobExecutionDelegate)?, globalExplicitDependencyJobGraph: (any SwiftGlobalExplicitDependencyGraph)?, workingDirectory: Path, eagerCompilationEnabled: Bool) throws {
            self.globalExplicitDependencyJobGraph = globalExplicitDependencyJobGraph
            self.argsResolver = argsResolver
            self.explicitModulesResolver = explicitModulesResolver
            self.eagerCompilationEnabled = eagerCompilationEnabled
            self.workingDirectory = workingDirectory
            (
                plannedTargetJobs: self.plannedTargetJobs,
                originalTargetJobs: self.driverTargetJobs,
                incrementalCompilationState: self.incrementalCompilationState,
                producerMap: self.producerMap,
                explicitModuleBuildJobKeys: self.explicitModuleBuildJobKeys,
                compilationRequirementsIndices: self.compilationRequirementsIndices,
                compilationIndices: self.compilationIndices,
                afterCompilationIndices: self.afterCompilationIndices,
                verificationIndices: self.verificationIndices
            ) = try Self.evaluateWorkload(workload, argsResolver: argsResolver, explicitModulesResolver: explicitModulesResolver, globalExplicitDependencyJobGraph: globalExplicitDependencyJobGraph, workingDirectory: workingDirectory, eagerCompilationEnabled: eagerCompilationEnabled)

            self.jobsUnfinished = Set(plannedTargetJobs.map { $0.key })
            self.jobsUnfinished.formUnion(explicitModuleBuildJobKeys)

            self.jobExecutionDelegate = jobExecutionDelegate
            self.dispatchQueue = SWBQueue(label: "org.swift.swift-build.SwiftDriver.PlannedBuildExecutionQueue", autoreleaseFrequency: .workItem)
        }

        private static func wrapJobs(_ jobs: [SwiftDriver.Job], argsResolver: ArgsResolver, explicitModulesResolver: ArgsResolver) throws -> [SwiftDriverJob] {
            try jobs.map { job in
                try SwiftDriverJob(job: job, resolver: argsResolver, explicitModulesResolver: explicitModulesResolver)
            }
        }

        private static func evaluateWorkload(_ workload: SwiftDriver.DriverExecutorWorkload, argsResolver: ArgsResolver, explicitModulesResolver: ArgsResolver, globalExplicitDependencyJobGraph: (any SwiftGlobalExplicitDependencyGraph)?, workingDirectory: Path, eagerCompilationEnabled: Bool) throws -> (plannedTargetJobs: [PlannedSwiftDriverJob], originalTargetJobs: [SwiftDriver.Job], incrementalCompilationState: IncrementalCompilationState?, producerMap: [Path: JobKey], explicitModuleBuildJobKeys: Set<JobKey>, compilationRequirementsIndices: Range<JobIndex>, compilationIndices:  Range<JobIndex>, afterCompilationIndices: Range<JobIndex>, verificationIndices: Range<JobIndex>) {
            var wrappedJobs: [SwiftDriverJob] = []
            var originalTargetJobs: [SwiftDriver.Job] = []
            let incrementalCompilationState: IncrementalCompilationState?
            var producerMap: [Path: JobKey] = [:]
            let compilationRequirementsIndices, compilationIndices, afterCompilationIndices, verificationIndices: Range<JobIndex>
            let explicitModuleBuildJobKeys: Set<JobKey>
            guard let explicitDependencyJobGraph = globalExplicitDependencyJobGraph else {
                fatalError("Explicit Modules Swift build plan invoked without a globalExplicitDependencyJobGraph.")
            }

            let jobsToWrap: [SwiftDriver.Job]
            switch workload.kind {
            case let .all(jobs):
                incrementalCompilationState = nil
                jobsToWrap = jobs
            case let .incremental(state):
                incrementalCompilationState = state
                jobsToWrap = state.mandatoryJobsInOrder + state.jobsAfterCompiles
            }

            let groupedJobs = try wrapJobs(jobsToWrap, argsResolver: argsResolver, explicitModulesResolver: explicitModulesResolver)
                .grouped(by: [
                    /* 0 */ \.categorizer.isExplicitDependencyBuild,
                    /* 1 */ \.categorizer.isEmitModule,
                    /* 2 */ \.categorizer.isGeneratePch,
                    /* 3 */ \.categorizer.isCompile,
                    /* 4 */ \.categorizer.isVerification,
                    /* 5 */ { _ in true }
                ])


            explicitModuleBuildJobKeys = try addExplicitDependencyBuildJobs(groupedJobs[0],
                                                                            to: explicitDependencyJobGraph,
                                                                            workingDirectory: workingDirectory,
                                                                            producing: &producerMap)

            compilationRequirementsIndices = try addTargetJobs(groupedJobs[2] + groupedJobs[1] + (eagerCompilationEnabled ? [] : groupedJobs[3]),
                                                               to: &wrappedJobs,
                                                               producing: &producerMap)

            compilationIndices = try addTargetJobs(eagerCompilationEnabled ? groupedJobs[3] : [],
                                                   to: &wrappedJobs,
                                                   producing: &producerMap)

            verificationIndices = try addTargetJobs(groupedJobs[4],
                                                    to: &wrappedJobs,
                                                    producing: &producerMap)

            afterCompilationIndices = try addTargetJobs(groupedJobs[5],
                                                        to: &wrappedJobs,
                                                        producing: &producerMap)

            originalTargetJobs = jobsToWrap.filter {
                !SwiftDriverJobCategorizer($0).isExplicitDependencyBuild
            }

            let plannedTargetJobs: [PlannedSwiftDriverJob] = wrappedJobs.enumerated().map { index, driverJob in
                let givenInputs = driverJob.inputs.compactMap { producerMap[$0] }
                var implicitInputs: [JobKey] = []
                if !eagerCompilationEnabled {
                    implicitInputs.append(contentsOf: (afterCompilationIndices.contains(index) ? Array(compilationIndices) : []).map { JobKey.targetJob($0) })
                }
                if compilationIndices.contains(index) || compilationRequirementsIndices.contains(index) {
                    implicitInputs.append(contentsOf: explicitModuleBuildJobKeys)
                }
                let dependencies = Set(givenInputs + implicitInputs).sorted()
                return PlannedSwiftDriverJob(key: .targetJob(index), driverJob: driverJob, dependencies: dependencies, workingDirectory: workingDirectory)
            }

            return (
                plannedTargetJobs: plannedTargetJobs,
                originalTargetJobs: originalTargetJobs,
                incrementalCompilationState: incrementalCompilationState,
                producerMap: producerMap,
                explicitModuleBuildJobKeys: explicitModuleBuildJobKeys,
                compilationRequirementsIndices: compilationRequirementsIndices,
                compilationIndices: compilationIndices,
                afterCompilationIndices: afterCompilationIndices,
                verificationIndices: verificationIndices
            )
        }

        @discardableResult
        private static func addExplicitDependencyBuildJobs(_ explicitDependencyDriverJobs: [SwiftDriverJob],
                                                           to explicitDependencyJobGraph: any SwiftGlobalExplicitDependencyGraph,
                                                           workingDirectory: Path, producing producerMap: inout [Path: JobKey]) throws -> Set<JobKey> {
            return try explicitDependencyJobGraph.addExplicitDependencyBuildJobs(explicitDependencyDriverJobs,
                                                                                 workingDirectory: workingDirectory,
                                                                                 producerMap: &producerMap)
        }

        @discardableResult
        private static func addTargetJobs(_ driverJobs: [SwiftDriverJob], to jobs: inout [SwiftDriverJob], producing producerMap: inout [Path: JobKey]) throws -> Range<JobIndex> {
            let initialCount = jobs.count

            for job in driverJobs {
                try addProducts(of: job, index: .targetJob(jobs.count), knownJobs: jobs, to: &producerMap)
                jobs.append(job)
            }

            return initialCount ..< jobs.count
        }

        internal static func addProducts(of job: SwiftDriverJob, index: JobKey, knownJobs: [SwiftDriverJob], to producerMap: inout [Path: JobKey]
        ) throws {
            for output in job.outputs {
                if let otherJobKey = producerMap.updateValue(index, forKey: output) {
                    // Due to rdar://88393903 emit-module and compile jobs will specify to produce the Objective-C header file of the Swift target. Since we're not tracking outputs yet in llbuild for dynamic tasks it won't matter but we should throw the error again once llbuild starts tracking outputs. (rdar://70881411)

                    _ = otherJobKey
//                    switch otherJobKey {
//                        case .targetJob(let otherJobIndex):
//                            throw PlannedBuild.Errors.multipleProducers(output: output, jobs: [job, knownJobs[otherJobIndex]])
//                        case .explicitDependencyJob(let otherJobIndex):
//                            throw PlannedBuild.Errors.multipleProducers(output: output, jobs: [job, knownJobs[otherJobIndex]])
//                    }
                }
                producerMap[output] = index
            }
        }

        private func driverJob(for plannedDriverJob: PlannedSwiftDriverJob) throws -> SwiftDriver.Job {
            switch plannedDriverJob.key {
                case .targetJob(let index):
                    guard let job = driverTargetJobs[safe: index] else {
                        throw StubError.error("Data inconsistency between planned driver jobs and actual jobs. Job \(plannedDriverJob.driverJob) is unknown.")
                    }
                    return job
                case .explicitDependencyJob(_):
                throw StubError.error("Querying SwiftDriver.job unsupported for an Explicit Dependency Build job.")
            }
        }

        public func explicitModulesPlannedDriverJobs() -> [PlannedSwiftDriverJob] {
            guard let explicitDependencyJobGraph = globalExplicitDependencyJobGraph else {
                fatalError("Explicit Modules Swift build plan invoked without a globalExplicitDependencyJobGraph.")
            }
            return explicitDependencyJobGraph.getExplicitDependencyBuildJobs(for: Array(explicitModuleBuildJobKeys))
        }

        /// How many explicit module dependency jobs does this build plan have
        public var explicitModuleBuildJobCount: Int {
            explicitModuleBuildJobKeys.count
        }

        public var targetBuildJobCount: Int {
            compilationRequirementsIndices.count + compilationIndices.count + afterCompilationIndices.count
        }

        public func compilationRequirementsPlannedDriverJobs() -> ArraySlice<PlannedSwiftDriverJob> {
            dispatchQueue.blocking_sync {
                self.plannedTargetJobs[compilationRequirementsIndices]
            }
        }

        public func compilationPlannedDriverJobs() -> ArraySlice<PlannedSwiftDriverJob> {
            dispatchQueue.blocking_sync {
                self.plannedTargetJobs[compilationIndices]
            }
        }

        public func afterCompilationPlannedDriverJobs() -> ArraySlice<PlannedSwiftDriverJob> {
            dispatchQueue.blocking_sync {
                self.plannedTargetJobs[afterCompilationIndices]
            }
        }

        public func verificationPlannedDriverJobs() -> ArraySlice<PlannedSwiftDriverJob> {
            dispatchQueue.blocking_sync {
                self.plannedTargetJobs[verificationIndices]
            }
        }

        /// Returns a planned job for the given key
        /// - Parameter key: The key identifying the job
        /// - Returns: The job if known, `nil` if unknown
        public func plannedTargetJob(for key: JobKey) -> PlannedSwiftDriverJob? {
            guard case .targetJob(let index) = key else { return nil }
            return dispatchQueue.blocking_sync {
                guard index < plannedTargetJobs.count else { return nil }
                return plannedTargetJobs[index]
            }
        }

        /// Get all dependencies for a given planned job
        /// - Parameter job: The job that needs to be part of this build's planned jobs
        /// - Returns: An array of all jobs that are dependencies of the given job (that consume an output of `job` as their input)
        public func dependencies(for job: PlannedSwiftDriverJob) -> [PlannedSwiftDriverJob] {
            return job.dependencies.compactMap { dependencyKey in
                switch dependencyKey {
                    case .targetJob(_):
                        return plannedTargetJob(for: dependencyKey)
                    case .explicitDependencyJob(_):
                        guard let explicitDependencyJobGraph = globalExplicitDependencyJobGraph else {
                            fatalError("Explicit Module build job detected without a globalExplicitDependencyJobGraph.")
                        }
                        return explicitDependencyJobGraph.plannedExplicitDependencyBuildJob(for: dependencyKey)
                }
            }
        }

        // MARK: - Job Execution Lifecycle

        public func jobStarted(job: PlannedSwiftDriverJob, arguments: [String], pid: pid_t) throws {
            try dispatchQueue.blocking_sync {
                let driverJob = try self.driverJob(for: job)
                self.jobExecutionDelegate?.jobStarted(job: driverJob, arguments: arguments, pid: Int(pid))
            }
        }

        public func jobFinished(job: PlannedSwiftDriverJob, arguments: [String], pid: pid_t, environment: [String: String], exitStatus: Processes.ExitStatus, output: SWBUtil.ByteString) throws {
            try dispatchQueue.blocking_sync {
                let driverJob = try self.driverJob(for: job)
                // FIXME: Need to separate stdout and stderr
                let result = ProcessResult(arguments: arguments, environmentBlock: ProcessEnvironmentBlock(environment), exitStatus: .init(exitStatus), output: .success(output.bytes), stderrOutput: .success([]))
                self.jobExecutionDelegate?.jobFinished(job: driverJob, result: result, pid: Int(pid))
            }
        }

        public func reportSkippedJobs(_ iterator: (LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob) throws -> Void) throws {
            try dispatchQueue.blocking_sync {
                let skippedJobs = self.incrementalCompilationState?.skippedJobs ?? []
                let wrappedJobs = try Self.wrapJobs(skippedJobs, argsResolver: argsResolver, explicitModulesResolver: explicitModulesResolver)
                var jobs: [SwiftDriverJob] = []
                try Self.addTargetJobs(wrappedJobs, to: &jobs, producing: &producerMap)
                let plannedJobs: [PlannedSwiftDriverJob] = jobs.enumerated().map { index, jobToAdd in
                    let givenDependencies = jobToAdd.inputs.compactMap { producerMap[$0] }
                    return PlannedSwiftDriverJob(key: .targetJob(self.plannedTargetJobs.count + index), driverJob: jobToAdd, dependencies: givenDependencies, workingDirectory: workingDirectory)
                }
                plannedTargetJobs.append(contentsOf: plannedJobs)

                assert(skippedJobs.count == plannedJobs.count, "Unable to plan all skipped driver jobs.")
                for (driverJob, plannedJob) in zip(skippedJobs, plannedJobs) {
                    try iterator(plannedJob)
                    self.jobExecutionDelegate?.jobSkipped(job: driverJob)
                }
            }
        }

        public func getDiscoveredJobsAfterFinishing(job: PlannedSwiftDriverJob) throws -> [PlannedSwiftDriverJob] {

            dispatchQueue.blocking_sync {
                _ = self.jobsUnfinished.remove(job.key)
            }

            switch job.key {
            case .explicitDependencyJob(_):
                // Explicit dependency jobs do not participate in the incremental machinery
                return []
            case .targetJob(let jobIndex):
                // result is not used but needed for API compatibility
                let result = TSCBasic.ProcessResult(arguments: [], environmentBlock: ProcessEnvironmentBlock(), exitStatus: .terminated(code: 0), output: .success([]), stderrOutput: .success([]))
                guard let newJobs = try incrementalCompilationState?.collectJobsDiscoveredToBeNeededAfterFinishing(job: driverTargetJobs[jobIndex], result: result) else {
                    return []
                }
                let wrappedJobs = try Self.wrapJobs(newJobs, argsResolver: argsResolver, explicitModulesResolver: explicitModulesResolver)
                var jobs: [SwiftDriverJob] = []
                return try dispatchQueue.blocking_sync {
                    let plannedJobsRange = try Self.addTargetJobs(wrappedJobs, to: &jobs, producing: &producerMap)
                    let plannedJobs: [PlannedSwiftDriverJob] = jobs.enumerated().map { index, jobToAdd in
                        let givenDependencies = jobToAdd.inputs.compactMap { producerMap[$0] }
                        return PlannedSwiftDriverJob(key: .targetJob(self.plannedTargetJobs.count + index), driverJob: jobToAdd, dependencies: givenDependencies, workingDirectory: workingDirectory)
                    }
                    self.plannedTargetJobs.append(contentsOf: plannedJobs)
                    self.jobsUnfinished.formUnion(Set(plannedJobsRange.map { .targetJob($0) }))
                    // Update secondary jobs' dependencies
                    let newPrimaryJobsKeys = plannedJobs.map(\.key)
                    for index in afterCompilationIndices {
                        plannedTargetJobs[index] = plannedTargetJobs[index].addingDependencies(newPrimaryJobsKeys)
                    }
                    self.driverTargetJobs.append(contentsOf: newJobs)
                    return plannedJobs
                }
            }
        }
    }
}

private extension TSCBasic.ProcessResult.ExitStatus {
    init(_ status: SWBUtil.Processes.ExitStatus) {
        switch status {
        case let .exit(code):
            self = .terminated(code: code)
        case let .uncaughtSignal(signal):
#if os(Windows)
            self = .abnormal(exception: UInt32(signal))
#else
            self = .signalled(signal: signal)
#endif
        }
    }
}

public struct SwiftDriverJobCategorizer {
    fileprivate let ruleInfoType: () -> String
    fileprivate let containsInputs: ((_ fileExtension: String?, _ basename: String) -> Bool) -> Bool
    fileprivate let containsOutputs: ((_ fileExtension: String?, _ basename: String) -> Bool) -> Bool
    fileprivate let isExplicitModuleJob: () -> Bool

    fileprivate init(_ job: SwiftDriverJob) {
        ruleInfoType = { job.ruleInfoType }
        containsInputs = { block in
            job.inputs.contains(where: { path in
                block(path.fileExtension, path.basename)
            })
        }
        containsOutputs = { block in
            job.outputs.contains(where: { path in
                block(path.fileExtension, path.basename)
            })
        }
        isExplicitModuleJob = {
            switch job.kind {
            case .explicitModule: return true
            case .target: return false
            }
        }
    }

    fileprivate init(_ job: SwiftDriver.Job) {
        ruleInfoType = { job.kind.rawValue.capitalized.replacingOccurrences(of: "-", with: "") }
        containsInputs = { block in
            job.inputs.contains { path in
                block(path.file.extension, path.file.basenameWithoutExt)
            }
        }
        containsOutputs = { block in
            job.outputs.contains { path in
                block(path.file.extension, path.file.basenameWithoutExt)
            }
        }
        isExplicitModuleJob = {
            switch job.kind {
            case .generatePCM, .compileModuleFromInterface: return true
            default: return false
            }
        }
    }
}

public extension SwiftDriverJobCategorizer {
    var isExplicitDependencyBuild: Bool {
        isExplicitModuleJob()
    }

    var isEmitModule: Bool {
        containsInputs { ext, _ in ext == "swift" } &&
        containsOutputs { ext, basename in ext == "swiftmodule" && !basename.contains("~partial") }
    }

    var isCompile: Bool {
        // Compile jobs may not contain .o file if build for IS_ZIPPERED
        containsInputs { ext, _ in ext == "swift" } &&
        containsOutputs { ext, _ in ext == "d" || ext == "o" }
    }

    var isGeneratePch: Bool {
        containsInputs { ext, _ in ext == "h" } &&
        containsOutputs { ext, _ in ext == "pch" }
    }

    // FIXME: Track the SwiftDriver.Job.Kind of SWBCore.SwiftDriverJobs that are not for explicit modules, and use that to classify verification tasks.
    private static let moduleInterfaceVerificationRuleInfoType = "VerifyEmittedModuleInterface"
    var isVerification: Bool {
        ruleInfoType() == Self.moduleInterfaceVerificationRuleInfoType
    }

    var priority: TaskPriority {
        if isExplicitDependencyBuild || isEmitModule || isGeneratePch {
            return .unblocksDownstreamTasks
        } else {
            return .unspecified
        }
    }
}

public extension SwiftDriverJob {
    var categorizer: SwiftDriverJobCategorizer {
        .init(self)
    }
}

private extension Array {
    func grouped(by conditionsInOrder: [(Element) -> Bool]) throws -> [[Element]] {
        var result: [[Element]] = .init(repeating: [], count: conditionsInOrder.count)
    arrayLoop:
        for element in self {
            for (index, condition) in conditionsInOrder.enumerated() {
                if condition(element) {
                    result[index].append(element)
                    continue arrayLoop
                }
            }
            throw StubError.error("Non of given conditions matches element \(element)")
        }
        return result
    }
}
