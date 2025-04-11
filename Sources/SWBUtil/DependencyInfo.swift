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
import Foundation

public enum DependencyInfoEncodingError: Error {
    case emptyString
    case embeddedNullInString(string: String)
}

extension DependencyInfoEncodingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .emptyString:
            return "empty strings cannot be encoded"
        case .embeddedNullInString(let string):
            return "string '\(string)' containing embedded NUL character(s) cannot be encoded"
        }
    }
}

public enum DependencyInfoDecodingError: Error {
    case unexpectedEOF
    case missingVersion
    case duplicateVersion
    case unknownOpcode(opcode: UInt8)
    case invalidOperand(bytes: [UInt8]?)
}

extension DependencyInfoDecodingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unexpectedEOF:
            return "unexpected EOF"
        case .missingVersion:
            return "missing version record"
        case .duplicateVersion:
            return "duplicate version record"
        case .unknownOpcode(let opcode):
            return "unknown opcode 0x\(String(opcode, radix: 16, uppercase: true))"
        case .invalidOperand(let data):
            if let data {
                return "invalid operand: \(data)"
            } else {
                return "empty operand"
            }
        }
    }
}

/// Encapsulates an ld64-style dependency info object.
/// These are written in a binary format by various build tools and are used by
/// the build system to store dependency information.
public struct DependencyInfo: Codable, Equatable, Sendable {
    @_spi(Testing) public enum Opcode: UInt8, Equatable, Sendable {
        case version = 0x00
        case input = 0x10
        case missing = 0x11
        case output = 0x40
    }

    /// The "version" of the dependency info;
    /// usually a string indicating the tool by which it was created.
    public let version: String

    /// List of input files.
    public var inputs = [String]()

    /// List of missing input files.
    public var missing = [String]()

    /// List of output files.
    public var outputs = [String]()

    public init(version: String, inputs: [String] = [], missing: [String] = [], outputs: [String] = []) {
        self.version = version
        self.inputs = inputs
        self.missing = missing
        self.outputs = outputs
    }

    /// "Normalizes" the dependency info, that is, sorts all of the path lists alphabetically and removes any duplicates.
    public mutating func normalize() {
        inputs = Set(inputs).sorted()
        missing = Set(missing).sorted()
        outputs = Set(outputs).sorted()
    }

    /// Returns a "normalized" copy of the dependency info, that is, with all of the path lists sorted alphabetically and with any duplicates removed.
    public func normalized() -> DependencyInfo {
        var copy = self
        copy.normalize()
        return copy
    }
}

extension String {
    /// Validates that the given string can be encoded in the binary ld64 dependency info format.
    /// Returns the original string if everything is OK, otherwise throws an error.
    fileprivate func validatingEncodability() throws -> String {
        // Empty strings are not considered valid, although they are technically encodable
        if isEmpty {
            throw DependencyInfoEncodingError.emptyString
        }

        // Embedded nulls in strings cannot be encoded because all strings are NULL-terminated and are not length-prefixed
        if contains(Character("\0")) {
            throw DependencyInfoEncodingError.embeddedNullInString(string: self)
        }

        return self
    }
}

extension Array where Element == String {
    fileprivate func validatingEncodability() throws -> Array {
        for element in self {
            _ = try element.validatingEncodability()
        }
        return self
    }

    fileprivate func bytes(with opcode: DependencyInfo.Opcode) -> [UInt8] {
        return reduce(into: []) { result, value in result += [opcode.rawValue] + Array<UInt8>(value.utf8) + [0] }
    }
}

extension DependencyInfo.Opcode {
    fileprivate func bytes(for values: [String]) -> [UInt8] {
        return values.bytes(with: self)
    }
}

extension DependencyInfo {
    /// Initializes a `DependencyInfo` object from the binary format.
    public init(bytes: [UInt8]) throws {
        try self.init(bytes: bytes[...])
    }

    /// Initializes a `DependencyInfo` object from the binary format.
    public init(bytes: ArraySlice<UInt8>) throws {
        func readRecord(from data: inout ArraySlice<UInt8>) throws -> (Opcode, String) {
            guard let opcode = Opcode(rawValue: data[data.startIndex]) else {
                throw DependencyInfoDecodingError.unknownOpcode(opcode: data[data.startIndex])
            }

            data = data.dropFirst()

            guard let end = data.firstIndex(of: 0) else {
                throw DependencyInfoDecodingError.unexpectedEOF
            }

            let bytes = data[..<end]
            guard let operand = String(bytes: bytes, encoding: .utf8) else {
                throw DependencyInfoDecodingError.invalidOperand(bytes: Array(bytes))
            }

            data = data.dropFirst(bytes.count + 1)

            if operand.isEmpty {
                throw DependencyInfoDecodingError.invalidOperand(bytes: nil)
            }

            return (opcode, operand)
        }

        var bytes = bytes

        if bytes.isEmpty {
            throw DependencyInfoDecodingError.unexpectedEOF
        }

        let (opcode, version) = try readRecord(from: &bytes)
        if opcode != .version {
            throw DependencyInfoDecodingError.missingVersion
        }

        self.version = version

        while !bytes.isEmpty {
            let (opcode, operand) = try readRecord(from: &bytes)
            switch opcode {
            case .version:
                throw DependencyInfoDecodingError.duplicateVersion
            case .input:
                inputs.append(operand)
            case .missing:
                missing.append(operand)
            case .output:
                outputs.append(operand)
            }
        }
    }

    /// Returns the `DependencyInfo` object in its binary format.
    public func asBytes() throws -> [UInt8] {
        let operations: [@Sendable () throws -> [UInt8]] = [
            { Opcode.version.bytes(for: [try self.version.validatingEncodability()]) },
            { Opcode.input.bytes(for: try self.inputs.validatingEncodability()) },
            { Opcode.missing.bytes(for: try self.missing.validatingEncodability()) },
            { Opcode.output.bytes(for: try self.outputs.validatingEncodability()) }
        ]
        return try operations.map({ try $0() }).reduce(into: [], { result, element in result += element })
    }
}
