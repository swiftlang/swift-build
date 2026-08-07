//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

import Foundation
import Dispatch
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
    static let evidenceDirectory = "SWIFTBUILD_BAZEL_PROXY_EVIDENCE_DIR"
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
        let materialization: String
        let name: String
        let path: String?
        let type: String
    }

    struct Invocation: Codable, Equatable, Sendable {
        let adapterPath: String
        let bazelPath: String
        let bazelrcPath: String
        let environmentKeys: [String]
        let generatorLabel: String
        let receiptSchemaVersion: Int
    }

    struct Project: Codable, Equatable, Sendable {
        let containerName: String
        let identity: String
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
        let indexOutputGroups: [String]
        let outputGroup: String
        let previewOutputGroups: [String]
        let product: Product
        let targetID: String
        let variant: Variant
        let xcodeTargetGUID: String
    }

    let capabilities: Capabilities
    let ignoredXcodeTargetGUIDs: [String]
    let invocation: Invocation
    let project: Project
    let schemaVersion: Int
    let targets: [Target]

    static func load(path: Path, containerPath: Path? = nil) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: path.str))
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.schemaVersion == 2 else {
            throw StubError.error("unsupported Bazel build proxy manifest schema version \(manifest.schemaVersion)")
        }
        guard
            manifest.capabilities.actions.contains("build"),
            manifest.capabilities.actions.contains("clean"),
            manifest.capabilities.actions.contains("indexbuild"),
            manifest.capabilities.actions.contains("preview")
        else {
            throw StubError.error("Bazel build proxy manifest does not declare the build capability")
        }
        guard
            !manifest.invocation.adapterPath.isEmpty,
            !manifest.invocation.bazelPath.isEmpty,
            !manifest.invocation.bazelrcPath.isEmpty,
            !manifest.invocation.generatorLabel.isEmpty,
            manifest.invocation.receiptSchemaVersion == 1,
            !manifest.project.containerName.isEmpty,
            !manifest.project.identity.isEmpty
        else {
            throw StubError.error("Bazel build proxy manifest has an incomplete invocation contract")
        }
        for relativePath in [manifest.invocation.adapterPath, manifest.invocation.bazelrcPath] {
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !relativePath.hasPrefix("/"), !components.contains(".."), !components.contains("") else {
                throw StubError.error("Bazel build proxy manifest contains an unsafe invocation path")
            }
        }
        guard Set(manifest.invocation.environmentKeys).count == manifest.invocation.environmentKeys.count else {
            throw StubError.error("Bazel build proxy manifest contains duplicate environment keys")
        }
        if let containerPath {
            let requestedContainer = URL(fileURLWithPath: containerPath.str).lastPathComponent
            guard requestedContainer == manifest.project.containerName else {
                throw StubError.error(
                    "Bazel build proxy manifest belongs to \(manifest.project.containerName), not \(requestedContainer)"
                )
            }
        }
        for target in manifest.targets {
            switch target.product.materialization {
            case "none":
                guard target.product.path == nil else {
                    throw StubError.error("non-materialized Bazel product declares a path")
                }
            case "copy_file", "copy_tree":
                guard
                    let productPath = target.product.path,
                    productPath.hasPrefix("bazel-out/"),
                    !productPath.split(separator: "/").contains("..")
                else {
                    throw StubError.error("Bazel product path is unsafe or absent")
                }
            default:
                throw StubError.error(
                    "unsupported Bazel product materialization \(target.product.materialization)"
                )
            }
            guard target.outputGroup == "bp \(target.targetID)" else {
                throw StubError.error("Bazel build output group does not match its target ID")
            }
            guard target.indexOutputGroups == ["bc \(target.targetID)", "bi \(target.targetID)"] else {
                throw StubError.error("Bazel index output groups do not match their target ID")
            }
            guard
                target.previewOutputGroups == [
                    "bc \(target.targetID)", "bp \(target.targetID)", "bl \(target.targetID)",
                ]
            else {
                throw StubError.error("Bazel preview output groups do not match their target ID")
            }
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

        let capability =
            if isClean {
                "clean"
            } else if payload.parameters.action == BuildAction.indexBuild.actionName {
                "indexbuild"
            } else {
                "build"
            }
        guard capabilities.actions.contains(capability) else {
            throw StubError.error("Bazel build proxy manifest does not declare the \(capability) capability")
        }
        let action =
            isClean || payload.parameters.action == BuildAction.indexBuild.actionName
            ? "build"
            : payload.parameters.action
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
    case actionCompleted(identity: String)
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
            let action = identifier["actionCompleted"] as? [String: Any]
        {
            let label = action["label"] as? String ?? ""
            let primaryOutput = action["primaryOutput"] as? String ?? ""
            let configuration = action["configuration"] as? String ?? ""
            let identity = [label, primaryOutput, configuration].joined(separator: "|")
            if identity != "||" {
                events.append(.actionCompleted(identity: identity))
            }
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

final class BazelBuildProxyEventLedger: @unchecked Sendable {
    private struct State {
        let handle: FileHandle
        var sequence = 0
    }

    private let operationID: String
    private let state: SWBMutex<State>

    init(url: URL, operationID: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        self.operationID = operationID
        self.state = SWBMutex(State(handle: try FileHandle(forWritingTo: url)))
    }

    deinit {
        state.withLock { try? $0.handle.close() }
    }

    func record(
        _ kind: String,
        entityID: String? = nil,
        status: String? = nil,
        percentComplete: Double? = nil
    ) {
        state.withLock { state in
            state.sequence += 1
            var payload: [String: Any] = [
                "kind": kind,
                "operationID": operationID,
                "sequence": state.sequence,
                "timestampNanoseconds": DispatchTime.now().uptimeNanoseconds,
            ]
            if let entityID { payload["entityID"] = entityID }
            if let status { payload["status"] = status }
            if let percentComplete { payload["percentComplete"] = percentComplete }
            guard
                let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            else {
                return
            }
            try? state.handle.write(contentsOf: data + Data([0x0A]))
            try? state.handle.synchronize()
        }
    }
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

        let manifest = try BazelBuildProxyManifest.load(
            path: Path(manifestPath),
            containerPath: message.request.containerPath
        )
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
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tracePath
            )
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

final class BazelActiveBuildOperation: ActiveBuildOperation, @unchecked Sendable {
    private static let productMutationLock = SWBMutex<Void>(())

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
        var bepFinishedCount = 0
        var completedActionIDs: Set<String> = []
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
    private let eventLedger = SWBMutex<BazelBuildProxyEventLedger?>(nil)
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

        let invocation: BazelBuildProxyInvocation
        do {
            invocation = try createInvocation()
            let ledger = try BazelBuildProxyEventLedger(
                url: invocation.eventLedgerURL,
                operationID: String(id)
            )
            eventLedger.withLock { $0 = ledger }
        } catch {
            emitDiagnostic(.init(kind: .error, path: nil, line: nil, column: nil, message: "Bazel proxy setup failed: \(error)"))
            finish(status: .failed, taskStatus: nil, signalled: false)
            return
        }
        var bepIsSanitized = false
        defer {
            if !bepIsSanitized {
                try? FileManager.default.removeItem(at: invocation.eventFileURL)
            }
            try? invocation.preserveArtifacts(operationID: id)
            invocation.removeTemporaryFiles()
        }

        recordEvent("preparationCompleted")
        request.send(BuildOperationPreparationCompleted())
        recordEvent("operationStarted")
        request.send(BuildOperationStarted(id: id))
        recordEvent("pathMap")
        request.send(BuildOperationReportPathMap(copiedPathMap: [:], generatedFilesPathMap: [:]))
        for target in targetPresentations {
            recordEvent("targetStarted", entityID: String(target.id))
            request.send(BuildOperationTargetStarted(id: target.id, guid: target.mapping.xcodeTargetGUID, info: target.info))
        }
        state.withLock { $0.targetsStarted = true }

        recordEvent("taskStarted", entityID: String(taskID))
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
        recordEvent("console")
        request.send(
            BuildOperationConsoleOutputEmitted(
                data: Array(selectionMessage.utf8),
                taskID: taskID,
                taskSignature: taskSignature
            ))
        recordEvent("progress", percentComplete: -1)
        request.send(
            BuildOperationProgressUpdated(
                statusMessage: invocation.isClean ? "Cleaning Bazel outputs" : "Analyzing Bazel build",
                percentComplete: -1,
                showInLog: false
            ))

        if invocation.isClean {
            do {
                try cleanMaterializedProducts()
                finish(status: .succeeded, taskStatus: .succeeded, signalled: false)
            } catch {
                emitDiagnostic(
                    .init(
                        kind: .error,
                        path: nil,
                        line: nil,
                        column: nil,
                        message: "Bazel product clean failed: \(error)"
                    )
                )
                finish(status: .failed, taskStatus: .failed, signalled: false)
            }
            return
        }

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.environment = invocation.environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputStream = process.makeStream(for: \.standardOutputPipe, using: outputPipe)
        let errorStream = process.makeStream(for: \.standardErrorPipe, using: errorPipe)
        do {
            async let output: Void = consumeConsole(outputStream)
            async let errors: Void = consumeConsole(errorStream)
            try await process.run(interruptible: true)
            try await output
            try await errors

            let exitStatus = try Processes.ExitStatus(process)
            let cancelled = state.withLock { $0.cancelRequested }
            if cancelled {
                finish(status: .cancelled, taskStatus: .cancelled, signalled: exitStatus.wasSignaled)
                return
            }

            do {
                try consumeBEPFile(at: invocation.eventFileURL)
                bepIsSanitized = true
            } catch {
                emitDiagnostic(
                    .init(
                        kind: .error,
                        path: nil,
                        line: nil,
                        column: nil,
                        message: "Bazel event stream is invalid: \(error)"
                    )
                )
                finish(status: .failed, taskStatus: .failed, signalled: exitStatus.wasSignaled)
                return
            }

            if exitStatus.isSuccess && state.withLock({ $0.bepSucceeded == true && $0.bepFinishedCount == 1 }) {
                do {
                    if !invocation.isIndexBuild {
                        try materializeProducts(workspace: invocation.workingDirectory)
                    }
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

    private func consumeBEPFile(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let maximumLineBytes = 1024 * 1024
        let maximumFileBytes = 256 * 1024 * 1024
        var totalBytes = 0
        var pending = Data()
        var sanitizedBEP = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            totalBytes += chunk.count
            guard totalBytes <= maximumFileBytes else {
                throw StubError.error("BEP exceeds the 256 MB processing limit")
            }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if let sanitized = try handleBEP(data: line, maximumBytes: maximumLineBytes) {
                    sanitizedBEP.append(sanitized)
                    sanitizedBEP.append(0x0A)
                }
            }
            guard pending.count <= maximumLineBytes else {
                throw StubError.error("BEP line exceeds the 1 MB processing limit")
            }
        }
        if !pending.isEmpty {
            if let sanitized = try handleBEP(data: pending, maximumBytes: maximumLineBytes) {
                sanitizedBEP.append(sanitized)
                sanitizedBEP.append(0x0A)
            }
        }
        guard state.withLock({ $0.bepFinishedCount == 1 }) else {
            throw StubError.error("BEP must contain exactly one finished event")
        }
        try sanitizedBEP.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func handleBEP(data: Data, maximumBytes: Int) throws -> Data? {
        guard data.count <= maximumBytes else {
            throw StubError.error("BEP line exceeds the 1 MB processing limit")
        }
        guard
            !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let line = String(data: data, encoding: .utf8)
        else {
            throw StubError.error("BEP contains a malformed JSON line")
        }
        try handleBEP(line: line)
        guard let safeObject = Self.sanitizedBEPEvent(object) else { return nil }
        return try JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys])
    }

    static func sanitizedBEPEvent(_ object: [String: Any]) -> [String: Any]? {
        var safe: [String: Any] = [:]
        if let identifier = object["id"] as? [String: Any],
            let action = identifier["actionCompleted"] as? [String: Any]
        {
            var safeID: [String: Any] = [:]
            for key in ["label", "primaryOutput", "configuration"] {
                if let value = action[key] as? String { safeID[key] = value }
            }
            if !safeID.isEmpty {
                safe["id"] = ["actionCompleted": safeID]
                if let actionPayload = object["action"] as? [String: Any],
                    let success = actionPayload["success"] as? Bool
                {
                    safe["action"] = ["success": success]
                }
            }
        } else if let identifier = object["id"] as? [String: Any],
            let target = identifier["targetCompleted"] as? [String: Any],
            let label = target["label"] as? String
        {
            safe["id"] = ["targetCompleted": ["label": label]]
            if let completed = object["completed"] as? [String: Any],
                let success = completed["success"] as? Bool
            {
                safe["completed"] = ["success": success]
            }
        }
        if object["progress"] is [String: Any] {
            safe["progress"] = [:]
        }
        if let metrics = object["buildMetrics"] as? [String: Any],
            let summary = metrics["actionSummary"] as? [String: Any]
        {
            if let count = summary["actionsExecuted"] as? String {
                safe["buildMetrics"] = ["actionSummary": ["actionsExecuted": count]]
            } else if let count = summary["actionsExecuted"] as? Int {
                safe["buildMetrics"] = ["actionSummary": ["actionsExecuted": count]]
            }
        }
        if let finished = object["finished"] as? [String: Any],
            let success = finished["overallSuccess"] as? Bool
        {
            safe["finished"] = ["overallSuccess": success]
        }
        return safe.isEmpty ? nil : safe
    }

    private func consumeConsole(_ stream: AsyncThrowingStream<SWBDispatchData, any Error>) async throws {
        var pending = ""
        for try await chunk in stream {
            let bytes = Array(chunk)
            recordEvent("console")
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

    private func handleBEP(line: String) throws {
        for event in BazelBuildProxyBEPParser.parse(line: line) {
            switch event {
            case .progress(let completed, let total):
                emitProgress(completed: completed, total: total)
            case .actionCompleted(let identity):
                let count = state.withLock { state in
                    state.completedActionIDs.insert(identity)
                    return state.completedActionIDs.count
                }
                let message = "Bazel completed \(count) actions\n"
                recordEvent("console")
                request.send(
                    BuildOperationConsoleOutputEmitted(
                        data: Array(message.utf8),
                        taskID: taskID,
                        taskSignature: taskSignature
                    )
                )
            case .actionCount(let count):
                recordEvent("progress", percentComplete: 100)
                request.send(
                    BuildOperationProgressUpdated(
                        statusMessage: "Bazel completed \(count) actions",
                        percentComplete: 100,
                        showInLog: true
                    ))
                let message = "Bazel completed \(count) actions\n"
                recordEvent("console")
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
                let count = state.withLock { state in
                    state.bepFinishedCount += 1
                    state.bepSucceeded = succeeded
                    return state.bepFinishedCount
                }
                guard count == 1 else {
                    throw StubError.error("BEP contains duplicate finished events")
                }
            }
        }
    }

    private func handleConsole(line: String) {
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
        let percent = 100 * Double(completed) / Double(total)
        recordEvent("progress", percentComplete: percent)
        request.send(
            BuildOperationProgressUpdated(
                statusMessage: "Building \(completed) of \(total) Bazel actions",
                percentComplete: percent,
                showInLog: false
            ))
    }

    private func emitDiagnostic(_ diagnostic: BazelBuildProxyDiagnostic) {
        let shouldEmit = state.withLock { $0.emittedDiagnostics.insert(diagnostic).inserted }
        guard shouldEmit else { return }
        recordEvent("diagnostic")

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
        try Self.productMutationLock.withLock { _ in
            try materializeProductsUnlocked(workspace: workspace)
        }
    }

    private func materializeProductsUnlocked(workspace: URL) throws {
        struct TransactionEntry {
            let destination: URL
            let staged: URL
            var backup: URL?
            var committed = false
        }

        let fileManager = FileManager.default
        var entries: [TransactionEntry] = []
        defer {
            for entry in entries {
                Self.makeTreeRemovable(entry.staged, fileManager: fileManager)
                try? fileManager.removeItem(at: entry.staged)
                if let backup = entry.backup {
                    Self.makeTreeRemovable(backup, fileManager: fileManager)
                    try? fileManager.removeItem(at: backup)
                }
            }
        }

        for target in targetPresentations {
            guard target.mapping.product.materialization != "none" else { continue }
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
            guard destination.lastPathComponent == target.mapping.product.basename else {
                throw StubError.error("Xcode product destination does not match the manifest basename")
            }
            guard fileManager.fileExists(atPath: standardizedSource.path) else {
                throw StubError.error("Bazel product is missing at \(standardizedSource.path)")
            }
            if standardizedSource.path == destination.path { continue }

            let values = try standardizedSource.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            switch target.mapping.product.materialization {
            case "copy_tree" where values.isDirectory != true:
                throw StubError.error("Bazel tree product is not a directory at \(standardizedSource.path)")
            case "copy_file" where values.isRegularFile != true:
                throw StubError.error("Bazel file product is not a regular file at \(standardizedSource.path)")
            case "copy_tree", "copy_file":
                break
            default:
                throw StubError.error("unsupported Bazel product materialization strategy")
            }

            let parent = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let staged = parent.appendingPathComponent(
                ".bazel-proxy-\(UUID().uuidString)-\(destination.lastPathComponent)"
            )
            try fileManager.copyItem(at: standardizedSource, to: staged)
            try Self.makeTreeOwnerWritable(staged, fileManager: fileManager)
            entries.append(.init(destination: destination, staged: staged))
        }

        do {
            for index in entries.indices {
                let destination = entries[index].destination
                if fileManager.fileExists(atPath: destination.path) {
                    let backup = destination.deletingLastPathComponent().appendingPathComponent(
                        ".bazel-proxy-replaced-\(UUID().uuidString)-\(destination.lastPathComponent)"
                    )
                    try fileManager.moveItem(at: destination, to: backup)
                    entries[index].backup = backup
                }
                try fileManager.moveItem(at: entries[index].staged, to: destination)
                entries[index].committed = true
            }
        } catch {
            for entry in entries.reversed() {
                if entry.committed, fileManager.fileExists(atPath: entry.destination.path) {
                    Self.makeTreeRemovable(entry.destination, fileManager: fileManager)
                    try? fileManager.removeItem(at: entry.destination)
                }
                if let backup = entry.backup,
                    fileManager.fileExists(atPath: backup.path),
                    !fileManager.fileExists(atPath: entry.destination.path)
                {
                    try? fileManager.moveItem(at: backup, to: entry.destination)
                }
            }
            throw error
        }
    }

    private func cleanMaterializedProducts() throws {
        try Self.productMutationLock.withLock { _ in
            try cleanMaterializedProductsUnlocked()
        }
    }

    private func cleanMaterializedProductsUnlocked() throws {
        let fileManager = FileManager.default
        for target in targetPresentations {
            guard target.mapping.product.materialization != "none" else { continue }
            guard let destinationPath = target.destinationProductPath?.nilIfEmpty else {
                throw StubError.error("Xcode has no target build directory for \(target.mapping.bazelLabel)")
            }
            let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL
            guard destination.lastPathComponent == target.mapping.product.basename else {
                throw StubError.error("refusing to clean a destination outside the manifest product mapping")
            }
            if fileManager.fileExists(atPath: destination.path) {
                Self.makeTreeRemovable(destination, fileManager: fileManager)
                try fileManager.removeItem(at: destination)
            }
        }
    }

    private func recordEvent(
        _ kind: String,
        entityID: String? = nil,
        status: String? = nil,
        percentComplete: Double? = nil
    ) {
        eventLedger.withLock { ledger in
            ledger?.record(
                kind,
                entityID: entityID,
                status: status,
                percentComplete: percentComplete
            )
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

    static func makeTreeOwnerWritable(_ root: URL, fileManager: FileManager) throws {
        var urls = [root]
        var enumerationError: (any Error)?
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) {
            urls.append(contentsOf: enumerator.compactMap { $0 as? URL })
        }
        if let enumerationError { throw enumerationError }
        for url in urls {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                continue
            }
            guard let permissions = attributes[.posixPermissions] as? NSNumber else {
                throw StubError.error("materialized product item has no POSIX permissions at \(url.path)")
            }
            try fileManager.setAttributes(
                [.posixPermissions: permissions.intValue | 0o200],
                ofItemAtPath: url.path
            )
        }
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
            recordEvent("taskEnded", entityID: String(taskID))
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
                recordEvent("targetEnded", entityID: String(target.id))
                request.send(BuildOperationTargetEnded(id: target.id))
            }
        }
        session.unregisterActiveBuild(self)
        let ledgerStatus: String =
            switch status {
            case .succeeded: "succeeded"
            case .cancelled: "cancelled"
            default: "failed"
            }
        recordEvent("operationEnded", status: ledgerStatus)
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

        let integrationDirectory =
            setting("BAZEL_INTEGRATION_DIR")
            ?? Self.inferIntegrationDirectory(
                from: manifestPath,
                bazelrcPath: manifest.invocation.bazelrcPath
            )
            ?? Self.inferIntegrationDirectory(from: manifestPath)
        guard let integrationDirectory else {
            throw StubError.error("unable to determine rules_xcodeproj integration directory")
        }
        guard
            let adapterURL = Self.resolveProjectRelativePath(
                manifest.invocation.adapterPath,
                from: manifestPath
            )
        else {
            throw StubError.error("unable to resolve the rules_xcodeproj build proxy adapter")
        }

        var evaluatedEnvironment: [String: String] = [:]
        for key in manifest.invocation.environmentKeys {
            if let value = setting(key) {
                evaluatedEnvironment[key] = value
            }
        }
        evaluatedEnvironment["BAZEL_REAL"] = try BazelBuildProxyInvocation.resolveBazelReal(
            configuredPath: evaluatedEnvironment["BAZEL_REAL"],
            manifestProxyPath: manifest.invocation.bazelPath,
            environment: processEnvironment
        )

        let isClean: Bool
        switch buildRequest.buildCommand {
        case .cleanBuildFolder, .cleanBuildFolderAndCaches:
            isClean = true
        default:
            isClean = false
        }
        let action = buildRequest.parameters.action.actionName
        let isIndexBuild = buildRequest.parameters.action == .indexBuild
        let isPreview = evaluatedEnvironment["ENABLE_PREVIEWS"] == "YES"
        if isPreview, !manifest.capabilities.actions.contains("preview") {
            throw StubError.error("Bazel build proxy manifest does not declare the preview capability")
        }
        let outputGroups: [String]
        if isIndexBuild {
            outputGroups = targets.flatMap(\.indexOutputGroups)
        } else if isPreview {
            outputGroups = targets.flatMap(\.previewOutputGroups)
        } else {
            outputGroups = targets.map(\.outputGroup)
        }

        return try BazelBuildProxyInvocation(
            action: action,
            adapterURL: adapterURL,
            environmentKeys: manifest.invocation.environmentKeys,
            evaluatedEnvironment: evaluatedEnvironment,
            integrationDirectory: integrationDirectory,
            isClean: isClean,
            labels: targets.map(\.bazelLabel),
            outputGroups: outputGroups,
            targetIDs: targets.map(\.targetID),
            workspace: workspace
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

    private static func resolveProjectRelativePath(
        _ relativePath: String,
        from manifestPath: Path
    ) -> URL? {
        var container = URL(fileURLWithPath: manifestPath.str).deletingLastPathComponent()
        while container.path != "/" && container.pathExtension != "xcodeproj" {
            container.deleteLastPathComponent()
        }
        guard container.pathExtension == "xcodeproj" else { return nil }
        let resolved = container.appendingPathComponent(relativePath).standardizedFileURL
        guard resolved.path.hasPrefix(container.standardizedFileURL.path + "/") else {
            return nil
        }
        return resolved
    }
}

struct BazelBuildProxyInvocation: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let eventFileURL: URL
    let eventLedgerURL: URL
    let receiptFileURL: URL
    let workingDirectory: URL
    let isClean: Bool
    let isIndexBuild: Bool
    let isPreview: Bool
    private let temporaryDirectory: URL

    var displayString: String {
        ([executableURL.path] + arguments).map(shellEscaped).joined(separator: " ")
    }

    init(
        action: String,
        adapterURL: URL,
        environmentKeys: [String],
        evaluatedEnvironment: [String: String],
        integrationDirectory: String,
        isClean: Bool,
        labels: [String],
        outputGroups: [String],
        targetIDs: [String],
        workspace: String
    ) throws {
        let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true)
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else {
            throw StubError.error("Bazel workspace does not exist at \(workspace)")
        }
        workingDirectory = workspaceURL
        self.isClean = isClean
        isIndexBuild = action == BuildAction.indexBuild.actionName
        isPreview = evaluatedEnvironment["ENABLE_PREVIEWS"] == "YES"
        guard FileManager.default.isExecutableFile(atPath: adapterURL.path) else {
            throw StubError.error("Bazel build proxy adapter is not executable at \(adapterURL.path)")
        }
        executableURL = adapterURL
        arguments = []
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-build-bazel-proxy", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: temporaryRoot.path
        )
        temporaryDirectory =
            temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        eventFileURL = temporaryDirectory.appendingPathComponent("build-event.jsonl")
        eventLedgerURL = temporaryDirectory.appendingPathComponent("event-ledger.jsonl")
        receiptFileURL = temporaryDirectory.appendingPathComponent("invocation-receipt.json")
        let requestDirectory = temporaryDirectory.appendingPathComponent("request", isDirectory: true)
        try FileManager.default.createDirectory(
            at: requestDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.writeLines(labels, to: requestDirectory.appendingPathComponent("labels"))
        try Self.writeLines(outputGroups, to: requestDirectory.appendingPathComponent("output_groups"))
        try Self.writeLines(targetIDs, to: requestDirectory.appendingPathComponent("target_ids"))

        let processEnvironment = ProcessInfo.processInfo.environment
        var selectedEnvironment = evaluatedEnvironment.filter { environmentKeys.contains($0.key) }
        selectedEnvironment.merge(
            Self.sanitizedEnvironment(
                processEnvironment,
                bazelRealPath: evaluatedEnvironment["BAZEL_REAL"],
                developerDirectory: evaluatedEnvironment["DEVELOPER_DIR"],
                workspace: workspace
            ),
            uniquingKeysWith: { selected, _ in selected }
        )
        selectedEnvironment["ACTION"] = action
        selectedEnvironment["SRCROOT"] = workspace
        selectedEnvironment["BAZEL_INTEGRATION_DIR"] = integrationDirectory
        selectedEnvironment["SWIFTBUILD_BAZEL_PROXY_REQUEST_DIR"] = requestDirectory.path
        selectedEnvironment["SWIFTBUILD_BAZEL_PROXY_BEP_PATH"] = eventFileURL.path
        selectedEnvironment["SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT"] = receiptFileURL.path
        environment = selectedEnvironment
    }

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func preserveArtifacts(operationID: Int) throws {
        guard
            let evidenceDirectory = ProcessInfo.processInfo.environment[
                BazelBuildProxyEnvironment.evidenceDirectory
            ]?.nilIfEmpty
        else {
            return
        }
        let evidenceRoot = URL(fileURLWithPath: evidenceDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: evidenceRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: evidenceRoot.path
        )
        let destination = evidenceRoot.appendingPathComponent(
            "operation-\(operationID)-\(temporaryDirectory.lastPathComponent)",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: temporaryDirectory, to: destination)
    }

    private static func writeLines(_ values: [String], to url: URL) throws {
        guard !values.contains(where: { $0.contains("\n") || $0.contains("\r") }) else {
            throw StubError.error("Bazel build proxy request values must be single-line")
        }
        let data = Data((Array(Set(values)).sorted().joined(separator: "\n") + "\n").utf8)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
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

    static func resolveBazelReal(
        configuredPath: String?,
        manifestProxyPath: String,
        environment: [String: String]
    ) throws -> String {
        let candidate =
            environment[BazelBuildProxyEnvironment.bazelPath]?.nilIfEmpty
            ?? configuredPath?.nilIfEmpty
            ?? findBazelReal(excluding: manifestProxyPath, environment: environment)
        guard let candidate else {
            throw StubError.error("unable to locate the real Bazel executable")
        }
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
        guard candidate.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: standardized) else {
            throw StubError.error("configured Bazel executable is not an executable absolute path")
        }
        return standardized
    }

    private func shellEscaped(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "_./-=:,@".contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
