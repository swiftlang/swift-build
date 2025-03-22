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
import SWBTestSupport
import SWBUtil
import SWBMacro
@_spi(Testing) import SWBCore

@Suite fileprivate struct SDKRegistryTests: CoreBasedTests {

    /// Delegate for testing loading SDKs in a registry.
    final class TestDataDelegate : SDKRegistryDelegate {
        let namespace = MacroNamespace()
        let pluginManager: PluginManager
        private let _diagnosticsEngine = DiagnosticsEngine()

        init(pluginManager: PluginManager) {
            self.pluginManager = pluginManager
        }

        var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            return .init(_diagnosticsEngine)
        }

        var warnings: [String] {
            return _diagnosticsEngine.diagnostics.filter { $0.behavior == .warning }.map { $0.formatLocalizedDescription(.debugWithoutBehavior) }
        }

        var errors: [String] {
            return _diagnosticsEngine.diagnostics.filter { $0.behavior == .error }.map { $0.formatLocalizedDescription(.debugWithoutBehavior) }
        }

        var platformRegistry: PlatformRegistry? {
            nil
        }
    }

    /// Helper function for scanning test inputs.
    ///
    /// - parameter inputs: A list of test inputs, in the form (name, testData). These inputs will be written to files in a temporary directory for testing.
    /// - parameter perform: A block to run with the registry that results from scanning the inputs, as well as the list of warnings and errors. Each warning and error is a pair of the path basename and the diagnostic message.
    private func withRegistryForTestInputs(_ inputs: [(String, PropertyListItem?)],
                                           registryType: SDKRegistry.SDKRegistryType = .builtin,
                                           sourceLocation: SourceLocation = #_sourceLocation,
                                           perform: (SDKRegistry, TestDataDelegate, Path) async throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            for (name, dataOpt) in inputs {
                let itemPath = tmpDirPath.join(name).join("SDKSettings.plist")
                try localFS.createDirectory(itemPath.dirname, recursive: true)

                // Write the test data to the path, if present.
                if let data = dataOpt {
                    try await localFS.writePlist(itemPath, data)
                } else {
                    // Write bogus data, so the file exists.
                    let plistData = "\u{1}\u{1}notaplist".data(using: String.Encoding.utf8)!
                    try plistData.write(to: URL(fileURLWithPath: itemPath.str), options: [])
                }
            }

            let delegate = TestDataDelegate(pluginManager: try await getCore().pluginManager)
            let registry = SDKRegistry(delegate: delegate, searchPaths: [(tmpDirPath, nil)], type: registryType, hostOperatingSystem: try await getCore().hostOperatingSystem)
            try await perform(registry, delegate, tmpDirPath)
        }
    }

    @Test
    func parsingCanonicalName() async throws {
        func parseAndCheck(sdkName: String, check: (SDK.CanonicalNameComponents?, String?) -> Void) async throws {
            let components: SDK.CanonicalNameComponents?
            let errorString: String?
            do {
                components = try SDK.parseSDKName(sdkName, pluginManager: try await getCore().pluginManager)
                errorString = nil
            }
            catch {
                components = nil
                errorString = "\(error)"
            }
            check(components, errorString)
        }

        try await parseAndCheck(sdkName: "macosx") { components, error in
            #expect(components?.basename == "macosx")
            #expect(components?.version == nil)
            #expect(components?.suffix == nil)
            #expect(error == nil)
        }
        try await parseAndCheck(sdkName: "macosx10") { components, error in
            #expect(components?.basename == "macosx")
            #expect(components?.version == Version(10))
            #expect(components?.suffix == nil)
            #expect(error == nil)
        }
        try await parseAndCheck(sdkName: "macosx10.15") { components, error in
            #expect(components?.basename == "macosx")
            #expect(components?.version == Version(10, 15))
            #expect(components?.suffix == nil)
            #expect(error == nil)
        }
        try await parseAndCheck(sdkName: "macosx10.15.4") { components, error in
            #expect(components?.basename == "macosx")
            #expect(components?.version == Version(10, 15, 4))
            #expect(components?.suffix == nil)
            #expect(error == nil)
        }
        // Test that the base name can contain a dot.
        try await parseAndCheck(sdkName: "driverkit.macosx") { components, error in
            #expect(components?.basename == "driverkit.macosx")
            #expect(components?.version == nil)
            #expect(components?.suffix == nil)
            #expect(error == nil)
        }
        try await parseAndCheck(sdkName: "driverkit.macosx19.0") { components, error in
            #expect(components?.basename == "driverkit.macosx")
            #expect(components?.version == Version(19, 0))
            #expect(components?.suffix == nil)
            #expect(error == nil)
        }

        // Check error cases.
        try await parseAndCheck(sdkName: "macosx10.15bogus") { components, error in
            #expect(components == nil)
            #expect(error == "SDK canonical name 'macosx10.15bogus' not in supported format '<name>[<version>][suffix]'.")
        }
    }

    @Test(.requireHostOS(.macOS))
    func loadingErrors() async throws {
        try await withRegistryForTestInputs([
            ("unused", nil),
            ("a.sdk", nil),
            ("b.sdk", []),
            ("c.sdk", ["bad": "bad"]),
            ("d.sdk", ["CanonicalName": "d", "DefaultProperties": ["NAME": "VALUE"]]),
            ("e.sdk", ["CanonicalName": "d"]),
        ]) { registry, delegate, _ in
            #expect(registry.allSDKs.map({ $0.canonicalName }).sorted() == ["d"])

            let dSDK = registry.lookup("d")
            #expect(dSDK != nil)
            #expect(dSDK?.canonicalName == "d")
            #expect(dSDK?.defaultSettings["NAME"] == .plString("VALUE"))

            XCTAssertMatch(delegate.errors, [
                .contains("a.sdk: unable to load SDK: 'SDKSettings.plist' was malformed"),
                .contains("b.sdk: unexpected SDK data"),
                .contains("c.sdk: invalid or missing 'CanonicalName' field"),
                .contains("e.sdk: SDK 'd' already registered")
            ])
            #expect(delegate.warnings == [])
        }
    }

    @Test(.requireHostOS(.macOS))
    func lookup() async throws {
        try await withRegistryForTestInputs([
            ("boot.sdk", ["CanonicalName": "macosx", "Toolchains": ["swift", "default"]]),
            ("toastos1.0.sdk", ["CanonicalName": "toastos1.0", "Version": "1.0", "Aliases": ["toast", "toastx"]]),
            ("toastos2.0.sdk", ["CanonicalName": "toastos2.0", "Version": "2.0", "Aliases": ["toast", "toasty"]]),
            ("toastos2.0.1.sdk", ["CanonicalName": "toastos2.0.1", "Version": "2.0.1"]),
            // This SDK is used to make sure we don't find the wrong SDK when looking up 'toastos'.
            ("toastosextra1.0.sdk", ["CanonicalName": "toastosextra1.0", "Version": "1.0"]),
            // Test that having a dot in the base name works too.
            ("driverkit2.0.sdk", ["CanonicalName": "driverkit.toastos2.0", "Version": "2.0"]),
        ]) { registry, delegate, tmpDir in

            // Check the canonical names all defined SDKs to make sure we have a reasonable baseline.
            #expect(Set(registry.allSDKs.map({ $0.canonicalName })) == Set([
                "macosx", "toastos1.0", "toastos2.0", "toastos2.0.1", "toastosextra1.0", "driverkit.toastos2.0"]))

            // Look up the boot SDK (macosx) by name and make sure it has the expected properties.
            let bootSDK = try #require(registry.lookup("macosx"))
            #expect(bootSDK.toolchains == ["swift", "default"])
            #expect(bootSDK.path.basename == "boot.sdk")
            #expect(registry.bootSystemSDK === bootSDK)
            #expect(registry.lookup(nameOrPath: "", basePath: .root) === bootSDK)
            #expect(registry.lookup(tmpDir.join("boot.sdk")) === bootSDK)

            // Look up the toast SDKs by name and check their properties.
            let toast1SDK = try #require(registry.lookup("toastos1.0"))
            let toast2SDK = try #require(registry.lookup("toastos2.0"))
            let toast201SDK = try #require(registry.lookup("toastos2.0.1"))
            let driverkit2SDK = try #require(registry.lookup("driverkit.toastos2.0"))
            #expect(toast1SDK.path.basename == "toastos1.0.sdk")
            #expect(toast1SDK.toolchains == [])
            #expect(toast2SDK.path.basename == "toastos2.0.sdk")
            #expect(toast2SDK.toolchains == [])
            #expect(driverkit2SDK.path.basename == "driverkit2.0.sdk")

            // Perform some other lookups by name and by path.
            func lookupAndCheckSDK(name: String, expectedSDK: SDK, sourceLocation: SourceLocation = #_sourceLocation) {
                let sdk = registry.lookup(name)
                #expect(sdk === expectedSDK, "lookup of SDK '\(name)' yielded unexpected SDK: \(String(describing: sdk))", sourceLocation: sourceLocation)
            }
            func lookupAndCheckSDK(path: Path, expectedSDK: SDK, sourceLocation: SourceLocation = #_sourceLocation) {
                let sdk = registry.lookup(path)
                #expect(sdk === expectedSDK, "lookup of SDK '\(path)' yielded unexpected SDK: \(String(describing: sdk))", sourceLocation: sourceLocation)
            }
            lookupAndCheckSDK(name: "toastos", expectedSDK: toast201SDK)
            lookupAndCheckSDK(name: "toast", expectedSDK: toast2SDK)
            lookupAndCheckSDK(name: "toastx", expectedSDK: toast1SDK)
            lookupAndCheckSDK(name: "toasty", expectedSDK: toast2SDK)
            lookupAndCheckSDK(path: tmpDir.join("toastos1.0.sdk"), expectedSDK: toast1SDK)
            lookupAndCheckSDK(name: "driverkit.toastos", expectedSDK: driverkit2SDK)

            #expect(delegate.errors == [])
            #expect(delegate.warnings == [])
        }
    }

    @Test
    func overridingSDKs() async throws {
        try await withRegistryForTestInputs([
            ("boot.sdk", ["CanonicalName": "macosx"]),
            ("toastos1.0.sdk", ["CanonicalName": "toastos1.0"]),
        ]) { coreSDKRegistry, delegate, _ in

            try await withTemporaryDirectory { overridingSDKsDirPath in
                try await writeSDK(name: "overrideToast.sdk", parentDir: overridingSDKsDirPath, settings: ["CanonicalName": "toastos1.0"])

                let userNamespace = MacroNamespace()
                let registry = WorkspaceContextSDKRegistry(coreSDKRegistry: coreSDKRegistry, delegate: delegate, userNamespace: userNamespace, overridingSDKsDir: overridingSDKsDirPath)

                #expect(registry.lookup("macosx")?.path.basename == "boot.sdk")
                #expect(registry.lookup(nameOrPath: "macosx", basePath: .root)?.path.basename == "boot.sdk")

                #expect(registry.lookup("toastos")?.path.basename == "overrideToast.sdk")
                #expect(registry.lookup(nameOrPath: "toastos", basePath: .root)?.path.basename == "overrideToast.sdk")

                #expect(delegate.errors == [])
                #expect(delegate.warnings == [])
            }
        }
    }

    @Test
    func externalSDKs() async throws {
        try await withRegistryForTestInputs([
            ("boot.sdk", ["CanonicalName": "macosx"]),
        ]) { coreSDKRegistry, delegate, _ in

            // Create an external SDK.
            try await withTemporaryDirectory { externalSDKsDirPath in
                try await writeSDK(name: "external.sdk", parentDir: externalSDKsDirPath, settings: ["CanonicalName": "external1.0"])

                // First make sure we can't load the external SDK via the core registry.
                #expect(coreSDKRegistry.lookup("macosx")?.path.basename == "boot.sdk")
                #expect(coreSDKRegistry.lookup(nameOrPath: "macosx", basePath: .root)?.path.basename == "boot.sdk")

                #expect(coreSDKRegistry.lookup("external1.0") == nil)
                #expect(coreSDKRegistry.lookup(nameOrPath: "external1.0", basePath: .root) == nil)

                #expect(coreSDKRegistry.lookup(externalSDKsDirPath.join("external.sdk")) == nil)
                #expect(coreSDKRegistry.lookup(nameOrPath: externalSDKsDirPath.join("external.sdk").str, basePath: .root) == nil)

                // Now make sure we can load the external SDK via a workspace context registry.
                let userNamespace = MacroNamespace()
                let registry = WorkspaceContextSDKRegistry(coreSDKRegistry: coreSDKRegistry, delegate: delegate, userNamespace: userNamespace, overridingSDKsDir: nil)

                #expect(registry.lookup("macosx")?.path.basename == "boot.sdk")
                #expect(registry.lookup(nameOrPath: "macosx", basePath: .root)?.path.basename == "boot.sdk")

                #expect(registry.lookup(externalSDKsDirPath.join("external.sdk"))?.canonicalName == "external1.0")
                #expect(registry.lookup(externalSDKsDirPath.join("external.sdk"))?.canonicalName == "external1.0")

                #expect(delegate.errors == [])
                #expect(delegate.warnings == [])
            }
        }
    }

    @Test
    func customBuildSettings() async throws {
        try await withRegistryForTestInputs([
            ("boot.sdk", ["CanonicalName": "macosx"]),
        ]) { coreSDKRegistry, delegate, _ in

            // Create an SDK with custom build settings.
            try await withTemporaryDirectory { sdksDirPath in
                let sdkPath = sdksDirPath.join("TestSDK.sdk")
                let sdkIdentifier = "com.apple.sdk.1.0"
                try await writeSDK(name: sdkPath.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": .plString(sdkIdentifier),
                    "IsBaseSDK": "NO",
                    "DefaultProperties": [
                        "SOME_CUSTOM_SETTING": "foo"
                    ],
                    "CustomProperties": [
                        "SOME_CUSTOM_SETTING": "$(inherited) SOME_CUSTOM_SETTING"
                    ],
                ])
                let userNamespace = MacroNamespace()
                let registry = WorkspaceContextSDKRegistry(coreSDKRegistry: coreSDKRegistry, delegate: delegate, userNamespace: userNamespace, overridingSDKsDir: nil)

                // Looking up an external SDK by path also parses the build settings in it.
                #expect(registry.lookup(sdkPath)?.canonicalName == sdkIdentifier)

                #expect(delegate.errors == [])
                #expect(delegate.warnings == [])
            }
        }
    }

    @Test
    func invalidCustomBuildSettings() async throws {
        try await withRegistryForTestInputs([
            ("boot.sdk", ["CanonicalName": "macosx"]),
        ]) { coreSDKRegistry, delegate, _ in

            // Create an SDK with custom build settings.
            try await withTemporaryDirectory { sdksDirPath in
                let sdkPath = sdksDirPath.join("TestSDK.sdk")
                let sdkIdentifier = "com.apple.sdk.1.0"
                try await writeSDK(name: sdkPath.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": .plString(sdkIdentifier),
                    "IsBaseSDK": "NO",
                    "DefaultProperties": [
                        "CODE_SIGNING_REQUIRED": true
                    ],
                    "CustomProperties": [
                        "CODE_SIGNING_REQUIRED": true
                    ],
                ])
                let userNamespace = MacroNamespace()
                let registry = WorkspaceContextSDKRegistry(coreSDKRegistry: coreSDKRegistry, delegate: delegate, userNamespace: userNamespace, overridingSDKsDir: nil)

                // Looking up an external SDK by path also parses the build settings in it.
                #expect(registry.lookup(sdkPath)?.canonicalName == sdkIdentifier)

                #expect(delegate.errors == ["unexpected macro parsing failure loading SDK com.apple.sdk.1.0: inconsistentMacroDefinition(name: \"CODE_SIGNING_REQUIRED\", type: SWBMacro.MacroType.userDefined, value: true)"])
                #expect(delegate.warnings == [])
            }
        }
    }

    @Test
    func SDKVariants() async throws {
        try await withRegistryForTestInputs([
            ("boot.sdk", ["CanonicalName": "macosx"]),
        ]) { coreSDKRegistry, delegate, _ in

            // Create an SDK with variants.
            try await withTemporaryDirectory { sdksDirPath in
                let sdkPath = sdksDirPath.join("TestSDK.sdk")
                let sdkIdentifier = "com.apple.sdk.1.0"
                try await writeSDK(name: sdkPath.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": .plString(sdkIdentifier),
                    "Version": "1.0",
                    "IsBaseSDK": "YES",
                    "DefaultProperties": [
                        "SOME_CUSTOM_SETTING": "foo"
                    ],
                    "CustomProperties": [
                        "SOME_CUSTOM_SETTING": "$(inherited) SOME_CUSTOM_SETTING"
                    ],
                    "Variants": [
                        [   "Name": "iosmac",
                            "BuildSettings": [
                                "SOME_CUSTOM_SETTING": "$(inherited) S",
                            ],
                        ] as PropertyListItem,
                        [   "Name": "macos",
                            "BuildSettings": [
                                "SOME_CUSTOM_SETTING": "$(inherited) V",
                            ],
                        ] as PropertyListItem
                    ],
                    "SupportedTargets": [
                        "iosmac": [
                            "Archs": [ "x86_64", "x86_64h" ],
                            "BuildVersionPlatformID": "6",
                            "MinimumDeploymentTarget": "13.0",
                            "MaximumDeploymentTarget": "13.0.99",
                            "DefaultDeploymentTarget": "13.0",
                            "ValidDeploymentTargets": [ "13.0" ],
                            "LLVMTargetTripleVendor": "apple",
                            "LLVMTargetTripleSys": "ios",
                            "LLVMTargetTripleEnvironment": "macabi",
                        ] as PropertyListItem,
                        // Test the fact that the macOS variant's name is 'macos' but the target name is 'macosx', and we want to standardize on the platform name.
                        "macosx": [
                            "Archs": [ "x86_64" ],
                            "BuildVersionPlatformID": "1",
                            "MinimumDeploymentTarget": "10.12",
                            "DefaultDeploymentTarget": "10.15",
                            "ValidDeploymentTargets": [ "10.12", "10.13", "10.14", "10.15" ],
                            "LLVMTargetTripleVendor": "apple",
                            "LLVMTargetTripleSys": "macos",
                            "LLVMTargetTripleEnvironment": "",
                        ] as PropertyListItem,
                        // Test an externally defined platform target that we don't know about
                        "toastos": [
                            "Archs": [ "x86_64" ],
                            "BuildVersionPlatformID": "99",
                            "MinimumDeploymentTarget": "99.99",
                            "DeploymentTargetSettingName": "TOASTOS_DEPLOYMENT_TARGET",
                            "DefaultDeploymentTarget": "99.99",
                            "ValidDeploymentTargets": [ "99.99" ],
                            "LLVMTargetTripleVendor": "apple",
                            "LLVMTargetTripleSys": "toastos",
                            "PlatformFamilyName": "toastOS",
                        ] as PropertyListItem,
                    ],
                    "DefaultVariant": "macos"
                ])
                let userNamespace = MacroNamespace()
                let registry = WorkspaceContextSDKRegistry(coreSDKRegistry: coreSDKRegistry, delegate: delegate, userNamespace: userNamespace, overridingSDKsDir: nil)

                // Looking up an external SDK by path also parses the build settings in it.
                guard let sdk = registry.lookup(sdkPath) else {
                    Issue.record("Couldn't load the SDK at \(sdkPath.str)")
                    return
                }
                #expect(sdk.canonicalName == sdkIdentifier)

                // Check the variant definitions.
                #expect(sdk.variants.count == 3)
                let macCatalystVariant = try #require(sdk.variants[MacCatalystInfo.sdkVariantName])
                #expect(macCatalystVariant.name == MacCatalystInfo.sdkVariantName)
                #expect(Set(macCatalystVariant.settings.keys) == Set([
                    "IS_MACCATALYST",
                    "SDK_VARIANT",
                    "SOME_CUSTOM_SETTING",
                ]))
                #expect(macCatalystVariant.settings["IS_MACCATALYST"]?.stringValue == "YES")
                #expect(macCatalystVariant.settings["SDK_VARIANT"]?.stringValue == MacCatalystInfo.sdkVariantName)
                #expect(macCatalystVariant.settings["SOME_CUSTOM_SETTING"]?.stringValue == "$(inherited) S")
                guard let macosVariant = sdk.variants["macos"] else {
                    Issue.record("Could not find a macos variant")
                    return
                }
                #expect(macosVariant.name == "macos")
                #expect(Set(macCatalystVariant.settings.keys) == Set([
                    "IS_MACCATALYST",
                    "SDK_VARIANT",
                    "SOME_CUSTOM_SETTING",
                ]))
                #expect(macosVariant.settings["IS_MACCATALYST"]?.stringValue == "NO")
                #expect(macosVariant.settings["SDK_VARIANT"]?.stringValue == "macos")
                #expect(macosVariant.settings["SOME_CUSTOM_SETTING"]?.stringValue == "$(inherited) V")

                // Check the default variant.
                #expect(sdk.defaultVariant === macosVariant)

                // Check the other properties.
                #expect(macCatalystVariant.archs == [ "x86_64", "x86_64h" ])
                #expect(macCatalystVariant.buildVersionPlatformID == 6)
                #expect(macCatalystVariant.minimumDeploymentTarget == Version(13, 0))
                #expect(macCatalystVariant.maximumDeploymentTarget == Version(13, 0, 99))
                #expect(macCatalystVariant.defaultDeploymentTarget == Version(13, 0))
                #expect(macCatalystVariant.validDeploymentTargets == [ Version(13, 0) ])
                #expect(macCatalystVariant.llvmTargetTripleVendor == "apple")
                #expect(macCatalystVariant.llvmTargetTripleSys == "ios")
                #expect(macCatalystVariant.llvmTargetTripleEnvironment == "macabi")
                #expect(macosVariant.archs == [ "x86_64" ])
                #expect(macosVariant.buildVersionPlatformID == 1)
                #expect(macosVariant.minimumDeploymentTarget == Version(10, 12))
                #expect(macosVariant.maximumDeploymentTarget == nil)
                #expect(macosVariant.defaultDeploymentTarget == Version(10, 15))
                #expect(macosVariant.validDeploymentTargets == [ Version(10, 12), Version(10, 13), Version(10, 14), Version(10, 15) ])
                #expect(macosVariant.llvmTargetTripleVendor == "apple")
                #expect(macosVariant.llvmTargetTripleSys == "macos")
                #expect(macosVariant.llvmTargetTripleEnvironment == "")

                // check the external platform definition
                let toastosVariant = try #require(sdk.variants["toastos"])

                struct Lookup: PlatformInfoLookup {
                    let toastosVariant: SDKVariant

                    init(_ toastosVariant: SDKVariant) {
                        self.toastosVariant = toastosVariant
                    }

                    func lookupPlatformInfo(platform: BuildVersion.Platform) -> (any PlatformInfoProvider)? {
                        platform.rawValue == 99 ? toastosVariant : nil
                    }
                }

                if let toastPlatform = sdk.targetBuildVersionPlatform(sdkVariant: toastosVariant),
                   let infoProvider = Lookup(toastosVariant).lookupPlatformInfo(platform: toastPlatform) {
                    #expect(infoProvider.buildVersionPlatformID == 99)
                    #expect(infoProvider.defaultDeploymentTarget == Version(99, 99))
                    #expect(infoProvider.deploymentTargetSettingName == "TOASTOS_DEPLOYMENT_TARGET")
                    #expect(infoProvider.llvmTargetTripleEnvironment == nil)
                    #expect(infoProvider.llvmTargetTripleSys == "toastos")
                    #expect(infoProvider.llvmTargetTripleVendor == "apple")
                    #expect(infoProvider.name == "toastos")
                    #expect(infoProvider.platformFamilyName == "toastOS")
                } else {
                    Issue.record("Missing toastos platform info")
                }

                #expect(delegate.errors == [])
                #expect(delegate.warnings == [])
            }
        }
    }

    @Test
    func SDKVariantsEvaluatedTargetedDeviceFamilyIdentifierSkipping() async throws {
        try await withRegistryForTestInputs([
            ("boot.sdk", ["CanonicalName": "macosx"]),
        ]) { coreSDKRegistry, delegate, _ in

            // Create an SDK with variants.
            try await withTemporaryDirectory { sdksDirPath in
                let toastSDKPath = sdksDirPath.join("ToastOS1.0.sdk")
                try await writeSDK(name: toastSDKPath.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": "toastos",
                    "IsBaseSDK": "YES",
                    "SupportedTargets": [
                        "toastos": [
                            "BuildVersionPlatformID": "11",
                            "DeviceFamilies": [
                                [ "DisplayName": "iPhone", "Identifier": "1", "Name": "phone" ],
                                [ "DisplayName": "iPad", "Identifier": "2", "Name": "pad" ],
                                [ "DisplayName": "Toaster", "Identifier": "7", "Name": "toaster" ],
                            ]
                        ] as PropertyListItem
                    ]
                ])

                let macosBorkSDKPath = sdksDirPath.join("MacOSBork.sdk")
                try await writeSDK(name: macosBorkSDKPath.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": "macosbork",
                    "IsBaseSDK": "YES",
                    "SupportedTargets": [
                        "iosmac": [] as PropertyListItem
                    ]
                ])

                let core = try await self.getCore()
                let userNamespace = MacroNamespace()
                var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
                var scope = MacroEvaluationScope(table: table)
                let registry = WorkspaceContextSDKRegistry(coreSDKRegistry: coreSDKRegistry, delegate: delegate, userNamespace: userNamespace, overridingSDKsDir: nil)

                guard let toastSDK = registry.lookup(toastSDKPath) else {
                    Issue.record("Couldn't load the SDK at \(toastSDKPath.str)")
                    return
                }

                guard let macosBorkSDK = registry.lookup(macosBorkSDKPath) else {
                    Issue.record("Couldn't load the SDK at \(macosBorkSDKPath.str)")
                    return
                }

                let toastVariant = try #require(toastSDK.variants["toastos"])
                let toastAppSpec: ProductTypeSpec = try core.specRegistry.getSpec("com.apple.product-type.application", domain: "embedded")

                table.push(BuiltinMacros.TARGETED_DEVICE_FAMILY, literal: "1,2")
                scope = MacroEvaluationScope(table: table)
                #expect(scope.evaluate(BuiltinMacros.TARGETED_DEVICE_FAMILY) == "1,2")

                var (filteredIds, effectiveIds, _, _) = toastVariant.evaluateTargetedDeviceFamilyBuildSetting(scope, toastAppSpec)
                #expect(filteredIds == Set([1,2]))
                #expect(effectiveIds == Set([1,2]))

                table.push(BuiltinMacros.TARGETED_DEVICE_FAMILY, literal: "7")
                scope = MacroEvaluationScope(table: table)
                #expect(scope.evaluate(BuiltinMacros.TARGETED_DEVICE_FAMILY) == "7")
                (filteredIds, effectiveIds, _, _) = toastVariant.evaluateTargetedDeviceFamilyBuildSetting(scope, toastAppSpec)
                #expect(filteredIds == Set([7]))
                #expect(effectiveIds == Set([7]))

                table.push(BuiltinMacros.TARGETED_DEVICE_FAMILY, literal: "1,2,7")
                scope = MacroEvaluationScope(table: table)
                #expect(scope.evaluate(BuiltinMacros.TARGETED_DEVICE_FAMILY) == "1,2,7")
                (filteredIds, effectiveIds, _, _) = toastVariant.evaluateTargetedDeviceFamilyBuildSetting(scope, toastAppSpec)
                #expect(filteredIds == Set([7]))
                #expect(effectiveIds == Set([7]))

                table.push(BuiltinMacros.TARGETED_DEVICE_FAMILY, literal: "")
                scope = MacroEvaluationScope(table: table)
                #expect(scope.evaluate(BuiltinMacros.TARGETED_DEVICE_FAMILY) == "")
                (filteredIds, effectiveIds, _, _) = toastVariant.evaluateTargetedDeviceFamilyBuildSetting(scope, toastAppSpec)
                #expect(filteredIds == Set())
                #expect(effectiveIds == Set([7]))

                let iosmacVariant = try #require(macosBorkSDK.variants["iosmac"])
                let macAppSpec: ProductTypeSpec = try core.specRegistry.getSpec("com.apple.product-type.application", domain: "macosx")

                table.remove(BuiltinMacros.TARGETED_DEVICE_FAMILY)
                scope = MacroEvaluationScope(table: table)
                (filteredIds, effectiveIds, _, _) = iosmacVariant.evaluateTargetedDeviceFamilyBuildSetting(scope, macAppSpec)
                #expect(filteredIds == Set())
                #expect(effectiveIds == Set([2,6]))

                table.push(BuiltinMacros.TARGETED_DEVICE_FAMILY, literal: "")
                scope = MacroEvaluationScope(table: table)
                (filteredIds, effectiveIds, _, _) = iosmacVariant.evaluateTargetedDeviceFamilyBuildSetting(scope, macAppSpec)
                #expect(filteredIds == Set())
                #expect(effectiveIds == Set([2,6]))

                // deployment target 13.0 keeps both devices
                table.push(BuiltinMacros.TARGETED_DEVICE_FAMILY, literal: "2,6")
                table.push(BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET, literal: "13.0")
                scope = MacroEvaluationScope(table: table)
                (filteredIds, effectiveIds, _, _) = iosmacVariant.evaluateTargetedDeviceFamilyBuildSetting(scope, macAppSpec)
                #expect(filteredIds == Set([2,6]))
                #expect(effectiveIds == Set([2,6]))

                // deployment target >= 14.0 skips ipad and only includes iosmac
                table.push(BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET, literal: "15.0")
                scope = MacroEvaluationScope(table: table)
                (filteredIds, effectiveIds, _, _) = iosmacVariant.evaluateTargetedDeviceFamilyBuildSetting(scope, macAppSpec)
                #expect(filteredIds == Set([6]))
                #expect(effectiveIds == Set([6]))
            }
        }
    }

    @Test(.requireHostOS(.macOS))
    func sparseSDKs() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            // Create the sparse SDK in the temporary directory, and create some (but not all) of the search path directories.
            let sdkPath = tmpDirPath.join("Sparse1.0.sdk")
            let canonicalName = "com.apple.sdk.sparse1.0"
            let settings: [String: PropertyListItem] = [
                "CanonicalName": .plString(canonicalName),
                "DisplayName": "Sparse SDK 1.0",
                "IsBaseSDK": "NO",
                "HeaderSearchPaths": [
                    "usr/include",
                    "usr/local/include",
                ],
                "LibrarySearchPaths": [
                    "usr/lib",
                    "usr/local/lib",
                ],
                "FrameworkSearchPaths": [
                    "Library/Frameworks",
                    "System/Library/PrivateFrameworks",
                    "System/Library/Frameworks",
                ],
                "CustomProperties": [
                    "MACOSX_DEPLOYMENT_TARGET": "10.11",
                    "SOME_OTHER_SETTING": "foo"
                ],
            ]
            try await writeSDK(name: sdkPath.basename, parentDir: sdkPath.dirname, settings: settings)
            try localFS.createDirectory(sdkPath.join("usr/include"), recursive: true)
            try localFS.createDirectory(sdkPath.join("usr/lib"), recursive: true)
            try localFS.createDirectory(sdkPath.join("System/Library/PrivateFrameworks"), recursive: true)
            try localFS.createDirectory(sdkPath.join("System/Library/Frameworks"), recursive: true)

            let delegate = TestDataDelegate(pluginManager: try await getCore().pluginManager)
            let registry = SDKRegistry(delegate: delegate, searchPaths: [(tmpDirPath, nil)], type: .builtin, hostOperatingSystem: try await getCore().hostOperatingSystem)

            // Check that we loaded the SDK and that it has the expected search paths.
            #expect(registry.allSDKs.map({ $0.canonicalName }).sorted() == [canonicalName])
            guard let sdk = registry.lookup(canonicalName) else {
                Issue.record("did not load SDK '\(canonicalName)'")
                return
            }
            #expect(sdk.headerSearchPaths == [sdkPath.join("usr/include")])
            #expect(sdk.librarySearchPaths == [sdkPath.join("usr/lib")])
            #expect(sdk.frameworkSearchPaths == [sdkPath.join("System/Library/PrivateFrameworks"), sdkPath.join("System/Library/Frameworks")])

            #expect(sdk.overrideSettings["MACOSX_DEPLOYMENT_TARGET"] == nil)
            #expect(sdk.overrideSettings["SOME_OTHER_SETTING"] == .plString("foo"))

            // Check the delegate issues.
            #expect(delegate.errors == [])
            // FIXME: <rdar://problem/34170562> Re-enable these checks when we want to warn about search paths an SDK declares which do not exist.
            //        XCTAssertEqual(delegate.warnings[0].0, "Sparse1.0.sdk")
            //        XCTAssertEqual(delegate.warnings[0].1, "header search path does not exist: " + sdkPath.join("usr/local/include").str)
            //        XCTAssertEqual(delegate.warnings[1].0, "Sparse1.0.sdk")
            //        XCTAssertEqual(delegate.warnings[1].1, "framework search path does not exist: " + sdkPath.join("Library/Frameworks").str)
            //        XCTAssertEqual(delegate.warnings[2].0, "Sparse1.0.sdk")
            //        XCTAssertEqual(delegate.warnings[2].1, "library search path does not exist: " + sdkPath.join("usr/local/lib").str)
            XCTAssertMatch(delegate.warnings, [.contains("Sparse1.0.sdk: setting 'MACOSX_DEPLOYMENT_TARGET' is not allowed in sparse SDK")])
        }
    }

    /// To match PBX: <rdar://problem/17907931> Improve SDK resolution to use versioned name when present as a symlink
    ///
    /// If you have:
    ///
    ///   X.sdk                 (directory)
    ///   Y.sdk  -> X.sdk       (symlink)
    ///   Z.sdk  -> X.sdk       (symlink)
    ///
    /// We should end up with:
    ///
    ///   - A total of one SDK, whose declared path is Y.sdk (we prefer symlinks and we register them in alphabetic order)
    ///   - Registry.lookup(X.sdk) -> Y.sdk
    ///   - Registry.lookup(Y.sdk) -> Y.sdk
    ///   - Registry.lookup(Z.sdk) -> Y.sdk
    ///
    /// In reality, PBX' behavior is more complicated, involving things like stringByStandardizingPath (which realpaths just the parent dir, removes certain known prefixes, and more), but we don't want to propagate that.
    @Test(.requireSDKs(.iOS))
    func symlink() async throws {
        let dirName = "iPhoneOS"
        let symName = "iPhoneOS11.0"
        let sym2Name = "jPhoneOS"

        try await withTemporaryDirectory { tmpDirPath in
            let sdksDir = tmpDirPath

            let dirPath = sdksDir.join(dirName + ".sdk")
            let symPath = sdksDir.join(symName + ".sdk")
            let sym2Path = sdksDir.join(sym2Name + ".sdk")

            let sdkSettings: PropertyListItem = .plDict([
                "CanonicalName": .plString("iphoneos11.0"),
            ])

            try localFS.createDirectory(dirPath)
            try localFS.write(dirPath.join("SDKSettings.plist"), contents: ByteString(sdkSettings.asBytes(.xml)))

            try localFS.symlink(symPath, target: Path(dirPath.basename))
            try localFS.symlink(sym2Path, target: Path(dirPath.basename))

            let registry: SDKRegistry = try await {
                final class TestDataDelegate : SDKRegistryDelegate {
                    let namespace = MacroNamespace()
                    let pluginManager: PluginManager

                    init(pluginManager: PluginManager) {
                        self.pluginManager = pluginManager
                    }

                    private let _diagnosticsEngine = DiagnosticsEngine()

                    var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
                        return .init(_diagnosticsEngine)
                    }

                    var diagnostics: [Diagnostic] {
                        _diagnosticsEngine.diagnostics
                    }

                    var platformRegistry: PlatformRegistry? {
                        nil
                    }
                }

                let delegate = TestDataDelegate(pluginManager: try await getCore().pluginManager)
                let registry = SDKRegistry(delegate: delegate, searchPaths: [(sdksDir, nil)], type: .builtin, hostOperatingSystem: try await getCore().hostOperatingSystem)
                #expect(delegate.diagnostics.isEmpty, "Unexpected diags: \(delegate.diagnostics)")
                return registry
            }()

            #expect(registry.allSDKs.count == 1)
            #expect(registry.lookup(dirPath)?.path == symPath)
            #expect(registry.lookup(symPath)?.path == symPath)
            #expect(registry.lookup(sym2Path)?.path == symPath)
        }
    }

    @Test
    func versionMap() async throws {
        try await withRegistryForTestInputs([
            ("boot.sdk", ["CanonicalName": "macosx"]),
        ]) { coreSDKRegistry, delegate, _ in

            // Create an SDK with custom build settings.
            try await withTemporaryDirectory { sdksDirPath in
                let sdkPath = sdksDirPath.join("TestSDK.sdk")
                let sdkIdentifier = "com.apple.sdk.1.0"
                try await writeSDK(name: sdkPath.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": .plString(sdkIdentifier),
                    "IsBaseSDK": "NO",
                    "VersionMap": [
                        "iOSMac_macOS": [
                            "13.0": "10.15",
                            "14.0": "11.0",
                        ],
                        "macOS_iOSMac": [
                            "10.15": "13.0"
                        ],
                        "f_x": [
                            "1": "3.4.2"
                        ]
                    ]
                ])
                let userNamespace = MacroNamespace()
                let registry = WorkspaceContextSDKRegistry(coreSDKRegistry: coreSDKRegistry, delegate: delegate, userNamespace: userNamespace, overridingSDKsDir: nil)

                // Looking up an external SDK by path also parses the build settings in it.
                let sdk = registry.lookup(sdkPath)
                #expect(sdk?.canonicalName == sdkIdentifier)

                let expected: [String:[Version:Version]] = [
                    "iOSMac_macOS": [
                        Version(13, 0): Version(10, 15),
                        Version(14, 0): Version(11, 0),
                    ],
                    "macOS_iOSMac": [
                        Version(10, 15): Version(13),
                    ],
                    "f_x": [
                        Version(1): Version(3, 4, 2),
                    ]
                ]

                #expect(sdk?.versionMap == expected)

                #expect(delegate.errors == [])
                #expect(delegate.warnings == [])
            }
        }
    }

    @Test
    func noVersionMap() async throws {
        try await withRegistryForTestInputs([
            ("boot.sdk", ["CanonicalName": "macosx"]),
        ]) { coreSDKRegistry, delegate, _ in

            // Create an SDK with custom build settings.
            try await withTemporaryDirectory { sdksDirPath in
                let sdkPath = sdksDirPath.join("TestSDK.sdk")
                let sdkIdentifier = "com.apple.sdk.1.0"
                try await writeSDK(name: sdkPath.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": .plString(sdkIdentifier),
                    "IsBaseSDK": "NO",
                ])
                let userNamespace = MacroNamespace()
                let registry = WorkspaceContextSDKRegistry(coreSDKRegistry: coreSDKRegistry, delegate: delegate, userNamespace: userNamespace, overridingSDKsDir: nil)

                // Looking up an external SDK by path also parses the build settings in it.
                let sdk = registry.lookup(sdkPath)
                #expect(sdk?.canonicalName == sdkIdentifier)
                #expect(sdk?.versionMap == [:])

                #expect(delegate.errors == [])
                #expect(delegate.warnings == [])
            }
        }
    }

    /// Tests that the macOS SDK knows which Mach-O platforms it's targeting.
    @Test(.requireSDKs(.macOS))
    func SDKBuildVersionPlatform_macOS() async throws {
        let realRegistry = try await getCore().sdkRegistry

        #expect(realRegistry.lookup("macosx")?.targetBuildVersionPlatform() == .macOS)
        #expect(realRegistry.lookup("macosx")?.targetBuildVersionPlatform(sdkVariant: realRegistry.lookup("macosx")?.variants["macos"]) == .macOS)
        #expect(realRegistry.lookup("macosx")?.targetBuildVersionPlatform(sdkVariant: realRegistry.lookup("macosx")?.variants[MacCatalystInfo.sdkVariantName]) == .macCatalyst)
    }

    /// Tests that the iOS SDK knows which Mach-O platforms it's targeting.
    @Test(.requireSDKs(.iOS))
    func SDKBuildVersionPlatform_iOS() async throws {
        let realRegistry = try await getCore().sdkRegistry

        #expect(realRegistry.lookup("iphoneos")?.targetBuildVersionPlatform() == .iOS)
        #expect(realRegistry.lookup("iphonesimulator")?.targetBuildVersionPlatform() == .iOSSimulator)
    }

    /// Tests that the tvOS SDK knows which Mach-O platforms it's targeting.
    @Test(.requireSDKs(.tvOS))
    func SDKBuildVersionPlatform_tvOS() async throws {
        let realRegistry = try await getCore().sdkRegistry

        #expect(realRegistry.lookup("appletvos")?.targetBuildVersionPlatform() == .tvOS)
        #expect(realRegistry.lookup("appletvsimulator")?.targetBuildVersionPlatform() == .tvOSSimulator)
    }

    /// Tests that the watchOS SDK knows which Mach-O platforms it's targeting.
    @Test(.requireSDKs(.watchOS))
    func SDKBuildVersionPlatform_watchOS() async throws {
        let realRegistry = try await getCore().sdkRegistry

        #expect(realRegistry.lookup("watchos")?.targetBuildVersionPlatform() == .watchOS)
        #expect(realRegistry.lookup("watchsimulator")?.targetBuildVersionPlatform() == .watchOSSimulator)
    }

    /// Tests that the visionOS SDK knows which Mach-O platforms it's targeting.
    @Test(.requireSDKs(.xrOS))
    func SDKBuildVersionPlatform_visionOS() async throws {
        let realRegistry = try await getCore().sdkRegistry

        #expect(realRegistry.lookup("xros")?.targetBuildVersionPlatform() == .xrOS)
        #expect(realRegistry.lookup("xrsimulator")?.targetBuildVersionPlatform() == .xrOSSimulator)
    }


    /// Tests that the DriverKit SDK knows which Mach-O platform it's targeting.
    @Test(.requireSDKs(.driverKit))
    func SDKBuildVersionPlatform_DriverKit() async throws {
        let realRegistry = try await getCore().sdkRegistry

        #expect(realRegistry.lookup("driverkit")?.targetBuildVersionPlatform() == .driverKit)
    }
}
