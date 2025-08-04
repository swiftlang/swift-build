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

public struct LLVMTriple: Decodable, Equatable, Sendable, CustomStringConvertible {
    public var arch: String
    public var vendor: String
    public var system: String
    public var environment: String?

    public var description: String {
        if let environment {
            return "\(arch)-\(vendor)-\(system)-\(environment)"
        }
        return "\(arch)-\(vendor)-\(system)"
    }

    public init(_ string: String) throws {
        guard let match = try #/(?<arch>[^-]+)-(?<vendor>[^-]+)-(?<system>[^-]+)(-(?<environment>[^-]+))?/#.wholeMatch(in: string) else {
            throw LLVMTripleError.invalidTripleStringFormat(string)
        }
        self.arch = String(match.output.arch)
        self.vendor = String(match.output.vendor)
        self.system = String(match.output.system)
        self.environment = match.output.environment.map { String($0) }
    }

    public init(from decoder: any Swift.Decoder) throws {
        self = try Self(decoder.singleValueContainer().decode(String.self))
    }
}

enum LLVMTripleError: Error, CustomStringConvertible {
    case invalidTripleStringFormat(String)

    var description: String {
        switch self {
        case let .invalidTripleStringFormat(tripleString):
            "Invalid triple string format: \(tripleString)"
        }
    }
}
