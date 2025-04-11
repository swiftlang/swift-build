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

import SWBCore
import SWBProtocol
public import SWBUtil

public struct SwiftDriverJobTaskKey: Serializable, CustomDebugStringConvertible {
    let identifier: String
    let variant: String
    let arch: String
    let driverJobKey: LibSwiftDriver.JobKey
    let driverJobSignature: ByteString
    let isUsingWholeModuleOptimization: Bool
    let compilerLocation: LibSwiftDriver.CompilerLocation
    let casOptions: CASOptions?

    init(identifier: String, variant: String, arch: String, driverJobKey: LibSwiftDriver.JobKey, driverJobSignature: ByteString, isUsingWholeModuleOptimization: Bool, compilerLocation: LibSwiftDriver.CompilerLocation, casOptions: CASOptions?) {
        self.identifier = identifier
        self.variant = variant
        self.arch = arch
        self.driverJobKey = driverJobKey
        self.driverJobSignature = driverJobSignature
        self.isUsingWholeModuleOptimization = isUsingWholeModuleOptimization
        self.compilerLocation = compilerLocation
        self.casOptions = casOptions
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(8) {
            serializer.serialize(identifier)
            serializer.serialize(variant)
            serializer.serialize(arch)
            serializer.serialize(driverJobKey)
            serializer.serialize(driverJobSignature)
            serializer.serialize(isUsingWholeModuleOptimization)
            serializer.serialize(compilerLocation)
            serializer.serialize(casOptions)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(8)
        identifier = try deserializer.deserialize()
        variant = try deserializer.deserialize()
        arch = try deserializer.deserialize()
        driverJobKey = try deserializer.deserialize()
        driverJobSignature = try deserializer.deserialize()
        isUsingWholeModuleOptimization = try deserializer.deserialize()
        compilerLocation = try deserializer.deserialize()
        casOptions = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<SwiftDriverJob identifier=\(identifier) arch=\(arch) variant=\(variant) jobKey=\(driverJobKey) jobSignature=\(driverJobSignature) isUsingWholeModuleOptimization=\(isUsingWholeModuleOptimization) compilerLocation=\(compilerLocation) casOptions=\(String(describing: casOptions))>"
    }
}

public struct SwiftDriverExplicitDependencyJobTaskKey: Serializable, CustomDebugStringConvertible {
    let arch: String
    let driverJobKey: LibSwiftDriver.JobKey
    let driverJobSignature: ByteString
    let compilerLocation: LibSwiftDriver.CompilerLocation
    let casOptions: CASOptions?

    init(arch: String, driverJobKey: LibSwiftDriver.JobKey, driverJobSignature: ByteString, compilerLocation: LibSwiftDriver.CompilerLocation, casOptions: CASOptions?) {
        self.arch = arch
        self.driverJobKey = driverJobKey
        self.driverJobSignature = driverJobSignature
        self.compilerLocation = compilerLocation
        self.casOptions = casOptions
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(5) {
            serializer.serialize(arch)
            serializer.serialize(driverJobKey)
            serializer.serialize(driverJobSignature)
            serializer.serialize(compilerLocation)
            serializer.serialize(casOptions)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        arch = try deserializer.deserialize()
        driverJobKey = try deserializer.deserialize()
        driverJobSignature = try deserializer.deserialize()
        compilerLocation = try deserializer.deserialize()
        casOptions = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<SwiftDriverExplicitDependencyJob arch=\(arch) jobKey=\(driverJobKey) jobSignature=\(driverJobSignature) compilerLocation=\(compilerLocation) casOptions=\(String(describing: casOptions))>"
    }
}

struct SwiftDriverJobDynamicTaskPayload: TaskPayload {
    let expectedOutputs: [Path]
    let isUsingWholeModuleOptimization: Bool
    let compilerLocation: LibSwiftDriver.CompilerLocation
    let casOptions: CASOptions?

    init(expectedOutputs: [Path], isUsingWholeModuleOptimization: Bool, compilerLocation: LibSwiftDriver.CompilerLocation, casOptions: CASOptions?) {
        self.expectedOutputs = expectedOutputs
        self.isUsingWholeModuleOptimization = isUsingWholeModuleOptimization
        self.compilerLocation = compilerLocation
        self.casOptions = casOptions
    }

    init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.expectedOutputs = try deserializer.deserialize()
        self.isUsingWholeModuleOptimization = try deserializer.deserialize()
        self.compilerLocation = try deserializer.deserialize()
        self.casOptions = try deserializer.deserialize()
    }

    func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(4) {
            serializer.serialize(expectedOutputs)
            serializer.serialize(isUsingWholeModuleOptimization)
            serializer.serialize(compilerLocation)
            serializer.serialize(casOptions)
        }
    }
}

final class SwiftDriverJobDynamicTaskSpec: DynamicTaskSpec {
    func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) throws -> any ExecutableTask {
        let commandLinePrefix: [ByteString] = [
            "builtin-swiftTaskExecution",
            "--"
        ]
        var commandLine: [ByteString]
        let expectedOutputs: [Path]
        let forTarget: ConfiguredTarget?
        let ruleInfo: [String]
        let descriptionForLifecycle: String
        let isUsingWholeModuleOptimization: Bool
        let compilerLocation: LibSwiftDriver.CompilerLocation
        let casOpts: CASOptions?
        switch dynamicTask.taskKey {
            case .swiftDriverJob(let key):
                guard let job = try context.swiftModuleDependencyGraph.queryPlannedBuild(for: key.identifier).plannedTargetJob(for: key.driverJobKey)?.driverJob else {
                    throw StubError.error("Failed to lookup Swift driver job \(key.driverJobKey) in build plan \(key.identifier)")
                }
                commandLine = commandLinePrefix + job.commandLine
                expectedOutputs = job.outputs
                ruleInfo = ["Swift\(job.ruleInfoType)", key.variant, key.arch, job.descriptionForLifecycle] + job.displayInputs.map(\.str)
                forTarget = dynamicTask.target
                descriptionForLifecycle = job.descriptionForLifecycle
                isUsingWholeModuleOptimization = key.isUsingWholeModuleOptimization
                compilerLocation = key.compilerLocation
                casOpts = key.casOptions
            case .swiftDriverExplicitDependencyJob(let key):
                guard let job = context.swiftModuleDependencyGraph.plannedExplicitDependencyBuildJob(for: key.driverJobKey)?.driverJob else {
                    throw StubError.error("Failed to lookup explicit modules Swift driver job \(key.driverJobKey)")
                }
                commandLine = commandLinePrefix + job.commandLine
                expectedOutputs = job.outputs
                assert(expectedOutputs.count > 0, "Explicit modules job was expected to have at least one primary output")
                ruleInfo = ["SwiftExplicitDependency\(job.ruleInfoType)", key.arch, expectedOutputs.first?.str ?? "<unknown>"]
                forTarget = nil
                descriptionForLifecycle = job.descriptionForLifecycle
                // WMO doesn't apply to explicit module builds
                isUsingWholeModuleOptimization = false
                compilerLocation = key.compilerLocation
                casOpts = key.casOptions
            default:
                fatalError("Unexpected dynamic task: \(dynamicTask)")
        }

        if !supportsParseableOutput(for: ruleInfo) {
            commandLine = commandLine.filter({ $0 != "-frontend-parseable-output" })
        }

        return Task(type: self,
                    payload:
                        SwiftDriverJobDynamicTaskPayload(
                            expectedOutputs: expectedOutputs,
                            isUsingWholeModuleOptimization: isUsingWholeModuleOptimization,
                            compilerLocation: compilerLocation,
                            casOptions: casOpts
                        ),
                    forTarget: forTarget,
                    ruleInfo: ruleInfo,
                    commandLine: commandLine.map { .literal($0) },
                    environment: dynamicTask.environment,
                    workingDirectory: dynamicTask.workingDirectory,
                    showEnvironment: dynamicTask.showEnvironment,
                    execDescription: descriptionForLifecycle,
                    preparesForIndexing: true,
                    showCommandLineInLog: false,
                    isDynamic: true
                )
    }

    var payloadType: (any TaskPayload.Type)? {
        SwiftDriverJobDynamicTaskPayload.self
    }

    private func supportsParseableOutput(for ruleInfo: [String]) -> Bool {
        return !(ruleInfo.first?.hasPrefix("SwiftExplicitDependency") ?? false) && !(ruleInfo.first?.hasPrefix("SwiftVerifyEmittedModuleInterface") ?? false)
    }

    func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        if supportsParseableOutput(for: task.ruleInfo) {
            return SwiftCommandOutputParser.self
        } else {
            return serializedDiagnosticsPaths(task).isEmpty ?
                        GenericOutputParser.self :
                        SerializedDiagnosticsOutputParser.self
        }
    }


    func serializedDiagnosticsPaths(_ task: any ExecutableTask) -> [Path] {
        if supportsParseableOutput(for: task.ruleInfo) {
            return []
        }

        guard let payload = task.payload as? SwiftDriverJobDynamicTaskPayload else {
            return []
        }

        return payload.expectedOutputs.filter({ $0.fileExtension == "dia" })
    }

    func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] {
        let expectedDiagnostics = serializedDiagnosticsPaths(task)

        // rdar://91295617 (Swift produces empty serialized diagnostics if there are none which is not parseable by clang_loadDiagnostics)
        return expectedDiagnostics.filter { filePath in
            do {
                let shouldAdd = try fs.exists(filePath) && (try fs.getFileSize(filePath)) > 0
                return shouldAdd
            } catch {
                return false
            }
        }
    }

    func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) throws -> TaskAction {
        switch dynamicTaskKey {
            case .swiftDriverJob(let key):
            guard let job = try context.swiftModuleDependencyGraph.queryPlannedBuild(for: key.identifier).plannedTargetJob(for: key.driverJobKey) else {
                throw StubError.error("Failed to lookup Swift driver job \(key.driverJobKey) in build plan \(key.identifier)")
            }
            return SwiftDriverJobTaskAction(job, variant: key.variant, arch: key.arch, identifier: .targetCompile(key.identifier), isUsingWholeModuleOptimization: key.isUsingWholeModuleOptimization)
            case .swiftDriverExplicitDependencyJob(let key):
                // WMO doesn't apply to explicit module builds
                guard let job = context.swiftModuleDependencyGraph.plannedExplicitDependencyBuildJob(for: key.driverJobKey) else {
                    throw StubError.error("Failed to lookup explicit module Swift driver job \(key.driverJobKey)")
                }
            return SwiftDriverJobTaskAction(job, variant: nil, arch: key.arch, identifier: .explicitDependency, isUsingWholeModuleOptimization: false)
            default:
                fatalError("Unexpected dynamic task key: \(dynamicTaskKey)")
        }
    }
}
