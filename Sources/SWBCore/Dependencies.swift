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
import SWBMacro

public struct ModuleDependency: Hashable, Sendable, SerializableCodable {
    public let name: String
    public let accessLevel: AccessLevel

    public enum AccessLevel: String, Hashable, Sendable, CaseIterable, Codable, Serializable {
        case Private = "private"
        case Package = "package"
        case Public = "public"

        public init(_ string: String) throws {
            guard let accessLevel = AccessLevel(rawValue: string) else {
                throw StubError.error("unexpected access modifier '\(string)', expected one of: \(AccessLevel.allCases.map { $0.rawValue }.joined(separator: ", "))")
            }

            self = accessLevel
        }
    }

    public init(name: String, accessLevel: AccessLevel) {
        self.name = name
        self.accessLevel = accessLevel
    }

    public init(entry: String) throws {
        var it = entry.split(separator: " ").makeIterator()
        switch (it.next(), it.next(), it.next()) {
        case (let .some(name), nil, nil):
            self.name = String(name)
            self.accessLevel = .Private

        case (let .some(accessLevel), let .some(name), nil):
            self.name = String(name)
            self.accessLevel = try AccessLevel(String(accessLevel))

        default:
            throw StubError.error("expected 1 or 2 space-separated components in: \(entry)")
        }
    }

    public var asBuildSettingEntry: String {
        "\(accessLevel == .Private ? "" : "\(accessLevel.rawValue) ")\(name)"
    }

    public var asBuildSettingEntryQuotedIfNeeded: String {
        let e = asBuildSettingEntry
        return e.contains(" ") ? "\"\(e)\"" : e
    }
}

public struct ModuleDependenciesContext: Sendable, SerializableCodable {
    var validate: BooleanWarningLevel
    var moduleDependencies: [ModuleDependency]
    var fixItContext: FixItContext?

    init(validate: BooleanWarningLevel, moduleDependencies: [ModuleDependency], fixItContext: FixItContext? = nil) {
        self.validate = validate
        self.moduleDependencies = moduleDependencies
        self.fixItContext = fixItContext
    }

    public init?(settings: Settings) {
        let validate = settings.globalScope.evaluate(BuiltinMacros.VALIDATE_MODULE_DEPENDENCIES)
        guard validate != .no else { return nil }
        let fixItContext = ModuleDependenciesContext.FixItContext(settings: settings)
        self.init(validate: validate, moduleDependencies: settings.moduleDependencies, fixItContext: fixItContext)
    }

    /// Nil `imports` means the current toolchain doesn't have the features to gather imports. This is temporarily required to support running against older toolchains.
    public func makeDiagnostics(imports: [(ModuleDependency, importLocations: [Diagnostic.Location])]?) -> [Diagnostic] {
        guard validate != .no else { return [] }
        guard let imports else {
            return [Diagnostic(
                behavior: .error,
                location: .unknown,
                data: DiagnosticData("The current toolchain does not support \(BuiltinMacros.VALIDATE_MODULE_DEPENDENCIES.name)"))]
        }

        let missingDeps = imports.filter {
            // ignore module deps without source locations, these are inserted by swift / swift-build and we should treat them as implementation details which we can track without needing the user to declare them
            if $0.importLocations.isEmpty { return false }

            // TODO: if the difference is just the access modifier, we emit a new entry, but ultimately our fixit should update the existing entry or emit an error about a conflict
            if moduleDependencies.contains($0.0) { return false }
            return true
        }

        guard !missingDeps.isEmpty else { return [] }

        let behavior: Diagnostic.Behavior = validate == .yesError ? .error : .warning

        let fixIt = fixItContext?.makeFixIt(newModules: missingDeps.map { $0.0 })
        let fixIts = fixIt.map { [$0] } ?? []

        let importDiags: [Diagnostic] = missingDeps
            .flatMap { dep in
                dep.1.map {
                    return Diagnostic(
                        behavior: behavior,
                        location: $0,
                        data: DiagnosticData("Missing entry in \(BuiltinMacros.MODULE_DEPENDENCIES.name): \(dep.0.asBuildSettingEntryQuotedIfNeeded)"),
                        fixIts: fixIts)
                }
            }

        let message = "Missing entries in \(BuiltinMacros.MODULE_DEPENDENCIES.name): \(missingDeps.map { $0.0.asBuildSettingEntryQuotedIfNeeded }.sorted().joined(separator: " "))"

        let location: Diagnostic.Location = fixIt.map {
            Diagnostic.Location.path($0.sourceRange.path, line: $0.sourceRange.endLine, column: $0.sourceRange.endColumn)
        } ?? Diagnostic.Location.buildSetting(BuiltinMacros.MODULE_DEPENDENCIES)

        return [Diagnostic(
            behavior: behavior,
            location: location,
            data: DiagnosticData(message),
            fixIts: fixIts,
            childDiagnostics: importDiags)]
    }

    struct FixItContext: Sendable, SerializableCodable {
        var sourceRange: Diagnostic.SourceRange
        var modificationStyle: ModificationStyle

        init(sourceRange: Diagnostic.SourceRange, modificationStyle: ModificationStyle) {
            self.sourceRange = sourceRange
            self.modificationStyle = modificationStyle
        }

        init?(settings: Settings) {
            guard let target = settings.target else { return nil }
            let thisTargetCondition = MacroCondition(parameter: BuiltinMacros.targetNameCondition, valuePattern: target.name)

            if let assignment = (settings.globalScope.table.lookupMacro(BuiltinMacros.MODULE_DEPENDENCIES)?.sequence.first {
                   $0.location != nil && ($0.conditions?.conditions == [thisTargetCondition] || ($0.conditions?.conditions.isEmpty ?? true))
               }),
               let location = assignment.location
            {
                self.init(sourceRange: .init(path: location.path, startLine: location.endLine, startColumn: location.endColumn, endLine: location.endLine, endColumn: location.endColumn), modificationStyle: .appendToExistingAssignment)
            }
            else if let path = settings.constructionComponents.targetXcconfigPath {
                self.init(sourceRange: .init(path: path, startLine: 0, startColumn: 0, endLine: 0, endColumn: 0), modificationStyle: .insertNewAssignment(targetNameCondition: nil))
            }
            else if let path = settings.constructionComponents.projectXcconfigPath {
                self.init(sourceRange: .init(path: path, startLine: 0, startColumn: 0, endLine: 0, endColumn: 0), modificationStyle: .insertNewAssignment(targetNameCondition: target.name))
            }
            else {
                return nil
            }
        }

        enum ModificationStyle: Sendable, SerializableCodable, Hashable {
            case appendToExistingAssignment
            case insertNewAssignment(targetNameCondition: String?)
        }

        func makeFixIt(newModules: [ModuleDependency]) -> Diagnostic.FixIt {
            let stringValue = newModules.map { $0.asBuildSettingEntryQuotedIfNeeded }.sorted().joined(separator: " ")
            let newText: String
            switch modificationStyle {
            case .appendToExistingAssignment:
                newText = " \(stringValue)"
            case .insertNewAssignment(let targetNameCondition):
                let targetCondition = targetNameCondition.map { "[target=\($0)]" } ?? ""
                newText = "\n\(BuiltinMacros.MODULE_DEPENDENCIES.name)\(targetCondition) = $(inherited) \(stringValue)\n"
            }

            return Diagnostic.FixIt(sourceRange: sourceRange, newText: newText)
        }
    }
}
