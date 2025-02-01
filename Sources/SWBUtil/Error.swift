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

public import class Foundation.NSError
public import class Foundation.NSErrorDomain
public import var Foundation.NSLocalizedDescriptionKey
public import var Foundation.NSOSStatusErrorDomain
public import protocol Foundation.LocalizedError

import SWBLibc

public enum StubError: Error, LocalizedError, CustomStringConvertible, Serializable, Equatable, Sendable {
    case error(String)

    public var description: String {
        switch self {
        case .error(let s): return s
        }
    }

    public var errorDescription: String? { return self.description }

    public func serialize<T: Serializer>(to serializer: T) {
        switch self {
        case .error(let s):
            serializer.serialize(s)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        let s = try deserializer.deserialize() as String
        self = .error(s)
    }
}

#if canImport(Darwin)
public struct MacError: Error, CustomStringConvertible, LocalizedError {
    public let code: OSStatus
    private let error: NSError

    public init(_ code: OSStatus) {
        self.code = code
        self.error = NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: nil)
    }

    public var description: String {
        // <rdar://42459842> No supported API is available for retrieving this information in a nicer way
        let prefix = "Error Domain=NSOSStatusErrorDomain Code=\(code) \""
        let suffix = "\""
        var rawDescription = error.description
        guard rawDescription.hasPrefix(prefix) else {
            return rawDescription
        }
        rawDescription = rawDescription.withoutPrefix(prefix)
        if rawDescription.hasSuffix(suffix) {
            rawDescription = rawDescription.withoutSuffix(suffix)
        }
        let (first, second) = rawDescription.split(":")

        let constant: String
        let message: String
        if !second.isEmpty {
            constant = first
            message = String(second.dropFirst())
        } else {
            constant = ""
            message = first
        }

        if !constant.isEmpty {
            return "\(message) (\(constant), \(code))"
        } else {
            if message == "(null)" || message.isEmpty {
                // Provide a friendlier message in these odd cases.
                return "The operation couldn’t be completed. (\(code))"
            }
            else {
                return "\(message) (\(code))"
            }
        }
    }

    public var errorDescription: String? { return description }
}
#endif
