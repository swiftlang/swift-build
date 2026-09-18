//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

package import SWBMacro

package struct CompilationCachingInfo: Hashable, Sendable {
    package static let enablementSettings: [BooleanMacroDeclaration] = [
        BuiltinMacros.CLANG_ENABLE_COMPILE_CACHE,
        BuiltinMacros.SWIFT_ENABLE_COMPILE_CACHE,
    ]

    package static let booleanSettings: [BooleanMacroDeclaration] = [
        BuiltinMacros.CLANG_CACHE_ENABLE_LAUNCHER,
        BuiltinMacros.CLANG_CACHE_FALLBACK_IF_UNAVAILABLE,
        BuiltinMacros.CLANG_ENABLE_COMPILE_CACHE,
        BuiltinMacros.CLANG_ENABLE_PREFIX_MAPPING,
        BuiltinMacros.CLANG_ENABLE_PROJECT_PREFIX_MAPPING,
        BuiltinMacros.COMPILATION_CACHE_ENABLE_DETACHED_KEY_QUERIES,
        BuiltinMacros.COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS,
        BuiltinMacros.COMPILATION_CACHE_ENABLE_PLUGIN,
        BuiltinMacros.COMPILATION_CACHE_ENABLE_STRICT_CAS_ERRORS,
        BuiltinMacros.COMPILATION_CACHE_KEEP_CAS_DIRECTORY,
        BuiltinMacros.COMPILATION_CACHE_VALIDATE_POST_BUILD,
        BuiltinMacros.SWIFT_ENABLE_COMPILE_CACHE,
        BuiltinMacros.SWIFT_ENABLE_PREFIX_MAPPING,
        BuiltinMacros.SWIFT_ENABLE_PROJECT_PREFIX_MAPPING,
    ]

    package static let valueSettings: [MacroDeclaration] = [
        BuiltinMacros.CLANG_CACHE_FINE_GRAINED_OUTPUTS,
        BuiltinMacros.CLANG_CACHE_FINE_GRAINED_OUTPUTS_VERIFICATION,
        BuiltinMacros.CLANG_OTHER_PREFIX_MAPPINGS,
        BuiltinMacros.COMPILATION_CACHE_CAS_PATH,
        BuiltinMacros.COMPILATION_CACHE_LIMIT_PERCENT,
        BuiltinMacros.COMPILATION_CACHE_LIMIT_SIZE,
        BuiltinMacros.COMPILATION_CACHE_PLUGIN_PATH,
        BuiltinMacros.COMPILATION_CACHE_REMOTE_SERVICE_PATH,
        BuiltinMacros.COMPILATION_CACHE_REMOTE_SUPPORTED_LANGUAGES,
        BuiltinMacros.SWIFT_OTHER_PREFIX_MAPPINGS,
        BuiltinMacros.VALIDATE_CAS_EXEC,
    ]

    package struct Conflict: Hashable, Sendable {
        package let settingName: String
        package let imposedValue: String
        package let discardedValue: String
    }

    package let enabledSettings: Set<String>
    package let values: [String: String]

    package static let none = CompilationCachingInfo(enabledSettings: [], values: [:])

    private init(enabledSettings: Set<String>, values: [String: String]) {
        self.enabledSettings = enabledSettings
        self.values = values
    }

    package init(imposedBy scope: MacroEvaluationScope) {
        guard Self.enablementSettings.contains(where: { scope.evaluate($0) }) else {
            self.init(enabledSettings: [], values: [:])
            return
        }
        var values: [String: String] = [:]
        for macro in Self.valueSettings {
            let value = scope.evaluateAsString(macro)
            guard !value.isEmpty else { continue }
            values[macro.name] = value
        }
        self.init(enabledSettings: Set(Self.booleanSettings.filter { scope.evaluate($0) }.map { $0.name }), values: values)
    }

    package var settings: [String: String] {
        return values.merging(enabledSettings.map { ($0, "YES") }, uniquingKeysWith: { _, new in new })
    }

    package var isEmpty: Bool {
        return enabledSettings.isEmpty && values.isEmpty
    }

    package func merging(_ other: CompilationCachingInfo) -> (info: CompilationCachingInfo, conflicts: [Conflict]) {
        guard !other.isEmpty else { return (self, []) }
        guard !isEmpty else { return (other, []) }

        var values = self.values
        var conflicts: [Conflict] = []
        for (name, value) in other.values.sorted(by: { $0.key < $1.key }) {
            guard let existing = values[name] else {
                values[name] = value
                continue
            }
            if existing != value {
                conflicts.append(Conflict(settingName: name, imposedValue: existing, discardedValue: value))
            }
        }

        let info = CompilationCachingInfo(enabledSettings: enabledSettings.union(other.enabledSettings), values: values)
        return (info, conflicts)
    }
}
