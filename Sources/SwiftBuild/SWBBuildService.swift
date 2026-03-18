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

public import Foundation

import SWBProtocol
import SWBUtil


/// A generic error from Swift Build.
//
// FIXME: We should refine this.
public enum SwiftBuildError: Hashable, CustomStringConvertible, LocalizedError {
    /// An unexpected protocol response was received.
    case protocolError(description: String)

    /// A generic request failure error.
    case requestError(description: String)

    public var description: String {
        switch self {
        case .protocolError(description: let description):
            return description
        case .requestError(description: let description):
            return description
        }
    }

    public var errorDescription: String? {
        description
    }
}

/// Proxy object for communicating with the Swift Build build service.
public final class SWBBuildService: Sendable {
    private let connectionMode: SWBBuildServiceConnectionMode
    private let variant: SWBBuildServiceVariant
    private let serviceBundleURL: URL?
    private var connection: SWBBuildServiceConnection

    /// An opaque identifier representing the lifetime of the service's specific connection instance.
    var connectionUUID: Foundation.UUID {
        return connection.uuid
    }

    /// Whether or not the underlying Swift Build service subprocess has terminated.
    ///
    /// A terminated service subprocess can be restarted by calling ``restart()``.
    public var terminated: Bool {
        return connection.hasTerminated
    }

    /// The PID of the active service subprocess, for debugging purposes. This may change at any time, so this property should not be used for basing any actual functionality on.
    ///
    /// Returns `nil` if there is no underlying subprocess, which is the case if the build service is being run in-process.
    var subprocessPID: pid_t? {
        return connection.subprocessPID
    }

    public init(connectionMode: SWBBuildServiceConnectionMode = .default, variant: SWBBuildServiceVariant = .default, serviceBundleURL: URL? = nil) async throws {
        self.connectionMode = connectionMode
        self.variant = variant
        self.serviceBundleURL = serviceBundleURL
        let connection = try await SWBBuildServiceConnection(connectionMode: connectionMode, variant: variant, serviceBundleURL: serviceBundleURL)
        self.connection = connection
        connection.resume()
    }

    /// Restarts the connection to the build service executable.
    ///
    /// This can be called to restart communications if the connection has terminated
    /// due to the build service executable exiting or crashing. The service can only
    /// be restarted if it is being run as an external process (not if it is being run
    /// in-process).
    public func restart() async throws {
        if case .inProcess = connectionMode {
            throw StubError.error("Can't restart the service process connection because the service is running in-process.")
        }

        let connection = try await SWBBuildServiceConnection(connectionMode: connectionMode, variant: variant, serviceBundleURL: serviceBundleURL)
        await self.connection.close()
        self.connection = connection
        connection.resume()
    }

    public func close() async {
        await connection.close()
    }

    @_spi(Testing) public func terminate() async {
        await connection.terminate()
    }

    /// Sends a message returns its response.
    /// - Returns: The reply message.
    internal func send(_ message: any Message) async -> any Message {
        let serializer = MsgPackSerializer()
        IPCMessage(message).serialize(to: serializer)
        let contents = serializer.byteString.bytes.withUnsafeBytes(SWBDispatchData.init(bytes:))
        let data = await self.connection.send(contents)

        // Deserialize the message.
        //
        // FIXME: Shouldn't need to copy here.
        let deserializer = MsgPackDeserializer(ByteString(Array(data)))
        do {
            return try (deserializer.deserialize() as IPCMessage).message
        } catch {
            return ErrorResponse("Error decoding response to \(type(of: message)) message: \(error)")
        }
    }

    internal func send(_ message: any Message, onChannel channel: UInt64) {
        let serializer = MsgPackSerializer()
        IPCMessage(message).serialize(to: serializer)
        let contents = serializer.byteString

        contents.bytes.withUnsafeBytes{ buffer in
            self.connection.send(SWBDispatchData(bytes: buffer), onChannel: channel)
        }
    }

    internal func openChannel() -> SWBChannel {
        SWBChannel(service: self)
    }

    internal func openChannel(handler block: @Sendable @escaping (UInt64, any Message) -> Void) -> UInt64 {
        return self.connection.openChannel{ channel, data in
            // Deserialize the message.
            //
            // FIXME: Shouldn't need to copy here.
            let deserializer = MsgPackDeserializer(ByteString(Array(data)))
            do {
                let wrapper: IPCMessage = try deserializer.deserialize()
                block(channel, wrapper.message)
            } catch {
                block(channel, ErrorResponse("Error decoding response: \(error)"))
            }
        }
    }

    internal func openChannel(handler block: @Sendable @escaping (any Message) -> Void) -> UInt64 {
        openChannel(handler: { (_, message) in block(message) })
    }

    internal func closeChannel(_ channel: UInt64) {
        return self.connection.close(channel: channel)
    }

    /// Sends a message returns its response.
    /// - Throws: If the reply message is not of the expected `ResponseMessage` type.
    /// - Returns: The reply message.
    internal func send<R: RequestMessage>(request message: R) async throws -> R.ResponseMessage {
        switch await send(message) {
        case let message as R.ResponseMessage:
            return message
        case let message as ErrorResponse:
            throw SwiftBuildError.requestError(description: message.description)
        default:
            throw SwiftBuildError.protocolError(description: "unexpected response")
        }
    }

    public func checkAlive() async throws {
        _ = try await send(request: PingRequest())
    }

    /// Request the service to clear as many caches as possible.
    public func clearAllCaches() async throws {
        _ = try await send(request: ClearAllCachesRequest())
    }

    /// Set a service configurable value.
    public func setConfig(key: String, value: String) async throws {
        _ = try await send(request: SetConfigItemRequest(key: key, value: value))
    }

    /// Get a dump of the Swift Build statistics.
    public func getStatisticsDump() async throws -> String {
        try await send(request: GetStatisticsRequest()).value
    }

    @available(*, deprecated, message: "Switch to createSession(name, developerPath, cachePath, inferiorProductsPath , environment)")
    public func createSession(name: String, developerPath: String? = nil, cachePath: String?, inferiorProductsPath: String?) async -> (Result<SWBBuildServiceSession, any Error>, [SwiftBuildMessage.DiagnosticInfo]) {
        await createSession(name: name, developerPath: developerPath, cachePath: cachePath, inferiorProductsPath: inferiorProductsPath, environment: nil)
    }

    // ABI compatibility
    public func createSession(name: String, developerPath: String? = nil, cachePath: String?, inferiorProductsPath: String?, environment: [String:String]?) async -> (Result<SWBBuildServiceSession, any Error>, [SwiftBuildMessage.DiagnosticInfo]) {
        await createSession(name: name, developerPath: developerPath, resourceSearchPaths: [], cachePath: cachePath, inferiorProductsPath: inferiorProductsPath, environment: environment)
    }

    /// Create a new service session.
    ///
    /// - Parameters:
    ///   - name: The name of the workspace.
    ///   - cachePath: If provided, the path to where Swift Build should cache per-workspace data.
    ///   - inferiorProductsPath: If provided, the path to where inferior Xcode build data is located.
    ///   - environment: If provided, a set of environment variables that are relevant to the build session's context
    /// - returns: The new session.
    public func createSession(name: String, developerPath: String? = nil, resourceSearchPaths: [String], cachePath: String?, inferiorProductsPath: String?, environment: [String:String]?) async -> (Result<SWBBuildServiceSession, any Error>, [SwiftBuildMessage.DiagnosticInfo]) {
        do {
            let response = try await send(request: CreateSessionRequest(name: name, developerPath: developerPath.map(Path.init), resourceSearchPaths: resourceSearchPaths.map(Path.init), cachePath: cachePath.map(Path.init), inferiorProductsPath: inferiorProductsPath.map(Path.init), environment: environment))
            let diagnostics = response.diagnostics.map { SwiftBuildMessage.DiagnosticInfo(.init($0, .global)) }
            if let sessionID = response.sessionID {
                return (.success(SWBBuildServiceSession(name: name, uid: sessionID, service: self)), diagnostics)
            } else {
                return (.failure(SwiftBuildError.requestError(description: "Could not initialize build system")), diagnostics)
            }
        } catch {
            return (.failure(error), [])
        }
    }

    public func createSession(name: String, swiftToolchainPath: String, resourceSearchPaths: [String], cachePath: String?, inferiorProductsPath: String?, environment: [String:String]?) async -> (Result<SWBBuildServiceSession, any Error>, [SwiftBuildMessage.DiagnosticInfo]) {
        do {
            let response = try await send(request: CreateSessionRequest(name: name, developerPath: .swiftToolchain(Path(swiftToolchainPath)), resourceSearchPaths: resourceSearchPaths.map(Path.init), cachePath: cachePath.map(Path.init), inferiorProductsPath: inferiorProductsPath.map(Path.init), environment: environment))
            let diagnostics = response.diagnostics.map { SwiftBuildMessage.DiagnosticInfo(.init($0, .global)) }
            if let sessionID = response.sessionID {
                return (.success(SWBBuildServiceSession(name: name, uid: sessionID, service: self)), diagnostics)
            } else {
                return (.failure(SwiftBuildError.requestError(description: "Could not initialize build system")), diagnostics)
            }
        } catch {
            return (.failure(error), [])
        }
    }

    /// List the active session UIDs and info.
    ///
    /// - returns: A map of session UIDs to info.
    func listSessions() async throws -> ListSessionsResponse {
        try await send(request: ListSessionsRequest())
    }

    /// List the active session UIDs and names.
    ///
    /// - returns: A map of session UIDs to names.
    public func listSessions() async throws -> [String: String] {
        try await listSessions().sessions.mapValues(\.name)
    }

    @_spi(Testing) public func waitForQuiescence(sessionHandle: String) async throws {
        _ = try await send(request: WaitForQuiescenceRequest(sessionHandle: sessionHandle))
    }

    /// Delete the session with the specified handle.
    public func deleteSession(sessionHandle: String) async throws {
        _ = try await send(request: DeleteSessionRequest(sessionHandle: sessionHandle))
    }

    /// Execute an `swbuild` "command line tool".
    ///
    /// These are tools which are implemented internally,
    /// primarily for debugging and testing purposes.
    func executeCommandLineTool(_ args: [String], workingDirectory: Path, developerPath: String? = nil, stdoutHandler: @Sendable @escaping (Data) -> Void, stderrHandler: @Sendable @escaping (Data) -> Void) async -> Bool {
        let (channel, result): (UInt64, Bool) = await withCheckedContinuation { continuation in
            Task {
                // Allocate a channel.
                let channel = self.openChannel { channel, message in
                    // FIXME: This is rather awkward, transforming the responses into
                    // the meanings in a way decoupled from the IPC definition.
                    switch message {
                    case let asString as StringResponse:
                        stdoutHandler(asString.value.data(using: String.Encoding.utf8)!)
                    case let asError as ErrorResponse:
                        stderrHandler(asError.description.data(using: String.Encoding.utf8)!)
                    case let response as BoolResponse:
                        continuation.resume(returning: (channel, response.value))
                    default:
                        stderrHandler("error: unknown response: \(String(describing: message))".data(using: String.Encoding.utf8)!)
                    }
                }

                // Start the tool.
                _ = await send(ExecuteCommandLineToolRequest(commandLine: args, workingDirectory: workingDirectory, developerPath: developerPath.map(Path.init), replyChannel: channel))
            }
        }

        // Close the channel.
        self.connection.close(channel: channel)

        return result
    }

    /// Creates an XCFramework from `Swift Build`.
    public func createXCFramework(_ args: [String], currentWorkingDirectory: String, developerPath: String?) async -> (Bool, String) {
        do {
            return try await (true, send(request: CreateXCFrameworkRequest(developerPath: developerPath.map(Path.init), commandLine: args, currentWorkingDirectory: Path(currentWorkingDirectory))).value)
        } catch {
            return (false, "\(error)")
        }
    }

    @available(*, deprecated, message: "Do not use.")
    public func appleSystemFrameworkNames(developerPath: String?) async throws -> Set<String> {
        try await Set(send(request: AppleSystemFrameworkNamesRequest(developerPath: developerPath.map(Path.init))).value)
    }

    public func productTypeSupportsMacCatalyst(developerPath: String?, productTypeIdentifier: String) async throws -> Bool {
        try await send(request: ProductTypeSupportsMacCatalystRequest(developerPath: developerPath.map(Path.init), productTypeIdentifier: productTypeIdentifier)).value
    }
}
