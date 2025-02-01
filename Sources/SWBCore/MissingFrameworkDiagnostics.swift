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

extension Diagnostic {
    static func missingFrameworkDiagnostic(forDiagnostic diagnostic: Diagnostic, settings: Settings, infoLookup: any PlatformInfoLookup, sdk: SDK, sdkVariant: SDKVariant?, missingFrameworkNames: Set<String>, frameworkReplacementInfo: [String: FrameworkReplacementKind], diagnosticMessageRegexes: [(RegEx, Bool)], context: MissingFrameworkDiagnosticContext) -> Diagnostic? {
        func extractFrameworkName(fromDiagnosticMessage message: String) -> (frameworkName: String, isModular: Bool)? {
            for (re, isModular) in diagnosticMessageRegexes {
                if let match = re.firstMatch(in: message) {
                    return (String(match[0]), isModular)
                }
            }
            return nil
        }

        if let (frameworkName, isModular) = extractFrameworkName(fromDiagnosticMessage: diagnostic.data.description) {
            let component: Component
            switch context {
            case .cxxCompiler:
                component = isModular ? .parseIssue : .lexicalOrPreprocessorIssue
            case .swiftCompiler:
                component = .swiftCompilerError
            case .linker:
                component = .default // TODO: PBX appears to have (generically) prefixed "Error" with the tool name, i.e. "Apple Mach-O Linker (ld) Error"; carry this forward?
            }

            if missingFrameworkNames.contains(frameworkName) {
                return Diagnostic(behavior: diagnostic.behavior, location: diagnostic.location, data: DiagnosticData(missingFrameworkDiagnosticString(frameworkName: frameworkName, alternateFramework: frameworkReplacementInfo[frameworkName] ?? nil, settings: settings, platformInfoLookup: infoLookup, sdk: sdk, sdkVariant: sdkVariant, context: context), component: component), appendToOutputStream: false)
            } else if let replacement = frameworkReplacementInfo[frameworkName] {
                // Framework deprecations/renames should only ever be a warning, not an error
                return Diagnostic(behavior: .warning, location: diagnostic.location, data: DiagnosticData(replacedFrameworkDiagnosticString(frameworkName: frameworkName, alternateFramework: replacement, settings: settings, context: context), component: component), appendToOutputStream: false)
            }
        }

        return nil
    }

    private static func missingFrameworkDiagnosticString(frameworkName: String, alternateFramework: FrameworkReplacementKind?, settings: Settings, platformInfoLookup: any PlatformInfoLookup, sdk: SDK, sdkVariant: SDKVariant?, context: MissingFrameworkDiagnosticContext) -> String {
        let buildPlatform = sdk.targetBuildVersionPlatform(sdkVariant: sdkVariant)
        let platformDisplayName = buildPlatform?.displayName(infoLookup: platformInfoLookup) ?? sdk.displayName

        let conditionalImportFragment: String?
        switch context {
        case .cxxCompiler:
            conditionalImportFragment = "#if __has_include(<\(frameworkName)/\(frameworkName).h>)"
        case .swiftCompiler:
            conditionalImportFragment = "#if canImport(\(frameworkName))"
        case .linker:
            conditionalImportFragment = nil
        }

        let considerMigratingFragment: String?
        let alternativeConsiderationsPrefix: String
        switch alternateFramework {
        case let .deprecated(alternateFrameworkName?):
            considerMigratingFragment = "Consider migrating to \(alternateFrameworkName) instead"
            alternativeConsiderationsPrefix = "\(considerMigratingFragment ?? "")" + (conditionalImportFragment.map { ", or use `\($0)`" } ?? "")
        case let .renamed(alternateFrameworkName):
            considerMigratingFragment = "Use \(alternateFrameworkName) instead"
            alternativeConsiderationsPrefix = "\(considerMigratingFragment ?? "")" + (conditionalImportFragment.map { ", or use `\($0)`" } ?? "")
        case .deprecated, nil:
            // Handles the case where there is no replacement info at all, or there is a deprecation but without a replacement framework name.
            considerMigratingFragment = nil
            alternativeConsiderationsPrefix = conditionalImportFragment.map { "Consider using `\($0)`" } ?? ""
        case .conditionallyAvailableSuccessor:
            // Empty string causes no additional fragment to be included via the logic below.
            alternativeConsiderationsPrefix = ""
        }

        let additionalFragments: [String]
        switch context {
        case .cxxCompiler, .swiftCompiler:
            let exclusionBuildConditionalTailFragment = conditionalImportFragment != nil ? " to conditionally import this framework" : ""
            additionalFragments = !alternativeConsiderationsPrefix.isEmpty ? ["\(alternativeConsiderationsPrefix)\(exclusionBuildConditionalTailFragment)."] : []
        case .linker:
            // TODO: Consider advice about conditional build settings like OTHER_LDFLAGS and/or a modified version of the conditional import blurb?
            additionalFragments = []
        }

        let notAvailableString: String
        switch alternateFramework {
        case .deprecated:
            notAvailableString = "\(frameworkName) is deprecated and is not available when building for \(platformDisplayName)."
        case .renamed:
            notAvailableString = "\(frameworkName) has been renamed."
        case .conditionallyAvailableSuccessor:
            notAvailableString = "\(frameworkName) is not available."
        case nil:
            notAvailableString = "\(frameworkName) is not available when building for \(platformDisplayName)."
        }

        return ([notAvailableString] + additionalFragments).joined(separator: " ")
    }

    private static func replacedFrameworkDiagnosticString(frameworkName: String, alternateFramework: FrameworkReplacementKind, settings: Settings, context: MissingFrameworkDiagnosticContext) -> String {
        let alternateFrameworkFragments: [String]
        switch alternateFramework {
        case let .deprecated(newName):
            alternateFrameworkFragments = ["\(frameworkName) is deprecated."] + (newName.map { ["Consider migrating to \($0) instead."] } ?? [])
        case let .renamed(newName):
            alternateFrameworkFragments = ["\(frameworkName) has been renamed.", "Use \(newName) instead."]
        case let .conditionallyAvailableSuccessor(originalName):
            let targetName = settings.productType.map { " in \($0.name) targets" } ?? ""
            alternateFrameworkFragments = ["\(frameworkName) is not available\(targetName).", "Use \(originalName) instead."]
        }

        return alternateFrameworkFragments.joined(separator: " ")
    }
}

extension DiagnosticsEngine {
    public static func generateMissingFrameworkDiagnostics(usingSerializedDiagnostics serializedDiagnostics: [Diagnostic], settings: Settings, infoLookup: any PlatformInfoLookup, sdk: SDK, sdkVariant: SDKVariant?, missingFrameworkNames: Set<String>, frameworkDeprecationInfo: [String: FrameworkReplacementKind], diagnosticMessageRegexes: [(RegEx, Bool)], context: MissingFrameworkDiagnosticContext, _ block: (_ originalDiagnostic: Diagnostic, _ newDiagnostic: Diagnostic) -> Void) {
        for diagnostic in serializedDiagnostics.filter({ $0.behavior == .error }) {
            if let newDiagnostic = Diagnostic.missingFrameworkDiagnostic(forDiagnostic: diagnostic, settings: settings, infoLookup: infoLookup, sdk: sdk, sdkVariant: sdkVariant, missingFrameworkNames: missingFrameworkNames, frameworkReplacementInfo: frameworkDeprecationInfo, diagnosticMessageRegexes: diagnosticMessageRegexes, context: context) {
                block(diagnostic, newDiagnostic)
            }
        }
    }
}

/// The context from which a "missing framework" diagnostic is being emitted.
///
/// This affects the precise wording of the diagnostic.
public enum MissingFrameworkDiagnosticContext {
    /// The diagnostic is being emitted based on feedback from a C/C++/Objective-C compilation task.
    case cxxCompiler

    /// The diagnostic is being emitted based on feedback from a Swift compilation task.
    case swiftCompiler

    /// The diagnostic is being emitted based on feedback from a linker task.
    case linker
}
