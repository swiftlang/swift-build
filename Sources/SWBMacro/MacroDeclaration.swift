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

public import SWBUtil

/// A declaration of a macro with a particular name.  Names are unique within a macro namespace.  Macro declarations are typed in order to promote type safety on lookup.  Every macro declaration belongs to a namespace, and macro declarations are always created using methods on the namespace.
public class MacroDeclaration: Hashable, CustomStringConvertible, Encodable, @unchecked Sendable {
    /// Macro name (always a non-empty string).
    public let name: String

    /// Type (boolean, string, string list, or user-defined).  Concrete subclasses override this property as appropriate.
    // FIXME: It would be great to not have to provide an implementation, in order to make this class abstract; we cannot use protocols because then we couldn't use MacroDeclaration objects as keys.
    public var type: MacroType { preconditionFailure("this method is a subclass responsibility") }

    /// Initializer is private, since only the concrete subclasses (one for each possible type of macro) can be instantiated.
    public required init(name: String) {
        precondition(name != "", "macro name cannot be empty")
        self.name = name
    }

    /// Returns a hash value based on the identity of the object.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    /// Tests for quality based on the identities of the two macro declarations.
    public static func ==(lhs: MacroDeclaration, rhs: MacroDeclaration) -> Bool {
        return lhs === rhs
    }

    /// Returns a description of the macro declaration.
    public var description: String {
        return "\(type):\(name)"
    }

    /// Returns the evaluated value of the macro in the given scope as a `PropertyListItem`.
    public func propertyListValue(in scope: MacroEvaluationScope) -> PropertyListItem? {
        preconditionFailure("this method is a subclass responsibility")
    }
}

/// Concrete subclass of `MacroDeclaration` for boolean macro declarations.
public final class BooleanMacroDeclaration: MacroDeclaration, @unchecked Sendable {
    /// Returns the `.boolean` type.
    override public var type: MacroType { return .boolean }

    /// Returns the evaluated value of the macro in the given scope, as a boolean.
    override public func propertyListValue(in scope: MacroEvaluationScope) -> PropertyListItem? {
        return .plBool(scope.evaluate(self))
    }
}

/// Type-erased variant of `EnumMacroDeclaration`.
public class AnyEnumMacroDeclaration: MacroDeclaration, @unchecked Sendable {
}

/// Concrete subclass of `MacroDeclaration` for enumeration macro declarations.
public final class EnumMacroDeclaration<T: EnumerationMacroType>: AnyEnumMacroDeclaration, @unchecked Sendable {
    /// Returns the `.string` type.
    override public var type: MacroType { return .string }

    /// Returns the evaluated value of the macro in the given scope, as a string.
    override public func propertyListValue(in scope: MacroEvaluationScope) -> PropertyListItem? {
        return .plString(scope.evaluateAsString(self))
    }
}

/// Concrete subclass of `MacroDeclaration` for string macro declarations.
public final class StringMacroDeclaration: MacroDeclaration, @unchecked Sendable {
    /// Returns the `.string` type.
    override public var type: MacroType { return .string }

    /// Returns the evaluated value of the macro in the given scope, as a string.
    public override func propertyListValue(in scope: MacroEvaluationScope) -> PropertyListItem? {
        return .plString(scope.evaluate(self))
    }
}

/// Concrete subclass of `MacroDeclaration` for string list macro declarations.
public final class StringListMacroDeclaration: MacroDeclaration, @unchecked Sendable {
    /// Returns the `.stringList` type.
    override public var type: MacroType { return .stringList }

    /// Returns the evaluated value of the macro in the given scope, as an array of strings.
    override public func propertyListValue(in scope: MacroEvaluationScope) -> PropertyListItem? {
        return .plArray(scope.evaluate(self).map { .plString($0) })
    }
}

/// Concrete subclass of `MacroDeclaration` for user-defined macro declarations.
public final class UserDefinedMacroDeclaration: MacroDeclaration, @unchecked Sendable {
    /// Returns the `.userDefined` type.
    override public var type: MacroType { return .userDefined }

    /// Returns nil since we don't currently have a syntax for indicating the type of the evaluated value of a user-defined macro.
    override public func propertyListValue(in scope: MacroEvaluationScope) -> PropertyListItem? {
        return nil
    }
}

public final class PathMacroDeclaration: MacroDeclaration, @unchecked Sendable {
    /// Returns the `.path` type.
    override public var type: MacroType { return .path }

    /// Returns the evaluated value of the macro in the given scope, as a string.
    public override func propertyListValue(in scope: MacroEvaluationScope) -> PropertyListItem? {
        return .plString(scope.evaluate(self).str)
    }
}

public final class PathListMacroDeclaration: MacroDeclaration, @unchecked Sendable {
    /// Returns the `.pathList` type.
    override public var type: MacroType { return .pathList }

    /// Returns the evaluated value of the macro in the given scope, as a string.
    public override func propertyListValue(in scope: MacroEvaluationScope) -> PropertyListItem? {
        return .plArray(scope.evaluate(self).map { .plString($0) })
    }
}
