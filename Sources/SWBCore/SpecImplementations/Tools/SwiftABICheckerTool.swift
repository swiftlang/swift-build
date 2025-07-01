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

    override public func resolveExecutablePath(_ cbc: CommandBuildContext, _ path: Path, delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> Path {
        let swiftInfo = await cbc.producer.swiftCompilerSpec.discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)
        if let prospectivePath = swiftInfo?.toolPath.dirname.join(path), cbc.producer.executableSearchPaths.fs.exists(prospectivePath) {
            return prospectivePath
        }

        return await super.resolveExecutablePath(cbc, path, delegate: delegate)
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }
    fileprivate struct ABICheckerPayload: TaskPayload {
        /// The path to the serialized diagnostic output.  Every clang task must provide this path.
        let serializedDiagnosticsPath: Path

        let downgradeErrors: Bool

        init(serializedDiagnosticsPath: Path, downgradeErrors: Bool) {
            self.serializedDiagnosticsPath = serializedDiagnosticsPath
            self.downgradeErrors = downgradeErrors
        }
        public func serialize<T: Serializer>(to serializer: T) {
            serializer.serializeAggregate(2) {
                serializer.serialize(serializedDiagnosticsPath)
                serializer.serialize(downgradeErrors)
            }
        }
        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            self.serializedDiagnosticsPath = try deserializer.deserialize()
            self.downgradeErrors = try deserializer.deserialize()
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
        let payload = task.payload! as! ABICheckerPayload
        if payload.downgradeErrors {
            return APIDigesterDowngradingSerializedDiagnosticsOutputParser.self
        } else {
            return SerializedDiagnosticsOutputParser.self
        }
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
        let downgradeErrors = cbc.scope.evaluate(BuiltinMacros.SWIFT_ABI_CHECKER_DOWNGRADE_ERRORS)
        if downgradeErrors {
            commandLine += ["-disable-fail-on-error"]
        }
        let allInputs = cbc.inputs.map { delegate.createNode($0.absolutePath) } + [baselinePath, allowlistPath].compactMap { $0 }.map { delegate.createNode($0.normalize()) }
        // Add import search paths
        for searchPath in SwiftCompilerSpec.collectInputSearchPaths(cbc, toolInfo: toolSpecInfo) {
            commandLine += ["-I", searchPath]
        }
        delegate.createTask(type: self,
                            payload: ABICheckerPayload(
                                serializedDiagnosticsPath: serializedDiagsPath,
                                downgradeErrors: downgradeErrors
                            ),
                            ruleInfo: defaultRuleInfo(cbc, delegate),
                            commandLine: commandLine,
                            environment: environmentFromSpec(cbc, delegate),
                            workingDirectory: cbc.producer.defaultWorkingDirectory,
                            inputs: allInputs,
                            outputs: [delegate.createNode(cbc.output)],
                            enableSandboxing: enableSandboxing)
    }
}

public final class APIDigesterDowngradingSerializedDiagnosticsOutputParser: TaskOutputParser {
    private let task: any ExecutableTask

    public let workspaceContext: WorkspaceContext
    public let buildRequestContext: BuildRequestContext
    public let delegate: any TaskOutputParserDelegate

    required public init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?) {
        self.task = task
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
    }

    public func write(bytes: ByteString) {
        // Forward the unparsed bytes immediately (without line buffering).
        delegate.emitOutput(bytes)

        // Disable diagnostic scraping, since we use serialized diagnostics.
    }

    public func close(result: TaskResult?) {
        defer {
            delegate.close()
        }
        // Don't try to read diagnostics if the process crashed or got cancelled as they were almost certainly not written in this case.
        if result.shouldSkipParsingDiagnostics { return }

        for path in task.type.serializedDiagnosticsPaths(task, workspaceContext.fs) {
            let diagnostics = delegate.readSerializedDiagnostics(at: path, workingDirectory: task.workingDirectory, workspaceContext: workspaceContext)
            for diagnostic in diagnostics {
                delegate.diagnosticsEngine.emit(diagnostic.with(behavior: diagnostic.behavior == .error ? .warning : diagnostic.behavior))
            }
        }
    }
}
