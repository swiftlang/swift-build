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
    public var systemComponent: String
    public var environmentComponent: String? {
        didSet {
            if environmentComponent == "" {
                environmentComponent = nil
            }
        }
    }

    public var description: String {
        if let environmentComponent {
            return "\(arch)-\(vendor)-\(systemComponent)-\(environmentComponent)"
        }
        return "\(arch)-\(vendor)-\(systemComponent)"
    }

    public init(_ string: String) throws {
        guard let match = try #/(?<arch>[^-]+)-(?<vendor>[^-]+)-(?<system>[^-]+)(-(?<environment>[^-]+))?/#.wholeMatch(in: string) else {
            throw LLVMTripleError.invalidTripleStringFormat(string)
        }
        self.arch = String(match.output.arch)
        self.vendor = String(match.output.vendor)
        self.systemComponent = String(match.output.system)
        self.environmentComponent = match.output.environment.map { String($0) } ?? nil
    }

    public init(from decoder: any Swift.Decoder) throws {
        self = try Self(decoder.singleValueContainer().decode(String.self))
    }
}

// The "names" of many platforms and environments end with numbers (ps4, ps5, wasip1, ...), so version extraction cannot be fully generalized.
// This roughly matches the behavior of LLVM's triple parsing, although this implementation is not as complete.
extension LLVMTriple {
    public var system: String {
        get {
            switch (vendor, systemComponent) {
            case
                (_, let sys) where sys.hasPrefix("freebsd"),
                (_, let sys) where sys.hasPrefix("openbsd"),
                (_, let sys) where sys.hasPrefix("netbsd"):
                fallthrough
            case ("apple", _):
                return systemComponent.prefixUpToFirstDigit
            default:
                return systemComponent
            }
        }
        set {
            systemComponent = newValue
        }
    }

    public var environment: String? {
        get {
            guard let environmentComponent else { return nil }
            switch system {
            case "linux" where environmentComponent.hasPrefix("android"),
                "nto" where environmentComponent.hasPrefix("qnx"):
                return environmentComponent.prefixUpToFirstDigit
            default:
                return environmentComponent
            }
        }
        set {
            environmentComponent = newValue
        }
    }

    public var unversioned: LLVMTriple {
        var triple = self
        triple.systemComponent = system
        triple.environmentComponent = environment
        return triple
    }

    public var version: Version? {
        get throws {
            switch try (systemComponent.withoutPrefix(system).nilIfEmpty.map { try Version($0) }, environmentComponent?.withoutPrefix(environment ?? "").nilIfEmpty.map { try Version($0) }) {
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

    public var systemVersion: Version? { try? version } // compatibility
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

fileprivate extension String {
    var prefixUpToFirstDigit: String {
        self.firstIndex(where: { $0.isNumber }).map { String(self.prefix(upTo: $0)) } ?? self
    }
}
