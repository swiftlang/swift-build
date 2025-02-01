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

/// A parameter on which macro value assignments can be made conditional.  Examples include "arch", "sdk", "config", etc.  MacroConditionParameters are created using API in MacroNamespace, and are referenced from MacroConditions.
public final class MacroConditionParameter: Hashable, CustomStringConvertible, Encodable, Sendable {
    /// Condition name (always a non-empty string).
    public let name: String

    /// Initializer is internal, since only `MacroNamespace` can create condition parameters.
    init(name: String) {
        precondition(name != "", "macro condition parameter name cannot be empty")
        self.name = name
    }

    /// Returns a hash value based on the identity of the object.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func ==(lhs: MacroConditionParameter, rhs: MacroConditionParameter) -> Bool {
        return lhs === rhs
    }

    /// Returns a description of the macro condition parameter.
    public var description: String {
        return "\(name)"
    }
}
