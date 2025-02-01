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

// https://www.ietf.org/rfc/rfc4180.txt - compliant CSV formatting
public struct CSVBuilder: Sendable {
    public private(set) var output: String

    public init() {
        output = ""
    }

    public mutating func writeRow(_ cols: [String]) {
        output.append(cols.map { $0.csvEscaped() }.joined(separator: ","))
        output.append("\r\n")
    }
}

extension String {
    public func csvEscaped() -> String {
        var result = ""
        var needsQuoting = false
        for character in self {
            if character.isWhitespace || character == "," {
                needsQuoting = true
            }
            if character == "\"" {
                needsQuoting = true
                result += "\"\(character)"
            } else {
                result.append(character)
            }
        }
        return needsQuoting ? "\"\(result)\"" : result
    }
}
