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

public struct LLVMTriple: Decodable, Hashable, Comparable, Sendable, CustomStringConvertible {
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
        [arch, vendor, systemComponent, environmentComponent].compactMap { $0 }.joined(separator: "-")
    }

    /// Initialize a target triple by parsing it from a string.
    /// This will throw an error if the string is malformed.
    public init(_ string: String) throws {
        guard let match = try #/(?<arch>[^-]+)-(?<vendor>[^-]+)-(?<system>[^-]+)(-(?<environment>[^-]+))?/#.wholeMatch(in: string) else {
            throw LLVMTripleError.invalidTripleStringFormat(string)
        }
        self.arch = String(match.output.arch)
        self.vendor = String(match.output.vendor)
        self.systemComponent = String(match.output.system)
        self.environmentComponent = match.output.environment.map { String($0) } ?? nil

        // Validate the version. This will throw if both the systemComponent and the environmentComponent contain versions.
        _ = try self.version
    }

    /// Initialize a target triple from its component parts.
    /// The version - if any - may be part of either `systemComponent` or `environmentComponent`, but not both.
    public init(arch: String, vendor: String, systemComponent: String, environmentComponent: String? = nil) throws {
        try self.init([arch, vendor, systemComponent, environmentComponent?.nilIfEmpty].compactMap { $0 }.joined(separator: "-"))
    }

    public init(from decoder: any Swift.Decoder) throws {
        self = try Self(decoder.singleValueContainer().decode(String.self))
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(description)
    }

    public static func < (lhs: borrowing LLVMTriple, rhs: borrowing LLVMTriple) -> Bool {
        // Ordering triples is mainly useful for stability in computing tasks, arguments, etc., so we just compare the descriptions of the two.
        return lhs.description < rhs.description
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

    /// This is the `environmentComponent` -  if non-empty - prefixed by a dash `-`, which is a common way that Swift Build works with the environment.
    public var suffix: String {
        get {
            guard let environmentComponent else { return "" }
            return environmentComponent.isEmpty ? "" : ("-" + environmentComponent)
        }
        set {
            environmentComponent = newValue.hasPrefix("-") ? String(newValue.dropFirst()) : newValue
        }
    }

    public var unversioned: LLVMTriple {
        var triple = self
        triple.systemComponent = system
        triple.environmentComponent = environment
        return triple
    }

    /// Returns a normalized version of the receiver where components which have aliases are replaced with their most common form, for easier comparison.
    public var normalized: LLVMTriple {
        var triple = self
        // Use 'arm64' for Apple platforms and 'aarch64' for other platforms.
        if self.arch == "aarch64" || self.arch == "arm64" {
            triple.arch = self.vendor == "apple" ? "arm64": "aarch64"
        }
        // 'macos' and 'macosx' are considered identical systems.
        if self.system == "macosx" {
            triple.system = "macos" + self.systemComponent.withoutPrefix(self.system)
        }
        return triple
    }

    public var withoutArch: LLVMTriple {
        var triple = self
        triple.arch = "unknown"
        return triple
    }

    /// On Apple platforms the `version` is the deployment target.  This can appear at a different place in the triple on different platforms, and this property handles that.
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
                throw LLVMTripleError.multipleVersions(self)
            }
        }
    }

    public var systemVersion: Version? { try? version } // compatibility
}

public enum LLVMTripleError: Error, CustomStringConvertible {
    case invalidTripleStringFormat(String)
    case multipleVersions(LLVMTriple)

    public var description: String {
        switch self {
        case let .invalidTripleStringFormat(tripleString):
            "Invalid triple string format '\(tripleString)'"
        case let .multipleVersions(triple):
            "Triple '\(triple)' has versions in both the system and environment fields"
        }
    }
}

fileprivate extension String {
    var prefixUpToFirstDigit: String {
        self.firstIndex(where: { $0.isNumber }).map { String(self.prefix(upTo: $0)) } ?? self
    }
}

/// Compares two triple strings by parsing them as `LLVMTriple` structs, removing any versions from them, and comparing the two structs.
///
/// If either string cannot be parsed, then the two are considered to be not equal (this method returns false).
package func compareUnversionedTripleStrings(_ firstTripleString: String, _ secondTripleString: String) -> Bool {
    guard let firstTriple = try? LLVMTriple(firstTripleString).unversioned.normalized else {
        return false
    }
    guard let secondTriple = try? LLVMTriple(secondTripleString).unversioned.normalized else {
        return false
    }
    return firstTriple == secondTriple
}
