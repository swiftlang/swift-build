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
public import SWBMacro
import Foundation

public extension PropertyListItem
{
    // TODO: In principle we could push 'preserveReferencesToSettings' down to the core evaluation methods, but that's a lot more work and not immediately needed.  I only added it here because evaluating macros in a whole property list structure is nontrivial.
    //
    /// Method which returns a new property list with macros evaluated in all string values.  By default, macros in dictionary keys are *not* evaluated, but they optionally can be.
    /// - parameter scope: The `MacroEvaluationScope` to use to evaluate macros.
    /// - parameter andDictionaryKeys: If `true`, then both keys and values in dictionaries will have macros evaluated.  If `false`, then only values in dictionaries will have keys evaluated.  Defaults to `false`.
    /// - parameter preserveReferencesToSettings: If not nil, then any macros in this set will not be evaluated but will be preserved for later potential evaluation.  Macros in this set take precedence over the later `lookup` parameter.
    /// - parameter lookup: A block used to override evaluation of macros in the scope.
    /// - returns: The receiver with settings evaluated as directed.
    func byEvaluatingMacros(withScope scope: MacroEvaluationScope, andDictionaryKeys: Bool = false, preserveReferencesToSettings: Set<MacroDeclaration>? = nil, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> PropertyListItem
    {
        // Helper function to evaluate macros in a string,
        func stringByEvaluatingMacros(_ string: String, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String
        {
            // If preserveSettingsReferences is not nil, then we create a lookup block to preserve settings references during evaluation.  We define this block here rather than in the outermost call so we can track whether we actually preserved any references and skip the .replacingOccurrences(of:) call below if we don't need to do it.
            var anyReferencesWerePreserved = false
            let preservingLookup: ((MacroDeclaration) -> MacroExpression?)?
            if let preserveSettingsReferences = preserveReferencesToSettings {
                preservingLookup = { macro in
                    if preserveSettingsReferences.contains(macro) {
                        // Replace the setting with a specially-constructed placeholder, so for example '$(SETTING_NAME)' will be replaced with '\$\(((SETTING_NAME)' so we can replace the '\$\(((' with '$('.  This obviously assumes that no string will contain '\$\((('.
                        anyReferencesWerePreserved = true
                        return scope.table.namespace.parseLiteralString("\\$\\(((\(macro.name))")
                    }
                    return lookup?(macro) ?? nil
                }
            }
            else {
                preservingLookup = lookup
            }
            let parsedString = scope.table.namespace.parseString(string)
            let result = scope.evaluate(parsedString, lookup: preservingLookup)
            if anyReferencesWerePreserved {
                // If we preserved any references, then we need to convert the '\$\(((' in the result back to '$('.
                return result.replacingOccurrences(of: "\\$\\(((", with: "$(")
            }
            return result
        }

        // Depending on what this item is we may recursively call to evaluate its items, or we may evaluate it directly, or we may not evaluate it.
        switch self
        {
        case .plString(let value):
            // Expand macros in a string.
            return .plString(stringByEvaluatingMacros(value, lookup: lookup))

        case .plArray(let value):
            // Expand macros in each value of an array.
            return .plArray(value.map({ return $0.byEvaluatingMacros(withScope: scope, andDictionaryKeys: andDictionaryKeys, preserveReferencesToSettings: preserveReferencesToSettings, lookup: lookup) }))

        case .plDict(let value):
            // Expand macros in values of a dictionary, and if requested, in keys.
            var result = [String: PropertyListItem]()
            for (key, item) in value
            {
                let newKey = andDictionaryKeys ? stringByEvaluatingMacros(key, lookup: lookup) : key
                let newValue = item.byEvaluatingMacros(withScope: scope, andDictionaryKeys: andDictionaryKeys, preserveReferencesToSettings: preserveReferencesToSettings, lookup: lookup)
                result[newKey] = newValue
            }
            return .plDict(result)

        // Other types of values we do not expand macros in.
        case .plBool, .plInt, .plData, .plDate, .plDouble, .plOpaque:
            return self
        }
    }
}

// TODO: This doesn't belong here.
extension MacroEvaluationScope {
    /// Returns the value of the `INFOPLIST_FILE` build setting, or the path to an empty plist file in a temporary directory if `INFOPLIST_FILE` is empty and `DONT_GENERATE_INFOPLIST_FILE` is not active.
    public func effectiveInputInfoPlistPath() -> Path {
        let scope = self
        let inputFile = scope.evaluate(BuiltinMacros.INFOPLIST_FILE)
        if !(SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value || scope.evaluate(BuiltinMacros.GENERATE_INFOPLIST_FILE)) {
            // Always use INFOPLIST_FILE verbatim if the default Info.plist feature flag is not enabled
            return inputFile
        }
        if inputFile.isEmpty && !scope.evaluate(BuiltinMacros.DONT_GENERATE_INFOPLIST_FILE) {
            return infoPlistEmptyPath()
        }
        return inputFile
    }

    /// Path to the fake "empty" plist for the target.
    ///
    /// - SeeAlso: effectiveInputInfoPlistPath
    public func infoPlistEmptyPath() -> Path {
        return evaluate(BuiltinMacros.TARGET_TEMP_DIR).join("empty-\(evaluate(BuiltinMacros.PRODUCT_NAME)).plist")
    }

    /// Indicates whether the Apple Generic versioning source file is being generated and is not being excluded via `EXCLUDED_SOURCE_FILE_NAMES`.
    public func generatesAppleGenericVersioningFile(_ context: any BuildFileFilteringContext) -> Bool {
        // Note: filters here is an empty array ("no filters are applied") because the generated version info file has no associated build file on which to apply filters
        return ["apple-generic", "apple-generic-hidden"].contains(evaluate(BuiltinMacros.VERSIONING_SYSTEM))
            && !context.isExcluded(evaluate(BuiltinMacros.DERIVED_FILE_DIR).join(evaluate(BuiltinMacros.VERSION_INFO_FILE)), filters: [])
    }

    public func generatesKernelExtensionModuleInfoFile(_ context: any BuildFileFilteringContext, _ settings: Settings, _ buildPhase: BuildPhaseWithBuildFiles) -> Bool {
        // Note: filters here is an empty array ("no filters are applied") because the generated version info file has no associated build file on which to apply filters
        return evaluate(BuiltinMacros.GENERATE_KERNEL_MODULE_INFO_FILE) && evaluate(BuiltinMacros.MODULE_NAME) != "" && evaluate(BuiltinMacros.MODULE_START) != "" && evaluate(BuiltinMacros.MODULE_STOP) != ""
            && !context.isExcluded(evaluate(BuiltinMacros.DERIVED_FILE_DIR).join(evaluate(BuiltinMacros.PRODUCT_NAME) + "_info.c"), filters: [])
    }

    /// Get the value of `$(TARGET_BUILD_DIR)` unmodified by `$(TARGET_BUILD_SUBPATH)`.
    /// This is used to retrieve the "original" target build directory for test targets using a host bundle.
    public var unmodifiedTargetBuildDir: Path {
        return evaluate(BuiltinMacros.TARGET_BUILD_DIR, lookup: {
            return ($0 == BuiltinMacros.TARGET_BUILD_SUBPATH) ? self.table.namespace.parseLiteralString("") : nil
        })
    }
}
