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

/// Represents a type of macro value.  There are currently four types: booleans, strings, string lists, and user-defined.  Booleans are parsed as strings, but interpreted as boolean after evaluation (in a manner similar to NSString's `-boolValue` method).  Values of user-defined macros are interpreted as booleans, strings, or string lists depending on context.
public enum MacroType: Sendable {
    case boolean
    case string
    case stringList
    case userDefined
    case path
    case pathList

    func matchesExpressionType(_ expression: MacroExpression) -> Bool {
        switch self {
        case .boolean, .string, .path:
            return expression is MacroStringExpression
        case .stringList, .userDefined, .pathList:
            return expression is MacroStringListExpression
        }
    }
}

public protocol EnumerationMacroType: Sendable {
    init?(rawValue: String)
    var rawValue: String { get }
    static var defaultValue: Self { get }
}
