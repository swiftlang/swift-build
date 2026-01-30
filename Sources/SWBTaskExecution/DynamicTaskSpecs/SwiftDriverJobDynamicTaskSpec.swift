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
    let serializedDiagnosticInfo: [SerializedDiagnosticInfo]
    let isUsingWholeModuleOptimization: Bool
    let compilerLocation: LibSwiftDriver.CompilerLocation
    let casOptions: CASOptions?

    init(serializedDiagnosticInfo: [SerializedDiagnosticInfo], isUsingWholeModuleOptimization: Bool, compilerLocation: LibSwiftDriver.CompilerLocation, casOptions: CASOptions?) {
        self.serializedDiagnosticInfo = serializedDiagnosticInfo
        self.isUsingWholeModuleOptimization = isUsingWholeModuleOptimization
        self.compilerLocation = compilerLocation
        self.casOptions = casOptions
    }

    init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.serializedDiagnosticInfo = try deserializer.deserialize()
        self.isUsingWholeModuleOptimization = try deserializer.deserialize()
        self.compilerLocation = try deserializer.deserialize()
        self.casOptions = try deserializer.deserialize()
    }

    func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(4) {
            serializer.serialize(serializedDiagnosticInfo)
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
        let serializedDiagnosticInfo: [SerializedDiagnosticInfo]
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
            var diagnosticInfo: [SerializedDiagnosticInfo] = []
            let diaOutputs = job.outputs.filter({ $0.fileExtension == "dia" })
            if job.categorizer.isCompile && !key.isUsingWholeModuleOptimization {
                // If this is a non-WMO compile job, group serialized diagnostics by their corresponding source file.
                var sourcePathsByBasename: [String: Path] = [:]
                for input in job.inputs {
                    if input.fileExtension == "swift" {
                        sourcePathsByBasename[input.basenameWithoutSuffix] = input
                    }
                }
                for diaOutput in diaOutputs {
                    if let sourceFilePath = sourcePathsByBasename[diaOutput.basenameWithoutSuffix] {
                        diagnosticInfo.append(.init(serializedDiagnosticsPath: diaOutput, sourceFilePath: sourceFilePath))
                    } else {
                        diagnosticInfo.append(.init(serializedDiagnosticsPath: diaOutput, sourceFilePath: nil))
                    }
                }
            } else {
                for diaOutput in diaOutputs {
                    diagnosticInfo.append(.init(serializedDiagnosticsPath: diaOutput, sourceFilePath: nil))
                }
            }

            serializedDiagnosticInfo = diagnosticInfo
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
            serializedDiagnosticInfo = []
            assert(job.outputs.count > 0, "Explicit modules job was expected to have at least one primary output")
            ruleInfo = ["SwiftExplicitDependency\(job.ruleInfoType)", key.arch, job.outputs.first?.str ?? "<unknown>"]
            forTarget = nil
            descriptionForLifecycle = job.descriptionForLifecycle
            // WMO doesn't apply to explicit module builds
            isUsingWholeModuleOptimization = false
            compilerLocation = key.compilerLocation
            casOpts = key.casOptions
        default:
            fatalError("Unexpected dynamic task: \(dynamicTask)")
        }

        return Task(type: self,
                    payload:
                        SwiftDriverJobDynamicTaskPayload(
                            serializedDiagnosticInfo: serializedDiagnosticInfo,
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

    func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        if serializedDiagnosticsInfo(task, localFS).isEmpty {
            GenericOutputParser.self
        } else {
            SwiftCompilerOutputParser.self
        }
    }

    func serializedDiagnosticsInfo(_ task: any ExecutableTask, _ fs: any FSProxy) -> [SerializedDiagnosticInfo] {
        return (task.payload as? SwiftDriverJobDynamicTaskPayload)?.serializedDiagnosticInfo ?? []
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
