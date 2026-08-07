//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

import Foundation
import Synchronization
import SWBCore
import SWBMacro
import SWBProtocol
import SWBServiceCore
import SWBUtil

/// Environment contract used to opt in to the Bazel-backed operation.
enum BazelBuildProxyEnvironment {
    static let manifestPath = "SWIFTBUILD_BAZEL_PROXY_MANIFEST"
    static let workspacePath = "SWIFTBUILD_BAZEL_PROXY_WORKSPACE"
    static let bazelPath = "SWIFTBUILD_BAZEL_PROXY_BAZEL"
    static let tracePath = "SWIFTBUILD_BAZEL_PROXY_TRACE"
}

enum BazelBuildProxyManifestLocator {
    static func resolve(
        request: BuildRequestMessagePayload,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> String? {
        let commandLinePath = request.parameters.overrides.commandLine[BazelBuildProxyEnvironment.manifestPath]?.nilIfEmpty
        let environmentPath = environment[BazelBuildProxyEnvironment.manifestPath]?.nilIfEmpty
        let inferredPath = request.containerPath.flatMap { containerPath -> String? in
            guard containerPath.fileExtension == "xcodeproj" else { return nil }
            return
                containerPath
                .join("rules_xcodeproj")
                .join("bazel")
                .join("build_proxy_manifest.json")
                .str
        }

        return [commandLinePath, environmentPath, inferredPath]
            .compactMap { $0 }
            .first(where: fileExists)
    }
}

struct BazelBuildProxyTargetSelector: Equatable, Sendable {
    let bazelLabel: String?
    let serviceTargetGUID: String
    let targetID: String?
    let targetName: String
}

/// Versioned contract emitted by rules_xcodeproj.
struct BazelBuildProxyManifest: Codable, Equatable, Sendable {
    struct Capabilities: Codable, Equatable, Sendable {
        let actions: [String]
    }

    struct Product: Codable, Equatable, Sendable {
        let basename: String
        let name: String
        let path: String?
        let type: String
    }

    struct Invocation: Codable, Equatable, Sendable {
        let bazelPath: String
        let bazelrcPath: String
        let generatorLabel: String
    }

    struct Variant: Codable, Equatable, Sendable {
        let arch: String
        let minimumOSVersion: String
        let platform: String
    }

    struct Target: Codable, Equatable, Sendable {
        let action: String
        let bazelLabel: String
        let configuration: String
        let outputGroup: String
        let product: Product
        let targetID: String
        let variant: Variant
        let xcodeTargetGUID: String
    }

    let capabilities: Capabilities
    let ignoredXcodeTargetGUIDs: [String]
    let invocation: Invocation
    let schemaVersion: Int
    let targets: [Target]

    static func load(path: Path) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path.str))
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.schemaVersion == 1 else {
            throw StubError.error("unsupported Bazel build proxy manifest schema version \(manifest.schemaVersion)")
        }
        guard manifest.capabilities.actions.contains("build") else {
            throw StubError.error("Bazel build proxy manifest does not declare the build capability")
        }
        guard
            !manifest.invocation.bazelPath.isEmpty,
            !manifest.invocation.bazelrcPath.isEmpty,
            !manifest.invocation.generatorLabel.isEmpty
        else {
            throw StubError.error("Bazel build proxy manifest has an incomplete invocation contract")
        }
        return manifest
    }

    func resolve(
        _ payload: BuildRequestMessagePayload,
        selectors: [BazelBuildProxyTargetSelector]? = nil
    ) throws -> [Target]? {
        let requestedSelectors =
            selectors
            ?? payload.configuredTargets.map {
                BazelBuildProxyTargetSelector(
                    bazelLabel: nil,
                    serviceTargetGUID: $0.guid,
                    targetID: nil,
                    targetName: ""
                )
            }
        guard !requestedSelectors.isEmpty else { return nil }

        let isClean: Bool
        switch payload.buildCommand {
        case .cleanBuildFolder, .cleanBuildFolderAndCaches:
            isClean = true
        case .build:
            isClean = false
        default:
            return nil
        }

        let action = isClean ? "build" : payload.parameters.action
        let configuration = payload.parameters.configuration ?? ""
        let requestedPlatform: String? =
            switch payload.parameters.activeRunDestination?.buildTarget {
            case .toolchainSDK(let platform, _, _): platform
            case .swiftSDK, .inMemorySwiftSDK: nil
            case nil: nil
            }
        let requestedArchitecture =
            (payload.parameters.activeArchitecture
            ?? payload.parameters.activeRunDestination?.targetArchitecture).flatMap { $0 == "undefined_arch" ? nil : $0 }

        var resolved: [Target] = []
        for selector in requestedSelectors {
            if selector.targetName == "BazelDependencies"
                || ignoredXcodeTargetGUIDs.contains(selector.serviceTargetGUID)
            {
                continue
            }
            var candidates = targets.filter {
                let identityMatches: Bool
                if let targetID = selector.targetID {
                    identityMatches = $0.targetID == targetID
                } else if let bazelLabel = selector.bazelLabel {
                    identityMatches = $0.bazelLabel == bazelLabel
                } else {
                    identityMatches = $0.xcodeTargetGUID == selector.serviceTargetGUID
                }
                return identityMatches
                    && $0.configuration == configuration
                    && $0.action == action
            }
            if let requestedPlatform {
                candidates = candidates.filter { $0.variant.platform == requestedPlatform }
            }
            if let requestedArchitecture {
                candidates = candidates.filter { $0.variant.arch == requestedArchitecture }
            }

            guard !candidates.isEmpty else {
                // A valid manifest remains opt-in per request. Unmapped requests
                // use the native Swift Build operation.
                return nil
            }
            guard candidates.count == 1 else {
                throw StubError.error(
                    "ambiguous Bazel build proxy mapping for target \(selector.targetName), configuration \(configuration)"
                )
            }
            resolved.append(candidates[0])
        }
        return resolved.isEmpty ? nil : resolved
    }
}

enum BazelBuildProxyParsedEvent: Equatable, Sendable {
    case progress(completed: Int, total: Int)
    case actionCount(Int)
    case targetCompleted(label: String, succeeded: Bool)
    case finished(succeeded: Bool)
}

/// Parses only an allowlist from BEP JSON. In particular, command-line and
/// environment-bearing events are never retained or forwarded.
enum BazelBuildProxyBEPParser {
    static func parse(line: String) -> [BazelBuildProxyParsedEvent] {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }

        var events: [BazelBuildProxyParsedEvent] = []
        if let progress = object["progress"] as? [String: Any],
            let stderr = progress["stderr"] as? String,
            let count = parseProgress(in: stderr)
        {
            events.append(.progress(completed: count.completed, total: count.total))
        }

        if let metrics = object["buildMetrics"] as? [String: Any],
            let summary = metrics["actionSummary"] as? [String: Any],
            let count = integer(summary["actionsExecuted"])
        {
            events.append(.actionCount(count))
        }

        if let identifier = object["id"] as? [String: Any],
            let target = identifier["targetCompleted"] as? [String: Any],
            let label = target["label"] as? String,
            let completed = object["completed"] as? [String: Any],
            let succeeded = completed["success"] as? Bool
        {
            events.append(.targetCompleted(label: label, succeeded: succeeded))
        }

        if let finished = object["finished"] as? [String: Any],
            let succeeded = finished["overallSuccess"] as? Bool
        {
            events.append(.finished(succeeded: succeeded))
        }
        return events
    }

    static func parseProgress(in text: String) -> (completed: Int, total: Int)? {
        var best: (completed: Int, total: Int)?
        for line in text.split(whereSeparator: \Character.isNewline) {
            guard
                let open = line.firstIndex(of: "["),
                let close = line[open...].firstIndex(of: "]")
            else { continue }
            let fraction = line[line.index(after: open)..<close]
                .split(separator: "/", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard
                fraction.count == 2,
                let completed = Int(fraction[0]),
                let total = Int(fraction[1]),
                total > 0,
                completed >= 0,
                completed <= total
            else { continue }
            if best == nil || completed > best!.completed || total > best!.total {
                best = (completed, total)
            }
        }
        return best
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

struct BazelBuildProxyDiagnostic: Equatable, Hashable, Sendable {
    let kind: BuildOperationDiagnosticEmitted.Kind
    let path: String?
    let line: Int?
    let column: Int?
    let message: String
}

enum BazelBuildProxyDiagnosticParser {
    static func parse(line originalLine: String) -> BazelBuildProxyDiagnostic? {
        let line = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        let parts = line.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        if parts.count == 5,
            let lineNumber = Int(parts[1]),
            let columnNumber = Int(parts[2]),
            let kind = kind(String(parts[3]).trimmingCharacters(in: .whitespaces))
        {
            return .init(
                kind: kind,
                path: String(parts[0]),
                line: lineNumber,
                column: columnNumber,
                message: String(parts[4]).trimmingCharacters(in: .whitespaces)
            )
        }

        for (prefix, kind): (String, BuildOperationDiagnosticEmitted.Kind) in [
            ("ERROR: ", .error),
            ("WARNING: ", .warning),
        ] where line.hasPrefix(prefix) {
            return .init(
                kind: kind,
                path: nil,
                line: nil,
                column: nil,
                message: String(line.dropFirst(prefix.count))
            )
        }
        return nil
    }

    private static func kind(_ value: String) -> BuildOperationDiagnosticEmitted.Kind? {
        switch value {
        case "error": .error
        case "warning": .warning
        case "note": .note
        case "remark": .remark
        default: nil
        }
    }
}

final class BazelBuildService: BuildService, @unchecked Sendable {
    private static let traceLock = SWBMutex<Void>(())

    override func createBuildOperation(request: Request, message: CreateBuildRequest) throws -> any ActiveBuildOperation {
        guard
            !message.onlyCreateBuildDescription,
            let manifestPath = try locateManifestPath(request: request, message: message)
        else {
            return try super.createBuildOperation(request: request, message: message)
        }

        let manifest = try BazelBuildProxyManifest.load(path: Path(manifestPath))
        let selectors = try configuredTargetSelectors(request: request, message: message)
        let targets = try manifest.resolve(message.request, selectors: selectors)
        Self.traceSelection(message: message, selectors: selectors, resolvedTargets: targets)
        guard let targets else {
            return try super.createBuildOperation(request: request, message: message)
        }

        let operation = try BazelActiveBuildOperation(
            request: request,
            message: message,
            manifestPath: Path(manifestPath),
            manifest: manifest,
            targets: targets
        )
        try operation.registerWithSession()
        return operation
    }

    private func configuredTargetSelectors(
        request: Request,
        message: CreateBuildRequest
    ) throws -> [BazelBuildProxyTargetSelector] {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let buildRequest = try BuildRequest.create(
            from: message.request,
            workspace: workspaceContext.workspace,
            core: workspaceContext.core
        )
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        return buildRequest.buildTargets.map { buildTarget in
            let settings = buildRequestContext.getCachedSettings(
                buildTarget.parameters,
                target: buildTarget.target
            )
            let scope = settings.globalScope
            func setting(_ name: String) -> String? {
                guard let macro = scope.namespace.lookupMacroDeclaration(name) else { return nil }
                return scope.evaluateAsString(macro).nilIfEmpty
            }
            return BazelBuildProxyTargetSelector(
                bazelLabel: setting("BAZEL_LABEL"),
                serviceTargetGUID: buildTarget.target.guid,
                targetID: setting("BAZEL_TARGET_ID"),
                targetName: buildTarget.target.name
            )
        }
    }

    private func locateManifestPath(request: Request, message: CreateBuildRequest) throws -> String? {
        if let manifestPath = BazelBuildProxyManifestLocator.resolve(request: message.request) {
            return manifestPath
        }

        // Xcode deliberately constrains the environment of its build-service
        // subprocess and does not always populate `containerPath`. Resolve the
        // generated integration directory from the target's evaluated build
        // settings as the authoritative in-request fallback.
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else { return nil }
        let buildRequest = try BuildRequest.create(
            from: message.request,
            workspace: workspaceContext.workspace,
            core: workspaceContext.core
        )
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        for buildTarget in buildRequest.buildTargets {
            let settings = buildRequestContext.getCachedSettings(
                buildTarget.parameters,
                target: buildTarget.target
            )
            let scope = settings.globalScope
            guard
                let macro = scope.namespace.lookupMacroDeclaration("BAZEL_INTEGRATION_DIR"),
                let integrationDirectory = scope.evaluateAsString(macro).nilIfEmpty
            else {
                continue
            }
            let candidate = Path(integrationDirectory).join("build_proxy_manifest.json").str
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func traceSelection(
        message: CreateBuildRequest,
        selectors: [BazelBuildProxyTargetSelector],
        resolvedTargets: [BazelBuildProxyManifest.Target]?
    ) {
        guard let tracePath = ProcessInfo.processInfo.environment[BazelBuildProxyEnvironment.tracePath]?.nilIfEmpty else {
            return
        }
        let payload = message.request
        let destination: String =
            switch payload.parameters.activeRunDestination?.buildTarget {
            case .toolchainSDK(let platform, _, _): platform
            case .swiftSDK: "swift-sdk"
            case .inMemorySwiftSDK: "in-memory-swift-sdk"
            case nil: "none"
            }
        let fields = [
            "descriptionOnly=\(message.onlyCreateBuildDescription)",
            "command=\(payload.buildCommand)",
            "action=\(payload.parameters.action)",
            "configuration=\(payload.parameters.configuration ?? "none")",
            "platform=\(destination)",
            "architecture=\(payload.parameters.activeArchitecture ?? payload.parameters.activeRunDestination?.targetArchitecture ?? "none")",
            "requested=\(payload.configuredTargets.map(\.guid).joined(separator: ","))",
            "selectors=\(selectors.map { "\($0.targetName):\($0.targetID ?? $0.bazelLabel ?? $0.serviceTargetGUID)" }.joined(separator: ","))",
            "resolved=\(resolvedTargets?.map(\.xcodeTargetGUID).joined(separator: ",") ?? "fallback")",
        ]
        let data = Data((fields.joined(separator: " ") + "\n").utf8)
        traceLock.withLock {
            let url = URL(fileURLWithPath: tracePath)
            if !FileManager.default.fileExists(atPath: tracePath) {
                FileManager.default.createFile(atPath: tracePath, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                return
            }
        }
    }
}

private final class BazelActiveBuildOperation: ActiveBuildOperation, @unchecked Sendable {
    private enum Phase {
        case registered
        case running
        case completed
    }

    private struct MutableState {
        var phase: Phase = .registered
        var cancelRequested = false
        var task: Task<Void, Never>?
        var emittedDiagnostics: Set<BazelBuildProxyDiagnostic> = []
        var lastProgress: (completed: Int, total: Int)?
        var bepSucceeded: Bool?
        var targetsStarted = false
        var taskStarted = false
    }

    private struct TargetPresentation {
        let destinationProductPath: String?
        let id: Int
        let info: BuildOperationTargetInfo
        let mapping: BazelBuildProxyManifest.Target
        let sourceProductPath: String?
    }

    let id: Int
    let buildRequest: BuildRequest
    let onlyCreatesBuildDescription = false

    private let session: Session
    private let request: Request
    private let manifest: BazelBuildProxyManifest
    private let manifestPath: Path
    private let targets: [BazelBuildProxyManifest.Target]
    private let targetPresentations: [TargetPresentation]
    private let buildRequestContext: BuildRequestContext
    private let state = SWBMutex(MutableState())
    private let taskID = 1
    private let taskSignature = BuildOperationTaskSignature.taskIdentifier(ByteString(encodingAsUTF8: "bazel-build-proxy"))

    init(
        request: Request,
        message: CreateBuildRequest,
        manifestPath: Path,
        manifest: BazelBuildProxyManifest,
        targets: [BazelBuildProxyManifest.Target]
    ) throws {
        self.id = request.buildService.nextBuildOperationID()
        self.session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let operationBuildRequest = try BuildRequest.create(
            from: message.request,
            workspace: workspaceContext.workspace,
            core: workspaceContext.core
        )
        let operationBuildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        self.buildRequest = operationBuildRequest
        self.buildRequestContext = operationBuildRequestContext
        self.request = Request(service: request.service, channel: message.responseChannel, name: "bazel_active_build")
        self.manifestPath = manifestPath
        self.manifest = manifest
        self.targets = targets

        var presentations: [TargetPresentation] = []
        for (index, mapping) in targets.enumerated() {
            guard
                let buildTarget = operationBuildRequest.buildTargets.first(where: { buildTarget in
                    let settings = operationBuildRequestContext.getCachedSettings(
                        buildTarget.parameters,
                        target: buildTarget.target
                    )
                    let scope = settings.globalScope
                    func setting(_ name: String) -> String? {
                        guard let macro = scope.namespace.lookupMacroDeclaration(name) else { return nil }
                        return scope.evaluateAsString(macro).nilIfEmpty
                    }
                    return setting("BAZEL_TARGET_ID") == mapping.targetID
                        || setting("BAZEL_LABEL") == mapping.bazelLabel
                        || buildTarget.target.guid == mapping.xcodeTargetGUID
                })
            else {
                throw StubError.error("mapped target \(mapping.xcodeTargetGUID) is absent from the build request")
            }
            let settings = operationBuildRequestContext.getCachedSettings(buildTarget.parameters, target: buildTarget.target)
            guard let project = settings.project else {
                throw StubError.error("mapped target \(mapping.xcodeTargetGUID) has no project settings")
            }
            let scope = settings.globalScope
            func setting(_ name: String) -> String? {
                guard let macro = scope.namespace.lookupMacroDeclaration(name) else { return nil }
                return scope.evaluateAsString(macro).nilIfEmpty
            }
            let destinationProductPath = setting("TARGET_BUILD_DIR").map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent(setting("FULL_PRODUCT_NAME") ?? mapping.product.basename)
                    .path
            }
            let sourceProductPath: String? = {
                guard
                    let relativeProductPath = mapping.product.path?.nilIfEmpty,
                    let bazelOut = setting("BAZEL_OUT")
                else {
                    return nil
                }
                let prefix = "bazel-out/"
                guard relativeProductPath.hasPrefix(prefix) else { return nil }
                return URL(fileURLWithPath: bazelOut, isDirectory: true)
                    .appendingPathComponent(String(relativeProductPath.dropFirst(prefix.count)))
                    .path
            }()
            presentations.append(
                TargetPresentation(
                    destinationProductPath: destinationProductPath,
                    id: index + 1,
                    info: BuildOperationTargetInfo(
                        name: buildTarget.target.name,
                        type: .standard,
                        projectInfo: .init(
                            name: project.name,
                            path: project.xcodeprojPath.str,
                            isPackage: project.isPackage,
                            isNameUniqueInWorkspace: workspaceContext.workspace.projects(named: project.name).count <= 1
                        ),
                        configurationName: mapping.configuration,
                        configurationIsDefault: false,
                        sdkCanonicalName: settings.sdk?.canonicalName
                    ),
                    mapping: mapping,
                    sourceProductPath: sourceProductPath
                ))
        }
        self.targetPresentations = presentations
    }

    func registerWithSession() throws {
        try session.registerActiveBuild(self)
    }

    func start() {
        let shouldStart = state.withLock { state in
            guard state.phase == .registered else { return false }
            state.phase = .running
            return true
        }
        guard shouldStart else { return }

        let task = Task { [self] in
            await run()
        }
        let cancelImmediately = state.withLock { state in
            guard state.phase != .completed else { return true }
            state.task = task
            return state.cancelRequested
        }
        if cancelImmediately {
            task.cancel()
        }
    }

    func cancel() {
        let task = state.withLock { state in
            guard state.phase != .completed else { return nil as Task<Void, Never>? }
            state.cancelRequested = true
            return state.task
        }
        task?.cancel()
        if task == nil {
            finish(status: .cancelled, taskStatus: .cancelled, signalled: false)
        }
    }

    private func run() async {
        if state.withLock({ $0.cancelRequested || $0.phase == .completed }) {
            finish(status: .cancelled, taskStatus: nil, signalled: false)
            return
        }
        request.send(BuildOperationPreparationCompleted())
        request.send(BuildOperationStarted(id: id))
        request.send(BuildOperationReportPathMap(copiedPathMap: [:], generatedFilesPathMap: [:]))
        for target in targetPresentations {
            request.send(BuildOperationTargetStarted(id: target.id, guid: target.mapping.xcodeTargetGUID, info: target.info))
        }
        state.withLock { $0.targetsStarted = true }

        let invocation: BazelBuildProxyInvocation
        do {
            invocation = try createInvocation()
        } catch {
            emitDiagnostic(.init(kind: .error, path: nil, line: nil, column: nil, message: "Bazel proxy setup failed: \(error)"))
            finish(status: .failed, taskStatus: nil, signalled: false)
            return
        }

        request.send(
            BuildOperationTaskStarted(
                id: taskID,
                targetID: targetPresentations.first?.id,
                parentID: nil,
                info: .init(
                    taskName: "Bazel",
                    signature: taskSignature,
                    ruleInfo: "BazelBuild \(targets.map(\.bazelLabel).joined(separator: " "))",
                    executionDescription: invocation.isClean ? "Clean Bazel outputs" : "Build with Bazel",
                    commandLineDisplayString: invocation.displayString,
                    interestingPath: nil,
                    serializedDiagnosticsPaths: []
                )
            ))
        state.withLock { $0.taskStarted = true }
        let selectionMessage = "Bazel build proxy operation \(id): \(manifest.invocation.generatorLabel) [\(targets.map(\.xcodeTargetGUID).joined(separator: ", "))]\n"
        request.send(
            BuildOperationConsoleOutputEmitted(
                data: Array(selectionMessage.utf8),
                taskID: taskID,
                taskSignature: taskSignature
            ))
        request.send(
            BuildOperationProgressUpdated(
                statusMessage: invocation.isClean ? "Cleaning Bazel outputs" : "Analyzing Bazel build",
                percentComplete: -1,
                showInLog: false
            ))

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.environment = invocation.environment
        process.standardOutput = FileHandle.nullDevice

        let consolePipe = Pipe()
        let consoleStream = process.makeStream(for: \.standardErrorPipe, using: consolePipe)
        defer { invocation.removeTemporaryFiles() }

        do {
            async let console: Void = consumeConsole(consoleStream)
            try await process.run(interruptible: true)
            try await console
            consumeBEPFile(at: invocation.eventFileURL)

            let exitStatus = try Processes.ExitStatus(process)
            let cancelled = state.withLock { $0.cancelRequested }
            if cancelled {
                finish(status: .cancelled, taskStatus: .cancelled, signalled: exitStatus.wasSignaled)
            } else if exitStatus.isSuccess && state.withLock({ $0.bepSucceeded != false }) {
                do {
                    try materializeProducts(workspace: invocation.workingDirectory)
                    finish(status: .succeeded, taskStatus: .succeeded, signalled: false)
                } catch {
                    emitDiagnostic(
                        .init(
                            kind: .error,
                            path: nil,
                            line: nil,
                            column: nil,
                            message: "Bazel product materialization failed: \(error)"
                        ))
                    finish(status: .failed, taskStatus: .failed, signalled: false)
                }
            } else {
                emitDiagnostic(
                    .init(
                        kind: .error,
                        path: nil,
                        line: nil,
                        column: nil,
                        message: "Bazel build failed (\(exitStatus))"
                    ))
                finish(status: .failed, taskStatus: .failed, signalled: exitStatus.wasSignaled)
            }
        } catch is CancellationError {
            finish(status: .cancelled, taskStatus: .cancelled, signalled: true)
        } catch {
            emitDiagnostic(.init(kind: .error, path: nil, line: nil, column: nil, message: "Unable to run Bazel: \(error)"))
            finish(status: .failed, taskStatus: .failed, signalled: false)
        }
    }

    private func consumeBEPFile(at url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in contents.split(whereSeparator: \.isNewline) {
            handleBEP(line: String(line))
        }
    }

    private func consumeConsole(_ stream: AsyncThrowingStream<SWBDispatchData, any Error>) async throws {
        var pending = ""
        for try await chunk in stream {
            let bytes = Array(chunk)
            request.send(BuildOperationConsoleOutputEmitted(data: bytes, taskID: taskID, taskSignature: taskSignature))
            pending.append(String(decoding: bytes, as: UTF8.self))
            while let newline = pending.firstIndex(of: "\n") {
                let line = String(pending[..<newline])
                pending.removeSubrange(...newline)
                handleConsole(line: line)
            }
        }
        if !pending.isEmpty {
            handleConsole(line: pending)
        }
    }

    private func handleBEP(line: String) {
        for event in BazelBuildProxyBEPParser.parse(line: line) {
            switch event {
            case .progress(let completed, let total):
                emitProgress(completed: completed, total: total)
            case .actionCount(let count):
                request.send(
                    BuildOperationProgressUpdated(
                        statusMessage: "Bazel completed \(count) actions",
                        percentComplete: 100,
                        showInLog: true
                    ))
                let message = "Bazel completed \(count) actions\n"
                request.send(
                    BuildOperationConsoleOutputEmitted(
                        data: Array(message.utf8),
                        taskID: taskID,
                        taskSignature: taskSignature
                    ))
            case .targetCompleted(_, let succeeded):
                if !succeeded {
                    state.withLock { $0.bepSucceeded = false }
                }
            case .finished(let succeeded):
                state.withLock { $0.bepSucceeded = succeeded }
            }
        }
    }

    private func handleConsole(line: String) {
        if let progress = BazelBuildProxyBEPParser.parseProgress(in: line) {
            emitProgress(completed: progress.completed, total: progress.total)
        }
        if let diagnostic = BazelBuildProxyDiagnosticParser.parse(line: line) {
            emitDiagnostic(diagnostic)
        }
    }

    private func emitProgress(completed: Int, total: Int) {
        let shouldEmit = state.withLock { state in
            if let previous = state.lastProgress,
                previous.completed >= completed,
                previous.total >= total
            {
                return false
            }
            state.lastProgress = (completed, total)
            return true
        }
        guard shouldEmit else { return }
        request.send(
            BuildOperationProgressUpdated(
                statusMessage: "Building \(completed) of \(total) Bazel actions",
                percentComplete: 100 * Double(completed) / Double(total),
                showInLog: false
            ))
    }

    private func emitDiagnostic(_ diagnostic: BazelBuildProxyDiagnostic) {
        let shouldEmit = state.withLock { $0.emittedDiagnostics.insert(diagnostic).inserted }
        guard shouldEmit else { return }

        let location: BuildOperationDiagnosticEmitted.Location
        if let path = diagnostic.path {
            location = .path(Path(path), line: diagnostic.line, column: diagnostic.column)
        } else {
            location = .unknown
        }
        request.send(
            BuildOperationDiagnosticEmitted(
                kind: diagnostic.kind,
                location: location,
                message: diagnostic.message,
                locationContext: .globalTask(taskID: taskID, taskSignature: taskSignature),
                appendToOutputStream: false,
                sourceRanges: [],
                fixIts: [],
                traits: [],
                attachments: [:],
                childDiagnostics: []
            ))
    }

    private func materializeProducts(workspace: URL) throws {
        let fileManager = FileManager.default
        for target in targetPresentations {
            guard let relativeProductPath = target.mapping.product.path?.nilIfEmpty else {
                throw StubError.error("manifest has no product path for \(target.mapping.bazelLabel)")
            }
            guard let destinationPath = target.destinationProductPath?.nilIfEmpty else {
                throw StubError.error("Xcode has no target build directory for \(target.mapping.bazelLabel)")
            }

            let source =
                target.sourceProductPath.map { URL(fileURLWithPath: $0) }
                ?? workspace.appendingPathComponent(relativeProductPath)
            let standardizedSource = source.standardizedFileURL
            let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL
            guard fileManager.fileExists(atPath: standardizedSource.path) else {
                throw StubError.error("Bazel product is missing at \(standardizedSource.path)")
            }
            if standardizedSource.path == destination.path {
                continue
            }

            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let staged = parent.appendingPathComponent(
                ".bazel-proxy-\(UUID().uuidString)-\(destination.lastPathComponent)"
            )
            defer { try? fileManager.removeItem(at: staged) }
            try fileManager.copyItem(at: standardizedSource, to: staged)
            var replaced: URL?
            if fileManager.fileExists(atPath: destination.path) {
                let replacement = parent.appendingPathComponent(
                    ".bazel-proxy-replaced-\(UUID().uuidString)-\(destination.lastPathComponent)"
                )
                try fileManager.moveItem(at: destination, to: replacement)
                replaced = replacement
            }
            do {
                try fileManager.moveItem(at: staged, to: destination)
            } catch {
                if let replaced {
                    try? fileManager.moveItem(at: replaced, to: destination)
                }
                throw error
            }
            if let replaced {
                Self.makeTreeRemovable(replaced, fileManager: fileManager)
                try? fileManager.removeItem(at: replaced)
            }
        }
    }

    private static func makeTreeRemovable(_ root: URL, fileManager: FileManager) {
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) {
            for case let url as URL in enumerator {
                try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
        }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private func finish(
        status: BuildOperationEnded.Status,
        taskStatus: BuildOperationTaskEnded.Status?,
        signalled: Bool
    ) {
        let lifecycle = state.withLock { state -> (shouldFinish: Bool, targetsStarted: Bool, taskStarted: Bool) in
            guard state.phase != .completed else { return (false, false, false) }
            let lifecycle = (targetsStarted: state.targetsStarted, taskStarted: state.taskStarted)
            state.phase = .completed
            state.task = nil
            return (true, lifecycle.targetsStarted, lifecycle.taskStarted)
        }
        guard lifecycle.shouldFinish else { return }

        if lifecycle.taskStarted, let taskStatus {
            request.send(
                BuildOperationTaskEnded(
                    id: taskID,
                    signature: taskSignature,
                    status: taskStatus,
                    signalled: signalled,
                    metrics: nil
                ))
        }
        if lifecycle.targetsStarted {
            for target in targetPresentations {
                request.send(BuildOperationTargetEnded(id: target.id))
            }
        }
        session.unregisterActiveBuild(self)
        request.reply(BuildOperationEnded(id: id, status: status))
    }

    private func createInvocation() throws -> BazelBuildProxyInvocation {
        guard let firstBuildTarget = buildRequest.buildTargets.first else {
            throw StubError.error("Bazel proxy build request has no targets")
        }
        let settings = buildRequestContext.getCachedSettings(firstBuildTarget.parameters, target: firstBuildTarget.target)
        let scope = settings.globalScope

        func setting(_ name: String) -> String? {
            guard let macro = scope.namespace.lookupMacroDeclaration(name) else { return nil }
            return scope.evaluateAsString(macro).nilIfEmpty
        }

        let processEnvironment = ProcessInfo.processInfo.environment
        let workspace =
            processEnvironment[BazelBuildProxyEnvironment.workspacePath]?.nilIfEmpty
            ?? setting("BAZEL_WORKSPACE_ROOT")
            ?? setting("SRCROOT")
            ?? Self.inferWorkspace(from: manifestPath)
        guard let workspace else {
            throw StubError.error("unable to determine Bazel workspace root")
        }

        let bazelPath =
            processEnvironment[BazelBuildProxyEnvironment.bazelPath]?.nilIfEmpty
            ?? manifest.invocation.bazelPath
        let bazelRealPath =
            setting("BAZEL_REAL")
            ?? BazelBuildProxyInvocation.findBazelReal(
                excluding: bazelPath,
                environment: processEnvironment
            )
        let integrationDirectory =
            setting("BAZEL_INTEGRATION_DIR")
            ?? Self.inferIntegrationDirectory(
                from: manifestPath,
                bazelrcPath: manifest.invocation.bazelrcPath
            )
            ?? Self.inferIntegrationDirectory(from: manifestPath)
        let outputBase = setting("BAZEL_OUTPUT_BASE")
        let bazelConfig = setting("BAZEL_CONFIG")
        let xcodeBuildVersion = setting("XCODE_PRODUCT_BUILD_VERSION")
        let developerDirectory = setting("DEVELOPER_DIR")

        let isClean: Bool
        switch buildRequest.buildCommand {
        case .cleanBuildFolder, .cleanBuildFolderAndCaches:
            isClean = true
        default:
            isClean = false
        }

        return try BazelBuildProxyInvocation(
            bazelPath: bazelPath,
            bazelRealPath: bazelRealPath,
            bazelConfig: bazelConfig,
            developerDirectory: developerDirectory,
            generatorLabel: manifest.invocation.generatorLabel,
            integrationDirectory: integrationDirectory,
            isClean: isClean,
            outputBase: outputBase,
            outputGroups: targets.map(\.outputGroup),
            workspace: workspace,
            xcodeBuildVersion: xcodeBuildVersion
        )
    }

    private static func inferWorkspace(from manifestPath: Path) -> String? {
        var url = URL(fileURLWithPath: manifestPath.str).deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "xcodeproj" {
                return url.deletingLastPathComponent().path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func inferIntegrationDirectory(from manifestPath: Path) -> String? {
        let url = URL(fileURLWithPath: manifestPath.str)
        let candidates = [
            url.deletingLastPathComponent(),
            url.deletingLastPathComponent().appendingPathComponent("bazel"),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("xcodeproj.bazelrc").path)
        }?.path
    }

    private static func inferIntegrationDirectory(from manifestPath: Path, bazelrcPath: String) -> String? {
        var url = URL(fileURLWithPath: manifestPath.str).deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "xcodeproj" {
                let bazelrc = url.appendingPathComponent(bazelrcPath)
                if FileManager.default.fileExists(atPath: bazelrc.path) {
                    return bazelrc.deletingLastPathComponent().path
                }
                return nil
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

struct BazelBuildProxyInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let eventFileURL: URL
    let workingDirectory: URL
    let isClean: Bool

    var displayString: String {
        ([executableURL.path] + arguments).map(shellEscaped).joined(separator: " ")
    }

    init(
        bazelPath: String,
        bazelRealPath: String?,
        bazelConfig: String?,
        developerDirectory: String?,
        generatorLabel: String,
        integrationDirectory: String?,
        isClean: Bool,
        outputBase: String?,
        outputGroups: [String],
        workspace: String,
        xcodeBuildVersion: String?
    ) throws {
        let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true)
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            throw StubError.error("Bazel workspace does not exist at \(workspace)")
        }
        workingDirectory = workspaceURL
        self.isClean = isClean
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-build-bazel-proxy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryDirectory =
            temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        eventFileURL = temporaryDirectory.appendingPathComponent("build-event.jsonl")

        if bazelPath.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: bazelPath)
            arguments = try Self.arguments(
                executablePrefix: [],
                bazelConfig: bazelConfig,
                developerDirectory: developerDirectory,
                generatorLabel: generatorLabel,
                integrationDirectory: integrationDirectory,
                isClean: isClean,
                eventFileURL: eventFileURL,
                outputBase: outputBase,
                outputGroups: outputGroups,
                workspace: workspace,
                xcodeBuildVersion: xcodeBuildVersion
            )
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            arguments = try Self.arguments(
                executablePrefix: [bazelPath],
                bazelConfig: bazelConfig,
                developerDirectory: developerDirectory,
                generatorLabel: generatorLabel,
                integrationDirectory: integrationDirectory,
                isClean: isClean,
                eventFileURL: eventFileURL,
                outputBase: outputBase,
                outputGroups: outputGroups,
                workspace: workspace,
                xcodeBuildVersion: xcodeBuildVersion
            )
        }
        environment = Self.sanitizedEnvironment(
            ProcessInfo.processInfo.environment,
            bazelRealPath: bazelRealPath,
            developerDirectory: developerDirectory,
            workspace: workspace
        )
    }

    private static func arguments(
        executablePrefix: [String],
        bazelConfig: String?,
        developerDirectory: String?,
        generatorLabel: String,
        integrationDirectory: String?,
        isClean: Bool,
        eventFileURL: URL,
        outputBase: String?,
        outputGroups: [String],
        workspace: String,
        xcodeBuildVersion: String?
    ) throws -> [String] {
        var arguments = executablePrefix
        if let integrationDirectory {
            let bazelrc = URL(fileURLWithPath: integrationDirectory)
                .appendingPathComponent("xcodeproj.bazelrc").path
            guard FileManager.default.fileExists(atPath: bazelrc) else {
                throw StubError.error("missing generated xcodeproj.bazelrc at \(bazelrc)")
            }
            arguments += ["--noworkspace_rc", "--bazelrc=\(bazelrc)"]
            let workspaceBazelrc = URL(fileURLWithPath: workspace).appendingPathComponent(".bazelrc").path
            if FileManager.default.fileExists(atPath: workspaceBazelrc) {
                arguments.append("--bazelrc=\(workspaceBazelrc)")
            }
        }
        if let outputBase {
            arguments.append("--output_base=\(outputBase)")
        }

        if isClean {
            arguments.append("clean")
            return arguments
        }

        arguments.append("build")
        if let bazelConfig {
            arguments.append("--config=_\(bazelConfig)_build")
        }
        arguments += [
            "--color=no",
            "--curses=no",
            "--bes_upload_mode=NOWAIT_FOR_UPLOAD_COMPLETE",
            "--build_event_json_file=\(eventFileURL.path)",
        ]
        if let developerDirectory {
            arguments.append("--repo_env=DEVELOPER_DIR=\(developerDirectory)")
        }
        if let xcodeBuildVersion {
            arguments += [
                "--xcode_version=\(xcodeBuildVersion)",
                "--repo_env=XCODE_VERSION=\(xcodeBuildVersion)",
                "--repo_env=USE_CLANG_CL=\(xcodeBuildVersion)",
            ]
        }
        arguments.append("--output_groups=\(Array(Set(outputGroups)).sorted().joined(separator: ","))")
        arguments.append(generatorLabel)
        return arguments
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: eventFileURL.deletingLastPathComponent())
    }

    static func sanitizedEnvironment(
        _ source: [String: String],
        bazelRealPath: String? = nil,
        developerDirectory: String?,
        workspace: String
    ) -> [String: String] {
        let allowed = [
            "HOME", "USER", "PATH", "TMPDIR", "SSH_AUTH_SOCK", "TERM",
            "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy",
            "NO_PROXY", "no_proxy",
        ]
        var result = source.filter { allowed.contains($0.key) }
        result["BUILD_WORKSPACE_DIRECTORY"] = workspace
        if let bazelRealPath {
            result["BAZEL_REAL"] = bazelRealPath
        }
        if let developerDirectory {
            result["DEVELOPER_DIR"] = developerDirectory
        }
        return result
    }

    static func findBazelReal(
        excluding bazelPath: String,
        environment: [String: String]
    ) -> String? {
        let excluded = URL(fileURLWithPath: bazelPath).standardizedFileURL.path
        let searchDirectories = (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        for executable in ["bazelisk", "bazel"] {
            for directory in searchDirectories {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent(executable)
                    .standardizedFileURL.path
                if candidate != excluded && FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func shellEscaped(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "_./-=:,@".contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
