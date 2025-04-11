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

import Foundation
import Testing

@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTestSupport
@_spi(Testing) import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct DocumentationTaskConstructionTests: CoreBasedTests {
    private struct SourceLanguageConfiguration {
        let withSwift: Bool
        let withObjectiveCLevel: HeaderVisibility?
        var withObjectiveC: Bool {
            withObjectiveCLevel != nil
        }
    }

    private static let sourceLanguageConfigurationsToTest: [SourceLanguageConfiguration] = [
        .init(withSwift: true,  withObjectiveCLevel: nil),
        .init(withSwift: false, withObjectiveCLevel: .public),
        .init(withSwift: true,  withObjectiveCLevel: .public),
    ]

    @Test(.requireSDKs(.macOS))
    func regularBuildDoesNotBuildDocumentation() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: [:])

                // Check the debug build.
                await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    checkNoDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, core: tester.core, results: results, SRCROOT: SRCROOT)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildWithAllFilesExcludedDoesNotBuildDocumentation() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["EXCLUDED_SOURCE_FILE_NAMES": "*"])

                // Check the debug build.
                await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    checkNoDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, core: tester.core, results: results, SRCROOT: SRCROOT)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildActionsWithoutBuildComponentDoesNotBuildDocumentationWhenBuildSettingIsSet() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            let buildActionsWithoutBuildComponents = BuildAction.allCases.filter{ !$0.buildComponents.contains("build") }

            #expect(!buildActionsWithoutBuildComponents.isEmpty, "This test should check at least one build action")

            let sourceLanguages = SourceLanguageConfiguration(withSwift: true, withObjectiveCLevel: .public)
            for buildAction in buildActionsWithoutBuildComponents {
                let (tester, fs, _) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: [
                    "RUN_DOCUMENTATION_COMPILER": "YES",
                    "SUPPORTS_TEXT_BASED_API": "YES" // This is needed to avoid some diagnostics
                ])

                // Check the debug build.
                await tester.checkBuild(BuildParameters(action: buildAction, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    results.checkNoTask(.matchRuleItem("CompileDocumentation"))
                    results.checkNoTask(.matchRuleItem("ExtractAPI"))
                    results.checkNoTask(.matchRuleItem("ConvertSDKDBToSymbolGraph"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func documentationBuildDoesNotBuildDocumentationWhenSkipBuildingDocumentationIsSet() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {

            let sourceLanguages = SourceLanguageConfiguration(withSwift: true, withObjectiveCLevel: .public)
            let (tester, fs, _) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: [
                "SKIP_BUILDING_DOCUMENTATION": "YES",
                "SUPPORTS_TEXT_BASED_API": "YES" // This is needed to avoid some diagnostics
            ])

            // Check the debug build.
            await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                // There shouldn't be any task construction diagnostics.
                results.checkNoDiagnostics()

                results.checkNoTask(.matchRuleItem("CompileDocumentation"))
                results.checkNoTask(.matchRuleItem("ExtractAPI"))
                results.checkNoTask(.matchRuleItem("ConvertSDKDBToSymbolGraph"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildWithSymbolExtractWithoutDocumentation() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            let sourceLanguages = SourceLanguageConfiguration(withSwift: true, withObjectiveCLevel: .public)
            let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: [
                "RUN_SYMBOL_GRAPH_EXTRACT": "YES",
                "SYMBOL_GRAPH_EXTRACTOR_OUTPUT_BASE": "/symbol_graph_extractor_output_base"
            ])

            // Check the debug build.
            try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                // There shouldn't be any task construction diagnostics.
                results.checkNoDiagnostics()

                var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                expectedTargetValues.expectedToConstructDocumentationTask = false
                expectedTargetValues.symbolGraphOutputBase = "/symbol_graph_extractor_output_base"

                try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildActionsWithoutBuildComponentDoesNotBuildRunSymbolExtractWhenBuildSettingIsSet() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            let buildActionsWithoutBuildComponents = BuildAction.allCases.filter{ !$0.buildComponents.contains("build") }

            #expect(!buildActionsWithoutBuildComponents.isEmpty, "This test should check at least one build action")

            let sourceLanguages = SourceLanguageConfiguration(withSwift: true, withObjectiveCLevel: .public)
            for buildAction in buildActionsWithoutBuildComponents {
                let (tester, fs, _) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: [
                    "RUN_SYMBOL_GRAPH_EXTRACT": "YES",
                    "SUPPORTS_TEXT_BASED_API": "YES" // This is needed to avoid some diagnostics
                ])

                // Check the debug build.
                await tester.checkBuild(BuildParameters(action: buildAction, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    results.checkNoTask(.matchRuleItem("CompileDocumentation"))
                    results.checkNoTask(.matchRuleItem("ExtractAPI"))
                    results.checkNoTask(.matchRuleItem("ConvertSDKDBToSymbolGraph"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func documentationBuildBuildsDocumentation() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: [:])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func runDocumentationCompilerInRegularBuild() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["RUN_DOCUMENTATION_COMPILER": "YES"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func runDocumentationCompilerInRegularBuildWithoutDocsCatalogInput() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["RUN_DOCUMENTATION_COMPILER": "YES"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func runDocumentationCompilerWithZipperedProduct() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["IS_ZIPPERED": "YES"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: .macCatalyst, core: tester.core, results: results, SRCROOT: SRCROOT)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func runDocumentationCompilerWithReverseZipperedProduct() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["IS_ZIPPERED": "YES", "SDK_VARIANT": "\(MacCatalystInfo.sdkVariantName)"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: .macOS, core: tester.core, results: results, SRCROOT: SRCROOT)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func documentationIdentifierFallbackValues() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["PRODUCT_BUNDLE_IDENTIFIER": nil])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedDocCatalogIdentifier: "Framework")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func documentationTemplateBuildSetting() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["DOCC_TEMPLATE_PATH": "/path/to/../to/some/template/"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, customTemplatePath: "/path/to/some/template") // the custom template is normalized
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithoutExtensionSymbolsSupport() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["DOCC_EXTRACT_EXTENSION_SYMBOLS": "NO"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedExtensionSymbolDocumentation: false)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithOtherDocCFlags() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["OTHER_DOCC_FLAGS": "--abc --enable-experimental-objective-c-support --ghi"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, withAdditionalDocCArguments: ["--abc", "--enable-experimental-objective-c-support", "--ghi"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithHostingBasePath() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["DOCC_HOSTING_BASE_PATH": "sloth-creator"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedHostingBasePath: "sloth-creator")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithoutTransformingForStaticHosting() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["DOCC_TRANSFORM_FOR_STATIC_HOSTING": "NO"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedToTransformForStaticHosting: false)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithSPIObjectiveCDocumentation() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["DOCC_EXTRACT_SPI_DOCUMENTATION": "YES"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                    expectedTargetValues.expectedToProcessPrivateHeaders = true

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithSwiftDeclarationsForObjectiveCSymbols() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest where sourceLanguages.withSwift == true {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["DOCC_EXTRACT_OBJC_INFO_FOR_SWIFT_SYMBOLS": "YES"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                    expectedTargetValues.expectedToProcessGeneratedSwiftInterfaceHeader = .always

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithoutInstalledCompatibilityHeader() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest where sourceLanguages.withSwift == true {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["SWIFT_INSTALL_OBJC_HEADER": "NO"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                    expectedTargetValues.expectedToProcessGeneratedSwiftInterfaceHeader = .never

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithContradictingObjectiveCRelatedBuildSettings() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest where sourceLanguages.withSwift == true {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: [
                    // These two settings are contradictory
                    "DOCC_EXTRACT_OBJC_INFO_FOR_SWIFT_SYMBOLS": "YES",
                    "SWIFT_INSTALL_OBJC_HEADER": "NO"
                ])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    results.checkWarning("Multi-language documentation for Swift code (DOCC_EXTRACT_OBJC_INFO_FOR_SWIFT_SYMBOLS=YES) has no effect when the Objective-C compatibility header isn't installed (SWIFT_INSTALL_OBJC_HEADER=NO) (in target 'Framework' from project 'aProject')")
                    // There shouldn't be any other task construction diagnostics.
                    results.checkNoDiagnostics()

                    var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                    expectedTargetValues.expectedToProcessGeneratedSwiftInterfaceHeader = .never

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithObjectiveCDeclarationsForSwiftSymbols() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["DOCC_EXTRACT_SWIFT_INFO_FOR_OBJC_SYMBOLS": "YES"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                    expectedTargetValues.expectedToProcessRunSeparateSwiftSymbolGraphExtract = true

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func objectiveCDeclarationsForSwiftSymbolsWithoutModule() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: [
                    "DOCC_EXTRACT_SWIFT_INFO_FOR_OBJC_SYMBOLS": "YES",
                    "DEFINES_MODULE": "NO"
                ])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                    expectedTargetValues.expectedToProcessRunSeparateSwiftSymbolGraphExtract = false

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithoutModuleSupport() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest where sourceLanguages.withObjectiveC {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["TAPI_EXTRACT_API_ENABLE_MODULES": "NO"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                    expectedTargetValues.expectedToExtractWithModuleSupport = false

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithoutARC() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest where sourceLanguages.withObjectiveC {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["TAPI_EXTRACT_API_ENABLE_OBJC_ARC": "NO"])

                // Check the debug build.
                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                    expectedTargetValues.expectedToExtractWithARCSupport = false

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDocumentationWithOldSwiftVersion() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest where sourceLanguages.withObjectiveC && !sourceLanguages.withSwift {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["SWIFT_VERSION": "3.99"])

                // Check the debug build.
                var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
                expectedTargetValues.expectedToProcessRunSeparateSwiftSymbolGraphExtract = false

                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildWithAllSwiftFilesExcludedViaDirectoryGlobBuildsDocumentation() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            let sourceLanguages = SourceLanguageConfiguration(withSwift: true, withObjectiveCLevel: .public)
            let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: ["EXCLUDED_SOURCE_FILE_NAMES": "SwiftFiles/* Excluded*"])

            var expectedTargetValues = ExpectedTargetValues(targetType: .framework)
            expectedTargetValues.expectedToProcessGeneratedSwiftInterfaceHeader = .never
            expectedTargetValues.expectedToConstructSwiftTasks = false
            // Check the debug build.
            try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                // There shouldn't be any task construction diagnostics.
                results.checkNoDiagnostics()

                try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
            }
        }
    }


    @Test(.requireSDKs(.macOS))
    func buildAppDocumentationWithoutHeaderBuildPhase() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest where sourceLanguages.withObjectiveC {
                let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, targetType: .application, withHeadersBuildPhase: false, extraBuildSettings: [:])

                // Check the debug build.
                var expectedTargetValues = ExpectedTargetValues(targetType: .application)
                expectedTargetValues.expectedToProcessProjectVisibleHeaders = true
                expectedTargetValues.expectedToProcessPublicHeaders = false
                expectedTargetValues.expectedToProcessPrivateHeaders = false

                try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                    // There shouldn't be any task construction diagnostics.
                    results.checkNoDiagnostics()

                    try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func privateHeadersDoesNotCauseDocumentationBuild() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            let sourceLanguages = SourceLanguageConfiguration(withSwift: false, withObjectiveCLevel: .private)
            let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: false, sourceLanguages: sourceLanguages, extraBuildSettings: [:])

            // Check the debug build.
            await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                // There shouldn't be any task construction diagnostics.
                results.checkNoDiagnostics()

                checkNoDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, core: tester.core, results: results, SRCROOT: SRCROOT)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func multipleDocumentationCatalogsError() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            let sourceLanguages = SourceLanguageConfiguration(withSwift: true, withObjectiveCLevel: .private)
            let (tester, fs, _) = try await setUpTesterForTestProject(withDocsCatalog: true, withExtraDocsCatalog: true, sourceLanguages: sourceLanguages, extraBuildSettings: [:])

            // Check the debug build.
            await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                results.checkError(.equal("Each target may contain only a single documentation catalog.\n/tmp/Test/aProject/Project.docc: Documentation catalog named Project.docc\n/tmp/Test/aProject/Extra.docc: Documentation catalog named Extra.docc (in target 'Framework' from project 'aProject')"))

                // There shouldn't be any other task construction diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func additionalBuildVariantsDoNotCauseDuplicateBuilds() async throws {
        let sourceLanguages = SourceLanguageConfiguration(withSwift: true, withObjectiveCLevel: nil)
        let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(
            withDocsCatalog: true,
            sourceLanguages: sourceLanguages,
            extraBuildSettings: [
                "BUILD_VARIANTS": "normal asan",
                "OTHER_SWIFT_FLAGS[variant=asan]": "-sanitize=address"
            ]
        )

        try await tester.checkBuild(
            BuildParameters(action: .docBuild, configuration: "Debug"),
            runDestination: .anyMac,
            fs: fs
        ) { results in
            // There shouldn't be any task construction diagnostics.
            results.checkNoDiagnostics()

            try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT)
        }
    }

    private struct ExpectedTargetValues {
        let targetType: TestStandardTarget.TargetType

        init(targetType: TestStandardTarget.TargetType) {
            self.targetType = targetType
            let shouldProcessSPI = [TestStandardTarget.TargetType.application, .commandLineTool, .xpcService, .applicationExtension, .xcodeExtension, .driverExtension, .kernelExtension].contains(targetType)
            self.expectedToProcessPrivateHeaders = shouldProcessSPI
            self.expectedToProcessProjectVisibleHeaders = shouldProcessSPI
            self.expectedToProcessPublicHeaders = true
            self.expectedToProcessGeneratedSwiftInterfaceHeader = .whenTargetIsMixedLanguage
            self.expectedToProcessRunSeparateSwiftSymbolGraphExtract = false
            self.expectedToExtractWithModuleSupport = true
            self.expectedToExtractWithARCSupport = true
            self.expectedToConstructSwiftTasks = true
            self.expectedToConstructDocumentationTask = true
        }

        var expectedDefaultModuleKind: String? {
            switch targetType {
            case .framework, .staticFramework, .staticLibrary, .dynamicLibrary, .objectFile:
                return nil
            case .application:
                return "Application"
            case .commandLineTool:
                return "Command-line Tool"
            case .xpcService:
                return "XPC Service"
            case .applicationExtension, .xcodeExtension:
                return "Application Extension"
            case .driverExtension:
                return "DriverKit Driver"
            case .kernelExtension:
                return "Kernel Extension"
            default:
                Issue.record("Unexpected documentation target type.")
                return nil
            }
        }

        var expectedMinimumSymbolGraphAccessLevel: String? {
            switch targetType {
            case .framework, .staticFramework, .staticLibrary, .dynamicLibrary, .objectFile:
                return nil
            case .application, .commandLineTool, .xpcService, .applicationExtension, .xcodeExtension, .driverExtension, .kernelExtension:
                return "internal"
            default:
                Issue.record("Unexpected documentation target type.")
                return nil
            }
        }

        // Expected header levels
        var expectedToProcessPublicHeaders: Bool
        var expectedToProcessPrivateHeaders: Bool
        var expectedToProcessProjectVisibleHeaders: Bool

        // Expected to process Swift / Objective-C symbol information even when there's no Swift / Objective-C code
        enum SwiftInterfaceHeaderProcessingCriteria {
            case never
            case whenTargetIsMixedLanguage
            case always
        }
        var expectedToProcessGeneratedSwiftInterfaceHeader: SwiftInterfaceHeaderProcessingCriteria
        var expectedToProcessRunSeparateSwiftSymbolGraphExtract: Bool

        var expectedToProcessAnyHeaders: Bool {
            return expectedToProcessPublicHeaders || expectedToProcessPrivateHeaders || expectedToProcessProjectVisibleHeaders
        }

        var expectedToExtractWithModuleSupport: Bool
        var expectedToExtractWithARCSupport: Bool
        var expectedToConstructSwiftTasks: Bool
        var expectedToConstructDocumentationTask: Bool

        var symbolGraphOutputBase: String?

        func expectedProductHeaderDirs(builtProductsDir: String) -> [String]? {
            let expectedProductHeaderParentDir: String
            switch targetType {
            case .kernelExtension:
                return [
                    builtProductsDir + "/System/Library/Frameworks/Kernel.framework/Contents/Headers/family",
                    builtProductsDir + "/System/Library/Frameworks/Kernel.framework/Contents/PrivateHeaders/family",
                ]
            case .framework, .staticFramework:
                expectedProductHeaderParentDir = builtProductsDir + "/Framework.framework/Versions/A"
            case .staticLibrary, .dynamicLibrary, .objectFile:
                return [builtProductsDir + "/usr/local/include"]
            case .commandLineTool:
                return nil // command-line tools have no product headers
            case .application:
                expectedProductHeaderParentDir = builtProductsDir + "/Framework.app/Contents"
            case .xpcService:
                expectedProductHeaderParentDir = builtProductsDir + "/Framework.xpc/Contents"
            case .applicationExtension, .xcodeExtension:
                expectedProductHeaderParentDir = builtProductsDir + "/Framework.appex/Contents"
            case .driverExtension:
                expectedProductHeaderParentDir = builtProductsDir + "/Framework.dext/Contents"
            default:
                Issue.record("Unexpected documentation target type.")
                return nil
            }
            return [
                expectedProductHeaderParentDir + "/Headers",
                expectedProductHeaderParentDir + "/PrivateHeaders",
            ]
        }
    }

    @Test(.requireSDKs(.macOS))
    func expandedTargetTypesSupportBuildingDocumentation() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            for sourceLanguages in Self.sourceLanguageConfigurationsToTest {

                let typesThatSupportDocumentation: [TestStandardTarget.TargetType] = [
                    .framework,
                    .staticFramework,
                    .staticLibrary,
                    .dynamicLibrary,
                    .objectFile,
                    .application,
                    .commandLineTool,
                    .xpcService,
                    .applicationExtension,
                    .xcodeExtension,
                    .kernelExtension,
                ]

                for type in typesThatSupportDocumentation {
                    let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, targetType: type, extraBuildSettings: [:])

                    let expectedTargetValues = ExpectedTargetValues(targetType: type)
                    // Check the debug build.
                    try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                        // There shouldn't be any task construction diagnostics.
                        results.checkNoDiagnostics()

                        try await checkDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, withDocsCatalog: true, zipperedAlternateProduct: nil, core: tester.core, results: results, SRCROOT: SRCROOT, expectedTargetValues: expectedTargetValues)
                    }
                }

                // Only verifying most types that support macOS because the test helper expects that.
                let typesThatDoNotSupportDocumentation: [TestStandardTarget.TargetType] = [
                    .bundle,
                    .unitTest,
                ]

                for type in typesThatDoNotSupportDocumentation {
                    let (tester, fs, SRCROOT) = try await setUpTesterForTestProject(withDocsCatalog: true, sourceLanguages: sourceLanguages, targetType: type, extraBuildSettings: [:])

                    // Check the debug build.
                    await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                        // There shouldn't be any task construction diagnostics.
                        results.checkNoDiagnostics()

                        checkNoDocumentationTasksAreConstructed(sourceLanguages: sourceLanguages, core: tester.core, results: results, SRCROOT: SRCROOT)
                    }
                }
            }
        }
    }

    private func setUpTesterForTestProject(withDocsCatalog: Bool, withExtraDocsCatalog: Bool = false, sourceLanguages: SourceLanguageConfiguration, targetType: TestStandardTarget.TargetType = .framework, withHeadersBuildPhase: Bool = true, extraBuildSettings: [String: String?]) async throws -> (TaskConstructionTester, PseudoFS, String) {
        let core = try await getCore()
        var testFiles = [
            TestFile("Info.plist")
        ]

        var swiftFiles: [TestFile] = []
        var testHeaderBuildPhaseFiles: [TestBuildFile] = []
        var testSourcesBuildPhaseFiles: [TestBuildFile] = []

        if sourceLanguages.withSwift {
            swiftFiles.append(TestFile("SwiftSourceFile.swift"))
            testSourcesBuildPhaseFiles.append("SwiftSourceFile.swift")
        }
        switch sourceLanguages.withObjectiveCLevel {
        case .public?:
            testFiles.append(contentsOf: [
                TestFile("Framework.h"),
                TestFile("iOSOnlyObjCHeaderFilePublic.h"),
                TestFile("ExcludedObjCHeaderFilePublic.h"),
                TestFile("ObjCSourceFile.m"),
            ])
            testHeaderBuildPhaseFiles.append(contentsOf: [
                TestBuildFile("Framework.h", headerVisibility: .public),
                TestBuildFile("iOSOnlyObjCHeaderFilePublic.h", headerVisibility: .public, platformFilters: PlatformFilter.iOSFilters),
                TestBuildFile("ExcludedObjCHeaderFilePublic.h", headerVisibility: .public),
            ])
            testSourcesBuildPhaseFiles.append("ObjCSourceFile.m")
            fallthrough // Public implies private and project

        case .private?:
            testFiles.append(TestFile("ObjCHeaderFilePrivate.h"))
            testHeaderBuildPhaseFiles.append(TestBuildFile("ObjCHeaderFilePrivate.h", headerVisibility: .private))
            fallthrough // Private implies project

        case .some: // project visibility
            testFiles.append(TestFile("ObjCHeaderFileProject.h"))
            testHeaderBuildPhaseFiles.append(TestBuildFile("ObjCHeaderFileProject.h", headerVisibility: nil))

        case .none:
            break
        }
        if withDocsCatalog {
            testFiles.append(TestFile("Project.docc"))
            testSourcesBuildPhaseFiles.append("Project.docc")
        }
        if withExtraDocsCatalog {
            testFiles.append(TestFile("Extra.docc"))
            testSourcesBuildPhaseFiles.append("Extra.docc")
        }

        var buildPhases: [any TestBuildPhase] = [
            TestSourcesBuildPhase(testSourcesBuildPhaseFiles)
        ]
        if withHeadersBuildPhase && !testHeaderBuildPhaseFiles.isEmpty {
            buildPhases.insert(TestHeadersBuildPhase(testHeaderBuildPhaseFiles), at: 0)
        }

        let someFilesChildren: [any TestStructureItem] = testFiles.map({ $0 as (any TestStructureItem) }).appending(contentsOf: [
            TestGroup(
                "SwiftFiles",
                children: swiftFiles
            )
        ])

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: someFilesChildren
            ),

            targets: [
                TestStandardTarget(
                    "Framework",
                    type: targetType,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ARCHS": "x86_64 arm64",
                                "ONLY_ACTIVE_ARCH": "NO",
                                "SWIFT_VERSION": "5.2",
                                // Let the test project use the actual swift compiler, this is needed to detect the use of features in features.json
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                "TAPI_EXEC": tapiToolPath.str,
                                "LIBTOOL": libtoolPath.str,
                                "INFOPLIST_FILE":"SomeFiles/Info.plist",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.identifier",
                                "CURRENT_PROJECT_VERSION": "0.0.1",
                                "FRAMEWORK_SEARCH_PATHS": "framework_search_paths1 framework_search_paths2",
                                "SYSTEM_FRAMEWORK_SEARCH_PATHS": "system_framework_search_paths1 system_framework_search_paths2",
                                "HEADER_SEARCH_PATHS": "header_search_paths1 header_search_paths2",
                                "SYSTEM_HEADER_SEARCH_PATHS": "system_header_search_paths1 system_header_search_paths2",
                                "TOOLCHAIN_DIR": core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain").str,
                                "EXCLUDED_SOURCE_FILE_NAMES": "Excluded*",
                                "DOCC_EXTRACT_SWIFT_INFO_FOR_OBJC_SYMBOLS": "NO",
                                "TAPI_EXTRACT_API_ENABLE_MODULES": "YES",
                                "TAPI_EXTRACT_API_ENABLE_OBJC_ARC": "YES",
                                "TAPI_EXTRACT_API_MODULE_CACHE_PATH": "module_cache_dir",
                                "DEFINES_MODULE": (sourceLanguages.withObjectiveCLevel == .public) ? "YES" : "NO",
                                "EAGER_LINKING": "NO",
                                "DOCC_EXEC": doccToolPath.str,
                            ].merging(extraBuildSettings, uniquingKeysWith: { _, new in new }).compactMapValues({ $0 })
                        )
                    ],
                    buildPhases: buildPhases,
                    dependencies: [
                        TestTargetDependency("PlatformSpecificDependency", platformFilters: PlatformFilter.iOSFilters),
                        TestTargetDependency("ExpectedDependency"),
                    ]
                ),
                TestStandardTarget(
                    "PlatformSpecificDependency",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                "TAPI_EXEC": tapiToolPath.str,
                                "INFOPLIST_FILE":"SomeFiles/Info.plist",
                                "MODULEMAP_PATH": "platform_specific_dependency_module_map_path",
                            ]
                        )
                    ]
                ),
                TestStandardTarget(
                    "ExpectedDependency",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                "TAPI_EXEC": tapiToolPath.str,
                                "INFOPLIST_FILE":"SomeFiles/Info.plist",
                                "MODULEMAP_PATH": "expected_dependency_module_map_path",
                            ]
                        )
                    ]
                )
            ]
        )

        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        let folder = Path(SRCROOT).join("SomeFiles")
        try fs.createDirectory(folder, recursive: true)

        if sourceLanguages.withSwift {
            let swiftFolder = Path(SRCROOT).join("SwiftFiles")
            try fs.createDirectory(swiftFolder, recursive: true)
            try fs.write(swiftFolder.join("SwiftSourceFile.swift"), contents: "/* Some Swift content */\n")
        }
        if sourceLanguages.withObjectiveC {
            try fs.write(folder.join("ObjCSourceFile.m"), contents: "/* Some Objective-C content */\n")
            try fs.write(folder.join("ObjCSourceFilePublic.h"), contents: "/* Some Objective-C content */\n")
            try fs.write(folder.join("ObjCSourceFileProject.h"), contents: "/* Some Objective-C content */\n")
            try fs.write(folder.join("ObjCSourceFilePrivate.h"), contents: "/* Some Objective-C content */\n")
            try fs.write(folder.join("iOSOnlyObjCHeaderFilePublic.h"), contents: "/* Some Objective-C content */\n")
            try fs.write(folder.join("ExcludedObjCHeaderFilePublic.h"), contents: "/* Some Objective-C content */\n")
        }

        try fs.write(folder.join("Info.plist"), contents: "Test")
        if withDocsCatalog {
            let docsCatalog = folder.join("Project.docc")
            try fs.createDirectory(docsCatalog, recursive: true)
            try fs.write(docsCatalog.join("Framework.md"), contents: "# ``Framework``")
        }
        if withExtraDocsCatalog {
            let docsCatalog = folder.join("Extra.docc")
            try fs.createDirectory(docsCatalog, recursive: true)
            try fs.write(docsCatalog.join("Framework.md"), contents: "# ``Framework``")
        }
        try fs.createDirectory(folder.join("template"), recursive: true)

        return (tester, fs, SRCROOT)
    }

    private func checkDocumentationTasksAreConstructed(
        sourceLanguages: SourceLanguageConfiguration,
        withDocsCatalog: Bool,
        zipperedAlternateProduct: BuildVersion.Platform?,
        core: Core,
        results: TaskConstructionTester.PlanningResults,
        SRCROOT: String,
        customTemplatePath: String? = nil,
        expectedDisplayName: String = "Framework",
        expectedDocCatalogIdentifier: String = "test.bundle.identifier", // this default value is the same as target's bundle identifier.
        expectedHostingBasePath: String? = nil,
        expectedToTransformForStaticHosting: Bool = true,
        expectedTargetValues: ExpectedTargetValues? = nil,
        expectedExtensionSymbolDocumentation: Bool = true,
        withAdditionalDocCArguments: [String] = []
    ) async throws {
        let targetTriplePlatform: String
        let zipperedProductSuffix: String?
        let debugFolderSuffix: String
        switch zipperedAlternateProduct {
        case .macCatalyst?:
            targetTriplePlatform = "-macos"
            zipperedProductSuffix = "-ios-macabi"
            debugFolderSuffix = ""
        case .macOS?:
            targetTriplePlatform = "-ios-macabi"
            zipperedProductSuffix = "-macos"
            debugFolderSuffix = MacCatalystInfo.publicSDKBuiltProductsDirSuffix
        case nil:
            targetTriplePlatform = "-macos"
            zipperedProductSuffix = nil
            debugFolderSuffix = ""
        default:
            Issue.record("Unexpected 'zipperedAlternateProduct' value which isn't handled in the testing code: \(zipperedAlternateProduct!)")
            return
        }

        let expectedTargetValues = expectedTargetValues ?? .init(targetType: .framework)
        try await checkDocumentationTasksAreConstructed(
            sourceLanguages: sourceLanguages,
            withDocsCatalog: withDocsCatalog,
            targetTriplePlatform: targetTriplePlatform,
            zipperedProductSuffix: zipperedProductSuffix,
            debugFolderSuffix: debugFolderSuffix,
            core: core,
            results: results,
            SRCROOT: SRCROOT,
            customTemplatePath: customTemplatePath,
            expectedDisplayName: expectedDisplayName,
            expectedDocCatalogIdentifier: expectedDocCatalogIdentifier,
            expectedHostingBasePath: expectedHostingBasePath,
            expectedToTransformForStaticHosting: expectedToTransformForStaticHosting,
            expectedTargetValues: expectedTargetValues,
            expectedExtensionSymbolDocumentation: expectedExtensionSymbolDocumentation,
            withAdditionalDocCArguments: withAdditionalDocCArguments
        )
    }

    private func checkDocumentationTasksAreConstructed(
        sourceLanguages: SourceLanguageConfiguration,
        withDocsCatalog: Bool,
        targetTriplePlatform: String,
        zipperedProductSuffix: String?,
        debugFolderSuffix: String,
        core: Core,
        results: TaskConstructionTester.PlanningResults,
        SRCROOT: String,
        customTemplatePath: String?,
        expectedDisplayName: String,
        expectedDocCatalogIdentifier: String,
        expectedHostingBasePath: String?,
        expectedToTransformForStaticHosting: Bool,
        expectedTargetValues: ExpectedTargetValues,
        expectedExtensionSymbolDocumentation: Bool,
        withAdditionalDocCArguments: [String]
    ) async throws {
        let doccToolPath = try await self.doccToolPath
        let doccFeatures = try await self.doccFeatures
        let tapiToolPath = try await self.tapiToolPath

        try results.checkTarget("Framework") { target in
            // The output for ExtractSwiftSymbolGraph and input for CompileDocumentation.

            let builtProductsDir = "/tmp/Test/aProject/build/Debug\(debugFolderSuffix)"
            let frameworkBuildDir = "/tmp/Test/aProject/build/aProject.build/Debug\(debugFolderSuffix)/Framework.build"

            for arch in architectures {
                let (_, symbolGraphOutputDir) = architectureSpecificInput(core, SRCROOT, arch, targetTriplePlatform, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase)

                if sourceLanguages.withSwift && expectedTargetValues.expectedToConstructSwiftTasks {
                    let objectsNormalDir = "\(frameworkBuildDir)/Objects-normal/\(arch)"

                    results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation Requirements", "Framework", "normal", arch, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkCommandLineContains([
                            "-emit-symbol-graph",
                            "-emit-symbol-graph-dir", symbolGraphOutputDir,
                        ])

                        if expectedExtensionSymbolDocumentation {
                            task.checkCommandLineContains(["-emit-extension-block-symbols"])
                        }

                        task.checkOutputs(contain: [
                            .path(objectsNormalDir + "/Framework Swift Compilation Requirements Finished"),
                            .path(objectsNormalDir + "/Framework.swiftmodule"),
                            .path(symbolGraphOutputDir + "/Framework.symbols.json"),
                            .path(objectsNormalDir + "/Framework.swiftsourceinfo"),
                            .path(objectsNormalDir + "/Framework-Swift.h"),
                            .path(objectsNormalDir + "/Framework.swiftdoc"),
                        ])
                    }

                    results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation", "Framework", "normal", arch, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkCommandLineContains([
                            "-emit-symbol-graph",
                            "-emit-symbol-graph-dir", symbolGraphOutputDir,
                        ])

                        if expectedExtensionSymbolDocumentation {
                            task.checkCommandLineContains(["-emit-extension-block-symbols"])
                        }

                        task.checkOutputs([
                            .path(objectsNormalDir + "/Framework Swift Compilation Finished"),
                            .path(objectsNormalDir + "/SwiftSourceFile.o"),
                            .path(objectsNormalDir + "/SwiftSourceFile.swiftconstvalues")
                        ])
                    }

                    if let zipperedProductSuffix = zipperedProductSuffix {
                        let (_, zipperedSymbolGraphOutputDir) = architectureSpecificInput(core, SRCROOT, arch, zipperedProductSuffix, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase)
                        results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation Requirements", "Framework", "normal", arch + zipperedProductSuffix, "com.apple.xcode.tools.swift.compiler"])) { task in

                            task.checkCommandLineContains([
                                "-emit-symbol-graph",
                                "-emit-symbol-graph-dir", zipperedSymbolGraphOutputDir,
                            ])

                            if expectedExtensionSymbolDocumentation {
                                task.checkCommandLineContains(["-emit-extension-block-symbols"])
                            }

                            if let expectedMinimumSymbolGraphAccessLevel = expectedTargetValues.expectedMinimumSymbolGraphAccessLevel {
                                task.checkCommandLineContains([
                                    "-symbol-graph-minimum-access-level", expectedMinimumSymbolGraphAccessLevel,
                                ])
                            } else {
                                task.checkCommandLineDoesNotContain("-symbol-graph-minimum-access-level")
                            }

                            task.checkOutputs(contain: [
                                .path(zipperedSymbolGraphOutputDir + "/Framework.symbols.json")
                            ])
                        }
                    }
                }
            }

            if (sourceLanguages.withObjectiveC && expectedTargetValues.expectedToProcessAnyHeaders) || expectedTargetValues.expectedToProcessGeneratedSwiftInterfaceHeader == .always
            {
                let expectedToProcessGeneratedSwiftInterfaceHeader: Bool
                switch expectedTargetValues.expectedToProcessGeneratedSwiftInterfaceHeader {
                case .always:
                    expectedToProcessGeneratedSwiftInterfaceHeader = true
                case .whenTargetIsMixedLanguage:
                    expectedToProcessGeneratedSwiftInterfaceHeader = sourceLanguages.withSwift && sourceLanguages.withObjectiveC
                case .never:
                    expectedToProcessGeneratedSwiftInterfaceHeader = false
                }

                let headersInfoPath = frameworkBuildDir + "/Framework-extractapi-headers.json"
                if !SWBFeatureFlag.enableClangExtractAPI.value {

                    // Check the headers info file write task
                    try results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", headersInfoPath])) {
                        task, content in

                        task.checkCommandLine([
                            "write-file",
                            headersInfoPath
                        ])

                        task.checkInputs([
                            .namePattern(.and(.prefix("target-Framework-T-Framework-"), .suffix("--immediate"))),
                        ])

                        task.checkOutputs([
                            .path(headersInfoPath)
                        ])

                        let headersInfoContent = try JSONDecoder().decode(TestFileList.self, from: Data(bytes: content.bytes, count: content.size))

                        if sourceLanguages.withObjectiveC, let productHeadersDirs = expectedTargetValues.expectedProductHeaderDirs(builtProductsDir: builtProductsDir) {
                            switch (productHeadersDirs.first, productHeadersDirs.dropFirst().first) {
                            case let (publicHeadersDir?, privateHeadersDir?):
                                // The VFS overlay contains paths without the /Versions/A/ portion and the filelist file needs to use the same paths as the VFS overlay.
                                // It's possible to change this, but both would have change rdar://84523763 (TAPI file list & VFS overlay unnecessarily truncate paths)
                                let truncatedPublicHeadersDir = publicHeadersDir.replacingOccurrences(of: "/Versions/A/", with: "/")
                                let truncatedPrivateHeadersDir = privateHeadersDir.replacingOccurrences(of: "/Versions/A/", with: "/")

                                // Check that the truncated paths are in the file list ...
                                checkExpectedHeader(headersInfoContent, containsPath: "\(truncatedPublicHeadersDir)/Framework.h", isExpected: expectedTargetValues.expectedToProcessPublicHeaders, expectedHeaderLevel: .public)

                                checkExpectedHeader(headersInfoContent, containsPath: "\(truncatedPublicHeadersDir)/Framework.h", isExpected: expectedTargetValues.expectedToProcessPublicHeaders, expectedHeaderLevel: .public)
                                checkExpectedHeader(headersInfoContent, containsPath: "\(truncatedPrivateHeadersDir)/ObjCHeaderFilePrivate.h", isExpected: expectedTargetValues.expectedToProcessPrivateHeaders, expectedHeaderLevel: .private)

                                checkExpectedHeader(headersInfoContent, containsPath: "/tmp/Test/aProject/ObjCHeaderFileProject.h", isExpected: expectedTargetValues.expectedToProcessProjectVisibleHeaders, expectedHeaderLevel: .project)

                                // Check that neither version of the excluded headed are included
                                checkExpectedHeader(headersInfoContent, containsPath: "\(publicHeadersDir)/iOSOnlyObjCHeaderFilePublic.h", isExpected: false, expectedHeaderLevel: .public)
                                checkExpectedHeader(headersInfoContent, containsPath: "\(privateHeadersDir)/ExcludedObjCHeaderFilePublic.h", isExpected: false, expectedHeaderLevel: .public)
                                checkExpectedHeader(headersInfoContent, containsPath: "\(truncatedPublicHeadersDir)/iOSOnlyObjCHeaderFilePublic.h", isExpected: false, expectedHeaderLevel: .public)
                                checkExpectedHeader(headersInfoContent, containsPath: "\(truncatedPrivateHeadersDir)/ExcludedObjCHeaderFilePublic.h", isExpected: false, expectedHeaderLevel: .public)

                            case let (headersDir?, nil):
                                checkExpectedHeader(headersInfoContent, containsPath: "\(headersDir)/Framework.h", isExpected: expectedTargetValues.expectedToProcessPublicHeaders, expectedHeaderLevel: .public)
                                checkExpectedHeader(headersInfoContent, containsPath: "\(headersDir)/ObjCHeaderFilePrivate.h", isExpected: expectedTargetValues.expectedToProcessPrivateHeaders, expectedHeaderLevel: .private)

                                checkExpectedHeader(headersInfoContent, containsPath: "/tmp/Test/aProject/ObjCHeaderFileProject.h", isExpected: false, expectedHeaderLevel: .project)
                                checkExpectedHeader(headersInfoContent, containsPath: "\(headersDir)/iOSOnlyObjCHeaderFilePublic.h", isExpected: false, expectedHeaderLevel: .public)
                                checkExpectedHeader(headersInfoContent, containsPath: "\(headersDir)/ExcludedObjCHeaderFilePublic.h", isExpected: false, expectedHeaderLevel: .public)
                            default:
                                break
                            }
                        }

                        checkExpectedHeader(headersInfoContent, containsPath: "/Framework-Swift.h", isExpected: expectedToProcessGeneratedSwiftInterfaceHeader, expectedHeaderLevel: .public, expectedIsSwiftCompatibilityHeader: true)

                        #expect(expectedToProcessGeneratedSwiftInterfaceHeader == headersInfoContent.headers.contains(where: { $0.path.hasSuffix("/Framework-Swift.h") }))
                    }
                }

                for arch in architectures {
                    let (targetTriple, extractAPIOutputDir) = architectureSpecificInput(core, SRCROOT, arch, targetTriplePlatform, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase, forObjectiveC: true)

                    let sdkdbOutputPath = extractAPIOutputDir + "/Framework.sdkdb"
                    let symbolGraphPath = extractAPIOutputDir + "/Framework.symbols.json"

                    // Check the `tapi extractapi` or the `clang -extract-api task
                    results.checkTask(
                        .matchTarget(target),
                        .matchRule(["ExtractAPI", SWBFeatureFlag.enableClangExtractAPI.value ? symbolGraphPath : sdkdbOutputPath])
                    ) {
                        task in

                        if SWBFeatureFlag.enableClangExtractAPI.value {
                            task.checkCommandLineContains([
                                "clang",
                                "-extract-api"
                            ])

                            task.checkCommandLineContainsUninterrupted([
                                "-o",
                                symbolGraphPath
                            ])
                        } else {
                            task.checkCommandLineContainsUninterrupted([
                                tapiToolPath.str,
                                "extractapi",
                                headersInfoPath,
                                "-o",
                                sdkdbOutputPath,
                            ])
                        }

                        task.checkCommandLineContains([
                            "--target=\(targetTriple)",
                        ])

                        task.checkCommandLineContainsUninterrupted([
                            "-isysroot",
                            core.loadSDK(.macOS).path.str,
                        ])
                        if expectedTargetValues.expectedToExtractWithModuleSupport {
                            task.checkCommandLineContains([
                                "-fmodules",
                                "-fmodules-cache-path=module_cache_dir"
                            ])
                        } else {
                            task.checkCommandLineDoesNotContain("-fmodules")
                            task.checkCommandLineDoesNotContain("-fmodules-cache-path=module_cache_dir")
                        }
                        if expectedTargetValues.expectedToExtractWithARCSupport {
                            task.checkCommandLineContains([
                                "-fobjc-arc",
                            ])
                        } else {
                            task.checkCommandLineDoesNotContain("-fobjc-arc")
                        }

                        task.checkCommandLineContains([
                            "-Fframework_search_paths1",
                            "-Fframework_search_paths2"
                        ])
                        task.checkCommandLineContains([
                            "-Iheader_search_paths1",
                            "-Iheader_search_paths2",
                        ])

                        task.checkCommandLineContains([
                            "-I\(frameworkBuildDir)/Framework-own-target-headers.hmap",
                            "-I\(frameworkBuildDir)/Framework-all-target-headers.hmap"
                        ])
                        task.checkCommandLineContains([
                            "-iquote",
                            "\(frameworkBuildDir)/Framework-generated-files.hmap",
                            "-iquote",
                            "\(frameworkBuildDir)/Framework-project-headers.hmap"
                        ])

                        if targetTriplePlatform == "-ios-macabi" {
                            task.checkCommandLineContainsUninterrupted([
                                "-iframework",
                                "system_framework_search_paths1",
                            ])
                            task.checkCommandLineContainsUninterrupted([
                                "-iframework",
                                "system_framework_search_paths2",
                            ])
                            task.checkCommandLineContainsUninterrupted([
                                "-isystem",
                                "system_header_search_paths1",
                            ])
                            task.checkCommandLineContainsUninterrupted([
                                "-isystem",
                                "system_header_search_paths2",
                            ])
                        }

                        task.checkCommandLineContains(["-fmodule-name=Framework"])
                        task.checkCommandLineContains(["--product-name=Framework"])

                        if SWBFeatureFlag.enableClangExtractAPI.value {
                            task.checkCommandLineContainsUninterrupted(["-x", "objective-c-header"])
                        }

                        task.checkInputs(contain: [
                            SWBFeatureFlag.enableClangExtractAPI.value ? nil : .path(frameworkBuildDir + "/Framework-extractapi-headers.json"),
                            .namePattern(.and(.prefix("target-Framework-T-Framework-"), .suffix("--ModuleVerifierTaskProducer"))),
                            .namePattern(.and(.prefix("target-Framework-T-Framework-"), .suffix("--entry")))
                        ].compactMap({ $0 }))

                        task.checkCommandLineDoesNotContain(
                            "-fmodule-map-file=platform_specific_dependency_module_map_path"
                        )
                        task.checkCommandLineContains([
                            "-fmodule-map-file=expected_dependency_module_map_path"
                        ])

                        if sourceLanguages.withObjectiveC, let productHeadersDirs = expectedTargetValues.expectedProductHeaderDirs(builtProductsDir: builtProductsDir) {
                            switch (productHeadersDirs.first, productHeadersDirs.dropFirst().first) {
                            case let (publicHeadersDir?, privateHeadersDir?):
                                if expectedTargetValues.expectedToProcessPublicHeaders {
                                    task.checkInputs(contain: [
                                        .path("\(publicHeadersDir)/Framework.h"),
                                    ])
                                } else {
                                    task.checkNoInputs(contain: [
                                        .path("\(publicHeadersDir)/Framework.h"),
                                    ])
                                }

                                if expectedTargetValues.expectedToProcessPrivateHeaders {
                                    task.checkInputs(contain: [
                                        .path("\(privateHeadersDir)/ObjCHeaderFilePrivate.h"),
                                    ])
                                } else {
                                    task.checkNoInputs(contain: [
                                        .path("\(privateHeadersDir)/ObjCHeaderFilePrivate.h"),
                                    ])
                                }

                                if expectedTargetValues.expectedToProcessProjectVisibleHeaders {
                                    task.checkInputs(contain: [
                                        .path("/tmp/Test/aProject/ObjCHeaderFileProject.h"),
                                    ])
                                } else {
                                    task.checkNoInputs(contain: [
                                        .path("/tmp/Test/aProject/ObjCHeaderFileProject.h"),
                                    ])
                                }
                                task.checkNoInputs(contain: [
                                    .path("\(publicHeadersDir)/iOSOnlyObjCHeaderFilePublic.h"),
                                    .path("\(publicHeadersDir)/ExcludedObjCHeaderFilePublic.h"),
                                ])
                            case let (headersDir?, nil):
                                if expectedTargetValues.expectedToProcessPublicHeaders {
                                    task.checkInputs(contain: [
                                        .path("\(headersDir)/Framework.h"),
                                    ])
                                } else {
                                    task.checkNoInputs(contain: [
                                        .path("\(headersDir)/Framework.h"),
                                    ])
                                }

                                if expectedTargetValues.expectedToProcessPrivateHeaders {
                                    task.checkInputs(contain: [
                                        .path("\(headersDir)/ObjCHeaderFilePrivate.h"),
                                    ])
                                } else {
                                    task.checkNoInputs(contain: [
                                        .path("\(headersDir)/ObjCHeaderFilePrivate.h"),
                                    ])
                                }

                                task.checkNoInputs(contain: [
                                    .path("/tmp/Test/aProject/ObjCHeaderFileProject.h"),
                                ])
                                task.checkNoInputs(contain: [
                                    .path("\(headersDir)/iOSOnlyObjCHeaderFilePublic.h"),
                                    .path("\(headersDir)/ExcludedObjCHeaderFilePublic.h"),
                                ])
                            default:
                                break
                            }
                        }
                        if expectedToProcessGeneratedSwiftInterfaceHeader {
                            task.checkInputs(contain: [
                                .pathPattern(.suffix("/Framework-Swift.h")),
                            ])
                        } else {
                            task.checkNoInputs(contain: [
                                .pathPattern(.suffix("/Framework-Swift.h")),
                            ])
                        }

                        task.checkOutputs([
                            SWBFeatureFlag.enableClangExtractAPI.value ? .path(symbolGraphPath) : .path(sdkdbOutputPath)
                        ])
                    }

                    if !SWBFeatureFlag.enableClangExtractAPI.value {
                        // Check the `sdkdb_to_symgraph` task
                        results.checkTask(.matchTarget(target), .matchRule(["ConvertSDKDBToSymbolGraph", sdkdbOutputPath])) {
                            task in

                            task.checkCommandLine([
                                core.developerPath.path.dirname.join("SharedFrameworks/CoreDocumentation.framework/Resources/sdkdb_to_symgraph").str,
                                sdkdbOutputPath,
                                "Framework",
                                symbolGraphPath
                            ])

                            task.checkInputs([
                                .path(sdkdbOutputPath),

                                    .namePattern(.and(.prefix("target-Framework-T-Framework-"), .suffix("--ModuleVerifierTaskProducer"))),
                                .namePattern(.and(.prefix("target-Framework-T-Framework-"), .suffix("--entry")))
                            ])

                            task.checkOutputs([
                                .path(symbolGraphPath)
                            ])
                        }
                    }
                }
            }

            if sourceLanguages.withObjectiveC, !sourceLanguages.withSwift, expectedTargetValues.expectedToProcessAnyHeaders, expectedTargetValues.expectedToProcessRunSeparateSwiftSymbolGraphExtract {
                for arch in architectures {
                    // The Objective-C logic in `architectureSpecificInput` produce the target triple that `swift-symbolgraph-extract` expects.
                    let (targetTriple, _) = architectureSpecificInput(core, SRCROOT, arch, targetTriplePlatform, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase, forObjectiveC: true)
                    // The Swift logic in `architectureSpecificInput` produce the output directory that `swift-symbolgraph-extract` expects.
                    let (_, outputDir) = architectureSpecificInput(core, SRCROOT, arch, targetTriplePlatform, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase, forObjectiveC: false)

                    // Check the `swift-symbolgraph-extract` task
                    results.checkTask(.matchTarget(target), .matchRule(["ExtractSwiftAPI", targetTriple])) {
                        task in

                        task.checkCommandLineContainsUninterrupted([
                            "swift-symbolgraph-extract",
                            "-target",
                            targetTriple,
                            "-output-dir",
                            outputDir,
                            "-module-name",
                            "Framework",
                        ])
                        task.checkCommandLineContainsUninterrupted([
                            "-sdk",
                            core.loadSDK(.macOS).path.str,
                        ])
                        task.checkCommandLineContainsUninterrupted([
                            "-swift-version",
                            "5"
                        ])

                        task.checkCommandLineContains([
                            "-Fframework_search_paths1",
                            "-Fframework_search_paths2"
                        ])
                        task.checkCommandLineContains([
                            "-Iheader_search_paths1",
                            "-Iheader_search_paths2",
                        ])

                        task.checkCommandLineContains([
                            "-I\(frameworkBuildDir)/Framework-own-target-headers.hmap",
                            "-I\(frameworkBuildDir)/Framework-all-non-framework-target-headers.hmap",
                        ])
                        task.checkCommandLineMatches([
                            "-Xcc",
                            "-ivfsoverlay",
                            "-Xcc",
                            .suffix("all-product-headers.yaml"),
                        ])
                        task.checkCommandLineContains([
                            "-I",
                            "\(frameworkBuildDir)/Framework-generated-files.hmap",
                            "-I",
                            "\(frameworkBuildDir)/Framework-project-headers.hmap"
                        ])

                        if targetTriplePlatform == "-ios-macabi" {
                            task.checkCommandLineContainsUninterrupted([
                                "-Fsystem",
                                "system_framework_search_paths1",
                            ])
                            task.checkCommandLineContainsUninterrupted([
                                "-Fsystem",
                                "system_framework_search_paths2",
                            ])
                            task.checkCommandLineContainsUninterrupted([
                                "-I",
                                "system_header_search_paths1",
                            ])
                            task.checkCommandLineContainsUninterrupted([
                                "-I",
                                "system_header_search_paths2",
                            ])
                        }

                        task.checkInputs(contain: [.namePattern(.suffix(".h"))])

                        var expectedOutput = [NodePattern.path(outputDir + "/Framework.symbols.json")]

                        if let zipperedProductSuffix = zipperedProductSuffix {
                            let (_, zipperedSymbolGraphOutputDir) = architectureSpecificInput(core, SRCROOT, arch, zipperedProductSuffix, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase)
                            expectedOutput.append(.path(zipperedSymbolGraphOutputDir + "/Framework.symbols.json"))
                        }
                        task.checkOutputs(expectedOutput)
                    }
                }
            }

            if expectedTargetValues.expectedToConstructDocumentationTask {
                let docsCatalogFilePath = "\(SRCROOT)/Project.docc"
                var documentationRuleComponents = ["CompileDocumentation"]
                if withDocsCatalog {
                    documentationRuleComponents.append(docsCatalogFilePath)
                }

                try results.checkTask(.matchTarget(target), .matchRule(documentationRuleComponents)) { task in
                    let outputDir = "\(builtProductsDir)/Framework.doccarchive"

                    let symbolGraphOutputDir = URL(fileURLWithPath: architectureSpecificInput(core, SRCROOT, architectures[0], targetTriplePlatform, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase).outputDir)
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .path

                    #expect(symbolGraphOutputDir.hasSuffix("Framework.build/symbol-graph"))

                    var expectedCommandLine = [
                        doccToolPath.str,
                        "convert",
                        "--emit-lmdb-index",
                        "--fallback-display-name", expectedDisplayName,
                        "--fallback-bundle-identifier", expectedDocCatalogIdentifier,
                    ]

                    if let expectedHostingBasePath = expectedHostingBasePath {
                        expectedCommandLine += [
                            "--hosting-base-path", expectedHostingBasePath
                        ]
                    }

                    if !expectedToTransformForStaticHosting {
                        expectedCommandLine.append("--no-transform-for-static-hosting")
                    }

                    expectedCommandLine += [
                        "--output-dir", outputDir,
                    ]

                    let payload = try #require(task.execTask.payload as? DocumentationTaskPayload)
                    if doccFeatures.has(.diagnosticsFile) {
                        expectedCommandLine.append("--ide-console-output")
                        let targetBuildDir = Path(symbolGraphOutputDir).dirname
                        let diagnosticFilePath = targetBuildDir.join("\(expectedDisplayName)-diagnostics.json")
                        expectedCommandLine.append(contentsOf: ["--diagnostics-file", diagnosticFilePath.str])

                        #expect(payload.documentationDiagnosticsPath == diagnosticFilePath)
                    } else {
                        expectedCommandLine.append("--emit-fixits")

                        #expect(payload.documentationDiagnosticsPath == nil)
                    }

                    for argument in withAdditionalDocCArguments {
                        expectedCommandLine.append(argument)
                    }
                    if withDocsCatalog {
                        // we pass the inputs in-between the options and the special-args
                        expectedCommandLine.append(docsCatalogFilePath)
                    }
                    if sourceLanguages.withSwift || (sourceLanguages.withObjectiveC && expectedTargetValues.expectedToProcessAnyHeaders) {
                        expectedCommandLine.append(contentsOf: ["--additional-symbol-graph-dir", symbolGraphOutputDir])
                    }

                    if let expectedDefaultModuleKind = expectedTargetValues.expectedDefaultModuleKind {
                        expectedCommandLine.append(contentsOf: ["--fallback-default-module-kind", expectedDefaultModuleKind])
                    }

                    task.checkCommandLine(expectedCommandLine)

                    task.checkRuleInfo(documentationRuleComponents)

                    if sourceLanguages.withSwift && expectedTargetValues.expectedToConstructSwiftTasks {
                        let symbolGraphDirs = architectures.map { architectureSpecificInput(core, SRCROOT, $0, targetTriplePlatform, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase).outputDir }

                        task.checkInputs(contain: [
                            .path(symbolGraphDirs[0] + "/Framework.symbols.json"),
                            .path(symbolGraphDirs[1] + "/Framework.symbols.json"),
                        ])
                        if !sourceLanguages.withObjectiveC {
                            task.checkInputs(contain: [
                                .namePattern(.and(.prefix("target-Framework-T-Framework-"), .suffix("--ModuleVerifierTaskProducer"))),
                            ])
                        }

                        if let zipperedProductSuffix = zipperedProductSuffix {
                            // Add the zippered variant path after each original path.
                            let zipperedSymbolGraphDirs = architectures.map { architectureSpecificInput(core, SRCROOT, $0, zipperedProductSuffix, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase).outputDir }
                            task.checkInputs(contain: [
                                .path(zipperedSymbolGraphDirs[0] + "/Framework.symbols.json"),
                                .path(zipperedSymbolGraphDirs[1] + "/Framework.symbols.json"),
                            ])
                        }
                    }
                    if sourceLanguages.withObjectiveC, expectedTargetValues.expectedToProcessAnyHeaders {
                        // Only public and private headers are copied
                        if expectedTargetValues.expectedToProcessPublicHeaders || expectedTargetValues.expectedToProcessPrivateHeaders {
                            task.checkInputs(contain: [
                                .namePattern(.and(.prefix("target-Framework-T-Framework-"), .suffix("-phase0-copy-headers")))
                            ])
                        }
                        let symbolGraphDirs = architectures.map { architectureSpecificInput(core, SRCROOT, $0, targetTriplePlatform, debugFolderSuffix, expectedTargetValues.symbolGraphOutputBase, forObjectiveC: true).outputDir }
                        task.checkInputs(contain: [
                            .path(symbolGraphDirs[0] + "/Framework.symbols.json"),
                            .path(symbolGraphDirs[1] + "/Framework.symbols.json"),
                        ])
                    }

                    if withDocsCatalog {
                        task.checkInputs(contain: [
                            .path(docsCatalogFilePath)
                        ])
                    }

                    let diagnosticFileOutputPath = URL(fileURLWithPath: symbolGraphOutputDir)
                        .deletingLastPathComponent()
                        .appendingPathComponent("Framework-diagnostics.json")
                        .path
                    task.checkOutputs([
                        .path(outputDir),
                        .path(diagnosticFileOutputPath)
                    ])
                    task.checkEnvironment([
                        "DOCC_HTML_DIR": customTemplatePath.map { .equal($0)} ?? .none
                    ])
                }
            }

            // Check that no tasks were missed
            results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
            results.checkNoTask(.matchTarget(target), .matchRuleItem("ExtractAPI"))
            results.checkNoTask(.matchTarget(target), .matchRuleItem("ConvertSDKDBToSymbolGraph"))
            results.checkNoTask(.matchTarget(target), .matchRuleItem("ExtractSwiftAPI"))
        }
    }

    private func checkNoDocumentationTasksAreConstructed(sourceLanguages: SourceLanguageConfiguration, core: Core, results: TaskConstructionTester.PlanningResults, SRCROOT: String) {
        results.checkTarget("Framework") { target in
            // The output for ExtractSwiftSymbolGraph and input for CompileDocumentation.
            if sourceLanguages.withSwift {
                for arch in architectures {
                    let (targetTriple, symbolGraphOutputDir) = architectureSpecificInput(core, SRCROOT, arch, "macos", "", nil)

                    if let task = results.findMatchingTasks([.matchTarget(target), .matchRule(["SwiftDriver Compilation Requirements", "Framework", "normal", arch, "com.apple.xcode.tools.swift.compiler"])]).only {
                        let frameworkBuildDir = "/tmp/Test/aProject/build/aProject.build/Debug/Framework.build"

                        task.checkCommandLineDoesNotContain("-emit-symbol-graph")
                        task.checkCommandLineDoesNotContain("-emit-symbol-graph-dir")
                        task.checkCommandLineDoesNotContain(symbolGraphOutputDir)

                        task.checkNoOutputs(contain: [
                            .path(frameworkBuildDir + "/symbol-graph/swift/\(targetTriple)/Framework.symbols.json"),
                        ])
                    }
                }
            }

            let docsCatalogFilePath = "\(SRCROOT)/Project.docc"
            results.checkNoTask(.matchTarget(target), .matchRule(["CompileDocumentation", docsCatalogFilePath]))

            results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
            results.checkNoTask(.matchTarget(target), .matchRuleItem("ExtractAPI"))
            results.checkNoTask(.matchTarget(target), .matchRuleItem("ConvertSDKDBToSymbolGraph"))
        }
    }

    private let architectures = ["x86_64", "arm64"]

    private func architectureSpecificInput(_ core: Core, _ SRCROOT: String, _ arch: String, _ targetTriplePlatform: String, _ debugFolderSuffix: String, _ symbolGraphOutputBase: String?, forObjectiveC: Bool = false) -> (targetTriple: String, outputDir: String) {

        var targetTriple = "\(arch)-apple\(targetTriplePlatform)"
        if forObjectiveC {
            // The tapi target triple includes the deployment target
            targetTriple = targetTriplePlatform == "-ios-macabi"
            ? targetTriple.replacingOccurrences(of: "-ios-macabi", with: "-ios\(core.macCatalystSDKVariant.defaultDeploymentTarget)-macabi")
            : targetTriple + core.loadSDK(.macOS).defaultDeploymentTarget
        }

        let symbolGraphSubDir = forObjectiveC ? "clang" : "swift"
        let symbolGraphOutputBaseDir = symbolGraphOutputBase ?? "\(SRCROOT)/build/aProject.build/Debug\(debugFolderSuffix)/Framework.build/symbol-graph"
        let symbolGraphOutputDir = "\(symbolGraphOutputBaseDir)/\(symbolGraphSubDir)/\(targetTriple)"

        return (targetTriple, symbolGraphOutputDir)
    }

    private struct TestFileList: Decodable {
        struct Header: Decodable {
            let type: String
            let path: String
            let language: String?
            let swiftCompatibilityHeader: Bool?
        }
        let headers: [Header]
        let version: String
    }

    private func checkExpectedHeader(_ headerInfoContent: TestFileList, containsPath path: String, isExpected: Bool, expectedHeaderLevel: TAPIFileList.HeaderVisibility, expectedIsSwiftCompatibilityHeader: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        let matches = headerInfoContent.headers.filter { $0.path.hasSuffix(path) }
        #expect(!matches.isEmpty == isExpected)

        guard let headerInfo = matches.first else {
            return
        }
        #expect(matches.count == 1, "Duplicate headers with path: '\(path)'", sourceLocation: sourceLocation)

        if headerInfoContent.version == "1" || headerInfoContent.version == "2" {
            #expect(headerInfo.language == nil, "'language' is not supported in version '\(headerInfoContent.version)'", sourceLocation: sourceLocation)
            #expect(headerInfo.swiftCompatibilityHeader == nil, "'swiftCompatibilityHeader' is not supported in version '\(headerInfoContent.version)'", sourceLocation: sourceLocation)
        } else {
            #expect(headerInfo.language == "c")
            #expect(headerInfo.swiftCompatibilityHeader == (expectedIsSwiftCompatibilityHeader ? true : nil))
        }

        #expect(headerInfo.type == expectedHeaderLevel.rawValue)
    }
}
