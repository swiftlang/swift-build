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

/// A “program” consisting of a sequence of instructions for building a macro evaluation result buffer.  Regular clients of macro evaluation don’t need to be aware of this class.
final class MacroEvaluationProgram: Serializable, Sendable {
    /// We optimize storage by special casing literal strings.
    ///
    /// NOTE: We can do even better here by splitting out all the literal data into one contiguous buffer, and only indexing into it. That would allow us to have an optimized encoding for the instructions, and potentially serialize as byte strings.
    private enum ProgramVariant {
        /// An empty program.
        case empty

        /// A literal string.
        case literal(String)

        // FIXME: We should also support literal string lists.

        /// Array of instructions that control how the evaluation is performed.
        case instructions([EvalInstr])
    }
    private let variant: ProgramVariant

    /// Private initializer.  MacroEvaluationProgram objects are not instantiated directly; rather, they are constructed using MacroEvaluationProgramBuilder objects, which allow clients to build up sequences of evaluation “instructions”.
    fileprivate init(instructions: [EvalInstr]) {
        if instructions.isEmpty {
            self.variant = .empty
        } else if instructions.count == 1, case let .appendLiteral(string) = instructions[0] {
            self.variant = .literal(string)
        } else {
            self.variant = .instructions(instructions)
        }
    }

    /// Check if the program is a literal.
    var isLiteral: Bool {
        switch variant {
        case .empty:
            return true
        case .literal:
            return true
        case .instructions:
            return false
        }
    }

    /// Get the literal string value, if the program is one.
    var asLiteralString: String? {
        switch variant {
        case .empty:
            return ""
        case .literal(let value):
            return value
        case .instructions:
            return nil
        }
    }

    /// Encodes a single instruction in a “macro evaluation program” (conceptually similar to an individual ‘regcomp()’ program — quite different technically, however).  The instruction set is very simple, and execution progresses linearly until the end of the instruction sequence.  The idea is to distill the specific set of steps that needs to be carried out in order to evaluate a particular macro expression, to make the global decisions once and to let the individual steps be executed quickly at evaluation time.
    enum EvalInstr: Serializable {
        /// Instruction that appends zero or more characters to the result buffer, after applying any pending string list separator.  Because this instruction applies a pending list separator and also sets a flag indicating that literal text has been appended at all, a zero-length string is not a no-op.
        case appendLiteral(String)

        /// Instruction that appends zero or more characters to the result buffer, as with `.appendLiteral`, but only when evaluating the expression as a string (rather than a string-list).
        case appendStringFormOnlyLiteral(String)

        /// Instruction that makes a note that a list separator will be needed before any other literal text is emitted.  The list separator isn’t actually emitted until it’s needed, so that (for example) an arbitrary number of empty arrays can be concatenated without resulting in more than one list separator.  The associated string will be emitted when evaluating the expression as a string (rather than a string list) so that whitespace is fully preserved in that form.
        case setNeedsListSeparator(String)

        /// Instruction that begins a new subresult by pushing a new, empty subresult buffer onto the buffer stack.  Several other instructions use the topmost result buffer as the start of operands.  Every `.beginSubresult` instruction must be balanced by an instruction that “consumes” a subresult buffer:  `.evalNamedMacro`, `.mergeSubresult`, `.applyRetrievalOperator`, or `.applyReplacementOperator`.
        case beginSubresult

        /// Instruction that evaluates a named macro by looking it up and executing its evaluation “program”.  The topmost subresult buffer (as pushed by the `.beginSubresult` instruction) is popped from the stack and used as a macro name to look the assigned value for the macro.  It is an internal error if the subresult stack is empty when this instruction is executed.  The lookup is performed in the context passed to the `lookupMacroInContext()` function.  If a value is found, it is evaluated into the subresult buffer that’s at the top of the stack after the name has been popped.  If there is no value for the named macro in the context, and `preserveOriginalIfUnresolved` is false, nothing is appended to the subresult buffer.  If `preserveOriginalIfUnresolved` is true, then the original spelling of the macro will be inserted.  If `asString` is true, or if the `alwaysEvalAsString` parameter passed to the invocation of the `execute()` method is true, the value associated with the macro is evaluated as a string regardless of whether its native form is a list or a string.  Otherwise (if neither of those booleans is true), it is evaluated as its native form.
        //
        // FIXME: We should consider making the `preserveOriginalIfUnresolved` behavior deprecated, it is used rarely in practice and is mostly an accommodation to situations where the `$` is intended to be literal, but wasn't quoted, and it just happens to work because the trailing "macro name" is unlikely to be defined.
        case evalNamedMacro(asString: Bool, preserveOriginalIfUnresolved: Bool)

        /// Instruction that instruction that merges the topmost subresult buffer (as pushed by the `.beginSubresult` instruction) into the subresult buffer immediately below it.  It is an internal error if the subresult stack doesn’t contain at least two entries when this instruction is executed.
        case mergeSubresult

        /// Instruction that instruction that applies a retrieval operation to each element of the topmost subresult buffer, replacing that buffer with the result.  It is an internal error if the subresult stack is empty when this instruction is executed.
        case applyRetrievalOperator(MacroEvaluationRetrievalOperator)

        case applyReplacementOperator(MacroEvaluationReplacementOperator)

        /// We will most likely also add an EvalInherited instruction to avoid looking for specific keywords

        // Serialization

        func serialize<T: Serializer>(to serializer: T) {
            serializer.beginAggregate(2)
            switch self {
            case .appendLiteral(let string):
                serializer.serialize(0)
                serializer.serialize(string)
            case .appendStringFormOnlyLiteral(let string):
                serializer.serialize(1)
                serializer.serialize(string)
            case .setNeedsListSeparator(let string):
                serializer.serialize(2)
                serializer.serialize(string)
            case .beginSubresult:
                serializer.serialize(3)
                serializer.serializeNil()
            case .evalNamedMacro(let asString, let preservesOriginal):
                serializer.serialize(preservesOriginal ? 5 : 4)
                serializer.serialize(asString)
            case .mergeSubresult:
                serializer.serialize(6)
                serializer.serializeNil()
            case .applyRetrievalOperator(let op):
                serializer.serialize(7)
                serializer.serialize(op.rawValue)
            case .applyReplacementOperator(let op):
                serializer.serialize(8)
                serializer.serialize(op.rawValue)
            }
            serializer.endAggregate()
        }

        init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            let code: Int = try deserializer.deserialize()
            switch code {
            case 0:
                let string: String = try deserializer.deserialize()
                self = .appendLiteral(string)
            case 1:
                let string: String = try deserializer.deserialize()
                self = .appendStringFormOnlyLiteral(string)
            case 2:
                let string: String = try deserializer.deserialize()
                self = .setNeedsListSeparator(string)
            case 3:
                guard deserializer.deserializeNil() else { throw DeserializerError.deserializationFailed("Unexpected associated value for EvalInstr.beginSubresult.") }
                self = .beginSubresult
            case 4:
                let asString: Bool = try deserializer.deserialize()
                self = .evalNamedMacro(asString: asString, preserveOriginalIfUnresolved: false)
            case 5:
                let asString: Bool = try deserializer.deserialize()
                self = .evalNamedMacro(asString: asString, preserveOriginalIfUnresolved: true)
            case 6:
                guard deserializer.deserializeNil() else { throw DeserializerError.deserializationFailed("Unexpected associated value for EvalInstr.mergeSubresult.") }
                self = .mergeSubresult
            case 7:
                let opVal: Int = try deserializer.deserialize()
                guard let op = MacroEvaluationRetrievalOperator(rawValue: opVal) else { throw DeserializerError.deserializationFailed("Unexpected value '\(opVal)' for EvalInstr.applyRetrievalOperator") }
                self = .applyRetrievalOperator(op)
            case 8:
                let opVal: Int = try deserializer.deserialize()
                guard let op = MacroEvaluationReplacementOperator(rawValue: opVal) else { throw DeserializerError.deserializationFailed("Unexpected value '\(opVal)' for EvalInstr.applyReplacementOperator") }
                self = .applyReplacementOperator(op)
            default:
                throw DeserializerError.incorrectType("Unexpected type code for EvalInstr: \(code)")
            }
        }
    }

    /// This enum defines the supported retrieval operators for macro evaluation, and the logic to apply them to the result of evaluating a macro. A retrieval operator returns a transformation of the value of the setting, for example `:upper` and `:lower` which uppercase the lowercase the result respectively, or `dir`, `file`, `base` and `suffix`, which return a subset of the result if it is a path.
    ///
    /// The raw value of this enum is used to serialize it efficiently as part of a macro evaluation program.
    enum MacroEvaluationRetrievalOperator: Int {
        case quote
        case upper
        case lower
        case identifier
        case rfc1034identifier
        case c99extidentifier
        case md5
        case stripslash
        case dir
        case file
        case base
        case suffix
        case standardizepath
        case not

        /// Creates and returns a new retrieval operator with the given `name`.  Returns nil if the `name` is not a supported operator.
        init?(_ name: String) {
            switch name {
            case "quote": self = .quote
            case "upper": self = .upper
            case "lower": self = .lower
            case "identifier": self = .identifier
            case "rfc1034identifier": self = .rfc1034identifier
            case "c99extidentifier": self = .c99extidentifier
            case "__md5": self = .md5
            case "__stripslash": self = .stripslash
            case "dir": self = .dir
            case "file": self = .file
            case "base": self = .base
            case "suffix": self = .suffix
            case "standardizepath": self = .standardizepath
            case "not": self = .not
            default:
                return nil
            }
        }

        /// Applies a retrieval operator to the given `string`, returning the result.
        func apply(to string: String) -> String {
            switch self {
            case .quote:
                return string.quotedDescription
            case .upper:
                return string.uppercased()
            case .lower:
                return string.lowercased()
            case .identifier:
                return string.asLegalCIdentifier
            case .rfc1034identifier:
                return string.asLegalRfc1034Identifier
            case .c99extidentifier:
                return string.mangledToC99ExtendedIdentifier()
            case .md5:
                return string.md5()
            case .stripslash:
                return string.hasPrefix("/") ? String(string.dropFirst()) : string
            case .dir:
                // Return just the directory part, including the trailing slash, if any.
                let dirPath = Path(string).dirname.str
                guard !dirPath.isEmpty else { return "./" }
                return dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
            case .file:
                // Return the last path component, including any suffix.
                return Path(string).basename
            case .base:
                // Return the base name of the filename (last path component, minus suffix).
                return Path(string).basenameWithoutSuffix
            case .suffix:
                // Return the suffix of the filename (the extension with the leading '.').
                return Path(string).fileSuffix
            case .standardizepath:
                return Path(string).normalize(removeDotDotFromRelativePath: false).str
            case .not:
                return string != "YES" ? "YES" : "NO"
            }
        }
    }

    /// This enum defines the supported replacement operators for macro evaluation, and the logic to apply them to the result of evaluating a macro. A replacement operator has usage of the form `:op=` and replaces all or part of the value of the setting after evaluation. For example, if the result is a path then`:suffix=` will return the value with the path's suffix replaced with the rhs of the operator.
    ///
    /// Note that the value of the operator can itself be a macro expression; the evaluated expression is passed in to the `apply(to:withReplacement:)` method by the caller.
    ///
    /// The raw value of this enum is used to serialize it efficiently as part of a macro evaluation program.
    enum MacroEvaluationReplacementOperator: Int {
        case dir
        case file
        case base
        case suffix
        case `default`
        case relativeto
        case isancestor

        /// Creates and returns a new replacement operator with the given `name`.  Returns nil if the `name` is not a supported operator.
        init?(_ name: String) {
            switch name {
            case "dir": self = .dir
            case "file": self = .file
            case "base": self = .base
            case "suffix": self = .suffix
            case "relativeto": self = .relativeto
            case "isancestor": self = .isancestor
            case "default": self = .default
            default:
                return nil
            }
        }

        /// Returns true if the operator should be applied even to an empty result of evaluating a setting (as distinct from a result which is explicitly the empty string).
        fileprivate var applyToEmptyResult: Bool {
            switch self {
            case .default:
                return true
            default:
                return false
            }
        }

        /// Applies a replacement operator to the given `string` with `replacementString`, returning the result.
        func apply(to string: String, withReplacement replacementString: String) -> String {
            switch self {
            case .dir:
                return Path(replacementString).join(Path(string).basename).str
            case .file:
                return Path(string).dirname.join(Path(replacementString)).str
            case .base:
                let original = Path(string)
                return original.dirname.join(Path(replacementString)).str + ".\(original.fileExtension)"
            case .suffix:
                let suffix = replacementString.contains(".") ? Path(replacementString).fileExtension : replacementString
                return Path(Path(string).withoutSuffix).str + ".\(suffix)"
            case .relativeto:
                let stringPath: SWBUtil.AbsolutePath
                let replacementStringPath: SWBUtil.AbsolutePath
                do {
                    stringPath = try AbsolutePath(validating: string)
                    replacementStringPath = try AbsolutePath(validating: replacementString)
                } catch {
                    // If one of the paths wasn't absolute, we return the original input.
                    return string
                }

                return replacementStringPath.relative(to: stringPath).path.str
            case .isancestor:
                let stringPath: SWBUtil.AbsolutePath
                let replacementStringPath: SWBUtil.AbsolutePath
                do {
                    stringPath = try AbsolutePath(validating: string)
                    replacementStringPath = try AbsolutePath(validating: replacementString)
                } catch {
                    // If one of the paths wasn't absolute, we return the original input.
                    return "NO"
                }
                return replacementStringPath.isAncestor(of: stringPath) ? "YES" : "NO"
            case .default:
                return string.isEmpty ? replacementString : string
            }
        }
    }

    /// Look up the macro to use for a substitution.
    private func lookupMacroInContext(_ context: MacroEvaluationContext, name: String) -> MacroDeclaration? {
        // If the name is empty, it cannot map to a macro.
        guard !name.isEmpty else { return nil }

        // Otherwise, we can perform a normal lookup into namespace.
        //
        // FIXME: The check for "inherited" here is suboptimal, and will be cleaned up.  Instead, we can detect the lookup-inherited case at the time we generate the evaluation program, and instead emit a EvalInherited instruction.
        //
        // FIXME: We should pre-bind most of these, to avoid the lookup: <rdar://problem/28689568> Pre-bind macro declarations during expression parsing
        if name == "inherited" || name == "value" {
            if let inherited = context.macro {
                return inherited
            } else if name == "value" {
                // If we have no inherited macro, but this was a lookup for "value" specifically, allow clients to provide a specific value using the evaluation override mechanism.
                return context.scope.namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, "value")
            } else {
                return nil
            }
        } else {
            return context.scope.table.namespace.lookupMacroDeclaration(name)
        }
    }

    /// Executes the “macro evaluation program” within `context`, which provides all the state needed for macro value lookup.  Any emitted output will be added to `resultBuilder`.  If `alwaysEvalAsString` is true, all macro evaluation instructions will evaluate the string form of the looked-up macro value — otherwise, only the instructions whose `asString` flag is true will be evaluated as strings, and the others will evaluate as whatever the native form of the value is (string or string list).
    func executeInContext(_ context: MacroEvaluationContext, withResultBuilder resultBuilder: MacroEvaluationResultBuilder, alwaysEvalAsString: Bool = false) {
        // Extract the variant.
        let instructions: [EvalInstr]
        switch variant {
        case .empty:
            return

        case .literal(let s):
            resultBuilder.append(s)
            return

        case .instructions(let value):
            instructions = value
        }

        // Stack of subresult buffers.  All instructions that affect buffers apply to the top one on this stack.
        var subresults: [MacroEvaluationResultBuilder] = []

        // Iterate over all the instructions in order.  We currently don’t have any branching or conditional instructions, so this is very simple.
        for instr in instructions {
            switch instr {

              case .appendLiteral(let s):
                // Emit a literal sequence of characters to the result buffer.  Even an empty string can have significant meaning if it causes a pending list element separator to be made real, so we don’t take any shortcuts here by checking for empty string or anything like that.  Any instruction that is actually unnecessary should have already been optimized out by the instruction generation logic anyway.
                (subresults.last ?? resultBuilder).append(s)

              case .appendStringFormOnlyLiteral(let s):
                // Emit a literal sequence of characters to the result buffer, as with `.appendLiteral`, but only if 'alwaysEvalAsString' is true.  This is used for whitespace, quotes, and escape characters that appear in the string form but not the string list form.  This allows the same macro evaluation program to be used for both the string form and the string list form.
                if alwaysEvalAsString {
                    (subresults.last ?? resultBuilder).append(s)
                }

              case .setNeedsListSeparator(let s):
                // Either set a list separator or add a string-list-form-only substring (such as whitespace) to the result buffer, depending on whether or not the caller wants us to always execute the evaluation program as a string.  Note that we don’t look at `allEvalsAreStrings` here — that refers to evaluation of any embedded macro references.
                if alwaysEvalAsString {
                    // Add the whitespace which was captured for this separator in the string form.
                    (subresults.last ?? resultBuilder).append(s)
                }
                else {
                    // Tell the result builder that we’ll need a list element separator.  This doesn’t add one immediately, but rather sets a flag so that the next `.appendLiteral` instruction will cause a list separator to be added.  This allows us to, for example, concatenate a completely empty array without getting extraneous list separators.
                    (subresults.last ?? resultBuilder).setNeedsListElementSeparator()
                }

              case .beginSubresult:
                // Push a new, empty buffer onto the top of the subresult stack.  This must be balanced by one of the below instructions that use and pop result buffers off the stack.
                let subresult = MacroEvaluationResultBuilder()
                subresults.append(subresult)

              case .evalNamedMacro(let asString, let preservesOriginal):
                // Pop the topmost subresult buffer, and use its contents as the name of a macro to evaluate.  It’s an internal error if the subresult stack is empty.
                let nb = subresults.popLast()!
                let s = nb.buildString()
                // Look up the declaration (if any) for the macro name.
                if let macro = lookupMacroInContext(context, name: s) {
                    // Find the next value (if any) in the list of values for that macro name.
                    if let value = context.nextValueForMacro(macro) {
                        // We found a value, so we evaluate its associated "macro evaluation program” into it the topmost subresult buffer.  Note that multiple programs often contribute to the same buffer, e.g. in "$(X)/$(Y)".
                        value.expression.evaluate(context: MacroEvaluationContext(scope: context.scope, macro: macro, value: value, parent: context), resultBuilder: subresults.last!, alwaysEvalAsString: asString || alwaysEvalAsString)
                    }
                    else {
                        if preservesOriginal {
                            // If we are preserving the original string, we append it now.
                            (subresults.last ?? resultBuilder).append("$" + s)
                        } else {
                            // It’s a known macro but no value has been defined for it.  If it’s a boolean or a string we substitute the empty string.
                            if macro.type == .boolean || macro.type == .string {
                                (subresults.last ?? resultBuilder).append("")
                            }
                        }
                    }
                }
                else {
                    // It’s an unknown macro, so we cannot possibly have any definition for it — this should really be reported back as an error, and we should refine the API so that we can tell the calling context about it.  For now we silently append either the original string, if we've been asked to preserve it.
                    if preservesOriginal {
                        (subresults.last ?? resultBuilder).append("$" + s)
                    }
                }

              case .mergeSubresult:
                // Pop the topmost subresult buffer, and merge its contents into the buffer below it buffer.  It’s an internal error if the subresult stack is empty.
                let nb = subresults.popLast()!
                (subresults.last ?? resultBuilder).appendContentsOfResultBuilder(nb)

              case .applyRetrievalOperator(let op):
                // Pop the topmost subresult buffer, and apply the retrieval operator to each of its elements.  This results in a new equivalent subresult buffer, which we then push.  It’s an internal error if the subresult stack is empty.
                let sb = subresults.popLast()!
                let nb = MacroEvaluationResultBuilder()
                sb.enumerateListElementSubstrings() { elem in
                    nb.append(op.apply(to: elem))
                    nb.setNeedsListElementSeparator()
                }
                subresults.append(nb)

              case .applyReplacementOperator(let op):
                // Pop the topmost subresult buffer, and apply the retrieval operator to each of its elements.  This results in a new equivalent subresult buffer, which we then push.  It’s an internal error if the subresult stack is empty.
                let operand = subresults.popLast()!.buildString()
                let sb = subresults.popLast()!
                let nb = MacroEvaluationResultBuilder()
                if sb.hasHadAnyTextAppended {
                    sb.enumerateListElementSubstrings() { elem in
                        nb.append(op.apply(to: elem, withReplacement: operand))
                        nb.setNeedsListElementSeparator()
                    }
                }
                else {
                    // Special case: If the subresult buffer is empty, but the operator wants to be applied even to empty results, then we do so here, applying it to an empty string.
                    if op.applyToEmptyResult {
                        nb.append(op.apply(to: "", withReplacement: operand))
                    }
                }
                subresults.append(nb)
            }
        }

        // If any new subresult buffers were created (using the `BeginSubresult` instruction), they should have all been consumed again (using either `EvalNamedMacro` or `MergeSubresult` instructions) by now.
        assert(subresults.isEmpty)
    }

    // Serialization

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        switch variant {
        case .empty:
            serializer.serialize(0)
            serializer.serializeNil()
        case let .literal(string):
            serializer.serialize(1)
            serializer.serialize(string)
        case let .instructions(instructions):
            serializer.serialize(2)
            serializer.serialize(instructions)
        }
        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        let code: Int = try deserializer.deserialize()
        switch code {
        case 0:
            self.variant = .empty
            guard deserializer.deserializeNil() else { throw DeserializerError.deserializationFailed("Unexpected associated value for EvalInstr.beginSubresult.") }
        case 1:
            self.variant = .literal(try deserializer.deserialize())
        case 2:
            self.variant = .instructions(try deserializer.deserialize())
        default:
            throw DeserializerError.incorrectType("Unexpected type code for EvalInstr: \(code)")
        }
    }
}


/// A helper class to build a MacroEvaluationProgram.  Regular clients of macro evaluation don’t need to be aware of this class.
final class MacroEvaluationProgramBuilder {

    /// Instructions being built up.
    private var instrs = Array<MacroEvaluationProgram.EvalInstr>()

    /// Append `instr` to the end of the array of instructions being built up.
    func emit(_ instr: MacroEvaluationProgram.EvalInstr) {
        instrs.append(instr)
    }

    /// Creates and returns a MacroEvaluationProgram based on the instructions that have been emitted to the builder.  It’s not an error to append more instructions after building the program, but in most cases there’s no point.
    func build() -> MacroEvaluationProgram {
        return MacroEvaluationProgram(instructions: instrs)
    }
}


/// Lets a macro expression evaluator program build a result (either a string or a string list).  Conceptually, the result consists of a sequence of literal string fragments separated by “list element separators”, which demarcate the subranges of the result string that form the string list elements.  Both string and string list results are supported using the same function (a string and a single-element string list are the same thing, in practical terms).  This approach of a single string demarcated by separators is conceptually quite similar to how, for example, a continuous stream of audio data is separated into tracks using “cue sheet split points” on a CD.  In the case of macro expression evaluation, this approach avoids many of the special cases that would otherwise occur when evaluating a string list that refers to a mixture of string and string list subexpressions.
final class MacroEvaluationResultBuilder {

    /// Contiguous sequence of characters being built up.  List separators are indexes into this string.
    ///
    /// We use an array of raw UTF-8 bytes because Swift's String API does not provide "portable" indexes. For example, an index retrieved from a UTF8View must only be used to index into that specific instance, in part because the String.Index type stores "pointers" into the underlying string storage, which is not necessarily UTF-8 itself due to cases like Foundation NSString (UTF-16 encoded) bridging.
    private var accumulatedStringUTF8 = [UInt8]()

    /// Indexes of any list separators (split points), in ascending order.  The number of elements is always one greater than the number of list separators.
    private var listElementSeparators = Array<Array<UInt8>.Index>()

    /// Records whether or not a list separator will be needed when more text is added.
    private var needsListElementSeparator = false

    /// Records whether or not there has been any text appended at all.
    fileprivate private(set) var hasHadAnyTextAppended = false

    /// Create a macro result builder.
    init() { }

    /// If the “needs list element separator” flag has been set, this function adds a list separator for the index corresponding to the current end of the accumulator string, and clears the flag.  Otherwise, this function does nothing.  Clients never invoke this function directly — instead, they note the need for a list element separator and let it be created the next time anything is appended.
    private func applyPendingListElementSeparatorIfNeeded() {
        // If the flag is set, we record the current end index of the accumulated string as the start index of the next element, and clear the flag.
        guard needsListElementSeparator else { return }
        listElementSeparators.append(accumulatedStringUTF8.endIndex)
        needsListElementSeparator = false
    }

    /// Sets the “needs list element separator” flag so that a list element separator will be created if any more text is subsequently added.
    func setNeedsListElementSeparator() {
        guard hasHadAnyTextAppended else { return }
        needsListElementSeparator = true
    }

    /// Appends the contents of the string to the end of the buffer, after appending a list element barrier if the “needs list element separator” flag has been set (using the `setNeedsListElementSeparator` function).
    func append(_ string: String) {
        // We walso make a note that we've had any text appended at all, even if it was the empty string.
        applyPendingListElementSeparatorIfNeeded()
        accumulatedStringUTF8.append(contentsOf: string.utf8)
        hasHadAnyTextAppended = true
    }

    /// Appends the contents of the other result builder to the end of the buffer (including any list element barriers), after appending a list element barrier if the “needs list element separator” flag has been set (using the `setNeedsListElementSeparator` function).
    func appendContentsOfResultBuilder(_ other: MacroEvaluationResultBuilder) {
        guard other.hasHadAnyTextAppended else { return }
        applyPendingListElementSeparatorIfNeeded()
        // we use that as base for the shift operation
        let baseIndex = accumulatedStringUTF8.endIndex
        accumulatedStringUTF8.append(contentsOf: other.accumulatedStringUTF8)
        listElementSeparators.append(contentsOf: other.listElementSeparators.map { baseIndex + $0 })
        // If the other buffer has had any text at all appended (even empty strings), that means that we have so as well, now.
        if other.hasHadAnyTextAppended {
            hasHadAnyTextAppended = true
        }
    }

    /// Enumerates the substrings separated by list element separators, invoking the block for each one.  The block is always invoked at least once, since a string (even an empty one) without any list element separators is still a single string.
    func enumerateListElementSubstrings(_ block: (String) -> Void) {
        // Move through any list element separators, invoking the block once for each subrange that ends at the separator.
        var lastIndex = accumulatedStringUTF8.startIndex
        for separator in listElementSeparators {
            block(String(decoding: accumulatedStringUTF8[lastIndex..<separator], as: UTF8.self))
            lastIndex = separator
        }
        // If we’ve had any text appended at all (even the empty string), we also have a trailing subrange at the end.  The test is needed in order to distinguish completely empty arrays from ones that consist of just a single empty string element.
        if hasHadAnyTextAppended {
            block(String(decoding: accumulatedStringUTF8[lastIndex...], as: UTF8.self))
        }
    }

    /// Creates and returns a string from the contents of the result builder (ignoring any list element separators that might be present).
    func buildString() -> String {
        // The accumulated string buffer is already exactly the string we want.
        return String(decoding: accumulatedStringUTF8, as: UTF8.self)
    }

    /// Creates and returns a string list from the contents of the result builder (taking into account any list element separators that might be present).
    func buildStringList() -> Array<String> {
        // The accumulated string buffer is just a string that needs to be split according to the element separators.
        var result = Array<String>()
        result.reserveCapacity(listElementSeparators.count + 1)
        enumerateListElementSubstrings { result.append($0) }
        return result
    }
}

// MARK: TSC helpers

private import TSCBasic

extension SWBUtil.AbsolutePath {
    // FIXME: Sink down to SWBUtil with an implementation not bound to TSC. It's also not clear that this should be non-failable, as "Because both paths are absolute, they always have a common ancestor (the root path, if nothing else)." is not true on Windows.
    public func relative(to other: SWBUtil.AbsolutePath) -> SWBUtil.RelativePath {
        try! RelativePath(validating: TSCBasic.AbsolutePath(validating: path.str).relative(to: TSCBasic.AbsolutePath(validating: other.path.str)).pathString)
    }
}
