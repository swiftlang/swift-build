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

import Foundation

import SwiftDriver
import SwiftOptions
import TSCBasic

public import SWBUtil

public protocol SwiftGlobalExplicitDependencyGraph : AnyObject {
    /// Register a collection of driver jobs in the graph, de-duplicating them in the process
    /// - Parameters:
    ///   - jobs: A collection of explicit-dependency build jobs from a given Swift Driver invocation
    ///   - producerMap: A map of build products to their producer job
    /// - Returns: A set of `JobKey`s corresponding to the added jobs, either de-duplicated to an existing key already in a graph, or newly-added
    func addExplicitDependencyBuildJobs(_ jobs: [SwiftDriverJob], workingDirectory: Path, producerMap: inout [Path: LibSwiftDriver.JobKey]) throws -> Set<LibSwiftDriver.JobKey>

    /// Query all explicit dependency build jobs corresponding to a collection of keys
    /// - Parameters:
    ///    - keys: A collection of keys to query their corresponding `PlannedSwiftDriverJob` values
    /// - Returns: An array of `PlannedSwiftDriverJob` values corresponding to the query keys
    func getExplicitDependencyBuildJobs(for keys: [LibSwiftDriver.JobKey]) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob]

    /// Query a specific explicit dependency build jobs corresponding to a provided key
    /// - Parameters:
    ///    - key: A single `JobKey` for which to query the existence of a corresponding `PlannedSwiftDriverJob`
    /// - Returns: An optional `PlannedSwiftDriverJob` corresponding to the key. `nil` if no such job has been registered with the graph
    func plannedExplicitDependencyBuildJob(for key: LibSwiftDriver.JobKey) -> LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob?

    /// Query all job dependencies of a given explicit dependency-build `PlannedSwiftDriverJob`.
    /// Only other explicit dependency build jobs can be dependencies of such a job, so they can all be resolved by this query.
    /// - Parameters:
    ///    - job: `PlannedSwiftDriverJob` whose dependencies are queried
    /// - Returns: A collection of `PlannedSwiftDriverJob`s that produce values depended on by the `job` parameter Job.
    func explicitDependencies(for job: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob]
}

/// Keeps track of all of the explicit module dependency build jobs as depended on by individual target builds
private struct GlobalExplicitDependencyTracker {
    /// Maps a SwiftDriverJob's UniqueID to its index in this store
    private var uniqueIndexMap: [Int: Int] = [:]

    /// The collection of *all* explicit module dependency build jobs found so far
    fileprivate private(set) var plannedExplicitDependencyJobs: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] = []

    mutating func addExplicitDependencyBuildJobs(_ jobs: [SwiftDriverJob], workingDirectory: Path,
                                                 producerMap: inout [Path: LibSwiftDriver.JobKey]) throws -> Set<LibSwiftDriver.JobKey> {
        // Filter out "new" unique jobs and populate the `producerMap`
        var jobKeys: Set<LibSwiftDriver.JobKey> = []
        var jobsWithIndices: [(SwiftDriverJob, LibSwiftDriver.JobIndex)] = []
        for job in jobs {
            guard case let .explicitModule(uniqueID) = job.kind else {
                throw StubError.error("Unexpected job in explicit module builds: \(job.descriptionForLifecycle).")
            }
            let trackerIndex: Int
            if let existingIndex = uniqueIndexMap[uniqueID] {
                trackerIndex = existingIndex
                jobKeys.insert(LibSwiftDriver.JobKey.explicitDependencyJob(trackerIndex))
            } else {
                trackerIndex = plannedExplicitDependencyJobs.endIndex + jobsWithIndices.count
                jobsWithIndices.append((job, trackerIndex))
            }
            try LibSwiftDriver.PlannedBuild.addProducts(of: job, index: .explicitDependencyJob(trackerIndex), knownJobs: [], to: &producerMap)
        }

        // Once the producerMap has been populated, create the actual PlannedDriverJobs
        for (job, trackerIndex) in jobsWithIndices {
            guard case let .explicitModule(uniqueID) = job.kind else {
                throw StubError.error("Unexpected job in explicit module builds: \(job.descriptionForLifecycle).")
            }
            let jobKey = LibSwiftDriver.JobKey.explicitDependencyJob(trackerIndex)
            let inputs = job.inputs.compactMap { producerMap[$0] }
            let dependencies = Set(inputs).sorted()
            let plannedJob = LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob(key: jobKey, driverJob: job, dependencies: dependencies, workingDirectory: workingDirectory)
            assert(trackerIndex == plannedExplicitDependencyJobs.endIndex)
            plannedExplicitDependencyJobs.append(plannedJob)
            uniqueIndexMap[uniqueID] = trackerIndex
            jobKeys.insert(jobKey)
        }

        assert(jobKeys.count == jobs.count)
        return jobKeys
    }

    func getExplicitDependencyBuildJobs(for keys: [LibSwiftDriver.JobKey]) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] {
        var jobs: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] = []
        for key in keys {
            guard case .explicitDependencyJob(let index) = key else {
                assertionFailure("Unexpectedly found a regular job in 'plannedExplicitDependencyJobs'")
                continue
            }
            guard plannedExplicitDependencyJobs.indices.contains(index) else {
                assertionFailure("Unexpectedly found an out of bounds job index into 'plannedExplicitDependencyJobs'")
                continue
            }
            let job = plannedExplicitDependencyJobs[index]
            assert(job.key == key)
            jobs.append(job)
        }
        return jobs
    }

    public func plannedExplicitDependencyBuildJob(for key: LibSwiftDriver.JobKey) -> LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob? {
        let jobs = getExplicitDependencyBuildJobs(for: [key])
        return jobs.first
    }

    func explicitDependencies(for job: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] {
        return job.dependencies.compactMap(plannedExplicitDependencyBuildJob(for:))
    }
}

/// Build wide graph used to plan a module build
public final class SwiftModuleDependencyGraph: SwiftGlobalExplicitDependencyGraph {
    /// The key to oracle registry for swift dependency scanning
    struct OracleRegistryKey: Hashable {
        let compilerLocation: LibSwiftDriver.CompilerLocation
        let casOpts: CASOptions?
    }
    let oracleRegistry: Registry<OracleRegistryKey, InterModuleDependencyOracle> = .init()

    private let registryQueue = SWBQueue(label: "SwiftModuleDependencyGraph", autoreleaseFrequency: .workItem)
    private var registry: [String: LibSwiftDriver] = [:]
    private var globalExplicitDependencyTracker = GlobalExplicitDependencyTracker()

    public init() {}

    public func waitForCompletion() async {
        await registryQueue.sync { }
    }

    /// Plans a build and stores it for a given unique identifier.
    /// - Parameters:
    ///   - key: ID that will be used to store the planned build uniquely. Needs to be equal for the `queryPlannedBuild` call.
    ///   - outputDelegate: Delegate to output driver's diagnostics to
    ///   - compilerPath: The absolute path to the compiler binary (to base other tools on)
    ///   - target: The target that gets build
    ///   - args: The whole command line invocation for the module
    ///   - workingDirectory: The directory which should be used as a working directory for the invocation to resolve relative paths
    ///   - tempDirPath: The directory which should be used to output modules
    ///   - environment: The environment to use for executing jobs
    ///   - eagerCompilationEnabled: Flag to indicate state of eager compilation in Swift
    ///   - casOptions: The CAS configuration option and `nil` if no CAS is needed
    /// - Returns: `true` if the build was successfully planned, `false` otherwise
    public func planBuild(key: String, outputDelegate: any DiagnosticProducingDelegate, compilerLocation: LibSwiftDriver.CompilerLocation, target: ConfiguredTarget, args: [String], workingDirectory: Path, tempDirPath: Path, explicitModulesTempDirPath: Path, environment: [String: String], eagerCompilationEnabled: Bool, casOptions: CASOptions?) -> Bool {
        let driver = LibSwiftDriver.createAndPlan(for: self, outputDelegate: outputDelegate, compilerLocation: compilerLocation, target: target, workingDirectory: workingDirectory, tempDirPath: tempDirPath, explicitModulesTempDirPath: explicitModulesTempDirPath, commandLine: args, environment: environment, eagerCompilationEnabled: eagerCompilationEnabled, casOptions: casOptions)
        if let driver {
            register(key: key, driver: driver)
            return true
        } else {
            return false
        }
    }

    /// Query a previously planned build
    /// - Parameter key: A unique identifier which was used in the `planBuild` call as uniqueID
    /// - Throws: If build was not planned before, an error will be thrown
    /// - Returns: The driver wrapping instance for the given ID
    /// - Note: This method is thread safe and can be called multiple times on the same object
    public func queryPlannedBuild(for key: String) throws -> LibSwiftDriver.PlannedBuild {
        try registryQueue.blocking_sync {
            guard let driver = registry[key] else {
                throw StubError.error("Unable to find jobs for key \(key). Be sure to plan the build ahead of fetching results.")
            }
            return driver.plannedBuild
        }
    }

    public func querySwiftmodulesNeedingRegistrationForDebugging(for key: String) throws -> [String] {
        let graph = try registryQueue.blocking_sync {
            guard let driver = registry[key] else {
                throw StubError.error("Unable to find jobs for key \(key). Be sure to plan the build ahead of fetching results.")
            }
            return driver.intermoduleDependencyGraph
        }
        guard let graph else { return [] }
        var swiftmodulePaths: [String] = []
        swiftmodulePaths.reserveCapacity(graph.modules.values.count)
        for (_, moduleInfo) in graph.modules.sorted(byKey: { $0.moduleName < $1.moduleName }) {
            guard moduleInfo != graph.mainModule else {
                continue
            }
            switch moduleInfo.details {
            case .swift:
                if let modulePath = VirtualPath.lookup(moduleInfo.modulePath.path).absolutePath {
                    swiftmodulePaths.append(modulePath.pathString)
                }
            case .swiftPrebuiltExternal(let details):
                if let modulePath = VirtualPath.lookup(details.compiledModulePath.path).absolutePath {
                    swiftmodulePaths.append(modulePath.pathString)
                }
            case .clang, .swiftPlaceholder:
                break
            }
        }
        return swiftmodulePaths
    }

    public func queryPlanningDependencies(for key: String) throws -> [String] {
        let graph = try registryQueue.blocking_sync {
            guard let driver = registry[key] else {
                throw StubError.error("Unable to find jobs for key \(key). Be sure to plan the build ahead of fetching results.")
            }
            return driver.intermoduleDependencyGraph
        }
        guard let graph else { return [] }
        var fileDependencies: [String] = []
        fileDependencies.reserveCapacity(graph.modules.values.count * 10)
        for (_, moduleInfo) in graph.modules.sorted(byKey: { $0.moduleName < $1.moduleName }) {
            guard moduleInfo != graph.mainModule else {
                continue
            }
            fileDependencies.append(contentsOf: moduleInfo.sourceFiles ?? [])
            switch moduleInfo.details {
            case .swift:
                break
            case .swiftPlaceholder:
                break
            case .swiftPrebuiltExternal(let details):
                if let modulePath = VirtualPath.lookup(details.compiledModulePath.path).absolutePath {
                    fileDependencies.append(modulePath.pathString)
                }
            case .clang:
                break
            }
        }
        return fileDependencies
    }

    public func queryTransitiveDependencyModuleNames(for key: String) throws -> [String] {
        let graph = try registryQueue.blocking_sync {
            guard let driver = registry[key] else {
                throw StubError.error("Unable to find jobs for key \(key). Be sure to plan the build ahead of fetching results.")
            }
            return driver.intermoduleDependencyGraph
        }
        guard let graph else { return [] }
        // This calculation is a bit awkward because we cannot directly access the ID of the main module, just its info object
        let directDependencies = graph.mainModule.directDependencies ?? []
        let transitiveDependencies = Set(directDependencies + SWBUtil.transitiveClosure(directDependencies, successors: { moduleID in graph.modules[moduleID]?.directDependencies ?? [] }).0)
        return transitiveDependencies.map(\.moduleName)
    }

    /// Serialize incremental build state for the given key and removes its state from memory
    public func cleanUpForAllKeys() {
        registryQueue.async {
            for driver in self.registry.values {
                driver.writeIncrementalBuildInformation()
            }
            self.registry.removeAll()
        }
    }

    /// Serialize incremental build state for the given key and removes its state from memory
    public func cleanUp(key: String) {
        registryQueue.async {
            if let driver = self.registry.removeValue(forKey: key) {
                driver.writeIncrementalBuildInformation()
            }
        }
    }

    /// Get the CASDatabases from the casOptions
    public func getCASDatabases(casOptions: CASOptions?, compilerLocation: LibSwiftDriver.CompilerLocation) throws -> SwiftCASDatabases? {
        guard let casOpts = casOptions else { return nil }
        return try createCASDatabases(casOptions: casOpts, compilerLocation: compilerLocation)
    }

    private func register(key: String, driver: LibSwiftDriver) {
        registryQueue.async {
            self.registry[key] = driver
        }
    }

    public func addExplicitDependencyBuildJobs(_ jobs: [SwiftDriverJob], workingDirectory: Path,
                                               producerMap: inout [Path: LibSwiftDriver.JobKey]) throws -> Set<LibSwiftDriver.JobKey> {
        try registryQueue.blocking_sync {
            try globalExplicitDependencyTracker.addExplicitDependencyBuildJobs(jobs, workingDirectory: workingDirectory, producerMap: &producerMap)
        }
    }
    public func getExplicitDependencyBuildJobs(for keys: [LibSwiftDriver.JobKey]) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] {
        registryQueue.blocking_sync {
            globalExplicitDependencyTracker.getExplicitDependencyBuildJobs(for: keys)
        }
    }
    public func plannedExplicitDependencyBuildJob(for key: LibSwiftDriver.JobKey) -> LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob? {
        registryQueue.blocking_sync {
            globalExplicitDependencyTracker.plannedExplicitDependencyBuildJob(for: key)
        }
    }
    public func explicitDependencies(for job: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob) -> [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob] {
        registryQueue.blocking_sync {
            globalExplicitDependencyTracker.explicitDependencies(for: job)
        }
    }

    public var isEmpty: Bool {
        registryQueue.blocking_sync {
            globalExplicitDependencyTracker.plannedExplicitDependencyJobs.isEmpty
        }
    }

    public func generatePrecompiledModulesReport(in directory: Path, fs: any FSProxy) async throws -> String {
        // Collect DependencyInfo of every module built during the current build.
        var jobsByModuleID: [String: [SwiftDriverJob]] = [:]
        for job in globalExplicitDependencyTracker.plannedExplicitDependencyJobs {
            let qualifier: String
            switch job.driverJob.ruleInfoType {
            case "CompileModuleFromInterface":
                qualifier = "(Swift)"
            case "GeneratePcm":
                qualifier = "(Clang)"
            default:
                qualifier = "(Unknown)"
            }
            jobsByModuleID["\(job.driverJob.moduleName) \(qualifier)", default: []].append(job.driverJob)
        }

        var summaryCSV = CSVBuilder()
        summaryCSV.writeRow(["Name", "Variants"])
        var summaryMessage = ""

        for (moduleID, jobs) in jobsByModuleID.sorted(by: \.0) {
            summaryCSV.writeRow([moduleID, "\(jobs.count)"])
            summaryMessage += "\(moduleID): \(jobs.count == 1 ? "1 variant" : "\(jobs.count) variants")\n"

            let mergeResult = nWayMerge(jobs.map { $0.commandLine.filter {
                if ["pcm", "dia", "d"].contains(Path($0).fileExtension) {
                    // Filter differences in module paths, they are a function of the other args
                    return false
                } else if $0.hasPrefix("llvmcas://") {
                    // Filter differences in CAS URLs, they are a function of the other args
                    return false
                } else {
                    return true
                }
            }.map { $0.asString } }).filter {
                if $0.elementOf.count == jobs.count {
                    // Don't report args common to all variants
                    return false
                } else {
                    return true
                }
            }

            var moduleCSV = CSVBuilder()
            moduleCSV.writeRow(["Variant"] + mergeResult.map(\.element))

            for (idx, job) in jobs.enumerated() {
                let jobID = job.outputs.only?.basename ?? "Unknown"
                var checkboxes: [String] = []
                for mergeElement in mergeResult {
                    if mergeElement.elementOf.contains(idx) {
                        checkboxes.append("✅")
                    } else {
                        checkboxes.append("❌")
                    }
                }
                moduleCSV.writeRow([jobID] + checkboxes)
            }

            try fs.write(directory.join("\(moduleID).csv"), contents: ByteString(encodingAsUTF8: moduleCSV.output))
        }
        try fs.write(directory.join("Summary.csv"), contents: ByteString(encodingAsUTF8: summaryCSV.output))
        summaryMessage += "\nFull report written to '\(directory.str)'"
        return summaryMessage
    }
}

class Executor: DriverExecutor {
    let resolver: ArgsResolver
    let explicitModulesResolver: ArgsResolver
    let fileSystem: any FileSystem
    let env: [String: String]
    let eagerCompilationEnabled: Bool
    private(set) weak var explicitDependencyGraph: (any SwiftGlobalExplicitDependencyGraph)?
    let workingDirectory: Path

    private var plannedBuild: LibSwiftDriver.PlannedBuild?

    init(resolver: ArgsResolver, explicitModulesResolver: ArgsResolver, explicitDependencyGraph: (any SwiftGlobalExplicitDependencyGraph)?, workingDirectory: Path, fileSystem: any FileSystem, env: [String: String], eagerCompilationEnabled: Bool) {
        self.resolver = resolver
        self.explicitModulesResolver = explicitModulesResolver
        self.explicitDependencyGraph = explicitDependencyGraph
        self.fileSystem = fileSystem
        self.env = env
        self.eagerCompilationEnabled = eagerCompilationEnabled
        self.workingDirectory = workingDirectory
    }

    func execute(job: Job, forceResponseFiles: Bool, recordedInputModificationDates: [TypedVirtualPath : TimePoint]) throws -> ProcessResult {
        let useResponseFiles : ResponseFileHandling = forceResponseFiles ? .forced : .heuristic
        let arguments: [String] = try resolver.resolveArgumentList(for: job,
                                                                   useResponseFiles: useResponseFiles)

        try job.verifyInputsNotModified(since: recordedInputModificationDates, fileSystem: fileSystem)

        if job.requiresInPlaceExecution {
            for (envVar, value) in job.extraEnvironment {
                try ProcessEnv.setVar(envVar, value: value)
            }

            try exec(path: arguments[0], args: arguments)
        } else {
            var childEnv = env
            childEnv.merge(job.extraEnvironment, uniquingKeysWith: { (_, new) in new })

            let process = try Process.launchProcess(arguments: arguments, env: childEnv)
            return try process.waitUntilExit()
        }
    }

    func execute(workload: DriverExecutorWorkload, delegate: any JobExecutionDelegate, numParallelJobs: Int, forceResponseFiles: Bool, recordedInputModificationDates: [TypedVirtualPath : TimePoint]) throws {
        guard self.plannedBuild == nil else {
            throw StubError.error("Unexpected extra workload from Swift driver.")
        }
        self.plannedBuild = try LibSwiftDriver.PlannedBuild(workload: workload, argsResolver: self.resolver, explicitModulesResolver: self.explicitModulesResolver, jobExecutionDelegate: delegate, globalExplicitDependencyJobGraph: explicitDependencyGraph, workingDirectory: workingDirectory, eagerCompilationEnabled: eagerCompilationEnabled)
    }

    func checkNonZeroExit(args: String..., environment: [String : String]) throws -> String {
        try Process.checkNonZeroExit(arguments: args, environmentBlock: .init(environment))
    }

    /// Moves the ownership of the plannedBuild to the caller and clears internal state.
    func movePlannedBuild() -> LibSwiftDriver.PlannedBuild? {
        let plannedBuild = self.plannedBuild
        self.plannedBuild = nil
        return plannedBuild
    }

    func description(of job: Job, forceResponseFiles: Bool) throws -> String {
        let ruleInfoType = job.kind.rawValue.capitalized
        let moduleName = job.moduleName
        let inputs = job.displayInputs.map(\.file.basename)
        return ([ruleInfoType, moduleName] + inputs).joined(separator: " ")
    }
}

/// The class that wraps the Swift driver and provides a namespace for PlannedBuild
public final class LibSwiftDriver {
    public typealias JobIndex = Int
    /// Type to fetch dependencies of planned jobs
    public enum JobKey : Comparable, Hashable, Serializable {
        case explicitDependencyJob(_ index: JobIndex)
        case targetJob(_ index: JobIndex)

        public func serialize<T>(to serializer: T) where T : Serializer {
            serializer.beginAggregate(2)
            switch self {
                case .explicitDependencyJob(let index):
                    serializer.serialize(0)
                    serializer.serialize(index)
                case .targetJob(let index):
                    serializer.serialize(1)
                    serializer.serialize(index)
            }
            serializer.endAggregate()
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            let code: Int = try deserializer.deserialize()
            switch code {
                case 0:
                    let index: JobIndex = try deserializer.deserialize()
                    self = .explicitDependencyJob(index)
                case 1:
                    let index: JobIndex = try deserializer.deserialize()
                    self = .targetJob(index)
                default:
                    throw DeserializerError.incorrectType("Unexpected type code for LibSwiftDriver.JobKey: \(code)")
            }
        }
    }

    public enum CompilerLocation: SerializableCodable, CustomStringConvertible, Hashable, Sendable {
        case path(Path)
        case library(libSwiftScanPath: Path)

        public var compilerOrLibraryPath: Path {
            switch self {
            case .path(let path):
                return path
            case .library(let path):
                return path
            }
        }

        public var description: String {
            switch self {
            case .path(let path):
                return path.str
            case .library:
                return "library"
            }
        }
    }

    /// The target this build is part of
    public let target: ConfiguredTarget?
    /// The directory which gets used to resolve relative paths
    public let workingDirectory: Path
    /// The directory which gets used to store modules
    public let tempDirPath: Path
    /// The command line to build the module
    public let commandLine: [String]
    /// Indicates if the driver will create jobs for emitting modules which unblock downstream targets
    public let eagerCompilationEnabled: Bool
    /// Compiler location for the build
    public let compilerLocation: CompilerLocation

    private let resolver: ArgsResolver
    private let explicitModulesResolver: ArgsResolver
    private let executor: Executor
    private var driver: SwiftDriver.Driver
    private let diagnosticsEngine: TSCBasic.DiagnosticsEngine

    private var _plannedBuild: PlannedBuild?

    public var plannedBuild: PlannedBuild {
        if let build = _plannedBuild {
            return build
        }
        // If the executor has no planned build at this stage, there were no jobs to execute
        return try! PlannedBuild(workload: .all([]), argsResolver: self.resolver, explicitModulesResolver: self.explicitModulesResolver, jobExecutionDelegate: nil, globalExplicitDependencyJobGraph: nil, workingDirectory: workingDirectory, eagerCompilationEnabled: self.eagerCompilationEnabled)
    }

    var intermoduleDependencyGraph: InterModuleDependencyGraph?

    private init(graph: SwiftModuleDependencyGraph?, compilerLocation: CompilerLocation, target: ConfiguredTarget?, workingDirectory: Path, tempDirPath: Path, explicitModulesTempDirPath: Path, commandLine: [String], environment: [String: String], eagerCompilationEnabled: Bool, diagnosticsEngine: TSCBasic.DiagnosticsEngine, casOptions: CASOptions?) throws {
        self.target = target
        self.workingDirectory = workingDirectory
        self.tempDirPath = tempDirPath
        self.commandLine = commandLine
        self.compilerLocation = compilerLocation

        // Public API should not expose SwiftDriver types so do the mapping here.
        self.eagerCompilationEnabled = eagerCompilationEnabled
        // rdar://91153940 Inject file system, diagnostics engine and environment
        let fileSystem = localFileSystem
        self.resolver = try ArgsResolver(fileSystem: fileSystem, temporaryDirectory: VirtualPath(path: tempDirPath.str))
        self.explicitModulesResolver = try ArgsResolver(fileSystem: fileSystem, temporaryDirectory: VirtualPath(path: explicitModulesTempDirPath.str))
        self.executor = Executor(resolver: resolver, explicitModulesResolver: explicitModulesResolver, explicitDependencyGraph: graph, workingDirectory: workingDirectory, fileSystem: fileSystem, env: environment, eagerCompilationEnabled: eagerCompilationEnabled)
        self.diagnosticsEngine = diagnosticsEngine
        let env: [String: String]
        let compilerExecutableDir: TSCBasic.AbsolutePath?
        switch compilerLocation {
        case .path(let path):
            env = environment
            compilerExecutableDir = try TSCBasic.AbsolutePath(validating: path.dirname.str)
        case .library(libSwiftScanPath: let path):
            // Remove lib/swift/host/lib_InternalSwiftScan.dylib and add bin/swift-frontend to get a fake path to the compiler frontend.
            let fakeFrontendPath = path.dirname.dirname.dirname.dirname.join("bin/swift-frontend")
            env = environment.merging(["SWIFT_DRIVER_SWIFT_FRONTEND_EXEC": fakeFrontendPath.str, "SWIFT_DRIVER_SWIFTSCAN_LIB": path.str], uniquingKeysWith: { first, second in first })
            compilerExecutableDir = try TSCBasic.AbsolutePath(validating: fakeFrontendPath.dirname.str)
        }
        let key = SwiftModuleDependencyGraph.OracleRegistryKey(compilerLocation: compilerLocation, casOpts: casOptions)
        let oracle = graph?.oracleRegistry.getOrInsert(key, { InterModuleDependencyOracle() })
        self.driver = try Driver(args: commandLine, env: env, diagnosticsOutput: .engine(diagnosticsEngine), executor: executor, compilerExecutableDir: compilerExecutableDir, interModuleDependencyOracle: oracle)
        if let scanOracle = oracle, let scanLib = try driver.getSwiftScanLibPath() {
            // Errors instantiating the scanner are potentially recoverable, so suppress them here. Truly fatal errors
            // will be diagnosed later.
            try? scanOracle.verifyOrCreateScannerInstance(swiftScanLibPath: scanLib)
        }
    }

    private func run(dryRun: Bool = false) -> (success: Bool, diagnostics: [SWBUtil.Diagnostic], jobs: [Job]) {
        let driverDiagnostics: () -> [SWBUtil.Diagnostic] = {
            self.driver.diagnosticEngine.diagnostics.map({ .build(from: $0) })
        }

        do {
            let jobs = try driver.planBuild()
            if !dryRun {
                try driver.run(jobs: jobs)
                if let plannedBuild = executor.movePlannedBuild() {
                    _plannedBuild = plannedBuild
                    intermoduleDependencyGraph = driver.intermoduleDependencyGraph
                } else {
                    throw StubError.error("Swift driver build planning failed")
                }
            }
            return (true, driverDiagnostics(), jobs)
        } catch {
            let fallbackDiagnostics: [SWBUtil.Diagnostic]
            if driver.diagnosticEngine.hasErrors {
                #if canImport(os)
                OSLog.log("Driver threw error \(error) but emitted errors to build log.")
                #endif
                fallbackDiagnostics = []
            } else {
                fallbackDiagnostics = [SWBUtil.Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData(error.localizedDescription, component: .swiftCompilerError))]
            }
            return (false, fallbackDiagnostics + driverDiagnostics(), [])
        }
    }

    /// Serialize this driver's incremental build state
    public func writeIncrementalBuildInformation() {
        driver.writeIncrementalBuildInformation(plannedBuild.driverTargetJobs)
    }

    static func frontendCommandLine(outputDelegate: any DiagnosticProducingDelegate, compilerLocation: CompilerLocation, inputPath: Path, workingDirectory: Path, tempDirPath: Path, explicitModulesTempDirPath: Path, commandLine: [String], environment: [String: String], eagerCompilationEnabled: Bool, casOptions: CASOptions?) -> [String]? {
        let diagnosticsEngine = TSCBasic.DiagnosticsEngine(handlers: [Driver.stderrDiagnosticsHandler])
        do {
            let shim = try LibSwiftDriver(graph: nil, compilerLocation: compilerLocation, target: nil, workingDirectory: workingDirectory, tempDirPath: tempDirPath, explicitModulesTempDirPath: explicitModulesTempDirPath, commandLine: commandLine, environment: environment, eagerCompilationEnabled: eagerCompilationEnabled, diagnosticsEngine: diagnosticsEngine, casOptions: casOptions)
            let (success, diagnostics, jobs) = shim.run(dryRun: true)
            for diagnostic in diagnostics {
                outputDelegate.emit(diagnostic)
            }
            if !success {
                return nil
            }
            do {
                guard let job = jobs.filter({ job in
                    job.primarySwiftSourceFiles.contains(where: { $0.typedFile.file.absolutePath?.pathString == inputPath.str })
                }).only else {
                    return nil
                }
                return try shim.resolver.resolveArgumentList(for: job, useResponseFiles: .heuristic)
            }
        } catch {
            for diagnostic in diagnosticsEngine.diagnostics.map({ SWBUtil.Diagnostic.build(from: $0) }) {
                outputDelegate.emit(diagnostic)
            }

            if diagnosticsEngine.hasErrors {
                #if canImport(os)
                OSLog.log("Driver threw error \(error) but emitted errors to build log.")
                #endif
            } else {
                outputDelegate.error("Driver threw \(error) without emitting errors.")
            }
            return nil
        }
    }

    fileprivate static func createAndPlan(for graph: SwiftModuleDependencyGraph, outputDelegate: any DiagnosticProducingDelegate, compilerLocation: CompilerLocation, target: ConfiguredTarget, workingDirectory: Path, tempDirPath: Path, explicitModulesTempDirPath: Path, commandLine: [String], environment: [String: String], eagerCompilationEnabled: Bool, casOptions: CASOptions?) -> LibSwiftDriver? {
        let diagnosticsEngine = TSCBasic.DiagnosticsEngine(handlers: [Driver.stderrDiagnosticsHandler])

        do {
            let shim = try LibSwiftDriver(graph: graph, compilerLocation: compilerLocation, target: target, workingDirectory: workingDirectory, tempDirPath: tempDirPath, explicitModulesTempDirPath: explicitModulesTempDirPath, commandLine: commandLine, environment: environment, eagerCompilationEnabled: eagerCompilationEnabled, diagnosticsEngine: diagnosticsEngine, casOptions: casOptions)
            let (success, diagnostics, _) = shim.run()
            for diagnostic in diagnostics {
                outputDelegate.emit(diagnostic)
            }
            guard success, !diagnosticsEngine.hasErrors else {
                return nil
            }
            return shim
        } catch {
            for diagnostic in diagnosticsEngine.diagnostics.map({ SWBUtil.Diagnostic.build(from: $0) }) {
                outputDelegate.emit(diagnostic)
            }

            if diagnosticsEngine.hasErrors {
                #if canImport(os)
                OSLog.log("Driver threw error \(error) but emitted errors to build log.")
                #endif
            } else {
                outputDelegate.error("Driver threw \(error) without emitting errors.")
            }
            return nil
        }
    }
}

extension LibSwiftDriver {
    static let supportedOptionSpellings = Set(SwiftOptions.Option.allOptions.map(\.spelling))
    public static func supportsDriverFlag(spelled spelling: String) -> Bool {
        Self.supportedOptionSpellings.contains(spelling)
    }
}

// MARK: Wrappers for SwiftDriver CAS types

extension SwiftModuleDependencyGraph {
    /// Create the CASDatabases from CASOptions
    private func createCASDatabases(casOptions: CASOptions, compilerLocation: LibSwiftDriver.CompilerLocation) throws -> SwiftCASDatabases {
        func toAbsolutePath(_ path: String?) throws -> TSCBasic.AbsolutePath? {
            guard let path else { return nil }
            return try AbsolutePath(validating: path)
        }
        var pluginOpts = [(String, String)]()
        if casOptions.hasRemoteCache, let servicePath = casOptions.remoteServicePath {
            pluginOpts.append(("remote-service-path", servicePath.str))
        }
        let key = SwiftModuleDependencyGraph.OracleRegistryKey(compilerLocation: compilerLocation, casOpts: casOptions)
        guard let oracle = oracleRegistry[key] else {
            throw StubError.error("can't find created dependency scanning oracle from compiler location \(compilerLocation)")
        }
        let cas = try oracle.getOrCreateCAS(pluginPath: try toAbsolutePath(casOptions.pluginPath?.str),
                                            onDiskPath: try toAbsolutePath(casOptions.casPath.str),
                                            pluginOptions: pluginOpts)
        return SwiftCASDatabases(cas)
    }
}

/// SwiftCachedCompilation wraps CachedCompilation from SwiftDriver
public final class SwiftCachedCompilation {
    let cachedCompilation: CachedCompilation
    public let key: String
    init(_ cachedCompilation: CachedCompilation, key: String) {
        self.cachedCompilation = cachedCompilation
        self.key = key
    }

    public var outputsCount: UInt32 {
        cachedCompilation.count
    }
    public var isUncacheable: Bool {
        cachedCompilation.isUncacheable
    }

    public func getOutputs() throws -> [SwiftCachedOutput] {
        try cachedCompilation.map {
            try SwiftCachedOutput($0)
        }
    }

    public func makeGlobal() async throws {
        try await cachedCompilation.makeGlobal()
    }

    public func makeGlobal(_ callback: @escaping ((any Swift.Error)?) -> Void) {
        cachedCompilation.makeGlobal(callback)
    }
}

/// SwiftCachedOutput wraps CachedOutput from SwiftDriver
public final class SwiftCachedOutput {
    let cachedOutput: CachedOutput

    public let casID: String
    public let kindName: String

    init(_ cachedOutput: CachedOutput) throws {
        self.cachedOutput = cachedOutput
        self.casID = try cachedOutput.getCASID()
        self.kindName = try cachedOutput.getOutputKindName()
    }

    public var isMaterialized: Bool {
        cachedOutput.isMaterialized
    }
    public func load() async throws -> Bool {
        try await cachedOutput.load()
    }
}

/// SwiftCacheReplayInstance wraps CacheReplayInstance from SwiftDriver
public final class SwiftCacheReplayInstance {
    let cacheReplayInstance: CacheReplayInstance
    init(_ cacheReplayInstance: CacheReplayInstance) {
        self.cacheReplayInstance = cacheReplayInstance
    }
}

/// SwiftCacheReplayResult wraps CacheReplayResult from SwiftDriver
public final class SwiftCacheReplayResult {
    let cacheReplayResult: CacheReplayResult
    init(_ cacheReplayResult: CacheReplayResult) {
        self.cacheReplayResult = cacheReplayResult
    }

    public func getStdOut() throws -> String {
        try self.cacheReplayResult.getStdOut()
    }
    public func getStdErr() throws -> String {
        try self.cacheReplayResult.getStdErr()
    }
}

/// SwiftCASDatabases wraps SwiftScanCAS that provides a CAS database interface
public final class SwiftCASDatabases {
    let cas: SwiftScanCAS
    init(_ cas: SwiftScanCAS) {
        self.cas = cas
    }

    public var supportsSizeManagement: Bool { cas.supportsSizeManagement }

    public func getStorageSize() throws -> Int64? { try cas.getStorageSize() }

    public func setSizeLimit(_ size: Int64) throws { try cas.setSizeLimit(size) }

    public func prune() throws { try cas.prune() }

    public func queryCacheKey(_ key: String, globally: Bool) async throws -> SwiftCachedCompilation? {
        guard let comp = try await cas.queryCacheKey(key, globally: globally) else { return nil }
        return SwiftCachedCompilation(comp, key: key)
    }

    /// synchronized query local cache only.
    public func queryLocalCacheKey(_ key: String) throws -> SwiftCachedCompilation? {
        guard let comp = try cas.queryCacheKey(key, globally: false) else { return nil }
        return SwiftCachedCompilation(comp, key: key)
    }

    public func createReplayInstance(cmd: [String]) throws -> SwiftCacheReplayInstance {
        return SwiftCacheReplayInstance(try cas.createReplayInstance(commandLine: cmd))
    }

    public func replayCompilation(instance: SwiftCacheReplayInstance, compilation: SwiftCachedCompilation) throws -> SwiftCacheReplayResult {
        return SwiftCacheReplayResult(try cas.replayCompilation(instance: instance.cacheReplayInstance, compilation: compilation.cachedCompilation))
    }

    public func download(with id: String) async throws -> Bool {
        return try await cas.download(with: id)
    }
}

extension SWBUtil.Diagnostic {
    fileprivate static func build(from other: TSCBasic.Diagnostic) -> Self {
        let location: SWBUtil.Diagnostic.Location
        if let scannerLocation = other.location as? ScannerDiagnosticSourceLocation {
            location = .path(Path(scannerLocation.bufferIdentifier), line: scannerLocation.lineNumber, column: scannerLocation.columnNumber)
        } else {
            location = .unknown
        }
        return SWBUtil.Diagnostic(behavior: .build(from: other.behavior), location: location, data: DiagnosticData(other.message.text, component: .swiftCompilerError))
    }
}

extension SWBUtil.Diagnostic.Behavior {
    fileprivate static func build(from other: TSCBasic.Diagnostic.Behavior) -> Self {
        switch other {
        case .error:
            return .error
        case .warning:
            return .warning
        case .note:
            return .note
        case .remark:
            return .remark
        case .ignored:
            return .ignored
        }
    }
}
