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

import SWBProtocol

class SWBServiceConsoleShowPlatformsCommand: SWBServiceConsoleCommand {
    static let name = "showPlatforms"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        return await invocation.console.applyToActiveSession(SWBBuildServiceSession.getPlatformsDump, invocation.commandLine)
    }
}

class SWBServiceConsoleShowSDKsCommand: SWBServiceConsoleCommand {
    static let name = "showSDKs"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        return await invocation.console.applyToActiveSession(SWBBuildServiceSession.getSDKsDump, invocation.commandLine)
    }
}

class SWBServiceConsoleShowSpecsCommand: SWBServiceConsoleCommand {
    static let name = "showSpecs"

    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        return nil
    }

    static func usage() -> String {
        return "\(name) [--conforms-to <product-type-identifier>]"
    }

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        return await invocation.console.applyToActiveSession(SWBBuildServiceSession.getSpecsDump, invocation.commandLine)
    }
}

class SWBServiceConsoleShowToolchainsCommand: SWBServiceConsoleCommand {
    static let name = "showToolchains"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        return await invocation.console.applyToActiveSession(SWBBuildServiceSession.getToolchainsDump, invocation.commandLine)
    }
}

class SWBServiceConsoleDescribeBuildSettingsCommand: SWBServiceConsoleCommand {
    static let name = "describeBuildSettings"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        return await invocation.console.applyToActiveSession(SWBBuildServiceSession.getBuildSettingsDescriptionDump, invocation.commandLine)
    }
}

func registerXcodeCommands() {
    for commandClass in ([
        SWBServiceConsoleShowPlatformsCommand.self,
        SWBServiceConsoleShowSDKsCommand.self,
        SWBServiceConsoleShowSpecsCommand.self,
        SWBServiceConsoleShowToolchainsCommand.self,
        SWBServiceConsoleDescribeBuildSettingsCommand.self
    ] as [any SWBServiceConsoleCommand.Type]) {
        SWBServiceConsoleCommandRegistry.registerCommandClass(commandClass)
    }
}

extension SWBBuildService {
    /// Dispatch a dump request.
    fileprivate func requestDump(_ message: any SWBProtocol.Message) async -> SWBServiceConsoleResult {
        switch await send(message) {
        case let asError as ErrorResponse:
            return SWBServiceConsoleResult(output: "error: \(asError.description)\n")
        case let asString as StringResponse:
            return SWBServiceConsoleResult(output: asString.value)
        case let result:
            return SWBServiceConsoleResult(output: "fatal error: unexpected reply: \(String(describing: result)))\n")
        }
    }
}

extension SWBBuildServiceSession {
    /// Get a dump of the registered platforms.
    public func getPlatformsDump(commandLine: [String]) async -> SWBServiceConsoleResult {
        await service.requestDump(GetPlatformsRequest(sessionHandle: uid, commandLine: commandLine))
    }

    /// Get a dump of the registered SDKs.
    public func getSDKsDump(commandLine: [String]) async -> SWBServiceConsoleResult {
        await service.requestDump(GetSDKsRequest(sessionHandle: uid, commandLine: commandLine))
    }

    /// Get a dump of the registered specifications.
    public func getSpecsDump(commandLine: [String]) async -> SWBServiceConsoleResult {
        await service.requestDump(GetSpecsRequest(sessionHandle: uid, commandLine: commandLine))
    }

    /// Get a dump of the registered toolchains.
    public func getToolchainsDump(commandLine: [String]) async -> SWBServiceConsoleResult {
        await service.requestDump(GetToolchainsRequest(sessionHandle: uid, commandLine: commandLine))
    }

    /// Get a dump of the registered build settings.
    public func getBuildSettingsDescriptionDump(commandLine: [String]) async -> SWBServiceConsoleResult {
        await service.requestDump(GetBuildSettingsDescriptionRequest(sessionHandle: uid, commandLine: commandLine))
    }
}
