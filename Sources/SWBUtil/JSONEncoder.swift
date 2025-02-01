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

public import struct Foundation.Data
public import class Foundation.JSONDecoder
public import class Foundation.JSONEncoder

/// Returns the raw bytes of the given object's json representation.
public func jsonDataArray<T: Encodable>(from object: T) throws -> [UInt8] {
    Array(try JSONEncoder().encode(object))
}

extension JSONEncoder {
    public convenience init(outputFormatting: JSONEncoder.OutputFormatting = []) {
        self.init()
        self.outputFormatting = outputFormatting
    }
}

extension JSONDecoder {
    public func decode<T>(_ type: T.Type, from path: Path, fs: any FSProxy) throws -> T where T : Decodable {
        let data = try fs.read(path)
        do {
            return try decode(type, from: Data(data))
        } catch {
            throw JSONFileParsingError(path: path, data: data, type: type)
        }
    }
}

public struct JSONFileParsingError<T>: Error, CustomStringConvertible, Sendable {
    public let path: Path
    public let data: ByteString
    public let type: T.Type

    public var description: String {
        "Failed to decode contents of file '\(path.str)' as \(type): \(data.unsafeStringValue)"
    }
}

public struct CommandLineOutputJSONParsingError: Error, CustomStringConvertible, Sendable {
    public let commandLine: [String]
    public let data: Data

    public init(commandLine: [String], data: Data) {
        self.commandLine = commandLine
        self.data = data
    }

    public var description: String {
        let codec = UNIXShellCommandCodec(encodingStrategy: .singleQuotes, encodingBehavior: .fullCommandLine)
        return "Could not parse output of `\(codec.encode(commandLine))` as JSON: \(String(decoding: data, as: UTF8.self))"
    }
}
