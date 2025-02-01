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

/// A macro value expression is a parsed representation of a string that might contain macro references.  Parsed macro expressions are immutable, and depend only on the contents of the input string.  Macro names are currently bound after parsing, so macro expressions are in fact independent of the namespace that was used to parse them.  There is no public API on MacroExpression to evaluate it in a MacroEvaluationScope — instead, use the `evaluate()` method on MacroEvaluationScope.
public class MacroExpression : PolymorphicSerializable, CustomStringConvertible, @unchecked Sendable {

    /// String representation from which the expression was instantiated.
    public let stringRep: String

    /// A “compiled program” that can be “run” in order to evaluate the expression in a MacroEvaluationContext.
    private let evalProgram: MacroEvaluationProgram

    /// Initializes the macro expression with `stringRep` as its string representation.  Clients don’t create MacroExpression objects directly; rather, they use MacroNamespace to parse strings into macro expressions.
    init(stringRep: String, evalProgram: MacroEvaluationProgram) {
        self.stringRep = stringRep
        self.evalProgram = evalProgram
    }

    /// Evaluates the expression `context`, rendering results to `result`.  Clients don’t invoke this method directly; rather, they use the `evaluate()` method on MacroEvaluationScope, which constructs a result buffer and a top-level evaluation context and invokes this method.  If `asString` is true, the string form of the expression will be appended to the result buffer — otherwise, the native form (string or list) will be appended.  The native form is the default.
    func evaluate(context: MacroEvaluationContext, resultBuilder: MacroEvaluationResultBuilder, alwaysEvalAsString: Bool = false) {
        evalProgram.executeInContext(context, withResultBuilder: resultBuilder, alwaysEvalAsString: alwaysEvalAsString)
    }

    /// Check if the expression is a literal.
    var isLiteral: Bool {
        return evalProgram.isLiteral
    }

    /// Get the literal string value, if the expression is one.
    public var asLiteralString: String? {
        return evalProgram.asLiteralString
    }

    public var description: String {
        return "\(type(of: self))(\(self.stringRep))"
    }

    // MARK: Serialization

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(stringRep)
        serializer.serialize(evalProgram)
        serializer.endAggregate()
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.stringRep = try deserializer.deserialize()
        self.evalProgram = try deserializer.deserialize()
    }

    public static let implementations: [SerializableTypeCode: any PolymorphicSerializable.Type] = [
        0: MacroExpression.self,
        1: MacroStringExpression.self,
        2: MacroStringListExpression.self
        ]
}

extension MacroExpression: Equatable {
    public static func ==(lhs: MacroExpression, rhs: MacroExpression) -> Bool {
        // Two MacroExpressions are the same if they are of the same type and have the same string representation.
        return type(of: lhs) == type(of: rhs) && lhs.stringRep == rhs.stringRep
    }
}

/// Represents a macro expression that can be evaluated as a string.
public final class MacroStringExpression : MacroExpression, Encodable, @unchecked Sendable {
}

/// Represents a macro expression that can be evaluated as a string list.
public final class MacroStringListExpression : MacroExpression, Encodable, @unchecked Sendable {
}

/// Support static storage of parsed string expressions.
extension MacroStringExpression: StaticStorable {
    public static var staticStorageTable = Dictionary<StaticStorageKey, MacroStringExpression>()
}

/// Support static storage of parsed string list expressions.
extension MacroStringListExpression: StaticStorable {
    public static var staticStorageTable = Dictionary<StaticStorageKey, MacroStringListExpression>()
}
