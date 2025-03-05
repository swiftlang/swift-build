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

public import SWBUtil
public import SWBMacro

public final class SwiftABICheckerToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, SwiftDiscoveredCommandLineToolSpecInfo, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.swift-abi-checker"

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        do {
            return try await (self as (any SwiftDiscoveredCommandLineToolSpecInfo)).discoveredCommandLineToolSpecInfo(producer, scope, delegate)
        } catch {
            delegate.error(error)
            return nil
        }
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }
    fileprivate struct ABICheckerPayload: TaskPayload {
        /// The path to the serialized diagnostic output.  Every clang task must provide this path.
        let serializedDiagnosticsPath: Path

        init(serializedDiagnosticsPath: Path) {
            self.serializedDiagnosticsPath = serializedDiagnosticsPath
        }
        public func serialize<T: Serializer>(to serializer: T) {
            serializer.serializeAggregate(1) {
                serializer.serialize(serializedDiagnosticsPath)
            }
        }
        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(1)
            self.serializedDiagnosticsPath = try deserializer.deserialize()
        }
    }

    override public func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] {
        let payload = task.payload! as! ABICheckerPayload
        return [payload.serializedDiagnosticsPath]
    }

    public override var payloadType: (any TaskPayload.Type)? {
        return ABICheckerPayload.self
    }

    // Override this func to ensure we can see these diagnostics in unit tests.
    public override func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        return SerializedDiagnosticsOutputParser.self
    }
    public func constructABICheckingTask(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, _ serializedDiagsPath: Path, _ baselinePath: Path?, _ allowlistPath: Path?) async {
        let toolSpecInfo: DiscoveredSwiftCompilerToolSpecInfo
        do {
            toolSpecInfo = try await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)
        } catch {
            delegate.error("Unable to discover `swiftc` command line tool info: \(error)")
            return
        }

        var commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)
        commandLine += ["-serialize-diagnostics-path", serializedDiagsPath.normalize().str]
        if let baselinePath {
            commandLine += ["-baseline-path", baselinePath.normalize().str]
        }
        if let allowlistPath {
            commandLine += ["-breakage-allowlist-path", allowlistPath.normalize().str]
        }
        let allInputs = cbc.inputs.map { delegate.createNode($0.absolutePath) } + [baselinePath, allowlistPath].compactMap { $0 }.map { delegate.createNode($0.normalize()) }
        // Add import search paths
        for searchPath in SwiftCompilerSpec.collectInputSearchPaths(cbc, toolInfo: toolSpecInfo) {
            commandLine += ["-I", searchPath]
        }
        commandLine += cbc.scope.evaluate(BuiltinMacros.SYSTEM_FRAMEWORK_SEARCH_PATHS).flatMap { ["-F", $0] }
        delegate.createTask(type: self,
                            payload: ABICheckerPayload(serializedDiagnosticsPath: serializedDiagsPath),
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: allInputs,
                            outputs: [delegate.createNode(cbc.output)],
                            enableSandboxing: enableSandboxing)
    }
}
