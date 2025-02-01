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

public import class Foundation.NSMutableString
public import class Foundation.NSRegularExpression
public import class Foundation.NSString
public import class Foundation.NSTextCheckingResult
public import func Foundation.NSMakeRange
public import var Foundation.NSNotFound

public struct RegEx: Sendable {
    public let pattern: String
    fileprivate let regex: NSRegularExpression
    public typealias Options = NSRegularExpression.Options

    public init(patternLiteral: StaticString, options: Options = []) {
        do {
            let patternString = patternLiteral.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
            try self.init(pattern: patternString, options: options)
        } catch {
            preconditionFailure("RegEx patterns initialized from static strings must be valid: \(error)")
        }
    }

    public init(pattern: String, options: Options = []) throws {
        self.pattern = pattern
        self.regex = try NSRegularExpression(pattern: pattern, options: options)
    }

    /// Returns a match group for the first match, or nil if there was no match.
    public func firstMatch(in string: String) -> [String]? {
        let nsString = string as NSString

        return regex.firstMatch(in: string, range: NSMakeRange(0, nsString.length)).map { match -> [String] in
            return (1 ..< match.numberOfRanges).map { idx -> String in
                let range = match.range(at: idx)
                return range.location == NSNotFound ? "" : nsString.substring(with: range)
            }
        }
    }

    /// Provides access to the named capture groups of a regular expression match result.
    public struct MatchResult {
        fileprivate let nsString: NSString
        fileprivate let result: NSTextCheckingResult

        /// Returns the value of the capture group identified by `name`, or `nil` if there is no capture group by that name.
        public subscript(name: String) -> String? {
            let range = result.range(withName: name)
            return range.location == NSNotFound ? nil : nsString.substring(with: range)
        }
    }

    /// Returns an object providing access to the named capture groups of the first match, or nil if there was no match.
    @_disfavoredOverload
    public func firstMatch(in string: String) -> MatchResult? {
        let nsString = string as NSString

        return regex.firstMatch(in: string, range: NSMakeRange(0, nsString.length)).map { match in
            .init(nsString: nsString, result: match)
        }
    }

    /// Returns match groups for each match. E.g.:
    /// RegEx(pattern: "([a-z]+)([0-9]+)").matchGroups(in: "foo1 bar2 baz3") -> [["foo", "1"], ["bar", "2"], ["baz", "3"]]
    public func matchGroups(in string: String) -> [[String]] {
        let nsString = string as NSString

        return regex.matches(in: string, range: NSMakeRange(0, nsString.length)).map{ match -> [String] in
            return (1 ..< match.numberOfRanges).map { idx -> String in
                let range = match.range(at: idx)
                return range.location == NSNotFound ? "" : nsString.substring(with: range)
            }
        }
    }

    /// The `template` string should use $1, $2, $3, etc to refer to capture groups.
    public func replace(in string: inout String, with template: String) -> Int {
        let nsString = NSMutableString(string: string)
        let matches = regex.replaceMatches(in: nsString, range: NSMakeRange(0, nsString.length), withTemplate: template)
        string = nsString as String
        return matches
    }

    /// Returns a string by adding backslash escapes as necessary to protect any characters that would match as pattern metacharacters.
    static public func escapedPattern(for string: String) -> String {
        return NSRegularExpression.escapedPattern(for: string)
    }

}

@available(*, unavailable)
extension RegEx.MatchResult: Sendable { }
