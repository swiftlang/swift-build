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
    public var systemVersion: Version?

    public var environment: String? {
        get { _environment?.environment }
        set {
            if let newValue {
                var env = _environment ?? Environment(environment: newValue, environmentVersion: nil)
                env.environment = newValue
                _environment = env
            } else {
                _environment = nil
            }
        }
    }

    public var environmentVersion: Version? {
        get { _environment?.environmentVersion }
        set {
            switch (_environment, newValue) {
            case (nil, nil):
                return
            case (nil, let newValue):
                fatalError("Can't set environmentVersion when environment is not set")
            case (var env?, let newValue):
                env.environmentVersion = newValue
                _environment = env
            }
        }
    }

    private struct Environment: Equatable, Sendable {
        var environment: String
        var environmentVersion: Version?
    }
    private var _environment: Environment?

    public var description: String {
        if let environment {
            return "\(arch)-\(vendor)-\(system)\(systemVersion?.description ?? "")-\(environment)\(environmentVersion?.description ?? "")"
        }
        return "\(arch)-\(vendor)-\(system)\(systemVersion?.description ?? "")"
    }

    public init(_ string: String) throws {
        guard let match = try #/(?<arch>[^-]+)-(?<vendor>[^-]+)-(?<system>[a-zA-Z_]+)(?<systemVersion>[0-9]+(?:.[0-9]+){0,})?(-(?<environment>[a-zA-Z_]+)(?<environmentVersion>[0-9]+(?:.[0-9]+){0,})?)?/#.wholeMatch(in: string) else {
            throw LLVMTripleError.invalidTripleStringFormat(string)
        }
        self.arch = String(match.output.arch)
        self.vendor = String(match.output.vendor)
        self.system = String(match.output.system)
        self.systemVersion = try match.output.systemVersion.map { try Version(String($0)) }
        self.environment = match.output.environment.map { String($0) }
        self.environmentVersion = try match.output.environmentVersion.map { try Version(String($0)) }
    }

    public init(from decoder: any Swift.Decoder) throws {
        self = try Self(decoder.singleValueContainer().decode(String.self))
    }
}

extension LLVMTriple {
    public var version: Version? {
        get throws {
            switch (systemVersion, environmentVersion) {
            case (let systemVersion?, nil):
                return systemVersion
            case (nil, let environmentVersion?):
                return environmentVersion
            case (nil, nil):
                return nil
            case (.some(_), .some(_)):
                throw LLVMTripleError.multipleVersions
            }
        }
    }
}

enum LLVMTripleError: Error, CustomStringConvertible {
    case invalidTripleStringFormat(String)
    case multipleVersions

    var description: String {
        switch self {
        case let .invalidTripleStringFormat(tripleString):
            "Invalid triple string format: \(tripleString)"
        case .multipleVersions:
            "Triple has versions in both the system and environment fields"
        }
    }
}
