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

import Foundation

public struct FnmatchOptions: OptionSet, Sendable {
    /// The default option.
    public static let `default` = FnmatchOptions([])

    /// Slash must be matched by slash.
    public static let pathname = FnmatchOptions(rawValue: 1 << 0)

    /// Case insensitive search.
    public static let caseInsensitive = FnmatchOptions(rawValue: 1 << 1)

    /// The underlying raw value.
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
}

private enum RangeStatus {
    case noMatch
    case match
    case error
}

private extension StringProtocol {
    @inline(__always)
    func firstIndex(matching characters: Set<Character>) -> String.Index? {
        if characters.isEmpty {
            return nil
        }
        return firstIndex(where: {characters.contains($0)})
    }
}

/// Multi-platform fnmatch implementation. This is intended to be a close match the the POSIX fnmatch of all platforms including Windows (though not all options are supported).
///
/// - parameter pattern: The pattern to match. When using the ``FnmatchOptions/pathname`` option, any path representation in the pattern is expected to use the POSIX path separator (`/`) to match with the input, and on Windows, the path separator (`/`) will be matched to either separator in the input string ( both `/` and `\` will be matched).
/// - parameter input: The input string to match.
/// - parameter options: The ``FnmatchOptions`` to use.
/// - returns: `true` if the pattern matches the input, `false` otherwise.
///
/// - note: On Windows and when using the ``FnmatchOptions/pathname`` option, both separators (`/` and `\`) are recognized (see note on pattern parameter).
public func fnmatch(pattern: some StringProtocol, input: some StringProtocol, options: FnmatchOptions = .default, pathSeparators: Set<Character> = Path.pathSeparators) throws
    -> Bool
{
    // Use Substrings to avoid String allocations
    var pattern = Substring(pattern)
    var input = Substring(input)
    var bt_pattern: Substring? = nil
    var bt_input: Substring = input

    while true {
        let pc = pattern.first
        pattern = pattern.dropFirst()

        switch pc {
        case nil:
            if input.first == nil {
                return true
            }
            if backtrack() {
                return false
            }
        case "?":
            guard let _sc = input.first else {
                return false
            }
            if options.contains(.pathname) && pathSeparators.contains(_sc) {
                if backtrack() {
                    return false
                }
            }
            input = input.dropFirst()
        case "*":
            var p = pattern.first
            while pattern.first == "*" {
                // consume multiple '*' in pattern
                pattern = pattern.dropFirst()
                p = pattern.first
            }
            if p == nil {
                if options.contains(.pathname) {
                    // make sure input does not have any more path separators
                    return input.firstIndex(matching: pathSeparators) == nil ? true : false
                } else {
                    return true  // pattern matched everything else in input
                }
            } else if pattern.first == "/" && options.contains(.pathname) {
                // we have a '*/' pattern input must have an path separators to continue
                guard let newInputIndex = input.firstIndex(matching: pathSeparators) else {
                    return false
                }
                input.removeSubrange(..<newInputIndex)
                continue
            }
            bt_pattern = pattern
            bt_input = input
        case "[":
            guard let _sc = input.first else {
                return false
            }
            if pathSeparators.contains(_sc) && options.contains(.pathname) {
                if backtrack() {
                    return false
                }
            }
            var new_input = input.dropFirst()
            var new_pattern = pattern
            switch rangematch(pattern: &new_pattern, input: &new_input, test: _sc, options: options, pathSeparators: pathSeparators) {
            case .error:
                throw FnmatchError.rangeError(pattern: "[" + pattern)
            case .match:
                pattern = new_pattern
                input = new_input
                break
            case .noMatch:
                if backtrack() {
                    return false
                }
            }
        default:
            guard let _sc = input.first else {
                return false
            }
            guard let _pc = pc else {
                return false
            }
            input = input.dropFirst()
            if _pc == _sc
                || (options.contains(.caseInsensitive) && _pc.lowercased() == _sc.lowercased())
            {
                continue
            } else {
                // windows need to test for both path separators
                if _pc == "/" && options.contains(.pathname) && pathSeparators.contains(_sc) {
                    continue
                }
                if backtrack() {
                    return false
                }
            }
        }

        // If we have a mismatch (other than hitting the end of the string),
        // go back to the last '*' seen and have it match one additional character.
        @inline(__always)
        func backtrack() -> Bool {
            guard let _pattern = bt_pattern else {
                return true
            }
            guard let _sc = bt_input.first else {
                return true
            }
            if _sc == "/" && options.contains(.pathname) {
                return true
            }
            bt_input = bt_input.dropFirst()
            input = bt_input
            pattern = _pattern
            return false
        }
    }
}

@inline(__always)
private func rangematch(pattern: inout Substring, input: inout Substring, test: Character, options: FnmatchOptions,  pathSeparators: Set<Character>) -> RangeStatus {
    var test = test

    if !pattern.contains("]") {
        // unmatched '[' test as literal '['
        return "[" == test ? .match : .noMatch
    }

    let negate = pattern.first == "!"
    if negate {
        pattern = pattern.dropFirst()
    }
    if options.contains(.caseInsensitive) {
        test = Character(test.lowercased())
    }
    var ok = false
    while var c = pattern.first {
        pattern = pattern.dropFirst()
        if c == "]" {
            break
        }
        if options.contains(.pathname) && pathSeparators.contains(c) {
            return .noMatch
        }
        if options.contains(.caseInsensitive) {
            c = Character(c.lowercased())
        }
        if pattern.first == "-" {
            let subPattern = pattern.dropFirst()
            if var c2 = subPattern.first {
                if c2 != "]" {
                    if options.contains(.caseInsensitive) {
                        c2 = Character(c2.lowercased())
                    }
                    if c...c2 ~= test {
                        ok = true
                    }
                    pattern = subPattern.dropFirst()
                } else {
                    return .error
                }
            }
        } else if c == test {
            ok = true
        }
    }
    return ok == negate ? .noMatch : .match
}

public enum FnmatchError: Swift.Error, CustomStringConvertible, Equatable {

    case rangeError(pattern: String)

    public var description: String {
        switch self {
        case .rangeError(let pattern):
            return "fnmatch failed with range error: pattern: \(pattern)"
        }
    }
}
