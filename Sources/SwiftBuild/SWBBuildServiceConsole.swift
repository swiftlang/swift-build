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

public typealias SWBCommandResult = Result<SWBServiceConsoleResult, SWBServiceConsoleError>

/// A command that can be executed within the context of the Swift Build service console.
public protocol SWBServiceConsoleCommand {
    static var name: String { get }
    static func usage() -> String
    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError?
    static func perform(invocation: SWBServiceConsoleCommandInvocation) async -> SWBCommandResult
}

extension SWBServiceConsoleCommand {
    static func validate(invocation: SWBServiceConsoleCommandInvocation) -> SWBServiceConsoleError? {
        if invocation.commandLine.count != 1 {
            return SWBServiceConsoleError.invalidCommandError(description: "usage: " + usage() + "\n")
        }
        return nil
    }

    public static func usage() -> String {
        return name
    }
}

/// Invocation context for an Swift Build service console command.
public struct SWBServiceConsoleCommandInvocation: Sendable {
    public let console: SWBBuildServiceConsole

    /// The command line invocation used to perform the command. The first argument is the name of the command.
    public let commandLine: [String]
}

/// The result of executing an Swift Build service console command.
public struct SWBServiceConsoleResult: Sendable {
    public let output: String
    public let shouldContinue: Bool

    public init(output: String = "", shouldContinue: Bool = true) {
        self.output = output
        self.shouldContinue = shouldContinue
    }
}

/// An error from the Swift Build service console.
public enum SWBServiceConsoleError: Error, Sendable {
    /// A command execution failed.
    case failedCommandError(description: String)

    /// An invalid command was passed.
    case invalidCommandError(description: String)

    /// An unexpected protocol response was received.
    case protocolError(description: String)

    /// A generic request failure error.
    case requestError(description: String)

    init(_ error: any Error, _ diagnostics: [SwiftBuildMessage.DiagnosticInfo] = []) {
        switch error {
        case SwiftBuildError.protocolError(let description):
            self = .protocolError(description: ([description] + diagnostics.map { "\($0.kind.rawValue): \($0.message)" }).joined(separator: "\n"))
        case SwiftBuildError.requestError(let description):
            self = .requestError(description: ([description] + diagnostics.map { "\($0.kind.rawValue): \($0.message)" }).joined(separator: "\n"))
        default:
            self = .failedCommandError(description: (["\(error)"] + diagnostics.map { "\($0.kind.rawValue): \($0.message)" }).joined(separator: "\n"))
        }
    }
}

extension SWBServiceConsoleError: CustomStringConvertible {
    public var description: String {
        // TODO: Display each error type differently?
        switch self {
        case SWBServiceConsoleError.failedCommandError(let msg),
             SWBServiceConsoleError.invalidCommandError(let msg),
             SWBServiceConsoleError.protocolError(let msg),
             SWBServiceConsoleError.requestError(let msg):
            return msg
        }
    }
}

open class SWBBuildServiceConsole: @unchecked Sendable {
    /// The underlying service.
    public let service: SWBBuildService

    /// The path to where inferior products are located, if set by the client.
    public var inferiorProductsPath: String? = nil

    /// The set of managed sessions.
    // FIXME: Don't keep a copy of these on the 'client' side.
    var sessions: [String: SWBBuildServiceSession] = [:]

    /// The active session being manipulated by session commands.
    var activeSession: SWBBuildServiceSession? = nil

    let commandRegistry = SWBServiceConsoleCommandRegistry()

    static let registerCommands: () = {
        registerBuildCommands()
        registerGeneralCommands()
        registerSessionCommands()
        registerXcodeCommands()
        registerXCFrameworkCommands()
    }()

    public init(service: SWBBuildService) {
        self.service = service
        _ = SWBBuildServiceConsole.registerCommands
    }

    public func close() async throws {
        // Close all the sessions
        let result = await Result.catching {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for session in sessions.values {
                    group.addTask {
                        try await session.close()
                    }
                }

                try await group.waitForAll()
            }
        }

        sessions = [:]
        activeSession = nil

        do {
            _ = try result.get()
        } catch {
            throw SwiftBuildError.protocolError(description: "Error closing sessions: \(error)\n")
        }
    }

    /// Create a new session and activate it.
    public func createSession(_ name: String) async throws -> SWBBuildServiceSession {
        // FIXME: <rdar://61869156> Propagate core loading diagnostics
        let (res, _) = await self.service.createSession(name: name, cachePath: nil, inferiorProductsPath: self.inferiorProductsPath, environment: nil)
        let session = try res.get()
        self.sessions[session.uid] = session
        self.activeSession = session
        return session
    }

    /// Delete a session.
    public func deleteSession(_ handle: String) async throws {
        try await self.service.deleteSession(sessionHandle: handle)
        if let session = self.sessions.removeValue(forKey: handle) {
            try await session.close()
        }
    }

    /// Get the active session, or create an automatic session if necessary.
    public func getOrCreateActiveSession() async throws -> SWBBuildServiceSession {
        if let activeSession {
            return activeSession
        }
        return try await createSession("<unnamed>")
    }

    public func applyToActiveSession(_ f: @escaping (SWBBuildServiceSession) -> ([String]) async -> (SWBServiceConsoleResult), _ commandLine: [String]) async -> SWBCommandResult {
        switch await Result.catching({ try await getOrCreateActiveSession() }) {
        case .success(let session):
            return await .success(f(session)(commandLine))
        case .failure(let error):
            return .failure(SWBServiceConsoleError(error))
        }
    }

    // TODO: Document/define the parsing rules for the Swift Build console. <rdar://problem/38407408>
    // The LLVM codec is probably close enough to what we'll eventually want anyways, but it should still be _defined_ somewhere.
    private static let commandSequenceCodec: any CommandSequenceDecodable = LLVMStyleCommandCodec()

    /// Process a console command.
    public func sendCommandString(_ commandLine: String) async -> (result: SWBServiceConsoleResult, success: Bool) {
        do {
            return await sendCommand(try SWBBuildServiceConsole.commandSequenceCodec.decode(commandLine))
        } catch {
            if let error = error as? (any LocalizedError), let errorDescription = error.errorDescription {
                return (SWBServiceConsoleResult(output: "\(errorDescription)\n"), false)
            }
            return (SWBServiceConsoleResult(output: "\(error)\n"), false)
        }
    }

    /// Process a console command.
    public func sendCommand(_ commandLine: [String]) async -> (result: SWBServiceConsoleResult, success: Bool) {
        switch await sendCommand(commandLine) as SWBCommandResult {
        case .success(let commandResult):
            return (commandResult, true)
        case .failure(let error):
            return (SWBServiceConsoleResult(output: error.description), false)
        }
    }

    private func sendCommand(_ commandLine: [String]) async -> SWBCommandResult {
        guard !commandLine.isEmpty, let command = commandLine.first, !command.isEmpty else {
            return .success(SWBServiceConsoleResult(output: ""))
        }

        guard let commandImpl = commandRegistry.commandClass(forName: command) else {
            return .success(SWBServiceConsoleResult(output: "error: unknown command: '\(command)'\n"))
        }

        let invocation = SWBServiceConsoleCommandInvocation(console: self, commandLine: commandLine)
        if let error = commandImpl.validate(invocation: invocation) {
            return .failure(error)
        } else {
            return await commandImpl.perform(invocation: invocation)
        }
    }
}

public final class SWBServiceConsoleCommandRegistry: Sendable {
    private static let commandClasses = LockedValue<[String: any SWBServiceConsoleCommand.Type]>([:])

    public static func registerCommandClass(_ type: any SWBServiceConsoleCommand.Type) {
        commandClasses.withLock { commandClasses in
            if let prev = commandClasses[type.name] {
                preconditionFailure("attempt to register duplicate command class '\(type)' for name '\(type.name)' with prior type \(prev)")
            }
            commandClasses[type.name] = type
        }
    }

    public init() {
    }

    public var allCommandNames: [String] {
        Self.commandClasses.withLock { $0.keys.sorted() }
    }

    public func commandClass(forName name: String) -> (any SWBServiceConsoleCommand.Type)? {
        Self.commandClasses.withLock { $0[name] }
    }
}
