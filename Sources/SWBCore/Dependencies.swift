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
    public var validate: BooleanWarningLevel
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

    /// Make diagnostics for missing module dependencies from Clang imports.
    ///
    /// The compiler tracing information does not provide the import locations or whether they are public imports
    /// (which depends on whether the import is in an installed header file).
    /// If `files` is nil, the current toolchain does support the feature to trace imports.
    public func makeDiagnostics(files: [Path]?) -> [Diagnostic] {
        guard validate != .no else { return [] }
        guard let files else {
            return [Diagnostic(
                behavior: .warning,
                location: .unknown,
                data: DiagnosticData("The current toolchain does not support \(BuiltinMacros.VALIDATE_MODULE_DEPENDENCIES.name)"))]
        }

        // The following is a provisional/incomplete mechanism for resolving a module dependency from a file path.
        // For now, just grab the framework name and assume there is a module with the same name.
        func findFrameworkName(_ file: Path) -> String? {
            if file.fileExtension == "framework" {
                return file.basenameWithoutSuffix
            }
            return file.dirname.isEmpty || file.dirname.isRoot ? nil : findFrameworkName(file.dirname)
        }

        let moduleDependencyNames = moduleDependencies.map { $0.name }
        let fileNames = files.compactMap { findFrameworkName($0) }
        let missingDeps = Set(fileNames.filter {
            return !moduleDependencyNames.contains($0)
        }.map {
            ModuleDependency(name: $0, accessLevel: .Private)
        })

        guard !missingDeps.isEmpty else { return [] }

        let behavior: Diagnostic.Behavior = validate == .yesError ? .error : .warning

        let fixIt = fixItContext?.makeFixIt(newModules: Array(missingDeps))
        let fixIts = fixIt.map { [$0] } ?? []

        let message = "Missing entries in \(BuiltinMacros.MODULE_DEPENDENCIES.name): \(missingDeps.map { $0.asBuildSettingEntryQuotedIfNeeded }.sorted().joined(separator: " "))"

        let location: Diagnostic.Location = fixIt.map {
            Diagnostic.Location.path($0.sourceRange.path, line: $0.sourceRange.endLine, column: $0.sourceRange.endColumn)
        } ?? Diagnostic.Location.buildSetting(BuiltinMacros.MODULE_DEPENDENCIES)

        return [Diagnostic(
            behavior: behavior,
            location: location,
            data: DiagnosticData(message),
            fixIts: fixIts)]
    }

    /// Make diagnostics for missing module dependencies from Swift imports.
    ///
    /// If `imports` is nil, the current toolchain does not support the features to gather imports.
    public func makeDiagnostics(imports: [(ModuleDependency, importLocations: [Diagnostic.Location])]?) -> [Diagnostic] {
        guard validate != .no else { return [] }
        guard let imports else {
            return [Diagnostic(
                behavior: .warning,
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
                self.init(sourceRange: .init(path: path, startLine: .max, startColumn: .max, endLine: .max, endColumn: .max), modificationStyle: .insertNewAssignment(targetNameCondition: nil))
            }
            else if let path = settings.constructionComponents.projectXcconfigPath {
                self.init(sourceRange: .init(path: path, startLine: .max, startColumn: .max, endLine: .max, endColumn: .max), modificationStyle: .insertNewAssignment(targetNameCondition: target.name))
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

public struct DependencyValidationInfo: Hashable, Sendable, Codable {
    public struct Import: Hashable, Sendable, Codable {
        public let dependency: ModuleDependency
        public let importLocations: [Diagnostic.Location]

        public init(dependency: ModuleDependency, importLocations: [Diagnostic.Location]) {
            self.dependency = dependency
            self.importLocations = importLocations
        }
    }

    public enum Payload: Hashable, Sendable, Codable {
        case clangDependencies(files: [String])
        case swiftDependencies(imports: [Import])
        case unsupported
    }

    public let payload: Payload

    public init(payload: Payload) {
        self.payload = payload
    }
}
