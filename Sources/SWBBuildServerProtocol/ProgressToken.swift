//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public enum ProgressToken: Codable, Hashable, Sendable {
  case integer(Int)
  case string(String)

  public init(from decoder: any Decoder) throws {
    if let integer = try? Int(from: decoder) {
      self = .integer(integer)
    } else if let string = try? String(from: decoder) {
      self = .string(string)
    } else {
      let context = DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected Int or String")
      throw DecodingError.dataCorrupted(context)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .integer(let integer):
      try integer.encode(to: encoder)
    case .string(let string):
      try string.encode(to: encoder)
    }
  }
}
