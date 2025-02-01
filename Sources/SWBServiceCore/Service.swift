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

import SWBLibc
public import SWBProtocol
public import SWBUtil

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

/// A generic named message handler.
public protocol MessageHandler {
    associatedtype MessageType: RequestMessage

    /// Create a new handler instance.
    init()

    /// Handle the given message.
    ///
    /// - Parameters:
    ///   - request: The incoming request to communicate on.
    ///   - deserializer: The deserializer to use to decode the message.
    /// - Returns: A reply message, if desired (which will be sent on the channel).
    func handle(request: Request, message: MessageType) async throws -> MessageType.ResponseMessage
}

/// This is the central class which manages a service instance communicating with a unique client.
///
/// This class is designed to be thread safe: clients can send messages from any thread and they will be sent in FIFO order. Note that individual messages are currently always processed in FIFO order non-concurrently. Messages which require non-trivial amounts of time to service should always be split to use an asynchronous reply.
open class Service: @unchecked Sendable {
    static let messagesReceived = Statistic("Service.messagesReceived", "The number of messages received.")
    static let messagesSent = Statistic("Service.messagesSent", "The number of messages sent.")

    /// The service connection object.
    private let connection: ServiceHostConnection

    public let connectionMode: ServiceHostConnectionMode

    public let pluginManager: PluginManager

    /// The message handlers, operating on (channel, message) pairs.
    ///
    /// This is effectively immutable, but needs to be a var because it is created with backreferences.
    private var handlers: [String: (Request, any Message) async throws -> (any Message)?] = [:]

    private let shutdownPromise = Promise<Void, any Error>()

    /// Create a new service.
    ///
    /// - Parameters:
    ///   - inputFD: The input file descriptor for incoming messages.
    ///   - outputFD: The output file descriptor for outgoing messages.
    ///   - connectionMode: Whether the build service is being run in-process or out-of-process.
    ///   - tracer: The tracing support service, if enabled.
    public init(inputFD: FileDescriptor, outputFD: FileDescriptor, connectionMode: ServiceHostConnectionMode, pluginManager: PluginManager) async {
        self.connectionMode = connectionMode
        self.pluginManager = pluginManager

        // Set up the connection.
        connection = ServiceHostConnection(inputFD: inputFD, outputFD: outputFD)
        connection.shutdownHandler = { [weak self] error in
            self?.shutdown(error)
        }

        // Set up the connection handler.
        connection.handler = self.connectionHandler

        // Load any handlers provided by plugins.
        for ext in await pluginManager.extensions(of: ServiceExtensionPoint.self) {
            ext.register(self)
        }
    }

    /// Runs the service until it is shut down.
    open func run() async throws {
        try await shutdownPromise.value
    }

    open func shutdown(_ error: (any Error)? = nil) {
        // Clear all caches, then check for leaks.
        SWBUtil.clearAllHeavyCaches()

        if let error {
            shutdownPromise.fail(throwing: error)
        } else {
            shutdownPromise.fulfill()
        }
    }

    public func registerMessageHandler<T: MessageHandler>(_ type: T.Type) where T.MessageType: Message {
        // Create the handler.
        let handler = type.init()

        // Install the callback.
        precondition(self.handlers[T.MessageType.name] == nil)
        self.handlers[T.MessageType.name] = { (request, message) in
            try await handler.handle(request: request, message: message as! T.MessageType)
        }
    }

    /// Start handling requests.
    public func resume() {
        connection.resume()
    }

    public func send(_ channel: UInt64, _ message: any Message) {
        Service.messagesSent.increment()

        // FIXME: We could in theory encode directly onto the stream.
        connection.send(channel, MsgPackSerializer.serialize(IPCMessage(message)))
    }

    private func connectionHandler(_ channel: UInt64, msg: [UInt8]) async {
        if msg.count >= 4 {
            // Handle throughput test messages ('TPUT').
            if msg[0..<4] == [84, 80, 85, 84] {
                connection.send(channel, [UInt8]("TGOT".utf8))
                return
            }

            // Handle 'EXIT' custom message.
            if msg[0..<4] == [69, 88, 73, 84] {
                assert(channel == 0)
                connection.suspend()
                return
            }
        }

        let deserializer = MsgPackDeserializer(ByteString(msg))
        await handleMessage(on: channel, deserializer: deserializer)
    }

    /// Handle a message which is handed to us as content in `deserializer`.  This method will deserialize the message (sending back an error if something goes wrong), look for a handler for the message type (sending back an error if it can't find one), and run the handler (sending back an error if the handler throws).  If all goes well, then it will send back the result of the handler (if any) on the same `channel` from which the original message was received.
    ///
    /// The handler is run synchronously on the thread which runs this method, so if the handler is going to be long-running, it should dispatch to a separate thread so as not to monopolize this thread.  (That means it will need to perform its own response and error reporting as it won't be able to return results through this method.)
    private func handleMessage(on channel: UInt64, deserializer: MsgPackDeserializer) async {
        // Look for a handler.
        //
        // FIXME: We could in theory decode directly from the stream.
        let wrapper: IPCMessage
        do {
            Service.messagesReceived.increment()
            wrapper = try IPCMessage(from: deserializer)
        } catch {
            send(channel, ErrorResponse("unknown message: \(error)"))
            return
        }
        let name = type(of: wrapper.message).name
        guard let handler = self.handlers[name] else {
            send(channel, ErrorResponse("unknown message: \(wrapper.message)"))
            return
        }

        // Execute the handler, and return its reply (if any).
        let request = Request(service: self, channel: channel, name: name)

        do {
            if let result = try await handler(request, wrapper.message) {
                request.reply(result)
            }
            // FIXME: We may eventually want to explicitly track deferred requests here.
        } catch {
            request.reply(ErrorResponse("\(error)"))
        }
    }
}
