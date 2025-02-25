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
import SWBCore
import SWBProtocol
public import SWBUtil

public struct PrecompileClangModuleTaskKey: Serializable, CustomDebugStringConvertible {
    let dependencyInfoPath: Path
    let usesSerializedDiagnostics: Bool
    let libclangPath: Path
    let casOptions: CASOptions?
    let verifyingModule: String?
    let fileNameMapPath: Path?

    init(
        dependencyInfoPath: Path,
        usesSerializedDiagnostics: Bool,
        libclangPath: Path,
        casOptions: CASOptions?,
        verifyingModule: String?,
        fileNameMapPath: Path?
    ) {
        self.dependencyInfoPath = dependencyInfoPath
        self.usesSerializedDiagnostics = usesSerializedDiagnostics
        self.libclangPath = libclangPath
        self.casOptions = casOptions
        self.verifyingModule = verifyingModule
        self.fileNameMapPath = fileNameMapPath
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(6) {
            serializer.serialize(dependencyInfoPath)
            serializer.serialize(usesSerializedDiagnostics)
            serializer.serialize(libclangPath)
            serializer.serialize(casOptions)
            serializer.serialize(verifyingModule)
            serializer.serialize(fileNameMapPath)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(6)
        self.dependencyInfoPath = try deserializer.deserialize()
        self.usesSerializedDiagnostics = try deserializer.deserialize()
        self.libclangPath = try deserializer.deserialize()
        self.casOptions = try deserializer.deserialize()
        self.verifyingModule = try deserializer.deserialize()
        self.fileNameMapPath = try deserializer.deserialize()
    }

    public var debugDescription: String {
        var result = "<PrecompileClangModule pcmPath=\(dependencyInfoPath) usesDia=\(usesSerializedDiagnostics)"
        if let verifyingModule {
            result += " verifyingModule=\(verifyingModule)"
        }
        if let fileNameMapPath {
            result += " fileNameMap=\(fileNameMapPath)"
        }
        result += ">"
        return result
    }
}

final class PrecompileClangModuleDynamicTaskSpec: DynamicTaskSpec {
    private struct Payload: ClangModuleVerifierPayloadType {
        let serializedDiagnosticsPath: Path?
        let fileNameMapPath: Path?

        init(serializedDiagnosticsPath: Path?, fileNameMapPath: Path?) {
            self.serializedDiagnosticsPath = serializedDiagnosticsPath
            self.fileNameMapPath = fileNameMapPath
        }

        func serialize<T>(to serializer: T) where T : SWBUtil.Serializer {
            serializer.serializeAggregate(3) {
                serializer.serialize(serializedDiagnosticsPath)
                serializer.serialize(fileNameMapPath)
            }

        }

        init(from deserializer: any SWBUtil.Deserializer) throws {
            try deserializer.beginAggregate(2)
            self.serializedDiagnosticsPath = try deserializer.deserialize()
            self.fileNameMapPath = try deserializer.deserialize()
        }
    }

    package var payloadType: (any TaskPayload.Type)? {
        return Payload.self
    }

    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> any ExecutableTask {
        guard case let .precompileClangModule(PrecompileClangModuleTaskKey) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTask.taskKey)")
        }

        precondition(dynamicTask.target == nil, "Precompiling modules should not be target specific.")
        // FIXME: Parsing the module identifier to reconstruct the module name is unfortunate.
        var moduleID = PrecompileClangModuleTaskKey.dependencyInfoPath.basenameWithoutSuffix.components(separatedBy: ":")[0]
        let isVerify = moduleID.hasSuffix("-verify")
        if isVerify {
            moduleID.removeLast("-verify".count)
        }
        assert(!isVerify || PrecompileClangModuleTaskKey.verifyingModule != nil)
        let moduleName = moduleID.prefix(upTo: moduleID.lastIndex(of: "-") ?? moduleID.endIndex)

        let ruleName: String, execDescription: String
        if isVerify, let verifyingModule = PrecompileClangModuleTaskKey.verifyingModule {
            ruleName = "VerifyPrecompileModule"
            if moduleName == "Test" {
                execDescription = "Verifying import of Clang module \(verifyingModule)"
            } else {
                assert(moduleName == verifyingModule || moduleName == "\(verifyingModule)_Private")
                execDescription = "Verifying compile of Clang module \(moduleName)"
            }
        } else {
            ruleName = "PrecompileModule"
            execDescription = "Compiling Clang module \(moduleName)"
        }

        return Task(
            type: self,
            dependencyData: .makefile(Path(PrecompileClangModuleTaskKey.dependencyInfoPath.withoutSuffix + ".d")),
            payload: Payload(serializedDiagnosticsPath: PrecompileClangModuleTaskKey.usesSerializedDiagnostics ? Path(PrecompileClangModuleTaskKey.dependencyInfoPath.withoutSuffix + ".dia") : nil, fileNameMapPath: PrecompileClangModuleTaskKey.fileNameMapPath),
            forTarget: dynamicTask.target,
            ruleInfo: [ruleName, PrecompileClangModuleTaskKey.dependencyInfoPath.str],
            commandLine: ["builtin-precompileModule", .literal(ByteString(encodingAsUTF8: PrecompileClangModuleTaskKey.dependencyInfoPath.str))],
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: execDescription,
            isDynamic: true
        )
    }

    package func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        guard case let .precompileClangModule(PrecompileClangModuleTaskKey) = dynamicTaskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTaskKey)")
        }
        return PrecompileClangModuleTaskAction(key: PrecompileClangModuleTaskKey)
    }

    func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        guard (task.payload as? Payload)?.serializedDiagnosticsPath != nil else {
            return GenericOutputParser.self
        }
        if task.ruleInfo.first == "VerifyPrecompileModule" {
            return ClangModuleVerifierOutputParser.self
        }
        return SerializedDiagnosticsOutputParser.self
    }

    package func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] {
        guard let path = (task.payload as? Payload)?.serializedDiagnosticsPath else {
            return []
        }
        return [path]
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // A precompile task should always start if requested.
        return true
    }
}
