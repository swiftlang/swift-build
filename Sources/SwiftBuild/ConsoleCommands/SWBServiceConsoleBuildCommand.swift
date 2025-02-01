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

import SWBProtocol
import SWBUtil

class SWBServiceConsoleBuildCommand: SWBServiceConsoleCommand {
    static let name = "build"

    static func usage() -> String {
        return name + " [options] <container-path>"
    }

    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        return nil
    }

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        // Parse the arguments.
        var positionalArgs = [String]()
        var configuredTargetNames = [String]()
        var configurationName: String? = nil
        var actionName: String? = nil
        var buildRequestFile: Path? = nil
        var buildParametersFile: Path? = nil
        var derivedDataPath: Path? = nil

        var iterator = invocation.commandLine.makeIterator()
        _ = iterator.next()
        while let arg = iterator.next() {
            switch arg {
            case "--action":
                guard let name = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }

                actionName = name

            case "--target":
                guard let name = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }
                configuredTargetNames.append(name)

            case "--configuration":
                guard let name = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }
                configurationName = name

            case "--derivedDataPath":
                guard let path = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }
                derivedDataPath = Path(path)

            case "--buildRequestFile":
                guard let path = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }
                buildRequestFile = Path(path)

            case "--buildParametersFile":
                guard let path = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }
                buildParametersFile = Path(path)

            case _ where arg.hasPrefix("-"):
                // Skip single-dash arguments so they can be interpreted as user defaults, but only with two or more non-dash characters (to avoid conflicting with the POSIX single-argument convention for arguments like -j).
                if arg.count > 2 && !arg.hasPrefix("--") {
                    guard iterator.next() != nil else {
                        return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                    }
                    break
                }

                return .failure(.invalidCommandError(description: "error: unknown argument \(arg)"))

            default:
                positionalArgs.append(arg)
            }
        }
        if positionalArgs.count != 1 {
            return .failure(.invalidCommandError(description: "usage: " + usage() + "\n"))
        }

        let containerPath = Path(positionalArgs[0])

        return await invocation.console.service.withSession(sessionName: containerPath.str) { session, diagnostics in
            let baseDirectory: AbsolutePath
            do {
                baseDirectory = try AbsolutePath(validating: Path.currentDirectory.str)
            } catch {
                return .failure(.failedCommandError(description: error.localizedDescription))
            }

            // Load the workspace.
            do {
                try await session.loadWorkspace(containerPath: containerPath.str, baseDirectory: baseDirectory)
            } catch {
                return .failure(SWBServiceConsoleError(error))
            }

            // Construct the build parameters.
            var parameters = SWBBuildParameters()

            // If a serialized build parameters file was supplied, use that.
            // More specific command line arguments for the action or configuration
            // will override the contents of those fields within the file if given.
            if let buildParametersFile {
                do {
                    parameters = try JSONDecoder().decode(SWBBuildParameters.self, from: buildParametersFile, fs: localFS)
                } catch {
                    return .failure(.failedCommandError(description: "error: unable to load --buildParametersFile ('\(buildParametersFile.str)'): \(error)"))
                }
            }

            // Default to `build`, if no action was given.
            if let actionName {
                parameters.action = actionName
            } else if parameters.action == nil {
                parameters.action = "build"
            }

            // If we don't have a build configuration at this point try to set a meaningful default
            if parameters.configurationName == nil {
                parameters.configurationName = configurationName ?? "Debug"
            }

            // Find the targets to build.
            let configuredTargets: [SWBConfiguredTarget]
            do {
                let workspaceInfo = try await session.workspaceInfo()
                configuredTargets = try workspaceInfo.configuredTargets(targetNames: configuredTargetNames, parameters: parameters)
            } catch {
                return .failure(.failedCommandError(description: error.localizedDescription))
            }

            // Create and configure a build request.
            var request = SWBBuildRequest()
            request.parameters = parameters
            request.configuredTargets = configuredTargets
            request.useParallelTargets = true
            request.useImplicitDependencies = false
            request.useDryRun = false
            request.hideShellScriptEnvironment = true
            request.showNonLoggedProgress = true

            // If a serialized build request file was supplied, use that.
            // This is higher precedence than everything else, and entirely overrides
            // any command line options pertaining to the build parameters or the
            // targets to build.
            if let buildRequestFile {
                do {
                    request = try JSONDecoder().decode(SWBBuildRequest.self, from: buildRequestFile, fs: localFS)
                } catch {
                    return .failure(.failedCommandError(description: "error: unable to load --buildRequestFile ('\(buildRequestFile.str)'): \(error)"))
                }
            }

            // Override the arena, if requested.
            // This is the absolute highest precedence option, and even overrides the arena info
            // of the serialized build request file above, if one was given. We need to apply the
            // arena info to both the request-global build parameters as well as the target-specific
            // build parameters, since they may have been deserialized from the build request file above,
            // overwriting the build parameters we set up earlier in this method.
            if let path = derivedDataPath {
                request.setDerivedDataPath(path)
            }

            let absoluteDerivedDataPath: AbsolutePath?
            do {
                absoluteDerivedDataPath = try (request.parameters.arenaInfo?.derivedDataPath).map { try AbsolutePath(validating: $0) } ?? nil
            } catch {
                return .failure(.failedCommandError(description: error.localizedDescription))
            }

            return await doBuildOperation(startInfo: .init(baseDirectory: baseDirectory, derivedDataPath: absoluteDerivedDataPath), session: session, sessionCreationDiagnostics: diagnostics, request: request)
        }
    }
}

class SWBServiceConsolePrepareForIndexCommand: SWBServiceConsoleCommand {
    static let name = "prepareForIndex"

    static func usage() -> String {
        return name + " [options] <container-path>"
    }

    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        return nil
    }

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        // Parse the arguments.
        var positionalArgs = [String]()
        var configuredTargetNames = [String]()
        var prepareTargetNames = [String]()
        var configurationName: String? = nil
        var derivedDataPath: Path? = nil

        var iterator = invocation.commandLine.makeIterator()
        _ = iterator.next()
        while let arg = iterator.next() {
            switch arg {
            case "--target":
                guard let name = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }
                configuredTargetNames.append(name)

            case "--prepare":
                guard let name = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }
                prepareTargetNames.append(name)

            case "--configuration":
                guard let name = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }
                configurationName = name

            case "--derivedDataPath":
                guard let path = iterator.next() else {
                    return .failure(.invalidCommandError(description: "error: missing argument for \(arg)"))
                }
                derivedDataPath = Path(path)

            case _ where arg.hasPrefix("-"):
                return .failure(.invalidCommandError(description: "error: unknown argument \(arg)"))

            default:
                positionalArgs.append(arg)
            }
        }
        if positionalArgs.count != 1 {
            return .failure(.invalidCommandError(description: "usage: " + usage() + "\n"))
        }

        let containerPath = Path(positionalArgs[0])

        return await invocation.console.service.withSession(sessionName: containerPath.str) { session, diagnostics in
            let baseDirectory: AbsolutePath
            do {
                baseDirectory = try AbsolutePath(validating: Path.currentDirectory.str)
            } catch {
                return .failure(.failedCommandError(description: error.localizedDescription))
            }

            // Load the workspace.
            do {
                try await session.loadWorkspace(containerPath: containerPath.str, baseDirectory: baseDirectory)
            } catch {
                return .failure(SWBServiceConsoleError(error))
            }

            // Construct the build parameters.
            var parameters = SWBBuildParameters()
            parameters.action = "build"

            // If we don't have a build configuration at this point try to set a meaningful default
            if parameters.configurationName == nil {
                parameters.configurationName = configurationName ?? "Debug"
            }

            // Find the targets to build.
            let configuredTargets: [SWBConfiguredTarget]
            var prepareTargets: [String]?
            do {
                let workspaceInfo = try await session.workspaceInfo()
                configuredTargets = try workspaceInfo.configuredTargets(targetNames: configuredTargetNames, parameters: parameters)

                if !prepareTargetNames.isEmpty {
                    do {
                        prepareTargets = try workspaceInfo.configuredTargets(targetNames: configuredTargetNames, parameters: parameters).map(\.guid)
                    } catch {
                        return .failure(.failedCommandError(description: error.localizedDescription))
                    }
                }
            } catch {
                return .failure(.failedCommandError(description: error.localizedDescription))
            }

            // Create and configure a build request.
            var request = SWBBuildRequest()
            request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: prepareTargets, enableIndexBuildArena: false)
            request.parameters = parameters
            request.configuredTargets = configuredTargets
            request.useParallelTargets = true
            request.useImplicitDependencies = true
            request.useDryRun = false
            request.hideShellScriptEnvironment = true
            request.showNonLoggedProgress = false
            request.continueBuildingAfterErrors = true

            // Override the arena, if requested.
            if let path = derivedDataPath {
                request.setDerivedDataPath(path)
            }

            let absoluteDerivedDataPath: AbsolutePath?
            do {
                absoluteDerivedDataPath = try (request.parameters.arenaInfo?.derivedDataPath).map { try AbsolutePath(validating: $0) } ?? nil
            } catch {
                return .failure(.failedCommandError(description: error.localizedDescription))
            }

            return await doBuildOperation(startInfo: .init(baseDirectory: baseDirectory, derivedDataPath: absoluteDerivedDataPath), session: session, sessionCreationDiagnostics: diagnostics, request: request)
        }
    }
}

extension SWBWorkspaceInfo {
    func configuredTargets(targetNames: [String], parameters: SWBBuildParameters) throws -> [SWBConfiguredTarget] {
        return try targetNames.map { targetName in
            let infos = targetInfos.filter { $0.targetName == targetName }
            switch infos.count {
            case 0:
                throw SwiftBuildError.requestError(description: "Could not find target named '\(targetName)'")
            case 1:
                return SWBConfiguredTarget(guid: infos[0].guid, parameters: parameters)
            default:
                throw SwiftBuildError.requestError(description: "Found multiple targets named '\(targetName)'")
            }
        }
    }
}

extension SWBBuildServiceSession {
    fileprivate func loadWorkspace(containerPath: String, baseDirectory: AbsolutePath) async throws {
        // Make the container path absolute, since the build service process may not have the same working directory as the command line tool.
        let absoluteContainerPath = Path(containerPath).makeAbsolute(relativeTo: Path(baseDirectory.pathString))?.normalize().str ?? containerPath

        return try await loadWorkspace(containerPath: absoluteContainerPath)
    }
}

extension SWBBuildService {
    /// Creates a session with the specified name and runs the `block`. The session is guaranteed to be closed once `block` returns.
    fileprivate func withSession(sessionName: String, _ block: (_ session: SWBBuildServiceSession, _ diagnostics: [SwiftBuildMessage.DiagnosticInfo]) async -> SWBCommandResult) async -> SWBCommandResult {
        let session: SWBBuildServiceSession
        let diagnostics: [SwiftBuildMessage.DiagnosticInfo]
        switch await createSession(name: sessionName, cachePath: nil, inferiorProductsPath: nil, environment: nil) {
        case let (.success(s), d):
            session = s
            diagnostics = d
            let result = await block(session, diagnostics)
            do {
                try await session.close()
            } catch {
                return .failure(.failedCommandError(description: "error: failed to close session: \(error)"))
            }
            return result
        case let (.failure(error), diagnostics):
            return .failure(SWBServiceConsoleError(error, diagnostics))
        }
    }
}

fileprivate func doBuildOperation(startInfo: SwiftBuildMessage.BuildStartedInfo, session: SWBBuildServiceSession, sessionCreationDiagnostics: [SwiftBuildMessage.DiagnosticInfo], request: SWBBuildRequest) async -> SWBCommandResult {
    let systemInfo: SWBSystemInfo
    do {
        systemInfo = try .default()
    } catch {
        return .failure(.failedCommandError(description: error.localizedDescription))
    }

    do {
        try await session.setSystemInfo(systemInfo)
    } catch {
        return .failure(.failedCommandError(description: error.localizedDescription))
    }

    // Also initialize the user info.
    do {
        try await session.setUserInfo(.default)
    } catch {
        return .failure(.failedCommandError(description: error.localizedDescription))
    }

    // FIXME: We need to be able to abstract the console output.
    let stdoutHandle = FileHandle.standardOutput

    func emitEvent(_ message: SwiftBuildMessage) throws {
        let stream = OutputByteStream()
        try stream.write(JSONEncoder(outputFormatting: [.sortedKeys, .withoutEscapingSlashes]).encode(message))
        stream.write("\n")

        // Emit using the same encoding as the Swift compiler streaming JSON structured output.
        //
        // NOTE: The count doesn't include the trailing newline.
        let payload = stream.bytes
        try stdoutHandle.write(contentsOf: Data("\(payload.count - 1)\n".utf8))
        try stdoutHandle.write(contentsOf: Data(payload.bytes))
    }

    // Start a build operation.  We set ourself as the delegate, so we will hear about output and completion.
    do {
        let operation = try await session.createBuildOperation(request: request, delegate: PlanningOperationDelegate())
        for try await event in try await operation.start() {
            switch event {
            case .buildStarted:
                // FIXME: We override the startInfo because the lower layers fill it in with bogus info since we don't normally have the container base path available there. Eventually this should be handled there instead, though.
                try emitEvent(.buildStarted(startInfo))
            default:
                try emitEvent(event)
            }
        }

        switch operation.state {
        case .succeeded:
            return .success(SWBServiceConsoleResult(output: sessionCreationDiagnostics.map { "\($0.kind.rawValue): \($0.message)" }.joined(separator: "\n")))
        case .failed:
            return .failure(.failedCommandError(description: "error: build failed"))
        case .cancelled:
            return .failure(.failedCommandError(description: "error: build was cancelled"))
        case .requested, .running, .aborted:
            return .failure(.failedCommandError(description: "error: unexpected build state"))
        }
    } catch {
        return .failure(.failedCommandError(description: error.localizedDescription))
    }
}

private final class PlanningOperationDelegate: SWBPlanningOperationDelegate, Sendable {
    public func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
        let identity = provisioningSourceData.signingCertificateIdentifier
        if identity == "-" {
            let signedEntitlements = provisioningSourceData.entitlementsDestination == "Signature"
            ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
            : [:]

            let simulatedEntitlements = provisioningSourceData.entitlementsDestination == "__entitlements"
            ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
            : [:]

            return SWBProvisioningTaskInputs(identityHash: "-", identityName: "-", profileName: nil, profileUUID: nil, profilePath: nil, designatedRequirements: nil, signedEntitlements: signedEntitlements.merging(provisioningSourceData.sdkRoot.contains("simulator") ? ["get-task-allow": .plBool(true)] : [:], uniquingKeysWith: { _, new  in new }), simulatedEntitlements: simulatedEntitlements, appIdentifierPrefix: nil, teamIdentifierPrefix: nil, isEnterpriseTeam: nil, keychainPath: nil, errors: [], warnings: [])
        } else if identity.isEmpty {
            return SWBProvisioningTaskInputs()
        } else {
            return SWBProvisioningTaskInputs(identityHash: "-", errors: [["description": "unable to supply accurate provisioning inputs for CODE_SIGN_IDENTITY=\(identity)\""]])
        }
    }

    public func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> SWBExternalToolResult {
        .deferred
    }
}

func registerBuildCommands() {
    for commandClass in ([
        SWBServiceConsoleBuildCommand.self,
        SWBServiceConsolePrepareForIndexCommand.self
    ] as [any SWBServiceConsoleCommand.Type]) { SWBServiceConsoleCommandRegistry.registerCommandClass(commandClass) }
}

extension SwiftBuildMessage.BuildCompletedInfo.Result {
    init(_ state: SWBBuildOperationState) {
        switch state {
        case .requested, .running:
            preconditionFailure()
        case .succeeded:
            self = .ok
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        case .aborted:
            self = .aborted
        }
    }
}

extension SWBBuildRequest {
    mutating func setDerivedDataPath(_ derivedDataPath: Path) {
        let arenaInfo = SWBArenaInfo(
            derivedDataPath: derivedDataPath.str,
            buildProductsPath: derivedDataPath.join("Products").str,
            buildIntermediatesPath: derivedDataPath.join("Intermediates.noindex").str,
            pchPath: derivedDataPath.str,
            indexRegularBuildProductsPath: nil,
            indexRegularBuildIntermediatesPath: nil,
            indexPCHPath: derivedDataPath.str,
            indexDataStoreFolderPath: derivedDataPath.str,
            indexEnableDataStore: parameters.arenaInfo?.indexEnableDataStore ?? false)

        parameters.arenaInfo = arenaInfo
        configuredTargets = configuredTargets.map { configuredTarget in
            var configuredTarget = configuredTarget
            configuredTarget.parameters?.arenaInfo = arenaInfo
            return configuredTarget
        }
    }
}
