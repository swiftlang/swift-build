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
import SWBUtil

class SWBServiceConsoleCreateSessionCommand: SWBServiceConsoleCommand {
    static let name = "createSession"

    static func usage() -> String {
        return name + " <name>"
    }

    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        if invocation.commandLine.count != 2 {
            return SWBServiceConsoleError.invalidCommandError(description: "usage: " + usage() + "\n")
        }
        return nil
    }

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        let name = invocation.commandLine[1]
        switch await Result.catching({ try await invocation.console.createSession(name) }) {
        case .success(let session):
            return .success(SWBServiceConsoleResult(output: "\(session.uid)\n"))
        case .failure(let error):
            return .failure(SWBServiceConsoleError(error))
        }
    }
}

class SWBServiceConsoleListSessionsCommand: SWBServiceConsoleCommand {
    static let name = "listSessions"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        switch await Result.catching({ try await invocation.console.service.listSessions() as ListSessionsResponse }) {
        case .success(let sessions):
            return .success(SWBServiceConsoleResult(output: sessions.sessions.sorted(byKey: <).map { uid, info in "\(uid): \(info.name) (\(info.activeBuildCount) active builds, \(info.activeNormalBuildCount) normal, \(info.activeIndexBuildCount) index)" }.joined(separator: "\n") + "\n"))
        case .failure(let error):
            return .failure(SWBServiceConsoleError(error))
        }
    }
}

class SWBServiceConsoleShowSessionCommand: SWBServiceConsoleCommand {
    static let name = "showSession"

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        guard let session = invocation.console.activeSession else {
            return .success(SWBServiceConsoleResult(output: "no active session\n"))
        }
        return .success(SWBServiceConsoleResult(output: "activeSession = '\(session.uid)'\n"))
    }
}

class SWBServiceConsoleSelectSessionCommand: SWBServiceConsoleCommand {
    static let name = "selectSession"

    static func usage() -> String {
        return name + " <uid>"
    }

    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        if invocation.commandLine.count != 2 {
            return SWBServiceConsoleError.invalidCommandError(description: "usage: " + usage() + "\n")
        }
        return nil
    }

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        let uid = invocation.commandLine[1]
        guard let session = invocation.console.sessions.values.filter({ $0.uid == uid }).first else {
            return .failure(.failedCommandError(description: "error: no session for UID '\(uid)'\n"))
        }
        invocation.console.activeSession = session
        return .success(SWBServiceConsoleResult(output: "ok\n"))
    }
}

class SWBServiceConsoleDeleteSessionCommand: SWBServiceConsoleCommand {
    static let name = "deleteSession"

    static func usage() -> String {
        return name + " <uid>"
    }

    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        if invocation.commandLine.count != 2 {
            return SWBServiceConsoleError.invalidCommandError(description: "usage: " + usage() + "\n")
        }
        return nil
    }

    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult {
        let uid = invocation.commandLine[1]
        switch await Result.catching({ try await invocation.console.deleteSession(uid) }) {
        case .success:
            return .success(SWBServiceConsoleResult(output: "ok\n"))
        case .failure(let error):
            return .failure(SWBServiceConsoleError(error))
        }
    }
}

func registerSessionCommands() {
    for commandClass in ([
        SWBServiceConsoleCreateSessionCommand.self,
        SWBServiceConsoleListSessionsCommand.self,
        SWBServiceConsoleShowSessionCommand.self,
        SWBServiceConsoleSelectSessionCommand.self,
        SWBServiceConsoleDeleteSessionCommand.self,
    ] as [any SWBServiceConsoleCommand.Type]) {
        SWBServiceConsoleCommandRegistry.registerCommandClass(commandClass)
    }
}
