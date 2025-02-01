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
public import SWBUtil

/// A request from the service for an external tool to be executed.
public struct ExternalToolExecutionRequest: ClientExchangeMessage, Equatable {
    public static let name = "EXTERNAL_TOOL_EXECUTION_REQUEST"

    public let sessionHandle: String
    public let exchangeHandle: String

    public let commandLine: [String]
    public let workingDirectory: String?
    public let environment: [String: String]

    public init(sessionHandle: String, exchangeHandle: String, commandLine: [String], workingDirectory: String?, environment: [String: String]) {
        self.sessionHandle = sessionHandle
        self.exchangeHandle = exchangeHandle
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        self.sessionHandle = try deserializer.deserialize()
        self.exchangeHandle = try deserializer.deserialize()
        self.commandLine = try deserializer.deserialize()
        self.workingDirectory = try deserializer.deserialize()
        self.environment = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(5) {
            serializer.serialize(sessionHandle)
            serializer.serialize(exchangeHandle)
            serializer.serialize(commandLine)
            serializer.serialize(workingDirectory)
            serializer.serialize(environment)
        }
    }
}

public enum ExternalToolResult: Equatable, Sendable {
    /// Defer to direct execution by the build engine
    case deferred

    /// Result of an external tool execution by the client.
    case result(status: Processes.ExitStatus, stdout: Data, stderr: Data)
}

extension ExternalToolResult {
    public static var emptyResult: ExternalToolResult {
        return .result(status: .exit(0), stdout: .init(), stderr: .init())
    }
}

extension ExternalToolResult: Serializable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .deferred:
                serializer.serialize(0 as Int)
                serializer.serializeNil()
            case let .result(status, stdout, stderr):
                serializer.serialize(1 as Int)
                serializer.serializeAggregate(3) {
                    serializer.serialize(status)
                    serializer.serialize(ByteString(stdout))
                    serializer.serialize(ByteString(stderr))
                }
            }
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        let tag = try deserializer.deserialize() as Int
        switch tag {
        case 0:
            guard deserializer.deserializeNil() else {
                throw DeserializerError.deserializationFailed("Unexpected associated value for ExternalToolResult.deferred.")
            }
            self = .deferred
        case 1:
            try deserializer.beginAggregate(3)
            self = .result(status: try deserializer.deserialize(), stdout: try Data((deserializer.deserialize() as ByteString).bytes), stderr: try Data((deserializer.deserialize() as ByteString).bytes))
        default:
            throw DeserializerError.unexpectedValue("Expected 0 or 1 for Result tag, but got \(tag)")
        }
    }
}

extension Processes.ExitStatus: Serializable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case let .exit(code):
                serializer.serialize(0 as Int)
                serializer.serialize(code)
            case let .uncaughtSignal(signal):
                serializer.serialize(1 as Int)
                serializer.serialize(signal)
            }
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        let tag = try deserializer.deserialize() as Int
        switch tag {
        case 0:
            self = .exit(try deserializer.deserialize())
        case 1:
            self = .uncaughtSignal(try deserializer.deserialize())
        default:
            throw DeserializerError.unexpectedValue("Expected 0 or 1 for Result tag, but got \(tag)")
        }
    }
}

/// A response from the client to the service's request for an external tool to be executed.
public final class ExternalToolExecutionResponse: ClientExchangeMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = BoolResponse

    public static let name = "EXTERNAL_TOOL_EXECUTION_RESPONSE"

    public let sessionHandle: String
    public let exchangeHandle: String

    public typealias Value = Result<ExternalToolResult, StubError>
    public let value: Value

    public init(sessionHandle: String, exchangeHandle: String, value: Value) {
        self.sessionHandle = sessionHandle
        self.exchangeHandle = exchangeHandle
        self.value = value
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.sessionHandle = try deserializer.deserialize()
        self.exchangeHandle = try deserializer.deserialize()

        try deserializer.beginAggregate(2)
        let tag = try deserializer.deserialize() as Int
        switch tag {
        case 0:
            self.value = .success(try deserializer.deserialize())
        case 1:
            self.value = .failure(try deserializer.deserialize())
        default:
            throw DeserializerError.unexpectedValue("Expected 0 or 1 for Result tag, but got \(tag)")
        }
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(sessionHandle)
            serializer.serialize(exchangeHandle)

            serializer.serializeAggregate(2) {
                switch value {
                case .success(let s):
                    serializer.serialize(0 as Int)
                    serializer.serialize(s)
                    break
                case .failure(let e):
                    serializer.serialize(1 as Int)
                    serializer.serialize(e)
                    break
                }
            }
        }
    }

    public static func == (lhs: ExternalToolExecutionResponse, rhs: ExternalToolExecutionResponse) -> Bool {
        return lhs.sessionHandle == rhs.sessionHandle && lhs.exchangeHandle == rhs.exchangeHandle && lhs.value == rhs.value
    }
}

let taskConstructionMessageTypes: [any Message.Type] = [
    ExternalToolExecutionRequest.self,
    ExternalToolExecutionResponse.self,
]
