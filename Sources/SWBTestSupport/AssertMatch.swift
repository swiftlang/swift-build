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

package import SWBUtil
package import Testing
import Synchronization

package indirect enum StringPattern: Sendable {
    /// Matches only the start, when matching a list of inputs.
    case start

    /// Matches only the end, when matching a list of inputs.
    case end

    /// Matches any sequence of zero or more strings, when matched a list of inputs.
    case anySequence

    case any
    case contains(String)
    case equal(String)
    case regex(StringPatternRegex)
    case prefix(String)
    case suffix(String)
    case and(StringPattern, StringPattern)
    case or(StringPattern, StringPattern)
    case not(StringPattern)

    case pathEqual(prefix: String, _ path: Path)
}

extension StringPattern {
    public static func path(_ path: Path) -> StringPattern {
        pathEqual(prefix: "", path)
    }

    public var withPOSIXSlashes: StringPattern {
        switch self {
        case .start, .end, .anySequence, .any, .regex, .pathEqual:
            self
        case let .contains(s):
            .contains(Path(s).strWithPosixSlashes)
        case let .equal(s):
            .equal(Path(s).strWithPosixSlashes)
        case let .prefix(s):
            .prefix(Path(s).strWithPosixSlashes)
        case let .suffix(s):
            .suffix(Path(s).strWithPosixSlashes)
        case let .and(l, r):
            .and(l.withPOSIXSlashes, r.withPOSIXSlashes)
        case let .or(l, r):
            .or(l.withPOSIXSlashes, r.withPOSIXSlashes)
        case let .not(s):
            .not(s.withPOSIXSlashes)
        }
    }
}

package final class StringPatternRegex: Sendable {
    fileprivate let regex: SWBMutex<Regex<Substring>>

    fileprivate init(_ regex: consuming sending Regex<Substring>) {
        self.regex = .init(regex)
    }
}

extension StringPattern {
    package static func regex(_ regex: consuming sending Regex<Substring>) -> StringPattern {
        .regex(.init(regex))
    }

    package static func all(_ patterns: StringPattern...) -> StringPattern {
        switch patterns.count {
        case 0:
            return .any
        case 1:
            return patterns[0]
        default:
            return patterns.dropFirst(1).reduce(patterns[0], { .and($0, $1) })
        }
    }

    package static func anyOf(_ patterns: StringPattern...) -> StringPattern {
        anyOf(patterns)
    }

    package static func anyOf(_ patterns: [StringPattern]) -> StringPattern {
        switch patterns.count {
        case 0:
            return .any
        case 1:
            return patterns[0]
        default:
            return patterns.dropFirst(1).reduce(patterns[0], { .or($0, $1) })
        }
    }
}

extension StringPattern: ExpressibleByStringInterpolation {
    package typealias UnicodeScalarLiteralType = StringLiteralType
    package typealias ExtendedGraphemeClusterLiteralType = StringLiteralType

    package init(unicodeScalarLiteral value: UnicodeScalarLiteralType) {
        self = .equal(value)
    }
    package init(extendedGraphemeClusterLiteral value: ExtendedGraphemeClusterLiteralType) {
        self = .equal(value)
    }
    package init(stringLiteral value: StringLiteralType) {
        self = .equal(value)
    }
}

package func ~=(pattern: StringPattern, value: String) -> Bool {
    switch pattern {
        // These cases never matches individual items, they are just used for matching string lists.
    case .start, .end, .anySequence:
        return false

    case .any:
        return true
    case .contains(let needle):
        return value.contains(needle)
    case .equal(let needle):
        return value == needle
    case .regex(let pattern):
        do {
            return try pattern.regex.withLock { pattern in
                return try pattern.firstMatch(in: value) != nil
            }
        } catch {
            return false
        }
    case .prefix(let needle):
        return value.hasPrefix(needle)
    case .suffix(let needle):
        return value.hasSuffix(needle)
    case let .and(lhs, rhs):
        return lhs ~= value && rhs ~= value
    case let .or(lhs, rhs):
        return lhs ~= value || rhs ~= value
    case let .not(pattern):
        return !(pattern ~= value)
    case .pathEqual(let prefix, let path):
        guard value.hasPrefix(prefix) else { return false }
        return path == Path(value.withoutPrefix(prefix))
    }
}

package func ~=(patterns: [StringPattern], input: [String]) -> Bool {
    let startIndex = input.startIndex
    let endIndex = input.endIndex

    /// Helper function to match at a specific location.
    func match(_ patterns: Array<StringPattern>.SubSequence, onlyAt input: Array<String>.SubSequence) -> Bool {
        // If we have read all the pattern, we are done.
        guard let item = patterns.first else { return true }
        let patterns = patterns.dropFirst()

        // Otherwise, match the first item and recurse.
        switch item {
        case .start:
            if input.startIndex != startIndex { return false }
            return match(patterns, onlyAt: input)

        case .end:
            if input.startIndex != endIndex { return false }
            return match(patterns, onlyAt: input)

        case .anySequence:
            return matchAny(patterns, input: input)

        default:
            if input.isEmpty || !(item ~= input.first!) { return false }
            return match(patterns, onlyAt: input.dropFirst())
        }
    }

    /// Match a pattern at any position in the input
    func matchAny(_ patterns: Array<StringPattern>.SubSequence, input: Array<String>.SubSequence) -> Bool {
        if match(patterns, onlyAt: input) {
            return true
        }
        if input.isEmpty {
            return false
        }
        return matchAny(patterns, input: input.dropFirst())
    }

    return matchAny(patterns[...], input: input[...])
}

private func XCTAssertMatchImpl<Pattern, Value>(_ result: @autoclosure @escaping () throws -> Bool, _ value: @escaping () -> Value, _ pattern: Pattern, _ message: String?, sourceLocation: SourceLocation) {
    let matched: Bool
    do {
        matched = try result()
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
        return
    }
    #expect(matched, Comment(rawValue: message ?? "unexpected failure matching '\(value())' against pattern \(pattern)"), sourceLocation: sourceLocation)
}

package func XCTAssertMatch(_ value: @autoclosure @escaping () -> String, _ pattern: StringPattern, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    XCTAssertMatchImpl(pattern ~= value(), value, pattern, message, sourceLocation: sourceLocation)
}
package func XCTAssertNoMatch(_ value: @autoclosure @escaping () -> String, _ pattern: StringPattern, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    XCTAssertMatchImpl(!(pattern ~= value()), value, pattern, message, sourceLocation: sourceLocation)
}

package func XCTAssertMatch(_ value: @autoclosure @escaping () -> String?, _ pattern: StringPattern, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let value = value() else {
        Issue.record("unexpected nil value for match against pattern: \(pattern)", sourceLocation: sourceLocation)
        return
    }
    XCTAssertMatchImpl(pattern ~= value, { value }, pattern, message, sourceLocation: sourceLocation)
}
package func XCTAssertNoMatch(_ value: @autoclosure @escaping () -> String?, _ pattern: StringPattern, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    XCTAssertMatchImpl({
        // `nil` always matches, so in this case we return true to ensure the underlying XCTAssert succeeds
        guard let value = value() else { return true }
        return !(pattern ~= value)
    }(), value, pattern, message, sourceLocation: sourceLocation)
}

package func XCTAssertMatch(_ value: @autoclosure @escaping () -> [String], _ pattern: [StringPattern], _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    XCTAssertMatchImpl(pattern ~= value(), value, pattern, message, sourceLocation: sourceLocation)
}
package func XCTAssertNoMatch(_ value: @autoclosure @escaping () -> [String], _ pattern: [StringPattern], _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    XCTAssertMatchImpl(!(pattern ~= value()), value, pattern, message, sourceLocation: sourceLocation)
}

package func XCTAssertEqualSequences<T: Sequence>(_ actual: T, _ expected: T, _ messageSuffix: @autoclosure @escaping () -> String = "", sourceLocation: SourceLocation = #_sourceLocation) where T: Equatable, T.Element: Comparable, T.Element: Hashable {
    let diff = actual.diff(against: expected)
    var message = [String]()
    do {
        let missing = diff.right
        if !missing.isEmpty {
            message.append("Missing arguments: \(missing)")
        }

        let unexpected = diff.left
        if !unexpected.isEmpty {
            message.append("Unexpected arguments: \(unexpected)")
        }
    }
    message.append(messageSuffix())
    #expect(actual == expected, Comment(rawValue: message.joined(separator: "; ")), sourceLocation: sourceLocation)
}

package func XCTAssertSuperset<T>(_ value1: @autoclosure @escaping () throws -> Set<T>, _ value2: @autoclosure @escaping () throws -> Set<T>, sourceLocation: SourceLocation = #_sourceLocation) rethrows where T: Comparable, T: Hashable {
    let v1 = try value1()
    let v2 = try value2()
    #expect(v1.isSuperset(of: v2), "\(v1) is not a superset of \(v2) (could not find values: \(v2.subtracting(v1)))", sourceLocation: sourceLocation)
}
