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

import SWBProtocol
import SWBTestSupport
@_spi(Testing) import SWBUtil
import SWBMacro
@_spi(Testing) import SWBCore

@Suite fileprivate struct SettingsTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func projectBasics() async throws {
        let core = try await getCore()

        // Test the basic settings construction for a trivial test project.
        let files: [Path: String] = [
            // The paths and includes in these .xcconfigs are devised to test searching the includer’s directory in addition to relative paths.
            .root.join("tmp/xcconfigs/Base0.xcconfig"): (
                "XCCONFIG_USER_SETTING = from-xcconfig\n"),
            .root.join("tmp/xcconfigs/Base1.xcconfig"): (
                "#include \"Base0.xcconfig\""),
            .root.join("tmp/Test.xcconfig"): (
                "#include \"xcconfigs/Base1.xcconfig\"\n" +
                "XCCONFIG_HEADER_SEARCH_PATHS = /tmp/path /tmp/other-path\n"
            )]
        let testWorkspace = try TestWorkspace("Workspace",
                                              projects: [
                                                TestProject("aProject",
                                                            groupTree: TestGroup("SomeFiles",
                                                                                 children: [TestFile(Path.root.join("tmp/Test.xcconfig").str)]),
                                                            buildConfigurations:[
                                                                TestBuildConfiguration("Config1", baseConfig: "Test.xcconfig", buildSettings: [
                                                                    "USER_PROJECT_SETTING": "USER_PROJECT_VALUE",
                                                                    "OTHER_CFLAGS[arch=*]": "-Wall",
                                                                    "OTHER_CFLAGS": "this value should be shadowed",
                                                                    "HEADER_SEARCH_PATHS": "$(inherited) $(SRCROOT)/include $(XCCONFIG_HEADER_SEARCH_PATHS)"
                                                                ])
                                                            ],
                                                            appPreferencesBuildSettings: [
                                                                "APP_PREF_SETTING": "APP_PREF_VALUE",
                                                            ]
                                                           )
                                              ]
        ).load(core)

        // Construct a mock environment.
        let environment = [
            "ENV_VAR": "ENV_VAR Value",
            "WEIRD_VAR[notacondition]okay": "weird value",
        ]

        let context = try await contextForTestData(testWorkspace, environment: environment, files: files)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject)
        #expect(settings.project === testProject)
        #expect(settings.target === nil)
        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        // Verify that the environment was added.
        let ENV_VAR = try #require(settings.userNamespace.lookupMacroDeclaration("ENV_VAR"))
        #expect(settings.tableForTesting.lookupMacro(ENV_VAR)?.expression.stringRep == "ENV_VAR Value")
        let WEIRD_VAR = try #require(settings.userNamespace.lookupMacroDeclaration("WEIRD_VAR[notacondition]okay"))
        #expect(settings.tableForTesting.lookupMacro(WEIRD_VAR)?.expression.stringRep == "weird value")

        // Verify that the command line tool defaults were added.
        let swiftModuleNameMacro = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("SWIFT_MODULE_NAME"))
        #expect(settings.tableForTesting.lookupMacro(swiftModuleNameMacro)?.expression.stringRep == "$(PRODUCT_MODULE_NAME)")

        // Verify that neither OutputFormat nor OutputPath were set.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.OutputFormat) === nil)
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.OutputPath) === nil)

        // Verify that the computed path defaults were added.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.DEVELOPER_DIR)?.expression.stringRep == core.developerPath.path.str)
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.AVAILABLE_PLATFORMS)?.expression.stringRep.contains("macosx") == true)

        // Verify that the CACHE_ROOT was added.
        let cacheRootMacro = try #require(settings.tableForTesting.lookupMacro(BuiltinMacros.CACHE_ROOT))
        #expect(cacheRootMacro.expression.stringRep.hasPrefix("/var/folders"))

        // Verify that the correct target-specific build system default settings were added.
        //
        // FIXME: This definition is always overridden by the project dynamic settings, so it is isn't clear it ever is used.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.CONFIGURATION_BUILD_DIR)?.next?.expression.stringRep == "$(BUILD_DIR)")

        let VERSION_INFO_FILE = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("VERSION_INFO_FILE"))
        #expect(settings.tableForTesting.lookupMacro(VERSION_INFO_FILE)?.expression.stringRep == "")

        // Verify that the project dynamic settings were added.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PROJECT_NAME)?.expression.stringRep == "aProject")
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SRCROOT)?.expression.stringRep.hasSuffix("/aProject") == true)
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PROJECT_TEMP_DIR)?.expression.stringRep == "$(OBJROOT)/$(PROJECT_NAME).build")
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.CONFIGURATION)?.expression.stringRep == "Config1")
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.CONFIGURATION_BUILD_DIR)?.expression.stringRep == "$(BUILD_DIR)/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)")
#if !RC_PLAYGROUNDS
        func checkXcodeVersion(_ settingName: StringMacroDeclaration, expectedVersion: Version, sourceLocation: SourceLocation = #_sourceLocation) {
            if let value = settings.tableForTesting.lookupMacro(settingName)?.expression.stringRep {
                if value.count >= 4, let uintValue = UInt(value) {
                    let version = Version(uintValue / 100, (uintValue % 100) / 10, uintValue % 10)
                    #expect(version == expectedVersion, sourceLocation: sourceLocation)
                } else {
                    Issue.record("Unexpected value for \(settingName.name): \(value)", sourceLocation: sourceLocation)
                }
            } else {
                Issue.record("\(settingName.name) is undefined", sourceLocation: sourceLocation)
            }
        }
        checkXcodeVersion(BuiltinMacros.XCODE_VERSION_MAJOR, expectedVersion: core.xcodeVersion.normalized(toNumberOfComponents: 1))
        checkXcodeVersion(BuiltinMacros.XCODE_VERSION_MINOR, expectedVersion: core.xcodeVersion.normalized(toNumberOfComponents: 2))
        checkXcodeVersion(BuiltinMacros.XCODE_VERSION_ACTUAL, expectedVersion: core.xcodeVersion)
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.XCODE_PRODUCT_BUILD_VERSION)?.expression.stringRep == core.xcodeProductBuildVersionString)
#endif
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.USER)?.expression.stringRep == "exampleUser")

        // Verify that the settings from the xcconfig were added.
        let XCCONFIG_USER_SETTING = try #require(settings.userNamespace.lookupMacroDeclaration("XCCONFIG_USER_SETTING"))
        #expect(settings.tableForTesting.lookupMacro(XCCONFIG_USER_SETTING)?.expression.stringRep == "from-xcconfig")

        // Verify the user project settings.
        let USER_PROJECT_SETTING = try #require(settings.userNamespace.lookupMacroDeclaration("USER_PROJECT_SETTING"))
        #expect(settings.tableForTesting.lookupMacro(USER_PROJECT_SETTING)?.expression.stringRep == "USER_PROJECT_VALUE")
        let headerSearchPaths = settings.globalScope.evaluate(BuiltinMacros.HEADER_SEARCH_PATHS)
        #expect(headerSearchPaths == ["/tmp/Workspace/aProject/include", "/tmp/path", "/tmp/other-path"])
        let otherCFlags = settings.globalScope.evaluate(BuiltinMacros.OTHER_CFLAGS)
        #expect(otherCFlags == ["-Wall"])

        // Verify the application preferences build settings.
        let APP_PREF_SETTING = try #require(settings.userNamespace.lookupMacroDeclaration("APP_PREF_SETTING"))
        #expect(settings.tableForTesting.lookupMacro(APP_PREF_SETTING)?.expression.stringRep == "APP_PREF_VALUE")

        // Verify that the platform settings were added.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PLATFORM_NAME)?.expression.stringRep.hasPrefix("macosx") == true)
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PLATFORM_FAMILY_NAME)?.expression.stringRep == "macOS")
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PLATFORM_DISPLAY_NAME)?.expression.stringRep == "macOS")
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.EFFECTIVE_PLATFORM_NAME)?.expression.stringRep == "")
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.EFFECTIVE_PLATFORM_SUFFIX)?.expression.stringRep == "os")
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PLATFORM_DIR)?.expression.stringRep.contains("MacOSX.platform") == true)
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SUPPORTED_PLATFORMS)?.expression.stringRep == "macosx")
        let ARCHS_STANDARD = try #require(settings.userNamespace.lookupMacroDeclaration("ARCHS_STANDARD"))
        #expect(settings.tableForTesting.lookupMacro(ARCHS_STANDARD)?.expression.stringRep == "arm64 x86_64")
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.VALID_ARCHS)?.expression.stringRep.contains("i386 x86_64") == true)
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PLATFORM_PREFERRED_ARCH)?.expression.stringRep == "x86_64")

        // Verify that the SDK settings were added.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_NAME)?.expression.stringRep.hasPrefix("macosx") == true)
        let sdkVersionString = try #require(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION))
        #expect(try Version(sdkVersionString.expression.stringRep) >= Version(10, 9))

        // Verify that the toolchain settings were added.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.TOOLCHAIN_DIR)?.expression.stringRep.hasSuffix("XcodeDefault.xctoolchain") == true)

        // Verify that the global overrides were added.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.DERIVED_DATA_DIR)?.expression.stringRep.hasPrefix("/var/folders") == true)
        // This setting is explicitly cleared.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MODULE_CACHE_DIR)?.expression.stringRep == "")

        // check the exported macro names.
        #expect(settings.exportedMacroNames.contains(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET))
        #expect(settings.exportedMacroNames.contains(BuiltinMacros.CACHE_ROOT))
        #expect(settings.exportedMacroNames.contains(BuiltinMacros.PROJECT_NAME))
        #expect(settings.exportedNativeMacroNames.contains(BuiltinMacros.SDK_NAME))

        #expect(!settings.exportedMacroNames.contains(BuiltinMacros.DERIVED_DATA_DIR))
        #expect(!settings.exportedNativeMacroNames.contains(BuiltinMacros.DERIVED_DATA_DIR))

        // check the global scope.
        let result = settings.globalScope.evaluate(BuiltinMacros.PROJECT_NAME)
        #expect(result == "aProject")

        var xcconfigPath: Path
        var scope: MacroEvaluationScope
        var macro: MacroDeclaration

        // Verify that changes to XCConfigs are being picked up
        xcconfigPath = Path.root.join("tmp/Test.xcconfig")
        scope = MacroEvaluationScope(table: buildRequestContext.getCachedMacroConfigFile(xcconfigPath, project: testProject, context: .baseConfiguration).table)
        macro = try #require(scope.namespace.lookupMacroDeclaration("XCCONFIG_HEADER_SEARCH_PATHS"))
        #expect(scope.evaluateAsString(macro) == "/tmp/path /tmp/other-path")

        try context.fs.write(xcconfigPath,
                             contents: ByteString(encodingAsUTF8:   "#include \"xcconfigs/Base1.xcconfig\"\n" +
                                                  "XCCONFIG_HEADER_SEARCH_PATHS = /tmp/changed\n"))

        do {
            let buildRequestContext = BuildRequestContext(workspaceContext: context)

            scope = MacroEvaluationScope(table: buildRequestContext.getCachedMacroConfigFile(xcconfigPath, project: testProject, context: .baseConfiguration).table)
            #expect(scope.evaluateAsString(macro) == "/tmp/changed")
        }

        // Verify that missing XCConfigs will be picked up once they appear
        xcconfigPath = Path.root.join("tmp/Other.xcconfig")
        #expect(buildRequestContext.getCachedMacroConfigFile(xcconfigPath, project: testProject, context: .baseConfiguration).diagnostics.map { $0.formatLocalizedDescription(.debug) } == ["/tmp/Workspace/aProject/aProject.xcodeproj: error: Unable to open base configuration reference file '/tmp/Other.xcconfig'."])

        try context.fs.write(xcconfigPath,
                             contents: ByteString(encodingAsUTF8:   "#include \"xcconfigs/Base1.xcconfig\"\n" +
                                                  "XCCONFIG_HEADER_SEARCH_PATHS = /tmp/changed\n"))

        do {
            let buildRequestContext = BuildRequestContext(workspaceContext: context)

            scope = MacroEvaluationScope(table: buildRequestContext.getCachedMacroConfigFile(xcconfigPath, project: testProject, context: .baseConfiguration).table)
            macro = try #require(scope.namespace.lookupMacroDeclaration("XCCONFIG_HEADER_SEARCH_PATHS"))
            #expect(scope.evaluateAsString(macro) == "/tmp/changed")
        }
    }

    @Test(.requireSDKs(.macOS))
    func standardTargetBasics() async throws {
        let core = try await getCore()
        try await withTemporaryDirectory { (sdksDirPath: Path) in
            let additionalSDKPath = sdksDirPath.join("TestSDK.sdk")
            try await writeSDK(name: additionalSDKPath.basename, parentDir: sdksDirPath, settings: [
                "CanonicalName": "com.apple.sdk.1.0",
                "IsBaseSDK": "NO",
            ])

            // Test the basic settings construction for a trivial test target.
            let testWorkspace = try TestWorkspace("Workspace",
                                                  projects: [TestProject("aProject",
                                                                         groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                         buildConfigurations:[
                                                                            TestBuildConfiguration("Config1", buildSettings: [
                                                                                "USER_PROJECT_SETTING": "USER_PROJECT_VALUE",
                                                                                "HEADER_SEARCH_PATHS": "$(inherited) $(SRCROOT)/include /usr/include .",
                                                                                "FRAMEWORK_SEARCH_PATHS": "$(inherited) /System/Library/Frameworks /Applications/Xcode.app /usr",
                                                                                "OTHER_LDFLAGS": "-current_version $(DYLIB_CURRENT_VERSION)",
                                                                                "GCC_PREFIX_HEADER": "/Cocoa.pch",
                                                                                "ADDITIONAL_SDKS": "\(additionalSDKPath.str)",
                                                                                "ARCHS": "x86_64 x86_64h",
                                                                                "RC_ARCHS": "x86_64 x86_64h",
                                                                                "VALID_ARCHS": "$(inherited) x86_64h",
                                                                            ])],
                                                                         targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Config1", buildSettings: [
                                                                                                    "BUILD_VARIANTS": "normal other",
                                                                                                    "ENABLE_TESTABILITY": "YES",
                                                                                                    "INSTALL_PATH": "",
                                                                                                    // Use this to check conditions end to end.
                                                                                                    "PRODUCT_NAME[sdk=macosx*]": "Foo",
                                                                                                    "USER_TARGET_SETTING": "USER_TARGET_VALUE"])],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(core)
            let context = try await contextForTestData(testWorkspace,
                files: [
                    core.loadSDK(.macOS).path.join("Cocoa.pch"): "",
                    core.loadSDK(.macOS).path.join("System/Library/Frameworks/mock.txt"): "",
                    core.loadSDK(.macOS).path.join("usr/include/mock.txt"): "",
                    additionalSDKPath.join("Applications/Xcode.app/mock.txt"): "",
                    additionalSDKPath.join("usr/mock.txt"): "",
                ]
            )
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            var settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

            // There should be no diagnostics.
            #expect(settings.warnings == [])
            #expect(settings.errors == [])

            // Verify that the global scope has the expected conditions (sdk and config).
            #expect(Set(settings.globalScope.conditionParameterValues.keys) == Set([BuiltinMacros.sdkCondition, BuiltinMacros.configurationCondition, BuiltinMacros.sdkBuildVersionCondition]))

            // Verify that the target configuration was captured.  Notice that this is *not* the configuration the build parameters were configured with.
            #expect(settings.targetConfiguration?.name == "Config1")
            #expect(settings.targetConfiguration?.name != parameters.configuration)

            // Verify that the environment settings work properly.
            #expect(settings.globalScope.evaluate(BuiltinMacros.RC_ARCHS) == ["x86_64", "x86_64h"])

            // Verify that the defaults from additional specs were added.
            let EMBEDDED_CONTENT_CONTAINS_SWIFT = try #require(settings.userNamespace.lookupMacroDeclaration("EMBEDDED_CONTENT_CONTAINS_SWIFT"))
            #expect(settings.tableForTesting.lookupMacro(EMBEDDED_CONTENT_CONTAINS_SWIFT)?.expression.stringRep == "NO")

            let ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = try #require(settings.userNamespace.lookupMacroDeclaration("ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"))
            #expect(settings.tableForTesting.lookupMacro(ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES)?.expression.stringRep == "$(EMBEDDED_CONTENT_CONTAINS_SWIFT)")

            // Verify that all the deployment target settings were added.
            let IPHONEOS_DEPLOYMENT_TARGET = try #require(settings.userNamespace.lookupMacroDeclaration("IPHONEOS_DEPLOYMENT_TARGET"))
            #expect(settings.tableForTesting.lookupMacro(IPHONEOS_DEPLOYMENT_TARGET)?.expression.stringRep != "")

            // Verify that the correct target-specific build system default settings were added.
            let VERSION_INFO_FILE = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("VERSION_INFO_FILE"))
            #expect(settings.tableForTesting.lookupMacro(VERSION_INFO_FILE)?.expression.stringRep == "$(PRODUCT_NAME)_vers.c")

            // Verify that the target "dynamic" settings were added.
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.TARGET_NAME)?.expression.stringRep == "Target1")
            let USER_TARGET_SETTING = try #require(settings.userNamespace.lookupMacroDeclaration("USER_TARGET_SETTING"))
            #expect(settings.tableForTesting.lookupMacro(USER_TARGET_SETTING)?.expression.stringRep == "USER_TARGET_VALUE")

            // Verify that the product and package settings were added (they will have overwritten the previous definition).
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.INSTALL_PATH)?.next?.expression.stringRep == nil)
            let EXECUTABLE_PATH = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("EXECUTABLE_PATH"))
            #expect(settings.tableForTesting.lookupMacro(EXECUTABLE_PATH)?.expression.stringRep == "$(EXECUTABLE_FOLDER_PATH)/$(EXECUTABLE_NAME)")
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PACKAGE_TYPE)?.expression.stringRep == "com.apple.package-type.wrapper.application")

            // Verify that the "target task" overrides were added.
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.ACTION)?.expression.stringRep == "build")
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SEPARATE_SYMBOL_EDIT)?.expression.stringRep == "NO")
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.GCC_SYMBOLS_PRIVATE_EXTERN)?.expression.stringRep == "NO")
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.LLVM_LTO)?.expression.stringRep == "NO")
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SKIP_INSTALL)?.expression.stringRep == "YES")
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.STRIP_INSTALLED_PRODUCT)?.expression.stringRep == "NO")

            // Verify the SDK path and other settings which are interesting to verify for the macOS SDK.
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDKROOT)?.expression.stringRep == core.loadSDK(.macOS).path.str)
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.DEVELOPER_SDK_DIR)?.expression.stringRep == core.loadSDK(.macOS).path.dirname.str)
            #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PLATFORM_DEVELOPER_SDK_DIR)?.expression.stringRep == "$(DEVELOPER_SDK_DIR)")

            // Verify that we rewrote the SDK into certain paths.
            #expect(settings.globalScope.evaluate(BuiltinMacros.HEADER_SEARCH_PATHS) == ["/tmp/Workspace/aProject/build/Config1/include", "/tmp/Workspace/aProject/include", core.loadSDK(.macOS).path.join("usr/include").str, "."])

            #expect(settings.globalScope.evaluate(BuiltinMacros.FRAMEWORK_SEARCH_PATHS) == [
                "/tmp/Workspace/aProject/build/Config1",

                // Paths found in SDKROOT get prefixed
                core.loadSDK(.macOS).path.join("System/Library/Frameworks").str,

                // Paths found in additional SDKs get mentioned twice: once prefixed and once as is
                additionalSDKPath.join("Applications/Xcode.app").str,
                "/Applications/Xcode.app",

                // Paths found in both SDKROOT and additional SDKs get mentioned twice: once prefixed with the additional SDK and once prefixed with the SDKROOT
                additionalSDKPath.join("usr").str,
                core.loadSDK(.macOS).path.join("usr").str,
            ])

            #expect(settings.globalScope.evaluate(BuiltinMacros.GCC_PREFIX_HEADER) == core.loadSDK(.macOS).path.join("Cocoa.pch"))

            // Check that we resolved toolchains paths.
            #expect(settings.globalScope.evaluate(BuiltinMacros.EFFECTIVE_TOOLCHAINS_DIRS) == (core.toolchainRegistry.defaultToolchain?.path.str).map { [$0] } ?? [])

            // Check that we set up the LINK_FILE_LIST_... macros.
            #expect(settings.tableForTesting.lookupMacro(try #require(settings.userNamespace.lookupMacroDeclaration("LINK_FILE_LIST_normal_x86_64")))?.expression.stringRep == "$(OBJECT_FILE_DIR)-normal/x86_64/$(PRODUCT_NAME).LinkFileList")

            // Check that we set up the SWIFT_RESPONSE_FILE_PATH_... macros
            #expect(settings.tableForTesting.lookupMacro(try #require(settings.userNamespace.lookupMacroDeclaration("SWIFT_RESPONSE_FILE_PATH_normal_x86_64")))?.expression.stringRep == "$(OBJECT_FILE_DIR)-normal/x86_64/$(PRODUCT_NAME).SwiftFileList")

            // Verify that the 'variant' and 'arch' settings were set up properly.
            #expect(settings.globalScope.evaluate(BuiltinMacros.BUILD_VARIANTS) == ["normal", "other"])
            #expect(settings.globalScope.evaluate(BuiltinMacros.ARCHS) == ["x86_64", "x86_64h"])
            #expect(settings.globalScope.evaluate(BuiltinMacros.variant) == "normal")
            #expect(settings.globalScope.evaluate(BuiltinMacros.arch) == "undefined_arch")
            let variantScope = settings.globalScope.subscope(binding: BuiltinMacros.variantCondition, to: "other")
            #expect(variantScope.evaluate(BuiltinMacros.variant) == "other")
            let archScope = settings.globalScope.subscope(binding: BuiltinMacros.archCondition, to: "x86_64")
            #expect(archScope.evaluate(BuiltinMacros.arch) == "x86_64")

            // Verify that the appropriate extra exports were added.
            #expect(settings.exportedMacroNames.contains(BuiltinMacros.TARGET_NAME))

            // Verify that "install"/"archive" actions behaves as expected.
            for action in [BuildAction.install, BuildAction.archive] {
                let context2 = try await contextForTestData(testWorkspace,
                                                            environment: [:],
                                                            files: [
                                                                core.loadSDK(.macOS).path.join("Cocoa.pch"): "",
                                                                core.loadSDK(.macOS).path.join("System/Library/Frameworks/mock.txt"): "",
                                                            ])
                let parameters2 = BuildParameters(action: action, configuration: "Debug")
                settings = Settings(workspaceContext: context2, buildRequestContext: buildRequestContext, parameters: parameters2, project: testProject, target: testTarget)
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.ACTION)?.expression.stringRep == action.actionName)
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.DEPLOYMENT_LOCATION)?.expression.stringRep == "YES")

                // Verify that the product location overrides were set properly (they will have overwritten the previous definition).
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.TARGET_BUILD_DIR)?.expression.stringRep == "$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)$(TARGET_BUILD_SUBPATH)")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.TARGET_BUILD_DIR)?.next?.expression.stringRep == "$(CONFIGURATION_BUILD_DIR)$(TARGET_BUILD_SUBPATH)")

                // Verify that the input paths were normalized.
                //
                // FIXME: This only happens for targets, which is confusing and inconsistent.
                if let project = settings.project {
                    #expect(settings.globalScope.evaluate(BuiltinMacros.OBJROOT) == Path("\(project.sourceRoot.str)/build"))
                    #expect(settings.globalScope.evaluate(BuiltinMacros.CONFIGURATION_BUILD_DIR) == Path("\(project.sourceRoot.str)/build/Config1"))
                    #expect(settings.globalScope.evaluate(BuiltinMacros.CLANG_EXPLICIT_MODULES_OUTPUT_PATH) == "\(project.sourceRoot.str)/build/ExplicitPrecompiledModules")
                }

                // check that we get the right value for VERSION_INFO_STRING, which validates we parsed it correctly.
                let VERSION_INFO_STRING = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("VERSION_INFO_STRING") as? StringMacroDeclaration)
                let result: String = settings.globalScope.evaluate(VERSION_INFO_STRING)
                #expect(result == "\"@(#)PROGRAM:Foo  PROJECT:aProject-\"")

                // check handle of empty default macro assignments inside list evaluation (rdar://problem/24786941).
                #expect(settings.globalScope.evaluate(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("OTHER_LDFLAGS") as? StringListMacroDeclaration)) == ["-current_version", ""])

                // check target task overrides.
                #expect(settings.globalScope.evaluate(BuiltinMacros.ACTION) == action.actionName)
                #expect(settings.globalScope.evaluate(BuiltinMacros.BUILD_COMPONENTS) == ["headers", "build"])
                #expect(settings.globalScope.evaluate(BuiltinMacros.GCC_VERSION) == "com.apple.compilers.llvm.clang.1_0")

                // Check build system defaults are exported.
                #expect(settings.exportedMacroNames.contains(BuiltinMacros.ALTERNATE_MODE))
                #expect(settings.exportedMacroNames.contains(BuiltinMacros.ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES))
                #expect(settings.exportedMacroNames.contains(BuiltinMacros.EMBEDDED_CONTENT_CONTAINS_SWIFT))
                #expect(settings.exportedMacroNames.contains(BuiltinMacros.VERSION_INFO_FILE))
                #expect(settings.exportedMacroNames.contains(BuiltinMacros.YACC))
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func iOSStandardTargetBasics() async throws {
        let core = try await getCore()

        // Test the basic settings construction for a trivial test target.
        let testWorkspace = try TestWorkspace("Workspace",
                                              projects: [TestProject("aProject",
                                                                     groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                     targets: [
                                                                        TestStandardTarget("Target1",
                                                                                           type: .application,
                                                                                           buildConfigurations: [
                                                                                            TestBuildConfiguration("Debug",
                                                                                                                   buildSettings: [
                                                                                                                    "SDKROOT": "iphoneos",

                                                                                                                    "IPHONEOS_SETTING[sdk=iphoneos*]": "correct",
                                                                                                                    "IPHONESIM_SETTING[sdk=iphonesimulator*]": "correct",
                                                                                                                    "EMBEDDED_SETTING[sdk=embedded*]": "correct",
                                                                                                                    // These are disabled because at the moment we don't enforce ordering of 'iphoneos' over 'embedded', so the success of evaluating this setting is not guaranteed.
                                                                                                                    //                                    "UNIFIED_SETTING[sdk=iphoneos*]": "iphoneos",
                                                                                                                    //                                    "UNIFIED_SETTING[sdk=embedded*]": "embedded",
                                                                                                                   ])],
                                                                                           buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(core)
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        let scope = settings.globalScope

        // Verify the SDK path and other settings which are interesting to verify for the macOS SDK.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDKROOT)?.expression.stringRep == core.loadSDK(.iOS).path.str)
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.DEVELOPER_SDK_DIR)?.expression.stringRep == core.loadSDK(.macOS).path.dirname.str)
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.PLATFORM_DEVELOPER_SDK_DIR)?.expression.stringRep == core.loadSDK(.iOS).path.dirname.str)

        // Validate the conditional settings.
        #expect(scope.evaluateAsString(try #require(settings.userNamespace.lookupMacroDeclaration("IPHONEOS_SETTING"))) == "correct")
        #expect(scope.evaluateAsString(try #require(settings.userNamespace.lookupMacroDeclaration("IPHONESIM_SETTING"))) == "")
        #expect(scope.evaluateAsString(try #require(settings.userNamespace.lookupMacroDeclaration("EMBEDDED_SETTING"))) == "correct")
    }

    @Test(.requireSDKs(.macOS))
    func bogusSupportedPlatforms() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: [
                                                                                                                        "SDKROOT": "macosx",
                                                                                                                        "ONLY_ACTIVE_ARCH": "YES",
                                                                                                                        "SUPPORTED_PLATFORMS": "macOS fakeOS"
                                                                                                                       ])],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macOS)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
        #expect(settings.errors == [])
        #expect(settings.warnings == ["Did not find any platform for SUPPORTED_PLATFORMS 'macOS, fakeOS'"])
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func deploymentTargetFallback() async throws {
        // Test the basic settings construction for a trivial test target.
        let core = try await getCore()
        let testWorkspace = try TestWorkspace("Workspace",
                                              projects: [TestProject("aProject",
                                                                     groupTree: TestGroup("SomeFiles", children: [
                                                                        TestFile("Mock.cpp")
                                                                     ]),
                                                                     targets: [
                                                                        TestStandardTarget("macOSTarget",
                                                                                           type: .application,
                                                                                           buildConfigurations: [
                                                                                            TestBuildConfiguration("Debug",
                                                                                                                   buildSettings: [
                                                                                                                    "SDKROOT": "macosx",
                                                                                                                    "MACOSX_DEPLOYMENT_TARGET": "",
                                                                                                                    "IPHONEOS_DEPLOYMENT_TARGET": "",
                                                                                                                   ])],
                                                                                           buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])]),
                                                                        TestStandardTarget("iOSTarget",
                                                                                           type: .application,
                                                                                           buildConfigurations: [
                                                                                            TestBuildConfiguration("Debug",
                                                                                                                   buildSettings: [
                                                                                                                    "SDKROOT": "iphoneos",
                                                                                                                    "MACOSX_DEPLOYMENT_TARGET": "",
                                                                                                                    "IPHONEOS_DEPLOYMENT_TARGET": "",
                                                                                                                   ])],
                                                                                           buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])]),
                                                                     ])]).load(core)
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let macOSTestTarget = testProject.targets[0]
        let iOSTestTarget = testProject.targets[1]

        let buildParameters = BuildParameters(action: .build, configuration: "Debug")
        let macOSTargetSettings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: buildParameters, project: testProject, target: macOSTestTarget)
        let iOSTargetSettings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: buildParameters, project: testProject, target: iOSTestTarget)

        // Check that overriding the deployment target with the empty string results in the default value for the SDK.

        #expect(macOSTargetSettings.globalScope.evaluateAsString(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET) == core.loadSDK(.macOS).defaultDeploymentTarget)
        #expect(macOSTargetSettings.globalScope.evaluateAsString(BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET) == "")
        #expect(iOSTargetSettings.globalScope.evaluateAsString(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET) == "")
        #expect(iOSTargetSettings.globalScope.evaluateAsString(BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET) == core.loadSDK(.iOS).defaultDeploymentTarget)
    }

    @Test(.requireSDKs(.macOS))
    func aggregateTargetBasics() async throws {
        let core = try await getCore()

        // Test the basic settings construction for an aggregate test target.
        let testWorkspace = try TestWorkspace("Workspace",
                                              projects: [TestProject(
                                                "aProject",
                                                groupTree: TestGroup("SomeFiles"),
                                                buildConfigurations:[
                                                    TestBuildConfiguration("TargetConfig",
                                                                           buildSettings: [
                                                                            "SDKROOT": "macosx",
                                                                           ]),
                                                ],
                                                targets: [
                                                    TestAggregateTarget("AggregateTarget1",
                                                                        buildConfigurations: [
                                                                            TestBuildConfiguration("TargetConfig"),
                                                                        ]),
                                                ]),
                                              ]).load(core)
        let testProject = testWorkspace.projects[0]
        let testTarget = testProject.targets[0]

        let context = try await contextForTestData(testWorkspace, environment: ["INSTALLED_PRODUCT_ASIDES": "YES", "USE_PER_CONFIGURATION_BUILD_LOCATIONS": "NO"])
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let parameters = BuildParameters(action: .install, configuration: "TargetConfig")
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        // Verify that the toolchains are correct.
        #expect(settings.toolchains == [core.coreSettings.defaultToolchain])

        // Aggregate targets' settings are substantially similar to standard targets, but it is common for certain values to not be defined for aggregate targets.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.TARGET_NAME)?.expression.stringRep == "AggregateTarget1")

        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDKROOT)?.expression.stringRep.hasPrefix(try context.fs.realpath(core.developerPath.path).str) == true)

        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.TARGET_BUILD_DIR)?.expression.stringRep == "$(UNINSTALLED_PRODUCTS_DIR)$(TARGET_BUILD_SUBPATH)")
        // Subsequent definitions will have overwritten the previous definition.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.TARGET_BUILD_DIR)?.next?.next?.expression.stringRep == "$(CONFIGURATION_BUILD_DIR)$(TARGET_BUILD_SUBPATH)")
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.CONFIGURATION_TEMP_DIR)?.next?.next?.expression.stringRep == nil)

        // This setting is always overridden by the project defaults.
        #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.CONFIGURATION_BUILD_DIR)?.next?.next?.expression.stringRep == nil)

        // Check that the correct build system defaults are exported (should be the native ones).
        #expect(settings.exportedMacroNames.contains(BuiltinMacros.YACC))
    }


    @Test(.requireHostOS(.macOS))
    func executablePaths() async throws {
        let core = try await getCore()
        // Check that we locate executables in the right places.
        let testWorkspaceData = TestWorkspace("Workspace",
                                              projects: [
                                                TestProject("aProject",
                                                            groupTree: TestGroup("SomeFiles"),
                                                            targets: [
                                                                TestAggregateTarget("AggregateTarget")])])
        // We test against the actual FS, to check the real executable paths.
        let context = WorkspaceContext(core: core, workspace: try testWorkspaceData.load(core), fs: SWBUtil.localFS, processExecutionCache: .sharedForTesting)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        // Check we can find clang in the toolchain.
        #expect(settings.executableSearchPaths.lookup(Path("clang")) == core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"))

        // Check that we find ibtool outside the toolchain.
        #expect(settings.executableSearchPaths.lookup(Path("ibtool")) == core.developerPath.path.join("usr/bin/ibtool"))

        // Check the paths directly.
        let paths = settings.executableSearchPaths.paths
        let toolchainPathIndex = paths.firstIndex(of: core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/bin")) ?? Int.max
        let platformPathIndex = paths.firstIndex(of: core.developerPath.path.join("Platforms/MacOSX.platform/usr/bin")) ?? Int.max
        let developerLocalBinIndex = paths.firstIndex(of: core.developerPath.path.join("usr/local/bin")) ?? Int.max
        let developerBinIndex = paths.firstIndex(of: core.developerPath.path.join("usr/bin")) ?? Int.max
        #expect(toolchainPathIndex < platformPathIndex)
        #expect(platformPathIndex < developerBinIndex)
        #expect(developerBinIndex < developerLocalBinIndex)
    }

    /// Check the handling of the various override mechanisms.
    @Test
    func settingOverrides() async throws {
        try await withTemporaryDirectory { tmpDir async throws -> Void in
            let testWorkspace = try await TestWorkspace("Workspace",
                                                        projects: [
                                                            TestProject("aProject",
                                                                        groupTree: TestGroup("SomeFiles"),
                                                                        buildConfigurations: [
                                                                            TestBuildConfiguration("Debug", buildSettings: [
                                                                                "BAZ": "project-$(inherited)"])],
                                                                        targets: [
                                                                            TestAggregateTarget("AggregateTarget",
                                                                                                buildConfigurations: [
                                                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                                                        "BAZ": "target-$(inherited)"])])])]).load(getCore())
            let context = try await contextForTestData(testWorkspace, environment: ["BAZ": "environment-$(inherited)"])
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            try context.fs.createDirectory(tmpDir, recursive: true)

            let cliPath = tmpDir.join("cliPath.xcconfig")
            try context.fs.write(cliPath, contents: "BAZ = commandlineconfig-$(inherited)-fromfile")

            let envPath = tmpDir.join("envPath.xcconfig")
            try context.fs.write(envPath, contents: "BAZ = environmentconfig-$(inherited)-fromfile")

            let parameters = BuildParameters(
                action: .build,
                configuration: "Debug",
                overrides: ["BAZ": "overrides-$(inherited)"],
                commandLineOverrides: ["BAZ": "commandline-$(inherited)"],
                commandLineConfigOverridesPath: cliPath,
                commandLineConfigOverrides: ["BAZ": "commandlineconfig-$(inherited)"],
                environmentConfigOverridesPath: envPath,
                environmentConfigOverrides: ["BAZ": "environmentconfig-$(inherited)"])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

            let diagnosticErrors = settings.diagnostics.filter { $0.behavior == .error }
            guard diagnosticErrors.isEmpty else {
                Issue.record("Errors creating settings: \(diagnosticErrors)")
                return
            }

            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings: \(settings.errors)")
                return
            }

            let scope = settings.globalScope
            #expect(scope.evaluateAsString(try #require(settings.userNamespace.lookupMacroDeclaration("BAZ"))) == "environmentconfig-commandlineconfig-commandline-overrides-target-project-environment--fromfile-fromfile")
        }
    }

    @Test
    func settingsOverridesDevelopmentAssets() async throws {
        func test(buildSettings: [String: String], action: BuildAction = .install, overrides: [String: String] = [:], extraFiles: [Path: String] = [:], configuration: String = "Debug", baseConfig: String? = nil, expectedExcludedFileNames: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let testWorkspace = try await TestWorkspace("Workspace", projects: [
                TestProject("aProject",
                            groupTree: TestGroup("SomeFiles", children: [TestFile("main.swift"), TestFile("Test.xcconfig")]),
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", baseConfig: baseConfig, buildSettings: buildSettings), TestBuildConfiguration("Release", baseConfig: baseConfig, buildSettings: buildSettings)],
                            targets: [
                                TestAggregateTarget("AppTarget", buildConfigurations: [TestBuildConfiguration("Debug"), TestBuildConfiguration("Release")], buildPhases: [TestSourcesBuildPhase(["main.swift"])])])]).load(getCore())

            let context = try await contextForTestData(testWorkspace, systemInfo: SystemInfo(operatingSystemVersion: Version(), productBuildVersion: "", nativeArchitecture: "arm64"), files: [
                .root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/AppIcon.png"): "a picture",
                .root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/Info.plist"): "a plist"
            ].merging(extraFiles, uniquingKeysWith: { original, override in override }))
            let buildRequestContext = BuildRequestContext(workspaceContext: context)

            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            let parameters = BuildParameters(
                action: action,
                configuration: configuration,
                overrides: overrides)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

            #expect(settings.errors.isEmpty, "Expect to not produce any errors", sourceLocation: sourceLocation)

            let scope = settings.globalScope
            #expect(scope.evaluate(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES) == expectedExcludedFileNames,  sourceLocation: sourceLocation)
        }

        // Specifying DEVELOPMENT_ASSET_PATHS and EXCLUDED_SOURCE_FILE_NAMES should merge them
        try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources'",
                                       "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                       expectedExcludedFileNames: ["docs/*", Path.root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/*").str])

        // Specifying DEVELOPMENT_ASSET_PATHS which are absolute should work as well
        try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'\(Path.root.join("tmp/Workspace/aProject/AppTarget/Preview Resources").strWithPosixSlashes)'",
                                       "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                       expectedExcludedFileNames: ["docs/*", Path.root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/*").str])

        // Specifying DEVELOPMENT_ASSET_PATHS which are absolute that are not part of SRCROOT should work as well
        try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'\(Path.root.join("tmp/Workspace/bProject/AppTarget/Preview Resources").strWithPosixSlashes)'",
                                       "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                       // the directory needs to exist (for /* at the end), so we write a mock file here
                       extraFiles: [.root.join("tmp/Workspace/bProject/AppTarget/Preview Resources/afile.txt"): ""],
                       expectedExcludedFileNames: ["docs/*", Path.root.join("tmp/Workspace/bProject/AppTarget/Preview Resources/*").str])

        // Not specifying DEVELOPMENT_ASSET_PATHS should not affect EXCLUDED_SOURCE_FILE_NAMES
        try await test(buildSettings: ["EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                       expectedExcludedFileNames: ["docs/*"])

        // Not specifying EXCLUDED_SOURCE_FILE_NAMES but DEVELOPMENT_ASSET_PATHS should create a list with DEVELOPMENT_ASSET_PATHS' contents
        try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources'"],
                       expectedExcludedFileNames: [Path.root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/*").str])

        // If the specified directory does not exist, we expect to not receive an error during Settings creation
        // Since the directory does not exist, it gets added as a file (without '*')
        try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Does Not Exist'"],
                       expectedExcludedFileNames: [Path.root.join("tmp/Workspace/aProject/AppTarget/Does Not Exist").str])

        // If the build action is install, development resources should be excluded
        for action in [BuildAction.install, .installAPI, .installHeaders, .installLoc, .installSource, .archive] {
            try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources'",
                                           "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                           action: action,
                           expectedExcludedFileNames: ["docs/*", Path.root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/*").str])
        }

        // If the build action is anything else but install (and DEPLOYMENT_POSTPROCESSING is not specified), we don't exclude
        for action in [BuildAction.analyze, .clean, .build] {
            try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources'",
                                           "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                           action: action,
                           expectedExcludedFileNames: ["docs/*"])
            try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources'",
                                           "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                           action: action,
                           overrides: ["DEPLOYMENT_LOCATION": "YES"],
                           expectedExcludedFileNames: ["docs/*"])
        }

        // If the build action is anything else but install *but* DEPLOYMENT_POSTPROCESSING is specified, we exclude
        for action in [BuildAction.analyze, .clean, .build] {
            try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources'",
                                           "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                           action: action,
                           overrides: ["DEPLOYMENT_POSTPROCESSING": "YES"],
                           expectedExcludedFileNames: ["docs/*", Path.root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/*").str])
        }

        // However, if DEPLOYMENT_LOCATION is explicitly set to NO, development assets should not be excluded
        for action in [BuildAction.analyze, .clean, .build] {
            try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources'",
                                           "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                           action: action,
                           overrides: ["DEPLOYMENT_LOCATION": "NO"],
                           expectedExcludedFileNames: ["docs/*"])
        }

        // Exclude directories and files
        try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources' 'AppTarget/DevelopmentResourceFile.txt'",
                                       "EXCLUDED_SOURCE_FILE_NAMES": "$(inherited) docs/*"],
                       expectedExcludedFileNames: ["docs/*", Path.root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/*").str, Path.root.join("tmp/Workspace/aProject/AppTarget/DevelopmentResourceFile.txt").str])

        let baseConfigFiles: [Path: String] = [
            .root.join("tmp/Workspace/aProject/Test.xcconfig"): "EXCLUDED_SOURCE_FILE_NAMES[config=Debug] = 'debug/files/*'"
        ]

        // Check that specified paths get added for condition sets as well
        try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources'"],
                       action: .install,
                       extraFiles: baseConfigFiles,
                       configuration: "Debug",
                       baseConfig: "Test.xcconfig",
                       expectedExcludedFileNames: ["debug/files/*", Path.root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/*").str])

        // If the condition set states debug, but we build release, we should only have dev assets in the value
        try await test(buildSettings: ["DEVELOPMENT_ASSET_PATHS": "'AppTarget/Preview Resources'"],
                       action: .install,
                       extraFiles: baseConfigFiles,
                       configuration: "Release",
                       baseConfig: "Test.xcconfig",
                       expectedExcludedFileNames: [Path.root.join("tmp/Workspace/aProject/AppTarget/Preview Resources/*").str])
    }

    @Test
    func arenaSettings() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [
                                                        TestProject("aProject",
                                                                    groupTree: TestGroup("SomeFiles"),
                                                                    buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [:])],
                                                                    targets: [
                                                                        TestAggregateTarget("AggregateTarget",
                                                                                            buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [:])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)

        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let arena = ArenaInfo(derivedDataPath: Path.root.join("tmp/foo/$(SDK_NAME)"), buildProductsPath: Path.root.join("tmp/foo/$(SDK_NAME)/products"), buildIntermediatesPath: Path.root.join("tmp/foo/$(SDK_NAME)/intermediates"), pchPath: Path(""), indexRegularBuildProductsPath: Path.root.join("tmp/foo/$(SDK_NAME)/regular-products"), indexRegularBuildIntermediatesPath: Path.root.join("tmp/foo/$(SDK_NAME)/regular-intermediates"), indexPCHPath: Path.root.join("tmp/foo/$(SDK_NAME)/indexpch"), indexDataStoreFolderPath: Path.root.join("tmp/foo/$(SDK_NAME)/index"), indexEnableDataStore: true)
        let parameters = BuildParameters(
            action: .build,
            configuration: "Debug",
            arena: arena)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        // Verify that indexing settings from the workspace arena are not exported
        #expect(!settings.exportedMacroNames.contains(BuiltinMacros.INDEX_REGULAR_BUILD_PRODUCTS_DIR))
        #expect(!settings.exportedMacroNames.contains(BuiltinMacros.INDEX_REGULAR_BUILD_INTERMEDIATES_DIR))
        #expect(!settings.exportedMacroNames.contains(BuiltinMacros.INDEX_PRECOMPS_DIR))
        #expect(!settings.exportedMacroNames.contains(BuiltinMacros.INDEX_DATA_STORE_DIR))
        #expect(!settings.exportedMacroNames.contains(BuiltinMacros.INDEX_ENABLE_DATA_STORE))
        #expect(!settings.exportedMacroNames.contains(BuiltinMacros.INDEX_PRECOMPS_DIR))

        let scope = settings.globalScope
        let sdk = scope.evaluateAsString(BuiltinMacros.SDK_NAME)
        #expect(scope.evaluateAsString(BuiltinMacros.INDEX_DATA_STORE_DIR) == Path.root.join("tmp/foo/\(sdk)/index").str)
        #expect(scope.evaluateAsString(BuiltinMacros.INDEX_ENABLE_DATA_STORE) == "YES")
        #expect(scope.evaluateAsString(BuiltinMacros.INDEX_PRECOMPS_DIR) == Path.root.join("tmp/foo/\(sdk)/indexpch").str)
    }

    @Test
    func hostOperatingSystemVersionSettings() async throws {
        let workspace = try await TestWorkspace("Workspace", projects: [TestProject("aProject", groupTree: TestGroup("SomeFiles", children: []))]).load(getCore())

        // Check the values for modern macOS (v11+)
        do {
            let context = try await contextForTestData(workspace, systemInfo: SystemInfo(operatingSystemVersion: Version(11, 1, 2), productBuildVersion: "20C129", nativeArchitecture: "arm64e"))
            let buildRequestContext = BuildRequestContext(workspaceContext: context)

            let testProject = context.workspace.projects[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject)
            #expect(settings.project === testProject)
            #expect(settings.target === nil)
            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings: \(settings.errors)")
                return
            }

            if context.core.hostOperatingSystem == .macOS {
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_MAJOR)?.expression.stringRep == "110000")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_MINOR)?.expression.stringRep == "110100")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_ACTUAL)?.expression.stringRep == "110102")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_PRODUCT_BUILD_VERSION)?.expression.stringRep == "20C129")
            }
            else {
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_MAJOR) == nil)
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_MINOR) == nil)
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_ACTUAL) == nil)
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_PRODUCT_BUILD_VERSION) == nil)
            }
        }

        // Check the values for legacy macOS (v10.x)
        do {
            let context = try await contextForTestData(workspace, systemInfo: SystemInfo(operatingSystemVersion: Version(10, 15, 4), productBuildVersion: "19E287", nativeArchitecture: "x86_64h"))
            let buildRequestContext = BuildRequestContext(workspaceContext: context)

            let testProject = context.workspace.projects[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject)
            #expect(settings.project === testProject)
            #expect(settings.target === nil)
            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings: \(settings.errors)")
                return
            }

            if context.core.hostOperatingSystem == .macOS {
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_MAJOR)?.expression.stringRep == "101500")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_MINOR)?.expression.stringRep == "1504")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_ACTUAL)?.expression.stringRep == "101504")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_PRODUCT_BUILD_VERSION)?.expression.stringRep == "19E287")
            }
            else {
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_MAJOR) == nil)
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_MINOR) == nil)
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_VERSION_ACTUAL) == nil)
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.MAC_OS_X_PRODUCT_BUILD_VERSION) == nil)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func SDKVersionSettings() async throws {
        // Use a separate Core instance to avoid corrupting the state of other test cases
        // due to the registration of temporary SDKs in this test case.
        let core = try await Self.makeCore(simulatedInferiorProductsPath: simulatedInferiorProductsPath())

        let macosx = try #require(core.platformRegistry.lookup(name: "macosx"), "could not load macosx platform")

        // Construct the test project.
        let testWorkspace = TestWorkspace("Workspace",
                                          projects: [TestProject("aProject",
                                                                 groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                 buildConfigurations:[
                                                                    TestBuildConfiguration("Debug", buildSettings: [:])
                                                                 ],
                                                                 targets: [
                                                                    TestStandardTarget("Target1",
                                                                                       type: .application,
                                                                                       buildConfigurations: [
                                                                                        TestBuildConfiguration("Debug", buildSettings: [:]
                                                                                                              )],
                                                                                       buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])]
                                                                                      ),
                                                                 ])
                                          ])
        let context = try await contextForTestData(testWorkspace, core: core)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)

        // Create multiple SDKs
        try await withTemporaryDirectory { sdksDirPath in
            do {
                let sdk = sdksDirPath.join("MacOSX11.1.2.sdk")
                try await writeSDK(name: sdk.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": "macosx11.1.2",
                    "IsBaseSDK": "YES",
                    "Version": "11.1.2",
                    "DefaultProperties": [
                        "PLATFORM_NAME": "macosx"
                    ],
                ])
            }

            do {
                let sdk = sdksDirPath.join("MacOSX10.15.4.sdk")
                try await writeSDK(name: sdk.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": "macosx10.15.4",
                    "IsBaseSDK": "YES",
                    "Version": "10.15.4",
                    "DefaultProperties": [
                        "PLATFORM_NAME": "macosx"
                    ],
                ])
            }

            do {
                let sdk = sdksDirPath.join("WatchOS8.1.2.sdk")
                try await writeSDK(name: sdk.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": "watchos8.1.2",
                    "IsBaseSDK": "YES",
                    "Version": "8.1.2",
                    "DefaultProperties": [
                        "PLATFORM_NAME": "watchos"
                    ],
                ])
            }

            final class TestDataDelegate : SDKRegistryDelegate {
                let namespace: MacroNamespace
                let pluginManager: PluginManager
                private let _diagnosticsEngine = DiagnosticsEngine()
                init(_ namespace: MacroNamespace, pluginManager: PluginManager) {
                    self.namespace = namespace
                    self.pluginManager = pluginManager
                }
                var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
                    .init(_diagnosticsEngine)
                }
                var warnings: [(String, String)] {
                    return _diagnosticsEngine.diagnostics.pathMessageTuples(.warning)
                }
                var errors: [(String, String)] {
                    return _diagnosticsEngine.diagnostics.pathMessageTuples(.error)
                }
                var platformRegistry: PlatformRegistry? {
                    nil
                }
            }

            // Need to make sure we use a consistent namespace here because the macro table expects the same namespace
            let delegate = TestDataDelegate(context.workspace.userNamespace, pluginManager: try await getCore().pluginManager)
            let sdkRegistry = SDKRegistry(delegate: delegate, searchPaths: [(sdksDirPath, macosx)], type: .builtin, hostOperatingSystem: try await getCore().hostOperatingSystem)

            // Needed as otherwise the extendedInfo isn't loaded and the DefaultSettingsTable! unwrap fails
            sdkRegistry.loadExtendedInfo(context.workspace.userNamespace)

            #expect(delegate.errors.map { "\($0): \($1)" } == [])
            #expect(delegate.warnings.map { "\($0): \($1)" } == [])

            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            // Check the values for modern macOS (v11+)
            do {
                let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macOS, overrides: ["SDKROOT": "macosx11.1.2"])
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, sdkRegistry: sdkRegistry)

                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION_MAJOR)?.expression.stringRep == "110000")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION_MINOR)?.expression.stringRep == "110100")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION_ACTUAL)?.expression.stringRep == "110102")
            }

            // Check the values for legacy macOS (v10.x)
            do {
                let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macOS, overrides: ["SDKROOT": "macosx10.15.4"])
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, sdkRegistry: sdkRegistry)

                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION_MAJOR)?.expression.stringRep == "101500")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION_MINOR)?.expression.stringRep == "1504")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION_ACTUAL)?.expression.stringRep == "101504")
            }

            // Check the values for non-macOS platforms, demonstrating that the SDK_VERSION_* family of macros _don't_ include a leading zero for major versions < 10.
            do {
                let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .watchOS, overrides: ["SDKROOT": "watchos8.1.2"])
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, sdkRegistry: sdkRegistry)

                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION_MAJOR)?.expression.stringRep == "80000")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION_MINOR)?.expression.stringRep == "80100")
                #expect(settings.tableForTesting.lookupMacro(BuiltinMacros.SDK_VERSION_ACTUAL)?.expression.stringRep == "80102")
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func nativeArchSettings() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [TestProject("aProject",
                                                                 groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                 targets: [
                                                                    TestStandardTarget("Target1",
                                                                                       type: .dynamicLibrary,
                                                                                       buildConfigurations: [
                                                                                        TestBuildConfiguration("Debug",
                                                                                                               buildSettings: [
                                                                                                                "SDKROOT": "iphoneos",
                                                                                                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                                                                                "SUPPORTS_MACCATALYST": "YES",
                                                                                                               ])],
                                                                                       buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(core)
        let context = try await contextForTestData(workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let project = context.workspace.projects[0]
        let target = project.targets[0]

        let arch32 = try #require(Architecture.host.as32bit.stringValue)
        let arch64 = try #require(Architecture.host.as64bit.stringValue)

        let destinations: [RunDestinationInfo] = [.macOS, .macCatalyst, .iOS, .iOSSimulator, .tvOS, .tvOSSimulator, .watchOS, .watchOSSimulator, .xrOS, .xrOSSimulator, .linux].filter { core.sdkRegistry.lookup($0.sdk) != nil }

        for destination in destinations {
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: destination, overrides: ["SDKROOT": destination.sdk, "SDK_VARIANT": destination.sdkVariant ?? ""])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: target)

            if settings.errors.isEmpty {
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == destination.platform)
                #expect(scope.evaluate(BuiltinMacros.SDK_VARIANT).nilIfEmpty == destination.sdkVariant)

                #expect(scope.evaluate(BuiltinMacros.NATIVE_ARCH) == arch64)
                #expect(scope.evaluate(BuiltinMacros.NATIVE_ARCH_32_BIT) == arch32)
                #expect(scope.evaluate(BuiltinMacros.NATIVE_ARCH_64_BIT) == arch64)
                #expect(scope.evaluate(BuiltinMacros.NATIVE_ARCH_ACTUAL) == arch64)
            } else {
                Issue.record("Errors creating settings: \(settings.errors)")
            }
        }
    }

    /// Tests that the recommended deployment target build settings have been properly set.
    @Test(.requireXcode16())
    func recommendedDeploymentTargets() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [TestFile("Mock.cpp")]),
                    targets: [
                        TestStandardTarget(
                            "Target1",
                            type: .dynamicLibrary,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                    ])],
                            buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(core)
        let context = try await contextForTestData(workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let project = context.workspace.projects[0]
        let target = project.targets[0]

        let destinations: [RunDestinationInfo] = [.macOS, .macCatalyst, .iOS, .iOSSimulator, .tvOS, .tvOSSimulator, .watchOS, .watchOSSimulator, .xrOS, .xrOSSimulator, .driverKit, .linux].filter { core.sdkRegistry.lookup($0.sdk) != nil }

        for destination in destinations {
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: destination, overrides: ["SDKROOT": destination.sdk, "SDK_VARIANT": destination.sdkVariant ?? ""])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: target)

            #expect(settings.errors == [])

            let scope = settings.globalScope

            #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == destination.platform)

            switch destination {
            case .macOS:
                #expect(try scope.evaluate(scope.namespace.declareStringMacro("RECOMMENDED_MACOSX_DEPLOYMENT_TARGET")) == "11.0")
            case .macCatalyst:
                #expect(try scope.evaluate(scope.namespace.declareStringMacro("RECOMMENDED_MACOSX_DEPLOYMENT_TARGET")) == "11.0")
                #expect(try scope.evaluate(scope.namespace.declareStringMacro("RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET")) == "14.2")
            case .iOS, .iOSSimulator:
                #expect(try scope.evaluate(scope.namespace.declareStringMacro("RECOMMENDED_IPHONEOS_DEPLOYMENT_TARGET")) == "15.0")
            case .tvOS, .tvOSSimulator:
                #expect(try scope.evaluate(scope.namespace.declareStringMacro("RECOMMENDED_TVOS_DEPLOYMENT_TARGET")) == "15.0")
            case .watchOS, .watchOSSimulator:
                #expect(try scope.evaluate(scope.namespace.declareStringMacro("RECOMMENDED_WATCHOS_DEPLOYMENT_TARGET")) == "8.0")
            case .xrOS, .xrOSSimulator:
                #expect(try scope.evaluate(scope.namespace.declareStringMacro("RECOMMENDED_XROS_DEPLOYMENT_TARGET")) == "1.0")
            case .driverKit:
                #expect(try scope.evaluate(scope.namespace.declareStringMacro("RECOMMENDED_DRIVERKIT_DEPLOYMENT_TARGET")) == "20.0")
            case .linux:
                // Linux doesn't have a concept of deployment target
                break
            default:
                Issue.record("Unrecognized destination: \(destination)")
            }
        }
    }

    /// Tests that the `PLATFORM_PREFERRED_ARCH` build setting has been correctly populated from the extended platform info.
    @Test
    func platformPreferredArchSettings() async throws {
        let core = try await getCore()
        let workspace = try TestWorkspace("Workspace",
                                          projects: [TestProject("aProject",
                                                                 groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                 targets: [
                                                                    TestStandardTarget("Target1",
                                                                                       type: .dynamicLibrary,
                                                                                       buildConfigurations: [
                                                                                        TestBuildConfiguration("Debug",
                                                                                                               buildSettings: [
                                                                                                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                                                                               ])],
                                                                                       buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(core)
        let context = try await contextForTestData(workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let project = context.workspace.projects[0]
        let target = project.targets[0]

        let destinations: [RunDestinationInfo] = [.macOS, .iOS, .iOSSimulator, .tvOS, .tvOSSimulator, .watchOS, .watchOSSimulator, .linux].filter { core.sdkRegistry.lookup($0.sdk) != nil }

        for destination in destinations {
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: destination, overrides: ["SDKROOT": destination.sdk])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: target)

            #expect(settings.errors == [])

            let scope = settings.globalScope

            #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == destination.platform)

            switch destination {
            case .macOS, .iOSSimulator, .tvOSSimulator, .watchOSSimulator:
                #expect(scope.evaluate(BuiltinMacros.PLATFORM_PREFERRED_ARCH) == "x86_64")
            case .iOS, .tvOS, .watchOS:
                #expect(scope.evaluate(BuiltinMacros.PLATFORM_PREFERRED_ARCH) == "arm64")
            case .linux:
                #expect(scope.evaluate(BuiltinMacros.PLATFORM_PREFERRED_ARCH) == "")
            default:
                Issue.record("Unrecognized destination: \(destination)")
            }
        }
    }

    /// Test ARCHS and the related settings which affect it.
    @Test(.requireSDKs(.iOS))
    func architectures() async throws {
        let core = try await getCore()
        // Use an iOS workspace for most of our tests.
        let iosWorkspace = try TestWorkspace("Workspace",
                                             projects: [TestProject("aProject",
                                                                    groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                    targets: [
                                                                        TestStandardTarget("Target1",
                                                                                           type: .application,
                                                                                           buildConfigurations: [
                                                                                            TestBuildConfiguration("Debug",
                                                                                                                   buildSettings: [
                                                                                                                    "SDKROOT": "iphoneos",
                                                                                                                    "ARCHS": "arm64 arm64e",
                                                                                                                    "VALID_ARCHS": "$(ARCHS)",
                                                                                                                    "EXCLUDED_ARCHS": "",
                                                                                                                   ])],
                                                                                           buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(core)
        let context = try await contextForTestData(iosWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let iosProject = context.workspace.projects[0]
        let iosTarget = iosProject.targets[0]

        // Basic test
        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: iosProject, target: iosTarget)

            if settings.errors.isEmpty {
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["arm64", "arm64e"])
            }
            else {
                Issue.record("Errors creating settings: \(settings.errors)")
            }
        }

        // Test EXCLUDED_ARCHS.
        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: ["EXCLUDED_ARCHS": "arm64"])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: iosProject, target: iosTarget)

            if settings.errors.isEmpty  {
                let scope = settings.globalScope

                // arm64e doesn't get removed by EXCLUDED_ARCHS because compatibility archs aren't used with that setting.
                #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["arm64e"])
            }
            else {
                Issue.record("Errors creating settings: \(settings.errors)")
            }
        }

        // Test with an explicit device build and arm64e exclusion.
        do {
            let runDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: nil, targetArchitecture: "arm64e", supportedArchitectures: ["arm64", "arm64e"], disableOnlyActiveArch: false)

            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: runDestination, overrides: ["EXCLUDED_ARCHS": "arm64e", "ONLY_ACTIVE_ARCH": "YES"])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: iosProject, target: iosTarget)

            if settings.errors.isEmpty  {
                let scope = settings.globalScope

                // arm64 should still be considered a valid arch for arm64e, so it should fallback.
                #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["arm64"])
            }
            else {
                Issue.record("Errors creating settings: \(settings.errors)")
            }
        }

        // Test with an explicit device build and arm64 exclusion.
        do {
            let runDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: nil, targetArchitecture: "arm64", supportedArchitectures: ["arm64", "arm64e"], disableOnlyActiveArch: false)

            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: runDestination, overrides: ["EXCLUDED_ARCHS": "arm64", "ONLY_ACTIVE_ARCH": "YES"])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: iosProject, target: iosTarget)

            if settings.errors.isEmpty  {
                let scope = settings.globalScope

                // This test should effectively be a no-op and arm64e is chosen.
                #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["arm64e"])
            }
            else {
                Issue.record("Errors creating settings: \(settings.errors)")
            }
        }

        // Test with an explicit device build with no fallback.
        do {
            let runDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: nil, targetArchitecture: "arm64e", supportedArchitectures: ["arm64e"], disableOnlyActiveArch: false)

            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: runDestination, overrides: ["EXCLUDED_ARCHS": "arm64e", "ONLY_ACTIVE_ARCH": "YES"])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: iosProject, target: iosTarget)

            if settings.errors.isEmpty  {
                let scope = settings.globalScope

                // Nothing from the device is allowed, so fallback to what ARCHS has.
                #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["arm64"])
            }
            else {
                Issue.record("Errors creating settings: \(settings.errors)")
            }
        }
    }

    /// Validate that setting `VALID_ARCHS` to `arm64` doesn't remove `arm64e` from `ARCHS` because `arm64` is marked as a compatibility architecture of `arm64e`. This only occurs if `__POPULATE_COMPATIBILITY_ARCH_MAP` is on.
    @Test(.requireSDKs(.iOS))
    func compatArchs() async throws {
        let core = try await getCore()

        let testWorkspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: []),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Config1", buildSettings: [
                                "ARCHS": "arm64 arm64e",
                                "SDKROOT": "iphoneos",
                                "VALID_ARCHS": "arm64",
                                "__POPULATE_COMPATIBILITY_ARCH_MAP": "YES",
                            ])
                    ],
                    targets: [TestStandardTarget("Target", type: .application)]
                )
            ]
        ).load(core)

        let context = try await contextForTestData(testWorkspace, core: core)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testProject.targets[0])

        // If arm64e didn't have arm64 in its CompatibilityArchitectures list in the xcspecs, this would only return arm64 due to the VALID_ARCHS build setting in the test project above.
        #expect(settings.globalScope.evaluate(BuiltinMacros.ARCHS).sorted() == ["arm64", "arm64e"])
    }

    func testArchPointerAuthentication(platform: String) async throws {
        func test(buildSettings: [String: String], expectedARCHS_STANDARD: [String], expectedErrors: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let workspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: buildSettings)],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
            let context = try await contextForTestData(workspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let project = context.workspace.projects[0]
            let target = project.targets[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: target)

            if settings.errors.isEmpty {
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.ARCHS_STANDARD) == expectedARCHS_STANDARD)
            }
            else {
                if expectedErrors.isEmpty {
                    Issue.record("Errors creating settings: \(settings.errors)", sourceLocation: sourceLocation)
                } else {
                    #expect(settings.errors.elements == expectedErrors)
                }
            }
        }

        // overriding ARCHS should always work
        try await test(buildSettings: ["SDKROOT": platform,
                                       "ARCHS": "foobar",
                                       "EXCLUDED_ARCHS": "",
                                       "ENABLE_POINTER_AUTHENTICATION": "YES"],
                       expectedARCHS_STANDARD: ["arm64", "arm64e"])

        // using pointer authentication will include arm64e
        try await test(buildSettings: ["SDKROOT": platform,
                                       "ENABLE_POINTER_AUTHENTICATION": "YES"],
                       expectedARCHS_STANDARD: ["arm64", "arm64e"])

        // explicitly opting out of pointer authentication does not add arm64e
        try await test(buildSettings: ["SDKROOT": platform,
                                       "ENABLE_POINTER_AUTHENTICATION": "NO"],
                       expectedARCHS_STANDARD: ["arm64"])
    }

    @Test(.requireSDKs(.iOS))
    func archPointerAuthentication_iOS() async throws {
        try await testArchPointerAuthentication(platform: "iphoneos")
    }

    @Test(.requireSDKs(.tvOS))
    func archPointerAuthentication_tvOS() async throws {
        try await testArchPointerAuthentication(platform: "appletvos")
    }

    @Test(.requireSDKs(.iOS))
    func swiftModuleOnlyArchs() async throws {
        func test(archs: [String],
                  moduleOnlyArchs: [String],
                  expectedArchs: [String],
                  expectedModuleOnlyArchs: [String],
                  overrides: [String:String] = [:],
                  runDestination: RunDestinationInfo? = nil,
                  sourceLocation: SourceLocation = #_sourceLocation) async throws {

            let buildSettings = [
                "SDKROOT": "iphoneos",
                "ARCHS": archs.joined(separator: " "),
                "SWIFT_MODULE_ONLY_ARCHS": moduleOnlyArchs.joined(separator: " "),
            ]

            let testWorkspace = try await TestWorkspace("Workspace", projects: [
                TestProject(
                    "TestProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [TestFile("Test.swift")]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: buildSettings.addingContents(of: overrides)),
                    ],
                    targets: [TestAggregateTarget(
                        "AppTarget",
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["Test.swift"])
                        ])
                    ])]).load(getCore())

            let context = try await contextForTestData(testWorkspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: runDestination)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(settings.errors.isEmpty, "Expect to not produce any errors", sourceLocation: sourceLocation)

            let scope = settings.globalScope
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == expectedArchs)
            #expect(scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_ARCHS) == expectedModuleOnlyArchs)

            #expect(scope.evaluate(BuiltinMacros.__ARCHS__) == archs)
            #expect(scope.evaluate(BuiltinMacros.__SWIFT_MODULE_ONLY_ARCHS__) == moduleOnlyArchs)
        }

        // Test empty SWIFT_MODULE_ONLY_ARCHS archs is a no-op.
        try await test(archs: ["arm64", "arm64e"],
                       moduleOnlyArchs: [],
                       expectedArchs: ["arm64", "arm64e"],
                       expectedModuleOnlyArchs: [])

        // Test SWIFT_MODULE_ONLY_ARCHS parses correctly.
        try await test(archs: ["arm64", "arm64e"],
                       moduleOnlyArchs: ["armv7", "armv7s"],
                       expectedArchs: ["arm64", "arm64e"],
                       expectedModuleOnlyArchs: ["armv7", "armv7s"])

        // Test SWIFT_MODULE_ONLY_ARCHS is a disjoint set from ARCHS.
        try await test(archs: ["arm64", "arm64e"],
                       moduleOnlyArchs: ["arm64", "armv7", "armv7s"],
                       expectedArchs: ["arm64", "arm64e"],
                       expectedModuleOnlyArchs: ["armv7", "armv7s"])

        // Test SWIFT_MODULE_ONLY_ARCHS only contains valid archs.
        try await test(archs: ["arm64", "arm64e"],
                       moduleOnlyArchs: ["nonsense64b"],
                       expectedArchs: ["arm64", "arm64e"],
                       expectedModuleOnlyArchs: [])

        // Test SWIFT_MODULE_ONLY_ARCHS removes excluded archs.
        try await test(archs: ["arm64", "arm64e"],
                       moduleOnlyArchs: ["armv7", "armv7s"],
                       expectedArchs: ["arm64", "arm64e"],
                       expectedModuleOnlyArchs: ["armv7"],
                       overrides: ["EXCLUDED_ARCHS": "armv7s"])

        // Test SWIFT_MODULE_ONLY_ARCHS is disabled if ONLY_ACTIVE_ARCH is active.
        try await test(archs: ["arm64", "arm64e"],
                       moduleOnlyArchs: ["arm64", "armv7", "armv7s"],
                       expectedArchs: ["arm64"],
                       expectedModuleOnlyArchs: [],
                       overrides: ["ONLY_ACTIVE_ARCH": "YES"],
                       runDestination: .iOS)

        // ...though with no run destination to provide an active arch, it's ignored.
        try await test(archs: ["arm64", "arm64e"],
                       moduleOnlyArchs: ["arm64", "armv7", "armv7s"],
                       expectedArchs: ["arm64", "arm64e"],
                       expectedModuleOnlyArchs: ["armv7", "armv7s"],
                       overrides: ["ONLY_ACTIVE_ARCH": "YES"],
                       runDestination: nil)
    }

    @Test
    func swiftModuleOnlyDeploymentTargets() async throws {
        let buildSettings = [
            "DEPLOYMENT_TARGET_SETTING_NAME": "IPHONEOS_DEPLOYMENT_TARGET",

            "SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET": "10.14.4",
            "SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET": "11.0",
            "SWIFT_MODULE_ONLY_TVOS_DEPLOYMENT_TARGET": "12.0",
            "SWIFT_MODULE_ONLY_WATCHOS_DEPLOYMENT_TARGET": "5.0",
            "SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET[arch=armv7]": "10.3",
            "SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET[arch=armv7s]": "10.3",
        ]

        let testWorkspace = try await TestWorkspace("Workspace", projects: [
            TestProject(
                "TestProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [TestFile("Test.swift")]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: buildSettings),
                ],
                targets: [TestAggregateTarget(
                    "AppTarget",
                    buildConfigurations: [
                        TestBuildConfiguration("Debug")
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Test.swift"])
                    ])
                ])]).load(getCore())

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
        #expect(settings.errors.isEmpty, "Expect to not produce any errors")

        let scope = settings.globalScope
        #expect(scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET) == "10.14.4")
        #expect(scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET) == "11.0")
        #expect(scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_TVOS_DEPLOYMENT_TARGET) == "12.0")
        #expect(scope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_WATCHOS_DEPLOYMENT_TARGET) == "5.0")

        func lookup(_ decl: MacroDeclaration) -> MacroExpression? {
            switch decl {
            case BuiltinMacros.SWIFT_DEPLOYMENT_TARGET:
                return Static {
                    scope.namespace.parseString("$(SWIFT_MODULE_ONLY_$(DEPLOYMENT_TARGET_SETTING_NAME))")
                } as MacroStringExpression
            default:
                return nil
            }
        }

        #expect(scope.evaluate(BuiltinMacros.SWIFT_DEPLOYMENT_TARGET, lookup: lookup) == "11.0")

        for arch in ["armv7", "armv7s"] {
            let subscope = scope.subscope(binding: BuiltinMacros.archCondition, to: arch)
            #expect(subscope.evaluate(BuiltinMacros.SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET) == "10.3")
        }
    }

    @Test(.requireSDKs(.iOS))
    func signingBasics() async throws {
        // Set up a trivial iOS project.
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: [
                                                                                                                        "SDKROOT": "iphoneos",
                                                                                                                        "CODE_SIGN_IDENTITY": "foo",
                                                                                                                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                                                                                                                       ])],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        // Test using the iOS SDK.
        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let provisioningInputs = ProvisioningTaskInputs(identityHash: "foo", identityName: "Foo", profileUUID: "foofoo")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, provisioningTaskInputs: provisioningInputs)

            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings: \(settings.errors)")
                return
            }

            let scope = settings.globalScope

            #expect(scope.evaluate(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY) == "foo")
            #expect(scope.evaluate(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY_NAME) == "Foo")
            #expect(scope.evaluate(BuiltinMacros.EXPANDED_PROVISIONING_PROFILE) == "foofoo")
        }
    }

    @Test(.requireSDKs(.iOS))
    func signingBasicErrorsForRequiredPlatforms() async throws {
        // Set up a trivial iOS project.
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: [
                                                                                                                        "SDKROOT": "iphoneos",
                                                                                                                       ])],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        // Try without an identity or entitlements.
        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let provisioningInputs = ProvisioningTaskInputs(identityHash: "", identityName: "", profileName: "foo", profileUUID: "foofoo", profilePath: Path.root.join("var/tmp/foo.mobileprovision"))
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, provisioningTaskInputs: provisioningInputs)

            XCTAssertMatch(settings.errors.elements, [
                .prefix("An empty code signing identity is not valid when signing a binary for the"),
                .prefix("Entitlements are required for product type \'Application\' in SDK \'iOS"),
            ])
        }

        // Try without an identity.
        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let provisioningInputs = ProvisioningTaskInputs(identityHash: "", identityName: "", profileName: "foo", profileUUID: "foofoo", profilePath: Path.root.join("var/tmp/foo.mobileprovision"), signedEntitlements: .plDict(["hi": .plString("bye")]))
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, provisioningTaskInputs: provisioningInputs)

            XCTAssertMatch(settings.errors.elements, [
                .prefix("An empty code signing identity is not valid when signing a binary for the")
            ])
        }

        // Try without entitlements.
        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let provisioningInputs = ProvisioningTaskInputs(identityHash: "foo", identityName: "foo", profileName: "foo", profileUUID: "foofoo", profilePath: Path.root.join("var/tmp/foo.mobileprovision"))
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, provisioningTaskInputs: provisioningInputs)

            // This is a case that is explicitly allowed by falling back to ad-hoc signing.
            XCTAssertMatch(settings.errors.elements, [
                .prefix("Entitlements are required for product type \'Application\' in SDK \'iOS")
            ])
        }
    }

    @Test(.requireSDKs(.iOS))
    func signingBasicWarningsForNonRequiredPlatforms() async throws {
        // Set up a trivial macOS project.
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles",
                                                                                                children: [TestFile("Mock.cpp")]),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .framework,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"])],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        // Try without an identity or entitlements.
        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let provisioningInputs = ProvisioningTaskInputs(identityHash: "", identityName: "", signedEntitlements: .plDict(["key": .plString("value")]))
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, provisioningTaskInputs: provisioningInputs)

            #expect(settings.errors.count == 0)
            #expect(settings.warnings.count == 1)
            #expect(settings.warnings.first == "Target1 isn't code signed but requires entitlements. It is not possible to add entitlements to a binary without signing it.")
        }
    }

    @Test(.requireSDKs(.iOS))
    func signingBasicErrorsForPlatformsAdhocIphoneos() async throws {
        // Set up a trivial iOS project.
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles",
                                                                                                children: [TestFile("Mock.cpp")]),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .framework,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug", buildSettings: ["SDKROOT": "iphoneos"])],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        // Try without an identity or entitlements.
        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let provisioningInputs = ProvisioningTaskInputs(identityHash: "-", identityName: "tac", signedEntitlements: .plDict(["key": .plString("value")]))
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, provisioningTaskInputs: provisioningInputs)

            #expect(settings.errors.count == 1)
            #expect(settings.warnings.count == 0)

            let core = try await getCore()
            let adhocSignError = "Ad Hoc code signing is not allowed with SDK \'iOS \(core.loadSDK(.iOS).version)\'."
            #expect(settings.errors.first?.hasPrefix(adhocSignError) == true)
        }
    }

    @Test
    func signingDefaults() async throws {
        let core = try await getCore()
        #expect(!core.platformRegistry.platforms.isEmpty)
        for developmentTeam in ["ABCDWXYZ", ""] {
            for platform in core.platformRegistry.platforms {
                if ["android", "linux", "qnx", "windows"].contains(platform.name) {
                    continue
                }
                for sdk in platform.sdks {
                    guard sdk.isBaseSDK, let components = sdk.canonicalNameComponents, components.suffix?.nilIfEmpty == nil else {
                        continue
                    }
                    let allVariants: [SDKVariant?] = sdk.variants.sorted(byKey: <).map { $0.value }
                    let variants = !allVariants.isEmpty ? allVariants : [nil]
                    for sdkVariant in variants {
                        let testWorkspace = try TestWorkspace(
                            "Workspace",
                            projects: [
                                TestProject(
                                    "aProject",
                                    groupTree: TestGroup(
                                        "SomeFiles",
                                        children: [TestFile("Mock.cpp")]
                                    ),
                                    targets: [
                                        TestStandardTarget(
                                            "Target1",
                                            type: .commandLineTool,
                                            buildConfigurations: [
                                                TestBuildConfiguration(
                                                    "Debug",
                                                    buildSettings: [
                                                        "DEVELOPMENT_TEAM": developmentTeam,
                                                        "SDKROOT": sdk.canonicalName,
                                                        "SDK_VARIANT": sdkVariant?.name ?? "",
                                                    ]
                                                )
                                            ],
                                            buildPhases: [
                                                TestSourcesBuildPhase(["Mock.cpp"])
                                            ]
                                        )
                                    ]
                                )
                            ]
                        ).load(core)

                        let context = try await contextForTestData(testWorkspace)
                        let buildRequestContext = BuildRequestContext(workspaceContext: context)
                        let testProject = context.workspace.projects[0]
                        let testTarget = testProject.targets[0]

                        do {
                            let parameters = BuildParameters(action: .build, configuration: "Debug")
                            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

                            guard settings.errors.isEmpty else {
                                Issue.record("Errors creating settings for sdk '\(sdk.displayName)': \(settings.errors)")
                                continue
                            }

                            let scope = settings.globalScope
                            let developmentTeam = scope.evaluate(BuiltinMacros.DEVELOPMENT_TEAM)

                            let defaultPublicSDKCodeSignIdentity: String
                            switch platform.familyName {
                            case _ where platform.isSimulator,
                                "macOS" where sdkVariant?.isMacCatalyst != true && developmentTeam.isEmpty && !sdk.canonicalName.hasPrefix("driverkit"):
                                defaultPublicSDKCodeSignIdentity = "-"
                            case "DriverKit" where try ProductBuildVersion(#require(core.sdkRegistry.lookup("macosx", activeRunDestination: nil)?.productBuildVersion)) < ProductBuildVersion("22A196"):
                                defaultPublicSDKCodeSignIdentity = ""
                            default:
                                defaultPublicSDKCodeSignIdentity = "Apple Development"
                            }

                            #expect(scope.evaluate(BuiltinMacros.CODE_SIGN_IDENTITY) == defaultPublicSDKCodeSignIdentity)
                        }
                    }
                }
            }
        }
    }

    @Test
    func signingDefaultsByProductType() async throws {
        let core = try await getCore()

        func settings(sdk: String, sdkVariant: String, targetType: TestStandardTarget.TargetType, extraSettings: [String: String] = [:]) async throws -> Settings {
            let testWorkspace = try TestWorkspace("Workspace",
                                                  projects: [TestProject("aProject",
                                                                         groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                         targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: targetType,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug", buildSettings: [
                                                                                                    "SDKROOT": sdk,
                                                                                                    "SDK_VARIANT": sdkVariant,
                                                                                                ].addingContents(of: extraSettings))
                                                                                               ])
                                                                         ])
                                                  ]).load(core)
            let context = try await contextForTestData(testWorkspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: nil)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            return settings
        }

        #expect(!core.platformRegistry.platforms.isEmpty)
        for platform in core.platformRegistry.platforms {
            if platform.name == "linux" {
                continue
            }
            for sdk in platform.sdks {
                if !sdk.isBaseSDK {
                    continue
                }
                let allVariants: [SDKVariant?] = sdk.variants.sorted(byKey: <).map { $0.value }
                let variants = !allVariants.isEmpty ? allVariants : [nil]
                for sdkVariant in variants {
                    do {
                        let settings = try await settings(sdk: sdk.canonicalName, sdkVariant: sdkVariant?.name ?? "", targetType: .bundle)
                        let scope = settings.globalScope
                        #expect(scope.evaluate(BuiltinMacros.CODE_SIGNING_ALLOWED))
                    }
                }
            }
        }
    }

    /// Check the behavior of user defined settings, especially w.r.t. quoting rules.
    @Test(.requireSDKs(.host))
    func userDefinedSettings() async throws {
        // Set up a trivial iOS project.
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: []),
                                                                           targets: [
                                                                            TestStandardTarget("Target1", type: .commandLineTool,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: [
                                                                                                                        "USER_HEADER_SEARCH_PATHS": "$(USER_PARAMETER)",
                                                                                                                       ])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        // Check that the user parameter is parsed as a string list.
        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [
            "USER_PARAMETER": "A B"
        ])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        let scope = settings.globalScope
        #expect(scope.evaluate(BuiltinMacros.USER_HEADER_SEARCH_PATHS) == ["A", "B"])
    }

    // Test that we correctly normalize path of some special macros.
    @Test(.requireSDKs(.host))
    func macroPathNormalization() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [
                                                        TestProject("aProject",
                                                                    groupTree: TestGroup("SomeFiles", children: []),
                                                                    targets: [
                                                                        TestStandardTarget("Target1", type: .commandLineTool, buildConfigurations: [
                                                                            TestBuildConfiguration("Debug", buildSettings: [
                                                                                "SYMROOT": "./build",
                                                                                "DSTROOT": "build/foo/bar/something/../dst",
                                                                            ])
                                                                        ])
                                                                    ])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        // Check that the user parameter is parsed as a string list.
        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        let scope = settings.globalScope
        #expect(scope.evaluate(BuiltinMacros.SYMROOT) == Path.root.join("tmp/Workspace/aProject/build"))
        #expect(scope.evaluate(BuiltinMacros.DSTROOT) == Path.root.join("tmp/Workspace/aProject/build/foo/bar/dst"))
    }

    @Test(.requireSDKs(.tvOS))
    func unableToResolveProductType() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                           targets: [
                                                                            TestStandardTarget("Target1", type: .xcodeExtension,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: [
                                                                                                                        "SDKROOT": "appletvos",
                                                                                                                       ])],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        #expect(settings.errors == ["unable to resolve product type 'com.apple.product-type.xcode-extension' for platform 'tvOS'", "unable to resolve product type 'com.apple.product-type.xcode-extension' for platform 'tvOS'"])
        #expect(settings.warnings == [])
    }

    func _testToolchainOverride(targetBuildSettings: [String: String] = [:], buildParameters: BuildParameters = BuildParameters(action: .build, configuration: "Debug"), _ check: (WorkspaceContext, Settings, MacroEvaluationScope) throws -> Void) async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "Project",
                    groupTree: TestGroup("SomeFiles", children: [TestFile("file.c")]),
                    targets: [
                        TestStandardTarget(
                            "Target",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: targetBuildSettings)],
                            buildPhases: [TestSourcesBuildPhase(["file.c"])])])]).load(getCore())

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: buildParameters, project: testProject, target: testTarget)

        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        let scope = settings.globalScope

        try check(context, settings, scope)
    }

    @Test(.requireSDKs(.macOS))
    func toolchainOverride() async throws {
        try await _testToolchainOverride(targetBuildSettings: ["TOOLCHAINS": "targetToolchain"], buildParameters: BuildParameters(action: .build, configuration: "Debug", commandLineOverrides: ["TOOLCHAINS": "commandLineToolchain $(inherited)"], toolchainOverride: "overrideToolchain")) { context, settings, scope in
            #expect(scope.evaluate(BuiltinMacros.TOOLCHAINS) == ["overrideToolchain", "commandLineToolchain", "targetToolchain"])
        }
    }

    /// Check the behavior of user defined settings, especially w.r.t. quoting rules.
    @Test(.requireSDKs(.macOS))
    func toolchainBuildSettings() async throws {
        let fs = localFS
        try await withTemporaryDirectory(fs: fs) { toolchainsDir in
            try await withEnvironment([.externalToolchainsDir: toolchainsDir.str]) {
                // Add in our custom toolchain.
                try fs.createDirectory(toolchainsDir.join("org.swift.testoss.xctoolchain"), recursive: true)
                try await fs.writePlist(toolchainsDir.join("org.swift.testoss.xctoolchain").join("Info.plist"), .plDict([
                    "Identifier": "org.swift.testoss",
                    "DisplayName": "TestOSS",
                    "Version": "1.2.3",
                    "DefaultBuildSettings": .plDict([
                        "TOOLCHAIN_DEFAULT": .plString("IncorrectValue"),
                    ]),
                    "OverrideBuildSettings": .plDict([
                        "TOOLCHAIN_OVERRIDE": .plString("CorrectValue"),
                    ])
                ]))

                // Make a new core to avoid impacting other tests, since we register a toolchain.
                let core = try await Self.makeCore()

                let toolchain = try #require(core.toolchainRegistry.lookup("org.swift.testoss"))
                #expect(toolchain.identifier == "org.swift.testoss")
                #expect(toolchain.displayName == "TestOSS")
                #expect(toolchain.version == Version(1, 2, 3))
                #expect(toolchain.defaultSettings == [
                    "TOOLCHAIN_DEFAULT": .plString("IncorrectValue"),
                ])
                #expect(toolchain.overrideSettings == [
                    "TOOLCHAIN_OVERRIDE": .plString("CorrectValue"),
                    "SWIFT_DEVELOPMENT_TOOLCHAIN": "YES",
                    "SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME": "YES"
                ])

                // Set up a trivial iOS project.
                let testWorkspace = try TestWorkspace(
                    "Workspace",
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup("SomeFiles", children: []),
                            targets: [
                                TestStandardTarget(
                                    "Target1",
                                    type: .application,
                                    buildConfigurations: [
                                        TestBuildConfiguration(
                                            "Debug",
                                            buildSettings: [
                                                "TOOLCHAIN_DEFAULT": "CorrectValue",
                                                "TOOLCHAIN_OVERRIDE": "IncorrectValue",
                                            ]
                                        )
                                    ]
                                )
                            ]
                        )
                    ]
                ).load(core)
                let context = try await contextForTestData(testWorkspace, core: core, fs: fs)
                let buildRequestContext = BuildRequestContext(workspaceContext: context)
                let testProject = context.workspace.projects[0]
                let testTarget = testProject.targets[0]

                let parameters = BuildParameters(action: .build, configuration: "Debug", toolchainOverride: "org.swift.testoss")
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

                guard settings.errors.isEmpty else {
                    Issue.record("Errors creating settings: \(settings.errors)")
                    return
                }
                #expect(settings.warnings == [])
                #expect(settings.notes == ["Using global toolchain override 'TestOSS'."])

                let scope = settings.globalScope
                #expect(scope.evaluateAsString(try #require(scope.namespace.lookupMacroDeclaration("TOOLCHAIN_DEFAULT"))) == "CorrectValue")
                #expect(scope.evaluateAsString(try #require(scope.namespace.lookupMacroDeclaration("TOOLCHAIN_OVERRIDE"))) == "CorrectValue")
            }
        }
    }

    /// Checks that none of our xcspecs have conflicting tool defaults
    @Test
    func builtinSettingsNoErrors() async throws {
        let core = try await getCore()
        for platform in core.platformRegistry.platforms {
            let (_, errors) = core.coreSettings.unionedToolDefaults(domain: platform.name)
            #expect(errors == [])
        }
    }

    @Test(.requireSDKs(.macOS))
    func externalTargetSettings() async throws {
        let core = try await getCore()
        let testWorkspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "Project",
                    groupTree: TestGroup("SomeFiles", children: [TestFile("file.c")]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                        ])],
                    targets: [
                        TestExternalTarget(
                            "ExternalTarget",
                            buildConfigurations: [TestBuildConfiguration("Debug")],
                            passBuildSettingsInEnvironment: true
                        ),
                    ])]).load(core)

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: BuildParameters(action: .build, configuration: "Debug"), project: testProject, target: testTarget)

        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        let scope = settings.globalScope

        #expect(settings.exportedMacroNames.contains(BuiltinMacros.PLATFORM_NAME))
        #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "macosx")

        #expect(settings.exportedMacroNames.contains(BuiltinMacros.SDKROOT))
        #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("macosx")?.path)

        #expect(settings.exportedMacroNames.contains(BuiltinMacros.TOOLCHAINS))
        #expect(scope.evaluate(BuiltinMacros.TOOLCHAINS) == [])

        #expect(settings.exportedMacroNames.contains(BuiltinMacros.TOOLCHAIN_DIR))
        #expect(scope.evaluate(BuiltinMacros.TOOLCHAIN_DIR) == core.toolchainRegistry.defaultToolchain?.path)
    }

    /// Test that the 'config' macro condition parameter works as expected.  This condition parameter is mainly used in xcconfig files, so we use one to test it here.
    @Test(.requireSDKs(.macOS))
    func configurationConditionParameter() async throws {
        let files: [Path: String] = [
            .root.join("tmp/Workspace/aProject/Sources/Test.xcconfig"): (
                "CONFIG_OVERRIDE[config=Release] = value_release\n" +       // This value will be overridden by the later unconditional value.
                "CONFIG_OVERRIDE = value_default\n" +
                "CONFIG_OVERRIDE[config=Debug] = value_debug\n" +           // This value overrides the preceding unconditional value for the Debug configuration.
                "CONFIG_PARTIAL = value_default\n" +
                "CONFIG_PARTIAL[config=D*] = value_d"
            )]
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [
                                                        TestProject("aProject",
                                                                    groupTree: TestGroup(
                                                                        "SomeFiles",  path: "Sources",
                                                                        children: [
                                                                            TestFile("Test.xcconfig"),
                                                                        ]),
                                                                    buildConfigurations: [
                                                                        TestBuildConfiguration("Debug"),
                                                                        TestBuildConfiguration("Release"),
                                                                    ],
                                                                    targets: [
                                                                        TestStandardTarget(
                                                                            "Application", type: .application,
                                                                            buildConfigurations: [
                                                                                TestBuildConfiguration("Debug", baseConfig: "Test.xcconfig", buildSettings: [:]),
                                                                                TestBuildConfiguration("Release", baseConfig: "Test.xcconfig", buildSettings: [:]),
                                                                            ],
                                                                            buildPhases: []
                                                                        )
                                                                    ]
                                                                   )
                                                    ]
        ).load(getCore())

        let context = try await contextForTestData(testWorkspace, files: files)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]


        // Test the Debug configuration.
        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings for Debug configuration: \(settings.errors)")
                return
            }
            let scope = settings.globalScope

            let CONFIG_OVERRIDE = try #require(scope.namespace.lookupMacroDeclaration("CONFIG_OVERRIDE"))
            #expect(scope.evaluateAsString(CONFIG_OVERRIDE) == "value_debug")

            let CONFIG_PARTIAL = try #require(scope.namespace.lookupMacroDeclaration("CONFIG_PARTIAL"))
            #expect(scope.evaluateAsString(CONFIG_PARTIAL) == "value_d")
        }

        // Test the Release configuration.
        do {
            let parameters = BuildParameters(action: .build, configuration: "Release")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings for Release configuration: \(settings.errors)")
                return
            }
            let scope = settings.globalScope

            let CONFIG_OVERRIDE = try #require(scope.namespace.lookupMacroDeclaration("CONFIG_OVERRIDE"))
            #expect(scope.evaluateAsString(CONFIG_OVERRIDE) == "value_default")

            let CONFIG_PARTIAL = try #require(scope.namespace.lookupMacroDeclaration("CONFIG_PARTIAL"))
            #expect(scope.evaluateAsString(CONFIG_PARTIAL) == "value_default")
        }
    }

    /// Test functionality in defining sparse SDKs, including:
    /// - Defining `ADDITIONAL_SDKS` using build settings conditioned on the base SDK.
    /// - That the `SDK_DIR_*** ` settings are properly defined.
    @Test(.requireSDKs(.macOS, .iOS))
    func sparseSdks() async throws {
        // Create some sparse SDKs in a temporary directory so we can control exactly what options get added.  Since sparse SDK logic doesn't check whether a directory exists, we don't need to do anything more than write the SDKSettings.plist file inside the SDK directory.
        try await withTemporaryDirectory { tmpDirPath in
            let iosSparseSDKPath = tmpDirPath.join("iosSparse1.0.sdk")
            let iosSparseSDKIdentBase = "com.apple.sdk.ios"
            let iosSparseSDKIdent = "\(iosSparseSDKIdentBase)1.0"
            try await writeSDK(name: iosSparseSDKPath.basename, parentDir: iosSparseSDKPath.dirname, settings: [
                "CanonicalName": .plString(iosSparseSDKIdent),
                "IsBaseSDK": "NO",
            ])
            let simSparseSDKPath = tmpDirPath.join("simSparse1.0.sdk")
            let simSparseSDKIdentBase = "com.apple.sdk.sparse.sim"
            let simSparseSDKIdent = "\(simSparseSDKIdentBase)1.0"
            try await writeSDK(name: simSparseSDKPath.basename, parentDir: simSparseSDKPath.dirname, settings: [
                "CanonicalName": .plString(simSparseSDKIdent),
                "IsBaseSDK": "NO",
            ])

            // Construct the test project.
            let testWorkspace = try TestWorkspace("Workspace",
                                                  projects: [TestProject("aProject",
                                                                         groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                         buildConfigurations:[
                                                                            TestBuildConfiguration("Debug", buildSettings: [:])
                                                                         ],
                                                                         targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug", buildSettings: [
                                                                                                    "SDKROOT": "macosx",
                                                                                                    "ADDITIONAL_SDKS[sdk=iphoneos*]": "\(iosSparseSDKPath.str)",
                                                                                                    "ADDITIONAL_SDKS[sdk=iphonesimulator*]": "\(simSparseSDKPath.str)",
                                                                                                ]
                                                                                                                      )],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])]
                                                                                              ),
                                                                         ])
                                                  ]).load(await getCore())
            let context = try await contextForTestData(testWorkspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            // Looks up a custom string macro and compares its value in scope against the given value.
            func assertCustomStringMacro(named macroName: String, in scope: MacroEvaluationScope, equals: String, sourceLocation: SourceLocation = #_sourceLocation) {
                guard let macro = scope.namespace.lookupMacroDeclaration(macroName) else {
                    Issue.record("expected macro was not defined: \(macroName)", sourceLocation: sourceLocation)
                    return
                }
                #expect(scope.evaluateAsString(macro) == equals)
            }

            // No overriding SDKROOT - uses macosx.
            if let macosSDK = context.sdkRegistry.lookup("macosx") {
                let parameters = BuildParameters(action: .build, configuration: "Debug")
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.SDKROOT) == macosSDK.path)
                #expect(scope.evaluate(BuiltinMacros.ADDITIONAL_SDKS).isEmpty)
                #expect(scope.evaluate(BuiltinMacros.ADDITIONAL_SDK_DIRS).isEmpty)
                assertCustomStringMacro(named: "SDK_DIR_\(macosSDK.canonicalName.asLegalCIdentifier)", in: scope, equals: macosSDK.path.str)
                #expect(settings.sparseSDKs.isEmpty)

                #expect(settings.warnings == [])
                #expect(settings.errors == [])
            }
            else {
                Issue.record("unable to look up macOS SDK")
            }

            // SDKROOT = iphoneos.
            if let iosSDK = context.sdkRegistry.lookup("iphoneos") {
                let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: ["SDKROOT": "iphoneos"])
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.SDKROOT) == iosSDK.path)
                assertCustomStringMacro(named: "SDK_DIR_\(iosSDK.canonicalName.asLegalCIdentifier)", in: scope, equals: iosSDK.path.str)
                #expect(scope.evaluate(BuiltinMacros.ADDITIONAL_SDKS) == [iosSparseSDKPath.str])
                #expect(scope.evaluate(BuiltinMacros.ADDITIONAL_SDK_DIRS) == [iosSparseSDKPath.str])
                #expect(settings.sparseSDKs.map({ $0.canonicalName }) == [iosSparseSDKIdent])
                assertCustomStringMacro(named: "SDK_DIR_\(iosSparseSDKIdent.asLegalCIdentifier)", in: scope, equals: iosSparseSDKPath.str)
                assertCustomStringMacro(named: "SDK_DIR_\(iosSparseSDKIdentBase.asLegalCIdentifier)", in: scope, equals: iosSparseSDKPath.str)

                #expect(settings.warnings == [])
                #expect(settings.errors == [])
            }
            else {
                Issue.record("unable to look up iOS SDK")
            }

            // SDKROOT = iphonesimulator.
            if let simSDK = context.sdkRegistry.lookup("iphonesimulator") {
                let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: ["SDKROOT": "iphonesimulator"])
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.SDKROOT) == simSDK.path)
                assertCustomStringMacro(named: "SDK_DIR_\(simSDK.canonicalName.asLegalCIdentifier)", in: scope, equals: simSDK.path.str)
                #expect(scope.evaluate(BuiltinMacros.ADDITIONAL_SDKS) == [simSparseSDKPath.str])
                #expect(scope.evaluate(BuiltinMacros.ADDITIONAL_SDK_DIRS) == [simSparseSDKPath.str])
                #expect(settings.sparseSDKs.map({ $0.canonicalName }) == [simSparseSDKIdent])
                assertCustomStringMacro(named: "SDK_DIR_\(simSparseSDKIdent.asLegalCIdentifier)", in: scope, equals: simSparseSDKPath.str)
                assertCustomStringMacro(named: "SDK_DIR_\(simSparseSDKIdentBase.asLegalCIdentifier)", in: scope, equals: simSparseSDKPath.str)

                #expect(settings.warnings == [])
                #expect(settings.errors == [])
            }
            else {
                Issue.record("unable to look up iOS simulator SDK")
            }

            // SDKROOT = iphoneos, but also using a sparse SDK with a base name collision to check for errors.
            if let iosSDK = context.sdkRegistry.lookup("iphoneos") {
                let iosSparseSDK2Path = tmpDirPath.join("iosSparse2.0.sdk")
                let iosSparseSDK2Ident = "\(iosSparseSDKIdentBase)2.0"
                try await writeSDK(name: iosSparseSDK2Path.basename, parentDir: iosSparseSDK2Path.dirname, settings: [
                    "CanonicalName": .plString(iosSparseSDK2Ident),
                    "IsBaseSDK": "NO",
                ])

                let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: ["SDKROOT": "iphoneos", "ADDITIONAL_SDKS": "$(inherited) \(iosSparseSDK2Path.str)"])
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.SDKROOT) == iosSDK.path)
                assertCustomStringMacro(named: "SDK_DIR_\(iosSDK.canonicalName.asLegalCIdentifier)", in: scope, equals: iosSDK.path.str)
                #expect(scope.evaluate(BuiltinMacros.ADDITIONAL_SDKS) == [iosSparseSDKPath.str, iosSparseSDK2Path.str])
                #expect(scope.evaluate(BuiltinMacros.ADDITIONAL_SDK_DIRS) == [iosSparseSDKPath.str, iosSparseSDK2Path.str])
                #expect(settings.sparseSDKs.map({ $0.canonicalName }) == [iosSparseSDKIdent, iosSparseSDK2Ident])
                assertCustomStringMacro(named: "SDK_DIR_\(iosSparseSDKIdent.asLegalCIdentifier)", in: scope, equals: iosSparseSDKPath.str)
                assertCustomStringMacro(named: "SDK_DIR_\(iosSparseSDK2Ident.asLegalCIdentifier)", in: scope, equals: iosSparseSDK2Path.str)
                assertCustomStringMacro(named: "SDK_DIR_\(iosSparseSDKIdentBase.asLegalCIdentifier)", in: scope, equals: iosSparseSDK2Path.str)

                #expect(settings.warnings == ["Multiple SDKs define the setting \'SDK_DIR_com_apple_sdk_ios\'; either the target is using multiple SDKs which shouldn\'t be used together, or some of these SDKs need their \'CanonicalName\' key updated to avoid this collision: \(iosSparseSDKPath.str), \(iosSparseSDK2Path.str)"])
                #expect(settings.errors == [])
            }
            else {
                Issue.record("unable to look up iOS SDK")
            }
        }
    }

    @Test(.requireSDKs(.linux))
    func addRunDestinationSettingsPlatformSDKLinux() async throws {
        let core = try await getCore()
        guard let linux = core.platformRegistry.lookup(name: "linux") else {
            return
        }

        // Construct the test project.
        let testWorkspace = try TestWorkspace("Workspace",
                                              projects: [TestProject("aProject",
                                                                     groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                     buildConfigurations:[
                                                                        TestBuildConfiguration("Debug", buildSettings: [:])
                                                                     ],
                                                                     targets: [
                                                                        TestStandardTarget("Target1",
                                                                                           type: .application,
                                                                                           buildConfigurations: [
                                                                                            TestBuildConfiguration("Debug", buildSettings: [
                                                                                                "SDKROOT": "linuxB",
                                                                                                "PLATFORM_NAME": "linux",
                                                                                            ]
                                                                                                                  )],
                                                                                           buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])]
                                                                                          ),
                                                                     ])
                                              ]).load(core)
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)

        // Create multiple SDKs
        try await withTemporaryDirectory { sdksDirPath in
            for (version, name) in ["linuxB", "linuxA", "linux"].enumerated() {
                let sdk = sdksDirPath.join("\(name).sdk")
                try await writeSDK(name: sdk.basename, parentDir: sdksDirPath, settings: [
                    "CanonicalName": .plString(name),
                    "Version": .plString("\(version).0"),
                    "DefaultProperties": [
                        "PLATFORM_NAME": "linux"
                    ],
                ])
            }
            final class TestDataDelegate : SDKRegistryDelegate {
                let namespace: MacroNamespace
                let pluginManager: PluginManager
                private let _diagnosticsEngine = DiagnosticsEngine()
                init(_ namespace: MacroNamespace, pluginManager: PluginManager) {
                    self.namespace = namespace
                    self.pluginManager = pluginManager
                }
                var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
                    .init(_diagnosticsEngine)
                }
                var warnings: [(String, String)] {
                    return _diagnosticsEngine.diagnostics.pathMessageTuples(.warning)
                }
                var errors: [(String, String)] {
                    return _diagnosticsEngine.diagnostics.pathMessageTuples(.error)
                }
                var platformRegistry: PlatformRegistry? {
                    nil
                }
            }

            // Need to make sure we use a consistent namespace here because the macro table expects the same namespace
            let sdkRegistry = SDKRegistry(delegate: TestDataDelegate(testWorkspace.userNamespace, pluginManager: try await getCore().pluginManager), searchPaths: [(sdksDirPath, linux)], type: .builtin, hostOperatingSystem: try await getCore().hostOperatingSystem)

            // Needed as otherwise the extendedInfo isn't loaded and the DefaultSettingsTable! unwrap fails
            sdkRegistry.loadExtendedInfo(testWorkspace.userNamespace)

            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .linux)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, sdkRegistry: sdkRegistry)
            #expect(settings.platform?.name == "linux")
            #expect(settings.sdk?.canonicalName == "linuxB")
        }
    }

    @Test(.requireSDKs(.macOS))
    func SDKVariants() async throws {
        // Create an SDK with variants.
        try await withTemporaryDirectory { sdksDirPath in
            let sdkPath = sdksDirPath.join("TestSDK.sdk")
            let sdkIdentifier = "com.apple.sdk.1.0"
            try await writeSDK(name: sdkPath.basename, parentDir: sdksDirPath, settings: [
                "CanonicalName": .plString(sdkIdentifier),
                "Version": "1.0",
                "IsBaseSDK": "YES",
                "DefaultProperties": [
                    "GCC_PREPROCESSOR_DEFINITIONS": "A=B",
                    "PLATFORM_NAME": "macosx",
                ],
                "CustomProperties": [
                    "GCC_PREPROCESSOR_DEFINITIONS": "$(inherited) C=D"
                ],
                "Variants": [
                    [   "Name": "Strawberry",
                        "BuildSettings": [
                            "GCC_PREPROCESSOR_DEFINITIONS": "$(inherited) FLAVOR=Strawberry",
                        ],
                    ] as PropertyListItem,
                    [   "Name": "Vanilla",
                        "BuildSettings": [
                            "GCC_PREPROCESSOR_DEFINITIONS": "$(inherited) FLAVOR=Vanilla",
                        ],
                    ] as PropertyListItem,
                ],
                "DefaultVariant": "Vanilla"
            ])

            // Construct the test project.
            let testWorkspace = try TestWorkspace("Workspace",
                                                  projects: [TestProject("aProject",
                                                                         groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                         buildConfigurations:[
                                                                            TestBuildConfiguration("Debug", buildSettings: [:])
                                                                         ],
                                                                         targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug", buildSettings: [
                                                                                                    "SDKROOT": "\(sdkPath.str)",
                                                                                                ]
                                                                                                                      )],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])]
                                                                                              ),
                                                                         ])
                                                  ]).load(await getCore())
            let context = try await contextForTestData(testWorkspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            // Not overriding SDK_VARIANT - uses the default "Vanilla" variant.
            do {
                let parameters = BuildParameters(action: .build, configuration: "Debug")
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.SDK_VARIANT) == "Vanilla")
                #expect(scope.evaluate(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS) == ["A=B", "FLAVOR=Vanilla", "C=D"])

                #expect(settings.warnings == [])
                #expect(settings.errors == [])
            }

            // Overriding SDK_VARIANT with "" - still uses the default "Vanilla" variant.
            do {
                let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: ["SDK_VARIANT": ""])
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.SDK_VARIANT) == "")
                #expect(scope.evaluate(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS) == ["A=B", "FLAVOR=Vanilla", "C=D"])

                #expect(settings.warnings == [])
                #expect(settings.errors == [])
            }

            // Overriding SDK_VARIANT with "Strawberry" - uses the overriding "Strawberry" value.
            do {
                let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: ["SDK_VARIANT": "Strawberry"])
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
                let scope = settings.globalScope

                #expect(scope.evaluate(BuiltinMacros.SDK_VARIANT) == "Strawberry")
                #expect(scope.evaluate(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS) == ["A=B", "FLAVOR=Strawberry", "C=D"])

                #expect(settings.warnings == [])
                #expect(settings.errors == [])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func SDKBuildVersionConditions() async throws {
        let realRegistry = try await getCore().sdkRegistry
        let macosSDK = try #require(realRegistry.lookup("macosx"))
        let productBuildVersion = try #require(macosSDK.productBuildVersion)

        // Construct the test project.
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: [TestFile("Dummy.cpp")]),
                                                                           buildConfigurations:[
                                                                            TestBuildConfiguration("Debug", buildSettings: [:])
                                                                           ],
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug", buildSettings: [
                                                                                                    "FRAMEWORK_SEARCH_PATHS": "$(inherited) onePath",
                                                                                                    "FRAMEWORK_SEARCH_PATHS[_sdk_build_version=\(productBuildVersion)]" : "$(inherited) twoPath",
                                                                                                    "FRAMEWORK_SEARCH_PATHS[_sdk_build_version=1A1234t]" : "$(inherited) threePath",
                                                                                                ]
                                                                                                                      )],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Dummy.cpp"])]
                                                                                              ),
                                                                           ])
                                                    ]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        // Create the settings and check for expected issues.
        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
        #expect(settings.globalScope.evaluate(BuiltinMacros.FRAMEWORK_SEARCH_PATHS) == ["\(testProject.xcodeprojPath.dirname.str)/build/Debug", "onePath", "twoPath"])
    }

    @Test(.requireHostOS(.macOS))
    func SDKFallbackConditions() async throws {
        // Create an SDK with fallback conditions.
        try await withTemporaryDirectory { sdksDirPath in
            let sdkPath = sdksDirPath.join("TestSDK.sdk")
            let sdkIdentifier = "appletvos"
            try await writeSDK(name: sdkPath.basename, parentDir: sdksDirPath, settings: [
                "CanonicalName": .plString(sdkIdentifier),
                "Version": "1.0",
                "IsBaseSDK": "Yes",
                "DefaultProperties": [
                    "PLATFORM_NAME": "macosx",
                ],
                "PropertyConditionFallbackNames": [
                    "iphoneos",
                    "embedded",
                ],
            ])

            // Construct the test project.
            let files: [Path: String] = [
                .root.join("tmp/Workspace/aProject/ProjectSettings.xcconfig"): (
                    "GCC_PREPROCESSOR_DEFINITIONS = $(inherited) PROJECT_XCCONFIG_BASE=Generic\n" +
                    "GCC_PREPROCESSOR_DEFINITIONS[sdk=iphone*] = $(inherited) PROJECT_XCCONFIG_FLAVOR=iPhone\n" +
                    "GCC_PREPROCESSOR_DEFINITIONS[sdk=appletv*] = $(inherited) PROJECT_XCCONFIG_FLAVOR=AppleTV\n" +
                    "GCC_PREPROCESSOR_DEFINITIONS[sdk=watch*] = $(inherited) PROJECT_XCCONFIG_FLAVOR=Watch\n" +
                    "GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS[sdk=embedded*] = $(inherited) PROJECT_XCCONFIG_FLAVOR=Embedded\n"
                ),
                .root.join("tmp/Workspace/aProject/TargetSettings.xcconfig"): (
                    "GCC_PREPROCESSOR_DEFINITIONS = $(inherited) TARGET_XCCONFIG_BASE=Generic\n" +
                    "GCC_PREPROCESSOR_DEFINITIONS[sdk=iphone*] = $(inherited) TARGET_XCCONFIG_FLAVOR=iPhone\n" +
                    "GCC_PREPROCESSOR_DEFINITIONS[sdk=appletv*] = $(inherited) TARGET_XCCONFIG_FLAVOR=AppleTV\n" +
                    "GCC_PREPROCESSOR_DEFINITIONS[sdk=watch*] = $(inherited) TARGET_XCCONFIG_FLAVOR=Watch\n" +
                    "GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS[sdk=embedded*][config=Debug] = $(inherited) TARGET_XCCONFIG_FLAVOR=Embedded\n"
                ),
            ]
            let testWorkspace = try TestWorkspace("Workspace",
                                                  projects: [TestProject("aProject",
                                                                         groupTree: TestGroup("Sources", children: [
                                                                            TestFile("ProjectSettings.xcconfig"),
                                                                            TestFile("TargetSettings.xcconfig"),
                                                                            TestFile("Mock.cpp"),
                                                                         ]),
                                                                         buildConfigurations:[
                                                                            TestBuildConfiguration("Debug", baseConfig: "ProjectSettings.xcconfig", buildSettings: [
                                                                                "GCC_PREPROCESSOR_DEFINITIONS": "$(inherited) PROJECT_BASE=Generic",
                                                                                "GCC_PREPROCESSOR_DEFINITIONS[sdk=iphone*]": "$(inherited) PROJECT_FLAVOR=iPhone",
                                                                                "GCC_PREPROCESSOR_DEFINITIONS[sdk=appletv*]": "$(inherited) PROJECT_FLAVOR=AppleTV",
                                                                                "GCC_PREPROCESSOR_DEFINITIONS[sdk=watch*]": "$(inherited) PROJECT_FLAVOR=Watch",
                                                                                "GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS[sdk=embedded*][arch=other-arch]": "$(inherited) PROJECT_FLAVOR=Embedded",
                                                                            ])
                                                                         ],
                                                                         targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug", baseConfig: "TargetSettings.xcconfig", buildSettings: [
                                                                                                    "SDKROOT": "\(sdkPath.str)",
                                                                                                    "GCC_PREPROCESSOR_DEFINITIONS": "$(inherited) TARGET_BASE=Generic",
                                                                                                    "GCC_PREPROCESSOR_DEFINITIONS[sdk=iphone*]": "$(inherited) TARGET_FLAVOR=iPhone",
                                                                                                    "GCC_PREPROCESSOR_DEFINITIONS[sdk=appletv*]": "$(inherited) TARGET_FLAVOR=AppleTV",
                                                                                                    "GCC_PREPROCESSOR_DEFINITIONS[sdk=watch*]": "$(inherited) TARGET_FLAVOR=Watch",
                                                                                                    "GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS[sdk=embedded*]": "$(inherited) TARGET_FLAVOR=Embedded",
                                                                                                ]
                                                                                                                      )],
                                                                                               buildPhases: [
                                                                                                TestSourcesBuildPhase(["Mock.cpp"])
                                                                                               ]
                                                                                              ),
                                                                         ])
                                                  ]).load(await getCore())
            let context = try await contextForTestData(testWorkspace, files: files)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            // Evaluate build settings to check that the fallback conditions work properly.
            let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings: \(settings.errors)")
                return
            }

            let scope = settings.globalScope

            // Check that basic passthrough works.
            #expect(scope.evaluate(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS) == ["PROJECT_XCCONFIG_BASE=Generic", "PROJECT_XCCONFIG_FLAVOR=AppleTV", "PROJECT_BASE=Generic", "PROJECT_FLAVOR=AppleTV", "TARGET_XCCONFIG_BASE=Generic", "TARGET_XCCONFIG_FLAVOR=AppleTV", "TARGET_BASE=Generic", "TARGET_FLAVOR=AppleTV"])

            // Check that other conditions are preserved and honored.
            #expect(scope.evaluate(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS) == ["PROJECT_XCCONFIG_FLAVOR=Embedded", "TARGET_XCCONFIG_FLAVOR=Embedded", "TARGET_FLAVOR=Embedded"])
        }
    }

    @Test
    func settingsIssues() async throws {
        do {
            // Construct the test project.
            let testWorkspace = try await TestWorkspace("Workspace",
                                                        projects: [TestProject("aProject",
                                                                               groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                               buildConfigurations:[
                                                                                TestBuildConfiguration("Debug", buildSettings: [:])
                                                                               ],
                                                                               targets: [
                                                                                TestStandardTarget("Target1",
                                                                                                   type: .application,
                                                                                                   buildConfigurations: [
                                                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                                                        "SDKROOT": "bogus",
                                                                                                    ]
                                                                                                                          )],
                                                                                                   buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])]
                                                                                                  ),
                                                                               ])
                                                        ]).load(getCore())
            let context = try await contextForTestData(testWorkspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            // Create the settings and check for expected issues.
            let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(settings.errors == [
                "unable to resolve product type \'com.apple.product-type.application\'",
                "unable to find sdk \'bogus\'",
            ])
        }
    }

    @Test(.requireSDKs(.iOS))
    func watchKitDeprecation() async throws {
        // A test project which uses a deprecated WatchKit 1.0 spec.
        do {
            // Construct the test project.
            let testWorkspace = try await TestWorkspace("Workspace",
                                                        projects: [TestProject("aProject",
                                                                               groupTree: TestGroup("SomeFiles", children: [TestFile("main.swift")]),
                                                                               buildConfigurations:[
                                                                                TestBuildConfiguration("Debug", buildSettings: [:])
                                                                               ],
                                                                               targets: [
                                                                                TestStandardTarget("Target1",
                                                                                                   guid: nil,
                                                                                                   type: .watchKit1App,
                                                                                                   buildConfigurations: [
                                                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                                                        "SDKROOT": "iphoneos",
                                                                                                        "IPHONEOS_DEPLOYMENT_TARGET": "9.0",
                                                                                                        "TARGETED_DEVICE_FAMILY": "1,2",
                                                                                                    ]
                                                                                                                          )],
                                                                                                   buildPhases: [TestSourcesBuildPhase(["main.swift"])])
                                                                               ])
                                                        ]).load(getCore())
            let context = try await contextForTestData(testWorkspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            // Create the settings and check for expected issues.
            let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

            #expect(settings.errors == ["deprecated product type 'com.apple.product-type.application.watchapp' for platform 'iOS'. WatchKit 1.0 is no longer supported.", "deprecated product type 'com.apple.product-type.application.watchapp' for platform 'iOS'. WatchKit 1.0 is no longer supported."])
        }
    }

    @Test
    func previews() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: [TestFile("main.swift")]),
                buildConfigurations:[
                    TestBuildConfiguration("Debug", buildSettings: [:])
                ],
                targets: [
                    TestStandardTarget(
                        "Target1",
                        guid: nil,
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SDKROOT": "iphoneos",
                                "SWIFT_VERSION": "5",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "ENABLE_PREVIEWS": "YES",
                                "ENABLE_DEBUG_DYLIB": "YES",
                                "ENABLE_THREAD_SANITIZER": "YES",
                            ]
                                                  )],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])])
                ])
            ]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        #expect(settings.globalScope.evaluate(BuiltinMacros.ENABLE_PREVIEWS))
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH) == "")

        // <rdar://59605442> Xcode preview app crashes when Thread Sanitizer is enabled
        // rdar://59606050 tracks re-enabling TSan.
        #expect(!settings.globalScope.evaluate(BuiltinMacros.ENABLE_THREAD_SANITIZER))
    }

    @Test(.requireSDKs(.iOS))
    func previewsXOJIT() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: [TestFile("main.swift")]),
                buildConfigurations:[
                    TestBuildConfiguration("Debug", buildSettings: [:])
                ],
                targets: [
                    TestStandardTarget(
                        "Target1",
                        guid: nil,
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SDKROOT": "iphoneos",
                                "SWIFT_VERSION": "5",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                                "ENABLE_DEBUG_DYLIB": "YES",
                                "ENABLE_THREAD_SANITIZER": "YES",
                                "PRODUCT_NAME": "Target1",
                            ]
                                                  )],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])])
                ])
            ]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        #expect(!settings.globalScope.evaluate(BuiltinMacros.ENABLE_PREVIEWS))
        #expect(settings.globalScope.evaluate(BuiltinMacros.ENABLE_XOJIT_PREVIEWS))
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH) == "Target1.app/Target1.debug.dylib")
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME) == "@rpath/Target1.debug.dylib")
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_MAPPED_INSTALL_NAME) == "")
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_BLANK_INJECTION_DYLIB_PATH).suffix(15) == "__preview.dylib")
    }

    @Test(.requireSDKs(.iOS))
    func previewsXOJITWithAnLDClientName() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: [TestFile("main.swift")]),
                buildConfigurations:[
                    TestBuildConfiguration("Debug", buildSettings: [:])
                ],
                targets: [
                    TestStandardTarget(
                        "Target1",
                        guid: nil,
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SDKROOT": "iphoneos",
                                "SWIFT_VERSION": "5",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                                "ENABLE_DEBUG_DYLIB": "YES",
                                "ENABLE_THREAD_SANITIZER": "YES",
                                "LD_CLIENT_NAME": "MyOtherClient",
                                "PRODUCT_NAME": "Target1",
                            ]
                                                  )],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])])
                ])
            ]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        #expect(!settings.globalScope.evaluate(BuiltinMacros.ENABLE_PREVIEWS))
        #expect(settings.globalScope.evaluate(BuiltinMacros.ENABLE_XOJIT_PREVIEWS))
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_PATH) == "Target1.app/Target1.debug.dylib")
        // Should have the client name as the install name
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_INSTALL_NAME) == "@rpath/MyOtherClient.debug.dylib")
        // But should be mapped to the original install name
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_MAPPED_INSTALL_NAME) == "@rpath/Target1.debug.dylib")
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_DEBUG_DYLIB_MAPPED_PLATFORM) == "2")
        #expect(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_BLANK_INJECTION_DYLIB_PATH).suffix(15) == "__preview.dylib")
    }

    @Test(.requireSDKs(.iOS))
    func previewsEnablingDisabling() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                    ]
                ),
                buildConfigurations:[
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ENABLE_PREVIEWS": "YES",
                        "SDKROOT": "iphoneos",
                    ])
                ],
                targets: [
                    // Should be on
                    TestStandardTarget(
                        "Target-on",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SWIFT_VERSION": "5",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "ENABLE_PREVIEWS_EXPECTED": "YES",
                            ]),
                        ],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])]
                    ),

                    // Should be off due to Opt Level
                    TestStandardTarget(
                        "Target-opt-level",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SWIFT_VERSION": "5",
                                "SWIFT_OPTIMIZATION_LEVEL": "-O",
                                "ENABLE_PREVIEWS_EXPECTED": "NO",
                            ]
                                                  )],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])]
                    ),

                    // Should be off because no Swift version
                    TestStandardTarget(
                        "Target-no-swift",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ENABLE_PREVIEWS_EXPECTED": "NO",
                            ]
                                                  )],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])]
                    ),
                ])
            ]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]

        let expectedMacro = try BuiltinMacros.namespace.declareBooleanMacro("ENABLE_PREVIEWS_EXPECTED")

        for testTarget in testProject.targets {
            let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            let actual = settings.globalScope.evaluate(BuiltinMacros.ENABLE_PREVIEWS)
            let expected = settings.globalScope.evaluate(expectedMacro)
            #expect(actual == expected)
            if !expected {
                // We do not currently emit any reasons for disabling in the notes.
                #expect(settings.notes == [])
            }
            else {
                #expect(settings.notes == [])
            }
        }

        // install action should disable previews
        do {
            guard let testTarget = (testProject.targets.first { $0.name == "Target-on" }) else { throw StubError.error("Failed to find expected target") }
            let parameters = BuildParameters(action: .install, configuration: "Debug", overrides: [:])
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(!settings.globalScope.evaluate(BuiltinMacros.ENABLE_PREVIEWS))
            #expect(settings.notes == [])
        }
    }

    @Test(.requireSDKs(.iOS))
    func previewsDisablingHardenedRuntimeWithAdHocSigning() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                    ]
                ),
                buildConfigurations:[
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "iphoneos",
                    ])
                ],
                targets: [
                    // Should be left alone
                    TestStandardTarget(
                        "Target-on",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SWIFT_VERSION": "5",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "ENABLE_HARDENED_RUNTIME": "YES",
                                "MACH_O_TYPE": "mh_execute",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                                "CODE_SIGN_IDENTITY": "An Engineer",

                                "ENABLE_HARDENED_RUNTIME_EXPECTED": "YES",
                            ]),
                        ],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])]
                    ),

                    // Should be force disabled
                    TestStandardTarget(
                        "Target-off",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SWIFT_VERSION": "5",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "ENABLE_HARDENED_RUNTIME": "YES",
                                "MACH_O_TYPE": "mh_execute",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                                "CODE_SIGN_IDENTITY": "-",

                                "ENABLE_HARDENED_RUNTIME_EXPECTED": "NO",
                            ]),
                        ],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])]
                    ),
                ])
            ]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])

        let expectedMacro = try BuiltinMacros.namespace.declareBooleanMacro("ENABLE_HARDENED_RUNTIME_EXPECTED")

        for target in testProject.targets {
            let settings = Settings(
                workspaceContext: context,
                buildRequestContext: buildRequestContext,
                parameters: parameters,
                project: testProject,
                target: target
            )

            let actual = settings.globalScope.evaluate(BuiltinMacros.ENABLE_HARDENED_RUNTIME)
            let expected = settings.globalScope.evaluate(expectedMacro)

            if expected {
                #expect(actual, "Hardened runtime should remain enabled")
                #expect(settings.notes == [])
            }
            else {
                #expect(!actual, "Hardened runtime should be disabled when ad-hoc signed")
                #expect(settings.notes == ["Disabling hardened runtime with ad-hoc codesigning."])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func impartedProperties() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestPackageProject("aProject",
                                                                                  groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                                  buildConfigurations:[
                                                                                    TestBuildConfiguration("Config1", buildSettings: [
                                                                                        "USER_PROJECT_SETTING": "USER_PROJECT_VALUE",
                                                                                        "HEADER_SEARCH_PATHS": "$(inherited) $(SRCROOT)/include /usr/include .",
                                                                                        "FRAMEWORK_SEARCH_PATHS": "$(inherited) /System/Library/Frameworks /Applications/Xcode.app /usr",
                                                                                        "OTHER_LDFLAGS": "-current_version 2.0",
                                                                                    ])],
                                                                                  targets: [
                                                                                    TestStandardTarget("Target1",
                                                                                                       type: .application,
                                                                                                       buildConfigurations: [
                                                                                                        TestBuildConfiguration("Config1", buildSettings: [
                                                                                                            "BUILD_VARIANTS": "normal other",
                                                                                                            "ENABLE_TESTABILITY": "YES",
                                                                                                            "INSTALL_PATH": "",
                                                                                                            // Use this to check conditions end to end.
                                                                                                            "PRODUCT_NAME[sdk=macosx*]": "Foo",
                                                                                                            "USER_TARGET_SETTING": "USER_TARGET_VALUE"])],
                                                                                                       buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace,
            environment: [
                "RC_ARCHS": "x86_64 x86_64h",
            ],
            files: [:]
        )
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let source = BuildConfiguration.MacroBindingSource(key: "OTHER_LDFLAGS", value: .stringList(["$(inherited)", "-lfoo"]))
        let conditionalSource = BuildConfiguration.MacroBindingSource(key: "OTHER_CFLAGS[__platform_filter=macos]", value: .stringList(["$(inherited)", "-DBEST"]))
        let buildProperties = SWBCore.ImpartedBuildProperties(ImpartedBuildProperties(buildSettings: [source, conditionalSource]), PIFLoader(data: .plArray([]), namespace: context.core.specRegistry.internalMacroNamespace))

        let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macOS)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, impartedBuildProperties: [buildProperties])

        // There should be no diagnostics.
        #expect(settings.warnings == [])
        #expect(settings.errors == [])

        #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_LDFLAGS) == ["-current_version", "2.0", "-lfoo"])
        #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_CFLAGS) == ["-DBEST"])
    }

    /// Test that the macOS deployment target is correctly inferred from the iOS deployment target in a number of scenarios when building for macCatalyst.
    ///
    /// Some considerations:
    ///     - The macOS deployment target is only inferred if it is not set; if it is set, then whatever it's set to is used.
    ///     - The iOS deployment target will have its lower bound limited to 13.0, which is the earliest iOS version supported for macCatalyst.
    ///     - The macOS deployment target does *not* have its lower bound limited.  Zippered products may want an older macOS deployment target, while for unzippered products doing this is strange but accepted.
    ///     - However, if the macOS deployment target is outside of the valid range, then a warning will be emitted.
    @Test(.requireSDKs(.macOS))
    func macCatalystVersionMapping() async throws {
        let core = try await getCore()
        // Create an SDK with build variants and version mapping definitions.  This SDK is part of the macOS platform and will use properties from that platform where appropriate.
        try await withTemporaryDirectory { sdksDirPath in
            let sdkPath = sdksDirPath.join("TestSDK.sdk")
            let sdkIdentifier = "macosx"
            try await writeSDK(name: sdkPath.basename, parentDir: sdksDirPath, settings: [
                "CanonicalName": .plString(sdkIdentifier),
                "Version": "1.0",
                "IsBaseSDK": "Yes",
                "DefaultProperties": [
                    "MACOSX_DEPLOYMENT_TARGET": "10.14",
                    "PLATFORM_NAME": "macosx",
                ],
                "DefaultVariant": "default",
                "Variants": [
                    [   "Name": "iosmac",
                        "BuildSettings": [:] as PropertyListItem,
                    ] as PropertyListItem,
                    [   "Name": "trooper",
                        "BuildSettings": [
                            "MACOSX_DEPLOYMENT_TARGET": "10.14",
                        ],
                    ] as PropertyListItem,
                    [   "Name": "default",
                        "BuildSettings": [:] as PropertyListItem,
                    ] as PropertyListItem
                ],
                "SupportedTargets": [
                    "iosmac": [
                        "DefaultDeploymentTarget": "13.0",
                        "MinimumDeploymentTarget": "13.0",
                        "MaximumDeploymentTarget": "13.99",
                    ],
                    "trooper": [:] as PropertyListItem,
                    "default": [:] as PropertyListItem,
                ],
                "VersionMap": [
                    "iOSMac_macOS": [
                        "13.0": "10.15",
                        "13.1": "10.15.1",
                        "14.0": "11.0",
                        "90.0": "87.0"
                    ],
                    "macOS_iOSMac": [
                        "10.15": "13.0",
                        "10.15.1": "13.1",
                        "11.0": "14.0",
                        "87.0": "90.0",
                    ],
                ]
            ])

            // Get platform properties relevant to tests.
            guard let macOSPlatform = core.platformRegistry.lookup(name: "macosx") else {
                Issue.record("Unable to lookup macOS platform.")
                return
            }
            guard let platformMinDeploymentTarget = macOSPlatform.deploymentTargetRange.start else {
                Issue.record("Unable to lookup minimum deployment target for macOS platform from range: \(macOSPlatform.deploymentTargetRange)")
                return
            }
            guard let platformMaxDeploymentTarget = macOSPlatform.deploymentTargetRange.end else {
                Issue.record("Unable to lookup maximum deployment target for macOS platform from range: \(macOSPlatform.deploymentTargetRange)")
                return
            }

            // Construct the test project.
            let files: [Path: String] = [
                .root.join("tmp/Workspace/aProject/ProjectSettings.xcconfig"): (
                    "IPHONEOS_DEPLOYMENT_TARGET=13.0\n"
                ),
            ]

            typealias DeploymentTargetTestCaseData = (
                target: TestStandardTarget,
                expectedMacOSDeploymentTarget: String?,
                expectedIOSDeploymentTarget: String?,
                expectedWarnings: [String],
                expectedErrors: [String]
            )
            let targets = [
                // Non-macCatalyst case: The effective macOS deployment target should be the one in the SDK.
                (
                    TestStandardTarget("Target1",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.14",
                    nil,
                    [],
                    []
                ),
                // macCatalyst case: The iOS deployment target should be the value from the macCatalyst target info, and the macOS deployment target should match it since we're building an unzippered target.
                (
                    TestStandardTarget("Target2",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.15",
                    "13.0",
                    [],
                    []
                ),
                // macCatalyst case: The iOS deployment target should be the value from the macCatalyst target info, and the macOS deployment target should match it since we're building an unzippered target.
                (
                    TestStandardTarget("Target3",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "MACOSX_DEPLOYMENT_TARGET": "",
                                            "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.15",
                    "13.0",
                    [],
                    []
                ),
                // Non-macCatalyst case: The effective macOS deployment target should be the one from the "trooper" SDK variant.
                (
                    TestStandardTarget("Target4",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "SDK_VARIANT": "trooper",
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.14",
                    nil,
                    [],
                    []
                ),
                // Non-macCatalyst case: The effective macOS deployment target should be the one defined in this target.
                (
                    TestStandardTarget("Target5",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "MACOSX_DEPLOYMENT_TARGET": "101",
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "101",
                    nil,
                    ["[targetIntegrity] The macOS deployment target \'MACOSX_DEPLOYMENT_TARGET\' is set to 101, but the range of supported deployment target versions is \(platformMinDeploymentTarget) to \(platformMaxDeploymentTarget). (in target 'Target5' from project 'aProject')"],
                    []
                ),
                // macCatalyst case: The iOS deployment target should be the value from the macCatalyst target info, and the macOS deployment target should match it since we're building an unzippered target.
                (
                    TestStandardTarget("Target6",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "MACOSX_DEPLOYMENT_TARGET": "10.18",
                                            "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.15",
                    "13.0",
                    [],
                    []
                ),
                // macCatalyst case: The iOS deployment target should be the value from defined in the target, and the macOS deployment target should match it since we're building an unzippered target.
                (
                    TestStandardTarget("Target7",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "IPHONEOS_DEPLOYMENT_TARGET": "90.0",
                                            "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "87.0",
                    "90.0",
                    ["[targetIntegrity] The Mac Catalyst deployment target \'IPHONEOS_DEPLOYMENT_TARGET\' is set to 90.0, but the range of supported deployment target versions is 13.0 to 13.99. (in target 'Target7' from project 'aProject')",
                     "[targetIntegrity] The macOS deployment target \'MACOSX_DEPLOYMENT_TARGET\' is set to 87.0, but the range of supported deployment target versions is \(platformMinDeploymentTarget) to \(platformMaxDeploymentTarget). (in target 'Target7' from project 'aProject')"],
                    []
                ),
                // macCatalyst case: The iOS deployment target should be the value from defined in the target, and the macOS deployment target should match it since we're building an unzippered target.
                (
                    TestStandardTarget("Target8",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "IPHONEOS_DEPLOYMENT_TARGET": "13.1",
                                            "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.15.1",
                    "13.1",
                    [],
                    []
                ),
                // Non-macCatalyst case: Since this is a zippered target, both the iOS and macOS deployment targets defined in the target should be preserved.
                (
                    TestStandardTarget("Target9",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "MACOSX_DEPLOYMENT_TARGET": "10.13",
                                            "IPHONEOS_DEPLOYMENT_TARGET": "13.0",
                                            "IS_ZIPPERED": "YES",
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.13",
                    "13.0",
                    [],
                    []
                ),
                // macCatalyst case: Since this is a zippered target, both the iOS and macOS deployment targets defined in the target should be preserved.
                (
                    TestStandardTarget("Target10",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "MACOSX_DEPLOYMENT_TARGET": "10.13",
                                            "IPHONEOS_DEPLOYMENT_TARGET": "13.0",
                                            "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                                            "IS_ZIPPERED": "YES",
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.13",
                    "13.0",
                    [],
                    []
                ),
                // Non-macCatalyst case: Since this is a zippered target, the macOS deployment target defined in the target should be preserved, but the iOS deployment target should be set to the lower limit.
                (
                    TestStandardTarget("Target11",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "MACOSX_DEPLOYMENT_TARGET": "10.13",
                                            "IPHONEOS_DEPLOYMENT_TARGET": "10.0",
                                            "IS_ZIPPERED": "YES",
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.13",
                    "13.0",
                    [],
                    []
                ),
                // Non-macCatalyst case: Since this is a zippered target, the macOS deployment target defined in the target should be preserved, and the iOS deployment target should be derived from it.
                (
                    TestStandardTarget("Target12",
                                       type: .application,
                                       buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "SDKROOT": "\(sdkPath.str)",
                                            "MACOSX_DEPLOYMENT_TARGET": "10.15.1",
                                            "IPHONEOS_DEPLOYMENT_TARGET": "",
                                            "IS_ZIPPERED": "YES",
                                        ]
                                                              )],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["Mock.cpp"])
                                       ]
                                      ),
                    "10.15.1",
                    "13.1",
                    [],
                    []
                ),
            ] as [DeploymentTargetTestCaseData]
            let testWorkspace = try TestWorkspace("Workspace",
                                                  projects: [TestProject("aProject",
                                                                         groupTree: TestGroup("Sources", children: [
                                                                            TestFile("ProjectSettings.xcconfig"),
                                                                            TestFile("Mock.cpp"),
                                                                         ]),
                                                                         buildConfigurations:[
                                                                            TestBuildConfiguration("Debug", baseConfig: "ProjectSettings.xcconfig", buildSettings: [:])
                                                                         ],
                                                                         targets: targets.map({ $0.target })
                                                                        )
                                                  ]).load(core)
            let context = try await contextForTestData(testWorkspace, files: files)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]

            // Evaluate build settings to check that the deployment target is properly defaulted.
            let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
            for n in 0..<targets.count {
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testProject.targets[n])
                let scope = settings.globalScope
                // If an expected deployment target is nil, then we don't care what the value is for that case.  Settings.addPlatformSettings() defines backstop values for all known platforms, but in scenarios where the value doesn't matter we explicitly ignore it here.
                if let expectedMacOSDeploymentTarget = targets[n].expectedMacOSDeploymentTarget {
                    #expect(scope.evaluate(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET) == expectedMacOSDeploymentTarget)
                }
                if let expectedIOSDeploymentTarget = targets[n].expectedIOSDeploymentTarget {
                    #expect(scope.evaluate(BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET) == expectedIOSDeploymentTarget)
                }
                let configuredTarget = ConfiguredTarget(parameters: parameters, target: testProject.targets[n])
                func DiagnosticDatas(_ settings: Settings, _ behavior: Diagnostic.Behavior) -> [String] {
                    let diagnostics = [nil: settings.diagnostics.elements, configuredTarget: settings.targetDiagnostics.elements]
                    return diagnostics.formatLocalizedDescription(.debugWithoutBehavior, workspace: context.workspace, filter: { $0.behavior == behavior })
                }
                #expect(settings.warnings + DiagnosticDatas(settings, .warning) == targets[n].expectedWarnings)
                #expect(settings.errors + DiagnosticDatas(settings, .error) == targets[n].expectedErrors)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func exportedSwiftResponseFileMacro() async throws {
        let archs = ["x86_64", "x86_64h"]

        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: [TestFile("main.swift")]),
                targets: [
                    TestStandardTarget(
                        "Target1",
                        guid: nil,
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS": archs.joined(separator: " "),
                                "VALID_ARCHS": "$(inherited) x86_64h",
                                "BUILD_VARIANTS": "normal",
                                "PRODUCT_NAME": "Target1",

                                // remove in rdar://53000820
                                "USE_SWIFT_RESPONSE_FILE": "YES",
                            ])],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])])
                ])
            ]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]
        let srcroot = testProject.sourceRoot

        let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .anyMac)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        for arch in archs {
            let macroName = "SWIFT_RESPONSE_FILE_PATH_normal_\(arch)"

            #expect(settings.exportedMacroNames.contains { $0.name == macroName }, "Expected that exported macro names contain Swift response file for each architecture. Didn't find \(macroName) in \(settings.exportedMacroNames)")
            #expect(!settings.exportedNativeMacroNames.contains { $0.name == "SWIFT_RESPONSE_FILE_PATH_normal_\(arch)" }, "Expected that exported native macro names doesn't contain Swift response file for each architecture. Did find \(macroName) in \(settings.exportedMacroNames)")

            let macro = try #require(settings.userNamespace.lookupMacroDeclaration(macroName))
            #expect(settings.globalScope.evaluateAsString(macro) == srcroot.join("build/aProject.build/Debug/Target1.build/Objects-normal/\(arch)/Target1.SwiftFileList").str)
        }
    }

    /// Check the behavior of user defined settings, especially w.r.t. quoting rules.
    @Test(.requireSDKs(.macOS))
    func buildDatabaseLocationOverride() async throws {
        // Set up a trivial macOS project.
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: []),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: [
                                                                                                                        "USER_HEADER_SEARCH_PATHS": "$(USER_PARAMETER)",
                                                                                                                        "BUILD_DESCRIPTION_CACHE_DIR": "/var/tmp/cache",
                                                                                                                       ])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [
            "BUILD_DESCRIPTION_CACHE_DIR": "/var/tmp/cache_override"
        ])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        guard settings.errors.isEmpty else {
            Issue.record("Errors creating settings: \(settings.errors)")
            return
        }

        let scope = settings.globalScope
        #expect(scope.evaluate(BuiltinMacros.BUILD_DESCRIPTION_CACHE_DIR) == "/var/tmp/cache_override")
    }

    /// Test disabling various `ENABLE_DEFAULT_SEARCH_PATHS` settings.
    @Test(.requireSDKs(.macOS))
    func defaultSearchPaths() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: []),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: [
                                                                                                                        "ENABLE_DEFAULT_SEARCH_PATHS": "YES",
                                                                                                                       ]
                                                                                                                      )
                                                                                               ]
                                                                                              )
                                                                           ]
                                                                          )]
        ).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        func createSettings(with overrides: [String: String] = [:], _ checkSettings: ((Settings) -> Void), sourceLocation: SourceLocation = #_sourceLocation) {
            let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: overrides)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings: \(settings.errors)", sourceLocation: sourceLocation)
                return
            }

            checkSettings(settings)
        }

        // Test the default behavior.
        createSettings() { settings in
            let scope = settings.globalScope
            #expect(scope.evaluate(BuiltinMacros.HEADER_SEARCH_PATHS) == ["\(testProject.xcodeprojPath.dirname.str)/build/Debug/include"])
            #expect(scope.evaluate(BuiltinMacros.FRAMEWORK_SEARCH_PATHS) == ["\(testProject.xcodeprojPath.dirname.str)/build/Debug"])
            #expect(scope.evaluate(BuiltinMacros.LIBRARY_SEARCH_PATHS) == ["\(testProject.xcodeprojPath.dirname.str)/build/Debug"])
            #expect(scope.evaluate(BuiltinMacros.REZ_SEARCH_PATHS) == ["\(testProject.xcodeprojPath.dirname.str)/build/Debug"])
            #expect(scope.evaluate(BuiltinMacros.SWIFT_INCLUDE_PATHS) == ["\(testProject.xcodeprojPath.dirname.str)/build/Debug"])
        }

        // Test disabling ENABLE_DEFAULT_SEARCH_PATHS.
        createSettings(with: ["ENABLE_DEFAULT_SEARCH_PATHS": "NO"]) { settings in
            let scope = settings.globalScope
            #expect(scope.evaluate(BuiltinMacros.HEADER_SEARCH_PATHS) == [])
            #expect(scope.evaluate(BuiltinMacros.FRAMEWORK_SEARCH_PATHS) == [])
            #expect(scope.evaluate(BuiltinMacros.LIBRARY_SEARCH_PATHS) == [])
            #expect(scope.evaluate(BuiltinMacros.REZ_SEARCH_PATHS) == [])
            #expect(scope.evaluate(BuiltinMacros.SWIFT_INCLUDE_PATHS) == [])
        }

        // Test each individual setting.
        for searchPathMacro in [
            BuiltinMacros.HEADER_SEARCH_PATHS,
            BuiltinMacros.FRAMEWORK_SEARCH_PATHS,
            BuiltinMacros.LIBRARY_SEARCH_PATHS,
            BuiltinMacros.REZ_SEARCH_PATHS,
            BuiltinMacros.SWIFT_INCLUDE_PATHS,
        ] {
            let settingName = "\(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS.name)_IN_\(searchPathMacro.name)"
            createSettings(with: [settingName: "NO"]) { settings in
                let scope = settings.globalScope
                #expect(scope.evaluate(BuiltinMacros.HEADER_SEARCH_PATHS) == (searchPathMacro == BuiltinMacros.HEADER_SEARCH_PATHS ? [] : ["\(testProject.xcodeprojPath.dirname.str)/build/Debug/include"]))
                #expect(scope.evaluate(BuiltinMacros.FRAMEWORK_SEARCH_PATHS) == (searchPathMacro == BuiltinMacros.FRAMEWORK_SEARCH_PATHS ? [] : ["\(testProject.xcodeprojPath.dirname.str)/build/Debug"]))
                #expect(scope.evaluate(BuiltinMacros.LIBRARY_SEARCH_PATHS) == (searchPathMacro == BuiltinMacros.LIBRARY_SEARCH_PATHS ? [] : ["\(testProject.xcodeprojPath.dirname.str)/build/Debug"]))
                #expect(scope.evaluate(BuiltinMacros.REZ_SEARCH_PATHS) == (searchPathMacro == BuiltinMacros.REZ_SEARCH_PATHS ? [] : ["\(testProject.xcodeprojPath.dirname.str)/build/Debug"]))
                #expect(scope.evaluate(BuiltinMacros.SWIFT_INCLUDE_PATHS) == (searchPathMacro == BuiltinMacros.SWIFT_INCLUDE_PATHS ? [] : ["\(testProject.xcodeprojPath.dirname.str)/build/Debug"]))
            }
        }
    }

    /// Test  analysis performed in `SettingsBuilder.analyzeSettings()`.
    ///
    /// Also note that if we ever move invocation of the `analyzeSettings()` to the point where issues are emitted <rdar://84686692> then this method will need to change to call that method explicitly.
    @Test(.requireSDKs(.macOS))
    func analyzeSettings() async throws {
        let core = try await getCore()

        // Test warnings we expect to see.
        try await withTemporaryDirectory { sdksDirPath in
            let macos13_0Path = sdksDirPath.join("macOS13.0.sdk")
            let macos13_0Identifier = "macosx13.0.bogus"
            try await writeSDK(name: macos13_0Path.basename, parentDir: sdksDirPath, settings: [
                "CanonicalName": .plString(macos13_0Identifier),
                "Version": "13.0",
                "IsBaseSDK": "Yes",
                "DefaultProperties": [
                    "PLATFORM_NAME": "macosx",
                ],
            ])
            let ios16_0Path = sdksDirPath.join("iphoneos16.0.sdk")
            let ios16_0Identifier = "iphoneos16.0.bogus"
            try await writeSDK(name: ios16_0Path.basename, parentDir: sdksDirPath, settings: [
                "CanonicalName": .plString(ios16_0Identifier),
                "Version": "16.0",
                "IsBaseSDK": "Yes",
                "DefaultProperties": [
                    "PLATFORM_NAME": "macosx",
                ],
            ])

            let testWorkspace = try TestWorkspace("Workspace",
                                                  projects: [
                                                    TestProject("aProject",
                                                                groupTree: TestGroup("SomeFiles", children: [
                                                                    TestFile("Mock.m"),
                                                                    TestFile("StringAndDict.xcstrings"), // suppose this one got migrated to xcstrings
                                                                ]),
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                        "SDKROOT": "\(macos13_0Path.str)",
                                                                        "SDKROOT[sdk=macosx*][variant=profile]": "\(macos13_0Path.str)",
                                                                        "CLANG_CXX_LIBRARY": "libstdc++",
                                                                        "DIAGNOSE_LOCALIZATION_FILE_EXCLUSION": "YES",
                                                                        "INCLUDED_SOURCE_FILE_NAMES": "Foo/Localizable.strings Foo/Localizable.xcstrings StringAndDict.strings*",
                                                                        "LOCALIZATION_PREFERS_STRING_CATALOGS": "NO",
                                                                    ])
                                                                ],
                                                                targets: [
                                                                    TestStandardTarget("AppTarget",
                                                                                       type: .application,
                                                                                       buildConfigurations: [
                                                                                        TestBuildConfiguration("Debug", buildSettings: [
                                                                                            "SDKROOT[sdk=iphoneos*]": "\(ios16_0Path.str)",
                                                                                            "EXCLUDED_SOURCE_FILE_NAMES": "Localizable.strings Src/Other.strings Src/Other.stringsdict Src/Other.xcstrings Modern.xcstrings OtherStringAndDict.strings*",
                                                                                        ]
                                                                                                              )],
                                                                                       buildPhases: [
                                                                                        TestSourcesBuildPhase(["Mock.m"]),
                                                                                        TestResourcesBuildPhase(["StringAndDict.xcstrings"]),
                                                                                       ]
                                                                                      ),
                                                                ]
                                                               )
                                                  ]
            ).load(core)

            let context = try await contextForTestData(testWorkspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(settings.project === testProject)
            #expect(settings.target === testTarget)
            if settings.errors.isEmpty {
                #expect(Set(settings.warnings) == [
                    "SDK condition on SDKROOT is unsupported, so the SDKROOT[sdk=macosx*][variant=profile] assignment at the project level will be ignored.",
                    "SDK condition on SDKROOT is unsupported, so the SDKROOT[sdk=iphoneos*] assignment at the target level will be ignored.",
                    "CLANG_CXX_LIBRARY is set to \'libstdc++\': The \'libstdc++\' C++ Standard Library is no longer available, and this setting can be removed.",
                    "The pattern with prefix 'Localizable' in EXCLUDED_SOURCE_FILE_NAMES at the target level matches strings files, but not stringsdict and xcstrings files. Consider using a file extension pattern such as '.*' or '.*strings*'",
                    "The pattern with prefix 'Foo/Localizable' in INCLUDED_SOURCE_FILE_NAMES at the project level matches strings and xcstrings files, but not stringsdict files. Consider using a file extension pattern such as '.*' or '.*strings*'",
                    "The pattern with prefix 'StringAndDict' in INCLUDED_SOURCE_FILE_NAMES at the project level matches strings and stringsdict files, but not xcstrings files. Consider using a file extension pattern such as '.*' or '.*strings*'",
                    // Shouldn't warn about OtherStringAndDict.strings* because there is no such xcstrings file in the project anyway.
                ])
            } else {
                Issue.record("Errors creating settings: \(settings.errors)")
            }
        }

        // Test cases where we don't expect to see warnings (but might if the settings were configured slightly differently).
        do {
            let testWorkspace = try TestWorkspace("Workspace",
                                                  projects: [
                                                    TestProject("aProject",
                                                                groupTree: TestGroup("SomeFiles",
                                                                                     children: []
                                                                                    ),
                                                                buildConfigurations: [
                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                        "CLANG_CXX_LIBRARY": "libc++",
                                                                        "DIAGNOSE_LOCALIZATION_FILE_EXCLUSION": "NO",
                                                                        "EXCLUDED_SOURCE_FILE_NAMES": "Localizable.strings",
                                                                    ])
                                                                ]
                                                               )
                                                  ]
            ).load(core)

            let context = try await contextForTestData(testWorkspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject)
            #expect(settings.project === testProject)
            #expect(settings.target === nil)
            if settings.errors.isEmpty {
                #expect(settings.warnings.isEmpty, "unexpected warnings: \(settings.warnings)")
            } else {
                Issue.record("Errors creating settings: \(settings.errors)")
            }
        }

        // We expect errors here
        do {
            let testWorkspace = try TestWorkspace(
                "Workspace",
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: []
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PATH_FOR_TOOLS": "$(DEVELOPER_DIR)/$(TOOLCHAIN_DIR)/usr/bin",
                                    "INSTALL_PATH": "$(PATH_FOR_TOOLS)",

                                    "COMMON_SEARCH_PATHS": "/abc $(DEVELOPER_INSTALL_DIR)",

                                    "FRAMEWORK_SEARCH_PATHS": "$(COMMON_SEARCH_PATHS) $(DT_TOOLCHAIN_DIR)",
                                    "LIBRARY_SEARCH_PATHS": "$(COMMON_SEARCH_PATHS) $(DT_TOOLCHAIN_DIR)",

                                    "DIAGNOSE_LOCALIZATION_FILE_EXCLUSION": "YES_ERROR",
                                    "EXCLUDED_SOURCE_FILE_NAMES": "Localizable.strings Src/Other.stringsdict Src/Migrated.strings*",
                                    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
                                ])
                        ]
                    )
                ]
            ).load(core)

            let context = try await contextForTestData(testWorkspace)
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject)
            #expect(settings.project === testProject)
            #expect(settings.target === nil)
            #expect(settings.warnings == [])
            #expect(Set(settings.errors) == Set([
                "DEVELOPER_DIR cannot be used to evaluate INSTALL_PATH, use DEVELOPER_INSTALL_DIR instead",
                "TOOLCHAIN_DIR cannot be used to evaluate INSTALL_PATH, use DT_TOOLCHAIN_DIR instead",
                "DT_TOOLCHAIN_DIR cannot be used to evaluate FRAMEWORK_SEARCH_PATHS, use TOOLCHAIN_DIR instead",
                "DT_TOOLCHAIN_DIR cannot be used to evaluate LIBRARY_SEARCH_PATHS, use TOOLCHAIN_DIR instead",
                "The pattern with prefix 'Localizable' in EXCLUDED_SOURCE_FILE_NAMES at the project level matches strings files, but not stringsdict and xcstrings files. Consider using a file extension pattern such as '.*' or '.*strings*'",
                "The pattern with prefix 'Src/Other' in EXCLUDED_SOURCE_FILE_NAMES at the project level matches stringsdict files, but not strings and xcstrings files. Consider using a file extension pattern such as '.*' or '.*strings*'",
                "The pattern with prefix 'Src/Migrated' in EXCLUDED_SOURCE_FILE_NAMES at the project level matches strings and stringsdict files, but not xcstrings files. Consider using a file extension pattern such as '.*' or '.*strings*'",
            ]))
        }
    }

    @Test(.requireSDKs(.macOS))
    func autoSDKROOTReplacement() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: [
                                                                                                                        "SDKROOT": "auto",
                                                                                                                        "SUPPORTED_PLATFORMS": "macosx"
                                                                                                                       ])],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macOS)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(settings.globalScope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("macosx")?.path)
        }

        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .iOS)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(settings.errors == [
                "unable to resolve product type \'com.apple.product-type.application\'",
                "unable to find sdk \'auto\'",
            ])
            #expect(settings.warnings == [])
            #expect(settings.globalScope.evaluate(BuiltinMacros.SDKROOT).str == "auto")
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func autoSDKROOTReplacementForMacCatalyst() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [TestProject("aProject",
                                                                           groupTree: TestGroup("SomeFiles", children: [TestFile("Mock.cpp")]),
                                                                           targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug",
                                                                                                                       buildSettings: [
                                                                                                                        "SDKROOT": "auto",
                                                                                                                        "SUPPORTED_PLATFORMS": "iphoneos",
                                                                                                                        "SUPPORTS_MACCATALYST": "YES",
                                                                                                                       ])],
                                                                                               buildPhases: [TestSourcesBuildPhase(["Mock.cpp"])])])]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macOS)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(settings.errors == [
                "unable to resolve product type \'com.apple.product-type.application\'",
                "unable to find sdk \'auto\'",
            ])
            #expect(settings.warnings == [])
            #expect(settings.globalScope.evaluate(BuiltinMacros.SDKROOT).str == "auto")
        }

        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macCatalyst)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(settings.globalScope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("macosx")?.path)
        }

        do {
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .iOS)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(settings.globalScope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("iphoneos")?.path)
        }
    }

    /// Test that `Settings` objects created for different purposes have the intended content for that purpose.
    @Test(.requireSDKs(.macOS))
    func settingsForDifferentPurposes() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [
                                                        TestProject("aProject",
                                                                    groupTree: TestGroup("SomeFiles"),
                                                                    buildConfigurations: [
                                                                        TestBuildConfiguration("Debug", buildSettings: [
                                                                            "SDKROOT": "macosx",
                                                                            "FOO": "project-$(inherited)",
                                                                            "FOO[sdk=macosx*]": "macos_$(inherited)",
                                                                            "FOO[sdk=iphone*]": "ios_$(inherited)",
                                                                            "BAZ": "project-$(inherited)",
                                                                        ])
                                                                    ],
                                                                    targets: [
                                                                        TestAggregateTarget("AggregateTarget",
                                                                                            buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug", buildSettings: [
                                                                                                    "BAZ": "target-$(inherited)",
                                                                                                ])
                                                                                            ]
                                                                                           )
                                                                    ]
                                                                   )
                                                    ]
        ).load(getCore())
        let context = try await contextForTestData(testWorkspace, environment: ["BAZ": "environment-$(inherited)"])
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(
            action: .build,
            configuration: "Debug",
            overrides: ["BAZ": "overrides-$(inherited)"],
            commandLineOverrides: ["BAZ": "commandline-$(inherited)"],
            commandLineConfigOverrides: ["BAZ": "commandlineconfig-$(inherited)"],
            environmentConfigOverrides: ["BAZ": "environmentconfig-$(inherited)"])

        // The .build purpose includes overrides and binds conditional settings to a specific SDK.  (The overrides testing here is not as comprehensive as in testSettingOverrides().)
        do {
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, purpose: .build)

            let diagnosticErrors = settings.diagnostics.filter { $0.behavior == .error }
            guard diagnosticErrors.isEmpty else {
                Issue.record("Errors creating settings: \(diagnosticErrors)")
                return
            }
            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings: \(settings.errors)")
                return
            }

            // Note that by default a build-purposed Settings' globalScope is bound to an SDK condition (as well as being bound to the SDK in several other ways).
            let scope = settings.globalScope

            // Check that overriding settings have been applied.
            #expect(scope.evaluateAsString(try #require(settings.userNamespace.lookupMacroDeclaration("BAZ"))) == "environmentconfig-commandlineconfig-commandline-overrides-target-project-environment-")

            // Check that we're bound to the SDK.
            // First, check that evaluating settings takes the SDK into account.
            #expect(scope.evaluateAsString(try #require(settings.userNamespace.lookupMacroDeclaration("FOO"))) == "macos_project-")
            // Second, check that only assignments using the bound SDK - or which don't use the SDK at all - are still in the table.
            var foo: MacroValueAssignment? = scope.table.lookupMacro(try #require(settings.userNamespace.lookupMacroDeclaration("FOO")))
            #expect(foo?.conditions?.description == nil)          // The condition has been removed because the assignment has been bound to the macOS SDK
            #expect(foo?.expression.stringRep == "macos_$(inherited)")
            foo = foo?.next
            #expect(foo?.conditions?.description == nil)
            #expect(foo?.expression.stringRep == "project-$(inherited)")
            foo = foo?.next
            #expect(foo == nil)
        }

        // The .editor purpose excludes overrides and does not bind conditional settings to a specific SDK.
        do {
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, purpose: .editor)

            let diagnosticErrors = settings.diagnostics.filter { $0.behavior == .error }
            guard diagnosticErrors.isEmpty else {
                Issue.record("Errors creating settings: \(diagnosticErrors)")
                return
            }
            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings: \(settings.errors)")
                return
            }

            // Note that the globalScope for this Settings object will not be bound to an SDK, unlike a build-purposed Settings' globalScope.
            let scope = settings.globalScope

            // Check that overriding settings have not been applied.
            #expect(scope.evaluateAsString(try #require(settings.userNamespace.lookupMacroDeclaration("BAZ"))) == "target-project-environment-")

            // Check that we're not bound to the SDK.
            // First, check that evaluating settings doesn't take the SDK into account.
            #expect(scope.evaluateAsString(try #require(settings.userNamespace.lookupMacroDeclaration("FOO"))) == "project-")
            // Second, check that all the assignments based on the SDK are still in the table.
            var foo: MacroValueAssignment? = scope.table.lookupMacro(try #require(settings.userNamespace.lookupMacroDeclaration("FOO")))
            #expect(foo?.conditions?.description == "[sdk=macosx*]")
            #expect(foo?.expression.stringRep == "macos_$(inherited)")
            foo = foo?.next
            #expect(foo?.conditions?.description == "[sdk=iphone*]")
            #expect(foo?.expression.stringRep == "ios_$(inherited)")
            foo = foo?.next
            #expect(foo?.conditions?.description == nil)
            #expect(foo?.expression.stringRep == "project-$(inherited)")
            foo = foo?.next
            #expect(foo == nil)
        }
    }


    /// Test settings which are set for different kinds of builds, such as `IS_UNOPTIMIZED_BUILD`.
    @Test(.requireSDKs(.macOS))
    func settingsDescribingTypeOfBuild() async throws {
        let testWorkspace = try await TestWorkspace("Workspace",
                                                    projects: [
                                                        TestProject("aProject",
                                                                    groupTree: TestGroup("SomeFiles"),
                                                                    buildConfigurations: [
                                                                        TestBuildConfiguration("Debug", buildSettings: [
                                                                            "SDKROOT": "macosx",
                                                                        ])
                                                                    ],
                                                                    targets: [
                                                                        TestAggregateTarget("AggregateTarget",
                                                                                            buildConfigurations: [
                                                                                                TestBuildConfiguration("Debug")
                                                                                            ]
                                                                                           )
                                                                    ]
                                                                   )
                                                    ]
        ).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        // If either GCC_OPTIMIZATION_LEVEL or SWIFT_OPTIMIZATION_LEVEL is unoptimized, then IS_UNOPTIMIZED_BUILD is YES.
        func checkIsDebugBuild(_ overrides: [String: String], expectedValue: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
            let parameters = BuildParameters(
                action: .build,
                configuration: "Debug",
                overrides: overrides)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, purpose: .build)

            let diagnosticErrors = settings.diagnostics.filter { $0.behavior == .error }
            guard diagnosticErrors.isEmpty else {
                Issue.record("Errors creating settings: \(diagnosticErrors)", sourceLocation: sourceLocation)
                return
            }
            guard settings.errors.isEmpty else {
                Issue.record("Errors creating settings: \(settings.errors)", sourceLocation: sourceLocation)
                return
            }

            let scope = settings.globalScope

            #expect(scope.evaluate(BuiltinMacros.IS_UNOPTIMIZED_BUILD) == expectedValue)
        }
        checkIsDebugBuild(["GCC_OPTIMIZATION_LEVEL": "0", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"], expectedValue: true)
        checkIsDebugBuild(["GCC_OPTIMIZATION_LEVEL": "s", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"], expectedValue: true)
        checkIsDebugBuild(["GCC_OPTIMIZATION_LEVEL": "0", "SWIFT_OPTIMIZATION_LEVEL": "-O"], expectedValue: true)
        checkIsDebugBuild(["GCC_OPTIMIZATION_LEVEL": "s", "SWIFT_OPTIMIZATION_LEVEL": "-O"], expectedValue: false)
    }

    /// Test that having a missing platform defaults to an unknown
    /// `EFFECTIVE_PLATFORM_NAME`, ie. that we don't default to the macOS
    /// build directory.
    @Test
    func settingsWithoutPlatform() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup("SomeFiles"),
                    targets: [
                        TestStandardTarget(
                            "SomeTarget",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug")
                            ])
                    ])
            ]).load(getCore())

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let runDestination = RunDestinationInfo(platform: "noplatform", sdk: "customsdk", sdkVariant: nil, targetArchitecture: "arm64", supportedArchitectures: ["arm64"], disableOnlyActiveArch: false)
        let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: runDestination, overrides: ["SDKROOT": "customsdk"])

        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, purpose: .build)
        #expect(settings.globalScope.evaluate(BuiltinMacros.EFFECTIVE_PLATFORM_NAME) == "-unknown")
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationAllowScriptsHandlesSandboxingOptOut() async throws {
        let testWorkspace = TestWorkspace("Workspace",
                                          projects: [
                                            TestProject(
                                                "aProject",
                                                groupTree: TestGroup("Sources", path: "Sources", children: [
                                                    TestFile("A.m"),
                                                ]),
                                                targets: [
                                                    TestStandardTarget(
                                                        "A", type: .framework,
                                                        buildConfigurations: [
                                                            TestBuildConfiguration("Debug", buildSettings: [
                                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                                                            ])],
                                                        buildPhases: [
                                                            TestSourcesBuildPhase([TestBuildFile("A.m")]),
                                                            TestShellScriptBuildPhase(
                                                                name: "A Script",
                                                                originalObjectID: "A Script",
                                                                contents: "true",
                                                                outputs: ["/lunch.txt"],
                                                                sandboxingOverride: .forceDisabled
                                                            ),
                                                        ]),
                                                ]
                                            )
                                          ])

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkNote("A script phase disables sandboxing, forcing `EAGER_COMPILATION_ALLOW_SCRIPTS` to off (in target \'A\' from project \'aProject\')")

            results.checkTarget("A") { target in
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: target.parameters, project: context.workspace.project(for: target.target), target: target.target, purpose: .build)
                #expect(!settings.globalScope.evaluate(BuiltinMacros.EAGER_COMPILATION_ALLOW_SCRIPTS))
            }
        }
    }

    @Test
    func buildSettingsEnforcedAbsolutePaths() async throws {
        let buildSettingsToEnforce = [
            BuiltinMacros.SRCROOT, BuiltinMacros.SYMROOT, BuiltinMacros.OBJROOT, BuiltinMacros.DSTROOT,
            BuiltinMacros.LOCROOT, BuiltinMacros.LOCSYMROOT,
            BuiltinMacros.CCHROOT,
            BuiltinMacros.CONFIGURATION_BUILD_DIR, BuiltinMacros.SHARED_PRECOMPS_DIR,
            BuiltinMacros.CONFIGURATION_TEMP_DIR, BuiltinMacros.TARGET_TEMP_DIR, BuiltinMacros.TEMP_DIR,
            BuiltinMacros.PROJECT_DIR, BuiltinMacros.BUILT_PRODUCTS_DIR
        ].map {
            (key: $0, value: $0.name)
        }
        let projRoot = Path.root.join("root")
        let testWorkspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "Project",
                    sourceRoot: projRoot,
                    groupTree: TestGroup("SomeGroup"),
                    targets: [
                        TestStandardTarget(
                            "SomeTarget",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: Dictionary(
                                        uniqueKeysWithValues: buildSettingsToEnforce.map {
                                            (key: $0.name, value: $1)
                                        }
                                    )
                                )
                            ]
                        )
                    ]
                )
            ]).load(await getCore())

        let testProject = testWorkspace.projects[0]
        let testTarget = testProject.targets[0]

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let settings = Settings(
            workspaceContext: context, buildRequestContext: buildRequestContext,
            parameters: parameters, project: testProject, target: testTarget
        )
        for (key, setValue) in buildSettingsToEnforce {
            let value = settings.globalScope.evaluate(key)
            #expect(value == projRoot.join(setValue))
        }
    }

    @Test
    func effectiveSwiftVersion() async throws {
        func testTarget(name: String, forVersion: String?) -> TestStandardTarget {
            var settings: [String: String] = [:]
            if let forVersion {
                settings["SWIFT_VERSION"] = forVersion
            }
            return TestStandardTarget(
                name,
                type: .framework,
                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: settings)],
                buildPhases: [TestSourcesBuildPhase(["main.swift"])]
            )
        }

        let expectations: [(TestStandardTarget, String)] = [
            (testTarget(name: "Empty", forVersion: nil), ""),
            (testTarget(name: "UnsupportedVersion", forVersion: "1.1"), ""),
            (testTarget(name: "UnparseableVersion", forVersion: "bad"), ""),
            (testTarget(name: "40To4", forVersion: "4.0"), "4"),
            (testTarget(name: "41To4", forVersion: "4.1"), "4"),
            (testTarget(name: "42Stays42", forVersion: "4.2"), "4.2"),
            (testTarget(name: "43To4", forVersion: "4.3"), "4"),
            (testTarget(name: "421To4", forVersion: "4.2.1"), "4"),
            (testTarget(name: "50To5", forVersion: "5.0"), "5"),
            (testTarget(name: "55To5", forVersion: "5.5"), "5"),
            (testTarget(name: "5Stays5", forVersion: "5"), "5"),
            (testTarget(name: "60To6", forVersion: "6.0"), "6"),
            (testTarget(name: "6Stays6", forVersion: "6"), "6")
        ]

        let testWorkspace = try TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: [TestFile("main.swift")]),
                buildConfigurations:[
                    TestBuildConfiguration("Debug")
                ],
                targets: expectations.map { $0.0 })
            ])
            .load(await getCore())

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        for (target, version) in expectations {
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testWorkspace.target(for: target.guid))
            let effectiveSwiftVersion = settings.globalScope.evaluate(BuiltinMacros.EFFECTIVE_SWIFT_VERSION)
            #expect(effectiveSwiftVersion == version)
        }
    }

    @Test
    func defaultUpcomingFeatures() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: [TestFile("main.swift")]),
                buildConfigurations:[
                    TestBuildConfiguration("Debug")
                ],
                targets: [
                    TestStandardTarget(
                        "SomeTarget",
                        type: .framework,
                        buildConfigurations: [TestBuildConfiguration("Debug")],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])]
                    )
                ]
            )])
            .load(getCore())

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let settings5 = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters.mergingOverrides(["SWIFT_VERSION": "5.0"]), project: testProject, target: testTarget)
        #expect(settings5.globalScope.evaluateAsString(try #require(settings5.userNamespace.lookupMacroDeclaration("SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE"))) == "NO")

        let settings6 = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters.mergingOverrides(["SWIFT_VERSION": "6.0"]), project: testProject, target: testTarget)
        #expect(settings6.globalScope.evaluateAsString(try #require(settings5.userNamespace.lookupMacroDeclaration("SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE"))) == "YES")
    }
}

@Suite fileprivate struct SettingsEditorTests: CoreBasedTests {

    /// Test the basics of getting data to display in the build settings editor.
    @Test(.requireSDKs(.macOS))
    func editorBasics() async throws {
        let core = try await getCore()
        try await withTemporaryDirectory { (tmpDirPath: Path) in
            // Filed to write.
            var files = [Path: String]()

            // Write an additional SDK.
            let sdksDirPath = tmpDirPath.join("SDKs")
            let additionalSDKPath = sdksDirPath.join("TestSDK.sdk")
            try await writeSDK(name: additionalSDKPath.basename, parentDir: sdksDirPath, settings: [
                "CanonicalName": "com.apple.sdk.1.0",
                "IsBaseSDK": "NO",
            ])
            files[additionalSDKPath.join("Applications/Xcode.app/mock.txt")] = ""
            files[additionalSDKPath.join("usr/mock.txt")] = ""

            // Write xcconfig files.
            let projectXcconfigPath = tmpDirPath.join("xcconfigs/Project.xcconfig")
            files[projectXcconfigPath] =
            "CASCADING = $(PROJECT_XCCONFIG_SETTING) $(inherited)\n" +
            "PROJECT_XCCONFIG_SETTING = project-xcconfig\n"
            let targetXcconfigPath = tmpDirPath.join("xcconfigs/Target.xcconfig")
            files[targetXcconfigPath] =
            "CASCADING = $(TARGET_XCCONFIG_SETTING) $(inherited)\n" +
            "CONDITIONAL[sdk=macosx*][arch=x86_64] = $(MAC_SETTING)_$(INTEL_SETTING)\n" +
            "TARGET_XCCONFIG_SETTING = target-xcconfig\n"

            // Test the basic settings construction for a trivial test target.
            let testWorkspace = try TestWorkspace("Workspace", sourceRoot: tmpDirPath.join("aWorkspace"),
                                                  projects: [TestProject("aProject",
                                                                         groupTree: TestGroup("SomeFiles",
                                                                                              children: [
                                                                                                TestFile("Mock.cpp"),
                                                                                                TestFile(projectXcconfigPath.str),
                                                                                                TestFile(targetXcconfigPath.str),
                                                                                              ]),
                                                                         buildConfigurations:[
                                                                            TestBuildConfiguration("Config", baseConfig: "Project.xcconfig", buildSettings: [
                                                                                "ADDITIONAL_SDKS": "\(additionalSDKPath.str)",
                                                                                "CASCADING": "$(PROJECT_SETTING) $(inherited)",
                                                                                "PROJECT_SETTING": "project",
                                                                                // This setting checks that we only see the target value when inspecting the target.
                                                                                "PROJECT_AND_MAYBE_TARGET": "$(TARGET_SETTING) $(PROJECT_SETTING)",
                                                                                "SDKROOT": "macosx",
                                                                            ]),
                                                                         ],
                                                                         targets: [
                                                                            TestStandardTarget("Target1",
                                                                                               type: .application,
                                                                                               buildConfigurations: [
                                                                                                TestBuildConfiguration("Config", baseConfig: "Target.xcconfig", buildSettings: [
                                                                                                    "CASCADING": "$(TARGET_SETTING) $(inherited)",
                                                                                                    "CONDITIONAL": "",
                                                                                                    "CONDITIONAL[arch=arm64]": "$(ARM_SETTING)",
                                                                                                    "CONDITIONAL[sdk=macosx*]": "$(MAC_SETTING)",
                                                                                                    "CONDITIONAL[sdk=ios*]": "$(IOS_SETTING)",
                                                                                                    "TARGET_SETTING": "target",
                                                                                                ]),
                                                                                               ],
                                                                                               buildPhases: [
                                                                                                TestSourcesBuildPhase([
                                                                                                    "Mock.cpp",
                                                                                                ]),
                                                                                               ]
                                                                                              ),
                                                                         ]
                                                                        ),
                                                  ]).load(core)
            let context = try await contextForTestData(testWorkspace,
                                                       environment: [
                                                        "CASCADING": "$(DEFAULTS_SETTING)",
                                                        "DEFAULTS_SETTING": "defaults",
                                                        "ARM_SETTING": "arm",
                                                        "INTEL_SETTING": "intel",
                                                        "IOS_SETTING": "ios",
                                                        "MAC_SETTING": "mac",
                                                       ],
                                                       files: files
            )
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]
            let parameters = BuildParameters(action: .build, configuration: "Config")

            // Create and check the settings through the target.
            // Key thing to remember: The '***ResolvedSettingsValues' properties are what the setting resolves to *at that level*, regardless of what it's defined to at higher levels.
            do {
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget, purpose: .editor)

                // There should be no diagnostics.
                #expect(settings.warnings == [])
                #expect(settings.errors == [])

                let editorInfo = settings.infoForBuildSettingsEditor

                // Check the assignments and resolved values of various settings.

                // Check the target settings.
                #expect(editorInfo.targetSettingAssignments?["CASCADING"] == "$(TARGET_SETTING) $(inherited)")
                #expect(editorInfo.targetResolvedSettingsValues?["CASCADING"] == "target target-xcconfig project project-xcconfig defaults")
                #expect(editorInfo.targetSettingAssignments?["TARGET_SETTING"] == "target")
                #expect(editorInfo.targetResolvedSettingsValues?["TARGET_SETTING"] == "target")
                #expect(editorInfo.targetSettingAssignments?["PROJECT_AND_MAYBE_TARGET"] == nil)
                #expect(editorInfo.targetResolvedSettingsValues?["PROJECT_AND_MAYBE_TARGET"] == "target project")
                #expect(editorInfo.targetSettingAssignments?["CONDITIONAL"] == "")
                #expect(editorInfo.targetSettingAssignments?["CONDITIONAL[arch=arm64]"] == "$(ARM_SETTING)")
                #expect(editorInfo.targetSettingAssignments?["CONDITIONAL[sdk=macosx*]"] == "$(MAC_SETTING)")
                #expect(editorInfo.targetSettingAssignments?["CONDITIONAL[sdk=ios*]"] == "$(IOS_SETTING)")
                #expect(editorInfo.targetResolvedSettingsValues?["CONDITIONAL"] == "")
                #expect(editorInfo.targetResolvedSettingsValues?["CONDITIONAL[arch=arm64]"] == "arm")
                #expect(editorInfo.targetResolvedSettingsValues?["CONDITIONAL[sdk=macosx*]"] == "mac")
                #expect(editorInfo.targetResolvedSettingsValues?["CONDITIONAL[sdk=ios*]"] == "ios")
                #expect(editorInfo.targetResolvedSettingsValues?["SDKROOT"] == "macosx")
                if let sdkDir = editorInfo.targetResolvedSettingsValues?["SDK_DIR"] {
                    #expect(sdkDir.contains("/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX"), "unexpected SDK_DIR: \(sdkDir)")
                }
                else {
                    Issue.record("SDK_DIR is empty")
                }

                // Check the target xcconfig settings.
                #expect(editorInfo.targetXcconfigSettingAssignments?["CASCADING"] == "$(TARGET_XCCONFIG_SETTING) $(inherited)")
                #expect(editorInfo.targetXcconfigResolvedSettingsValues?["CASCADING"] == "target-xcconfig project project-xcconfig defaults")
                #expect(editorInfo.targetXcconfigSettingAssignments?["CONDITIONAL[sdk=macosx*][arch=x86_64]"] == "$(MAC_SETTING)_$(INTEL_SETTING)")
                #expect(editorInfo.targetXcconfigResolvedSettingsValues?["CONDITIONAL[sdk=macosx*][arch=x86_64]"] == "mac_intel")
                #expect(editorInfo.targetXcconfigSettingAssignments?["TARGET_XCCONFIG_SETTING"] == "target-xcconfig")
                #expect(editorInfo.targetXcconfigResolvedSettingsValues?["TARGET_XCCONFIG_SETTING"] == "target-xcconfig")

                // Check the project settings.
                #expect(editorInfo.projectSettingAssignments?["CASCADING"] == "$(PROJECT_SETTING) $(inherited)")
                #expect(editorInfo.projectResolvedSettingsValues?["CASCADING"] == "project project-xcconfig defaults")
                #expect(editorInfo.projectSettingAssignments?["PROJECT_SETTING"] == "project")
                #expect(editorInfo.projectResolvedSettingsValues?["PROJECT_SETTING"] == "project")
                #expect(editorInfo.projectSettingAssignments?["PROJECT_AND_MAYBE_TARGET"] == "$(TARGET_SETTING) $(PROJECT_SETTING)")
                #expect(editorInfo.projectResolvedSettingsValues?["PROJECT_AND_MAYBE_TARGET"] == " project")

                // Check the project xcconfig settings.
                #expect(editorInfo.projectXcconfigSettingAssignments?["CASCADING"] == "$(PROJECT_XCCONFIG_SETTING) $(inherited)")
                #expect(editorInfo.projectXcconfigResolvedSettingsValues?["CASCADING"] == "project-xcconfig defaults")
                #expect(editorInfo.projectXcconfigSettingAssignments?["PROJECT_XCCONFIG_SETTING"] == "project-xcconfig")
                #expect(editorInfo.projectXcconfigResolvedSettingsValues?["PROJECT_XCCONFIG_SETTING"] == "project-xcconfig")

                // Check the defaults settings.  (We don't have assignments to check here since they are not something the user can set.)
                #expect(editorInfo.defaultsResolvedSettingsValues?["CASCADING"] == "defaults")
                #expect(editorInfo.defaultsResolvedSettingsValues?["DEFAULTS_SETTING"] == "defaults")
            }

            // Create and check the settings through the project.
            do {
                let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: nil, purpose: .editor)

                // There should be no diagnostics.
                #expect(settings.warnings == [])
                #expect(settings.errors == [])

                let editorInfo = settings.infoForBuildSettingsEditor

                // Check the assignments and resolved values of various settings.

                #expect(editorInfo.targetSettingAssignments == nil, "Unexpected assignments at target level when inspecting project: \(String(describing: editorInfo.targetSettingAssignments))")
                #expect(editorInfo.targetResolvedSettingsValues == nil, "Unexpected resolved settings at target level when inspecting project: \(String(describing: editorInfo.targetResolvedSettingsValues))")
                #expect(editorInfo.targetSettingAssignments == nil, "Unexpected assignments at target xcconfig level when inspecting project: \(String(describing: editorInfo.targetXcconfigSettingAssignments))")
                #expect(editorInfo.targetResolvedSettingsValues == nil, "Unexpected resolved settings at target xcconfig level when inspecting project: \(String(describing: editorInfo.targetXcconfigResolvedSettingsValues))")

                // Check the project settings.
                #expect(editorInfo.projectSettingAssignments?["CASCADING"] == "$(PROJECT_SETTING) $(inherited)")
                #expect(editorInfo.projectResolvedSettingsValues?["CASCADING"] == "project project-xcconfig defaults")
                #expect(editorInfo.projectSettingAssignments?["PROJECT_SETTING"] == "project")
                #expect(editorInfo.projectResolvedSettingsValues?["PROJECT_SETTING"] == "project")

                // Check the project xcconfig settings.
                #expect(editorInfo.projectXcconfigSettingAssignments?["CASCADING"] == "$(PROJECT_XCCONFIG_SETTING) $(inherited)")
                #expect(editorInfo.projectXcconfigResolvedSettingsValues?["CASCADING"] == "project-xcconfig defaults")
                #expect(editorInfo.projectXcconfigSettingAssignments?["PROJECT_XCCONFIG_SETTING"] == "project-xcconfig")
                #expect(editorInfo.projectXcconfigResolvedSettingsValues?["PROJECT_XCCONFIG_SETTING"] == "project-xcconfig")
                #expect(editorInfo.projectSettingAssignments?["PROJECT_AND_MAYBE_TARGET"] == "$(TARGET_SETTING) $(PROJECT_SETTING)")
                #expect(editorInfo.projectResolvedSettingsValues?["PROJECT_AND_MAYBE_TARGET"] == " project")

                // Check the defaults settings.  (We don't have assignments to check here since they are not something the user can set.)
                #expect(editorInfo.defaultsResolvedSettingsValues?["CASCADING"] == "defaults")
                #expect(editorInfo.defaultsResolvedSettingsValues?["DEFAULTS_SETTING"] == "defaults")
            }
        }
    }

}

@Suite fileprivate struct SettingsRunDestinationsTests: CoreBasedTests {
    func testActiveRunDestinationiOS(extraBuildSettings: [String: String] = [:], runDestination: RunDestinationInfo?, _ check: (WorkspaceContext, Settings, MacroEvaluationScope) throws -> Void) async throws {
        var buildSettings = [
            "SDKROOT": "iphoneos",
            "ARCHS[sdk=iphoneos*]": "arm64",
        ]
        buildSettings.addContents(of: extraBuildSettings)

        try await testActiveRunDestination(extraBuildSettings: buildSettings, runDestination: runDestination, check)
    }

    @Test(.requireSDKs(.iOS))
    func activeRunDestination_None() async throws {
        try await testActiveRunDestinationiOS(runDestination: nil) { context, settings, scope in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "iphoneos")
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_FAMILY_NAME) == "iOS")
            #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("iphoneos")?.path)
            #expect(scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH))
            let archName = try #require(scope.evaluate(BuiltinMacros.ARCHS_STANDARD).first)
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == [archName])
            let archNameSetting = try scope.namespace.declareStringMacro(archName)
            #expect(scope.evaluate(archNameSetting) == "YES")
        }
    }

    @Test(.requireSDKs(.linux))
    func activeRunDestination_Generic_Linux_Device() async throws {
        let arch = try #require(Architecture.hostStringValue, "Could not determine Linux host architecture")
        try await testActiveRunDestination(.commandLineTool, extraBuildSettings: ["SDKROOT": "linux", "ARCHS": arch], runDestination: RunDestinationInfo(platform: "linux", sdk: "linux", sdkVariant: nil, targetArchitecture: arch, supportedArchitectures: [arch], disableOnlyActiveArch: true)) { context, settings, scope throws in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "linux")
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_FAMILY_NAME) == "Linux")
            #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("linux")?.path)
            #expect(!scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH))
            #expect(Set(scope.evaluate(BuiltinMacros.ARCHS)) == Set([arch]))
            try #require(scope.evaluate(try scope.namespace.declareStringMacro(arch)) == "YES")
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("i386")) == "")
        }
    }

    @Test(.requireSDKs(.iOS))
    func activeRunDestination_Generic_iOS_Device() async throws {
        try await testActiveRunDestinationiOS(runDestination: RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: nil, targetArchitecture: "arm64", supportedArchitectures: ["armv7", "arm64"], disableOnlyActiveArch: true)) { context, settings, scope throws in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "iphoneos")
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_FAMILY_NAME) == "iOS")
            #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("iphoneos")?.path)
            #expect(!scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH))
            #expect(Set(scope.evaluate(BuiltinMacros.ARCHS)) == Set(["arm64"]))
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("arm64")) == "YES")
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64")) == "")
        }
    }

    @Test(.requireSDKs(.iOS))
    func activeRunDestination_Specific_iOS_Device() async throws {
        try await testActiveRunDestinationiOS(runDestination: .iOS) { context, settings, scope throws in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "iphoneos")
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_FAMILY_NAME) == "iOS")
            #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("iphoneos")?.path)
            #expect(scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH))
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["arm64"])
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("arm64")) == "YES")
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64")) == "")
        }
    }

    @Test(.requireSDKs(.iOS))
    func activeRunDestination_Simulator_Device() async throws {
        try await testActiveRunDestinationiOS(runDestination: .iOSSimulator) { context, settings, scope throws in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "iphonesimulator")
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_FAMILY_NAME) == "iOS")
            #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("iphonesimulator")?.path)
            #expect(scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH))
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["x86_64"])
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64")) == "YES")
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("arm64")) == "")
        }
    }

    @Test(.requireSDKs(.macOS))
    func activeRunDestination_Device_Different_Platform() async throws {
        try await testActiveRunDestinationiOS(runDestination: .macOS) { context, settings, scope throws in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "iphoneos")
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_FAMILY_NAME) == "iOS")
            #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("iphoneos")?.path)
            #expect(!scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH))
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["arm64"])
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("arm64")) == "YES")
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64")) == "")
        }
    }

    @Test(.requireSDKs(.watchOS))
    func activeRunDestination_Simulator_Device_Different_Platform() async throws {
        // If a target supports both device+sim and the run destination is a simulator, we should build the target for its supported simulator
        try await testActiveRunDestinationiOS(runDestination: .watchOSSimulator) { context, settings, scope throws in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "iphonesimulator")
            #expect(scope.evaluate(BuiltinMacros.PLATFORM_FAMILY_NAME) == "iOS")
            #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("iphonesimulator")?.path)
            #expect(!scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH))
            #expect(scope.evaluate(BuiltinMacros.ARCHS).sorted() == ["arm64", "x86_64"])
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64")) == "YES")
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("arm64")) == "YES")
        }
    }

    @Test(.requireSDKs(.macOS))
    func activeRunDestination_ONLY_ACTIVE_ARCH_interaction() async throws {
        // Prefer the run destination's targetArchitecture
        try await testActiveRunDestination(
            extraBuildSettings: [
                "SDKROOT": "macosx",
                "ARCHS": "arm64 foo x86_64 baz x86_64h qux arm64e",
            ],
            runDestination: .macOSIntel,
            activeArchitecture: "x86_64h",
            hostArchitecture: "x86_64h"
        ) { context, settings, scope throws in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["x86_64"])
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64h")) == "")
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64")) == "YES")
        }

        // Prefer the run destination's supportedArchitectures when its targetArchitecture is not in ARCHS
        try await testActiveRunDestination(
            extraBuildSettings: [
                "SDKROOT": "macosx",
                "VALID_ARCHS": "foo x86_64h x86_64 qux",
                "ARCHS": "$(VALID_ARCHS)",
            ],
            runDestination: .macOSAppleSilicon,
            activeArchitecture: "x86_64h",
            hostArchitecture: "x86_64h"
        ) { context, settings, scope throws in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["x86_64"])
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64h")) == "")
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64")) == "YES")
        }

        // Generic run destinations don't provide an active arch
        try await testActiveRunDestination(
            extraBuildSettings: [
                "SDKROOT": "macosx",
                "ARCHS": "$(ARCHS_STANDARD)",
            ],
            runDestination: .anyMac,
            activeArchitecture: nil,
            hostArchitecture: nil
        ) { context, settings, scope in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["arm64", "x86_64"])
        }

        // If there's no run destination, prefer activeArchitecture
        try await testActiveRunDestination(
            extraBuildSettings: [
                "SDKROOT": "macosx",
                "VALID_ARCHS": "foo i386 bar x86_64 baz x86_64h qux",
                "ARCHS": "$(VALID_ARCHS)",
            ],
            runDestination: nil,
            activeArchitecture: "x86_64",
            hostArchitecture: "x86_64h"
        ) { context, settings, scope throws in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["x86_64"])
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("x86_64")) == "YES")
            try #require(scope.evaluate(try scope.namespace.declareStringMacro("i386")) == "")
        }

        // If there's no activeArchitecture, build for all archs and emit a warning
        try await testActiveRunDestination(
            extraBuildSettings: [
                "SDKROOT": "iphonesimulator",
                "VALID_ARCHS": "foo bar x86_64 baz x86_64h qux",
                "ARCHS": "$(VALID_ARCHS)",
            ],
            runDestination: nil,
            activeArchitecture: nil,
            hostArchitecture: "x86_64h"
        ) { context, settings, scope in
            #expect(settings.errors == [])
            #expect(settings.warnings == ["ONLY_ACTIVE_ARCH=YES requested with multiple ARCHS and no active architecture could be computed; building for all applicable architectures"])
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["foo", "bar", "x86_64", "baz", "x86_64h", "qux"])
        }

        // If there's no hostArchitecture and ARCHS is a single arch, pick it without a warning
        try await testActiveRunDestination(
            extraBuildSettings: [
                "SDKROOT": "macosx",
                "VALID_ARCHS": "foo i386 bar x86_64 baz x86_64h qux",
                "ARCHS": "foo",
            ],
            runDestination: nil,
            activeArchitecture: nil,
            hostArchitecture: nil
        ) { context, settings, scope in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["foo"])
        }

        // If there's no hostArchitecture match and ARCHS is a single arch, pick it without a warning
        try await testActiveRunDestination(
            extraBuildSettings: [
                "SDKROOT": "macosx",
                "VALID_ARCHS": "foo i386 bar x86_64 baz x86_64h qux",
                "ARCHS": "foo",
            ],
            runDestination: nil,
            activeArchitecture: nil,
            hostArchitecture: "x86_64h"
        ) { context, settings, scope in
            #expect(settings.errors == [])
            #expect(settings.warnings == [])
            #expect(scope.evaluate(BuiltinMacros.ARCHS) == ["foo"])
        }
    }

    @Test(.requireSDKs(.watchOS))
    func activeRunDestination_MultiPlatform_Target() async throws {
        try await testActiveRunDestinationiOS(
            extraBuildSettings: [
                "SDKROOT": "iphoneos",
                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator watchos watchsimulator",
            ],
            runDestination: .watchOS) { context, settings, scope in
                #expect(settings.errors == [])
                #expect(settings.warnings == [])
                #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "watchos")
                #expect(scope.evaluate(BuiltinMacros.PLATFORM_FAMILY_NAME) == "watchOS")
                #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("watchos")?.path)
                #expect(scope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH))
                #expect(Set(scope.evaluate(BuiltinMacros.ARCHS)) == Set(["arm64_32"]))
            }
    }

    @Test(.requireSDKs(.iOS))
    func activeRunDestination_DeviceToSimulator_PublicToPublic() async throws {
        try await testActiveRunDestinationiOS(
            runDestination: .iOSSimulator) { context, settings, scope in
                #expect(settings.errors == [])
                #expect(settings.warnings == [])
                #expect(scope.evaluate(BuiltinMacros.PLATFORM_NAME) == "iphonesimulator")
                #expect(scope.evaluate(BuiltinMacros.PLATFORM_FAMILY_NAME) == "iOS")
                #expect(scope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("iphonesimulator")?.path)
            }
    }

    /// Regression test for <rdar://problem/49698749> Opt-in: macCatalyst framework targets should not require "SDKROOT = iphoneos” to be set
    @Test(.requireSDKs(.macOS))
    func macCatalystFromMacOSSDK() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: []),
                targets: [
                    TestStandardTarget(
                        "Target",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "macosx",
                                    "SUPPORTS_MACCATALYST": "YES",
                                ])
                        ]),
                ])
            ]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)

        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]
        let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macCatalyst)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)
        #expect(settings.globalScope.evaluate(BuiltinMacros.SDKROOT) == context.sdkRegistry.lookup("macosx")?.path)
        #expect(settings.globalScope.evaluate(BuiltinMacros.SDK_VARIANT) == MacCatalystInfo.sdkVariantName)
        #expect(settings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS).contains("macosx"))
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func platformConditionals() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestPackageProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: []),
                targets: [
                    TestStandardTarget(
                        "Target",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "macosx",
                                    // config=Debug is added here to ensure platform conditionals still compose with existing conditionals.
                                    "OTHER_CFLAGS[__platform_filter=macos][config=Debug]": "-best",
                                    "OTHER_CFLAGS[__platform_filter=ios;ios-maccatalyst]": "-unbar",
                                    "OTHER_LDFLAGS[__platform_filter=macos]": "-macos",
                                    "OTHER_LDFLAGS[__platform_filter=ios]": "-ios",
                                    "OTHER_LDFLAGS[__platform_filter=ios-maccatalyst]": "-catalyst",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                    "SUPPORTS_MACCATALYST": "YES",
                                ])
                        ]),
                ])
            ]).load(getCore())

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let expectedResults: [RunDestinationInfo: (String, [String], [String])] = [
            .macOS: ("macosx", ["-best"], ["-macos"]),
            .iOS: ("iphoneos", ["-unbar"], ["-ios"]),
            .iOSSimulator: ("iphonesimulator", ["-unbar"], ["-ios"]),
            .macCatalyst: ("macosx", ["-unbar"], ["-catalyst"]),
        ]

        for key in expectedResults.keys {
            let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: key)
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

            let (expectedSDK, expectedCFlags, expectedLdFlags) = try #require(expectedResults[key])
            let sdk = try #require(context.sdkRegistry.lookup(expectedSDK), "could not find SDK \(expectedSDK)")
            #expect(settings.globalScope.evaluate(BuiltinMacros.SDKROOT) == sdk.path)
            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_CFLAGS) == expectedCFlags)
            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_LDFLAGS) == expectedLdFlags)
        }
    }

    @Test(.requireSDKs(.driverKit))
    func platformConditionalsDriverKit() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestPackageProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: []),
                targets: [
                    TestStandardTarget(
                        "Target",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "driverkit",
                                    "OTHER_CFLAGS[__platform_filter=driverkit][config=Debug]": "-best",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ])
                        ]),
                ])
            ]).load(getCore())

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .driverKit)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_CFLAGS) == ["-best"])
    }

    @Test(.requireSDKs(.driverKit))
    func platformConditionalsAreOnlySupportedForPackages() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: []),
                targets: [
                    TestStandardTarget(
                        "Target",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "driverkit",
                                    "OTHER_CFLAGS[__platform_filter=driverkit][config=Debug]": "-best",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ])
                        ]),
                ])
            ]).load(getCore())

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .macOS)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_CFLAGS) == [])
    }

    @Test(.requireSDKs(.driverKit))
    func platformConditionalsInImpartedSettingsWorkForNonPackages() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: []),
                targets: [
                    TestStandardTarget(
                        "Target",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "driverkit",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ])
                        ]),
                ])
            ]).load(getCore())

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let source = BuildConfiguration.MacroBindingSource(key: "OTHER_CFLAGS", value: .stringList(["$(inherited)"]))
        let conditionalSource = BuildConfiguration.MacroBindingSource(key: "OTHER_CFLAGS[__platform_filter=driverkit][config=Debug]", value: .stringList(["-best"]))
        let buildProperties = SWBCore.ImpartedBuildProperties(ImpartedBuildProperties(buildSettings: [source, conditionalSource]), PIFLoader(data: .plArray([]), namespace: context.core.specRegistry.internalMacroNamespace))

        let parameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .driverKit)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget,  impartedBuildProperties: [buildProperties])

        #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_CFLAGS) == ["-best"])
    }

    @Test(.requireSDKs(.macOS))
    func catalystDoesNotBreakOnlyActiveArch() async throws {
        let testWorkspace = TestWorkspace("Test", projects: [
            TestProject("Project", groupTree: TestGroup("Sources", path: "Sources", children: [TestFile("best.swift")]), targets: [
                TestStandardTarget("Target",
                                   type: .application,
                                   buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ONLY_ACTIVE_ARCH": "YES",
                        "SUPPORTS_MACCATALYST": "YES",
                        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                    ])
                ])
            ])
        ])

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(configuration: "Debug", activeRunDestination: .macCatalyst)
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        #expect(try settings.globalScope.evaluate(BuiltinMacros.SDKROOT) == context.core.sdkRegistry.lookup("macosx", activeRunDestination: nil)?.path)
        #expect(settings.globalScope.evaluate(BuiltinMacros.ONLY_ACTIVE_ARCH))
    }
}

@Suite fileprivate struct SettingsLookupTests: CoreBasedTests {

    /// Test that we can look up different `Settings` objects the caching in the `BuildRequestContext` works.
    ///
    /// In particular this checks whether looking up `Settings` with the same parameters and purpose returns the same object each time, and that looking up similar but slightly different `Settings` will not return the wrong one.  This way we can test, for example, that changes to the `SettingsCacheKey` work as expected.
    @Test
    func settingsCaching() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "Project",
                    sourceRoot: Path.root.join("Source"),
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: []
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "CASCADING": "$(PROJECT_SETTING) $(CONFIGURATION) $(inherited)",
                            "PROJECT_SETTING": "project",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                        TestBuildConfiguration("Release", buildSettings: [
                            "CASCADING": "$(PROJECT_SETTING) $(CONFIGURATION) $(inherited)",
                            "PROJECT_SETTING": "project",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                    ],
                    targets: [
                        TestStandardTarget("TargetA",
                                           type: .application,
                                           buildConfigurations: [
                                            TestBuildConfiguration("Debug", buildSettings: [
                                                "CASCADING": "$(TARGET_SETTING) $(inherited)",
                                                "TARGET_SETTING": "target_a",
                                            ]),
                                            TestBuildConfiguration("Release", buildSettings: [
                                                "CASCADING": "$(TARGET_SETTING) $(inherited)",
                                                "TARGET_SETTING": "target_a",
                                            ]),
                                           ]
                                          ),
                        TestStandardTarget("TargetB",
                                           type: .application,
                                           buildConfigurations: [
                                            TestBuildConfiguration("Debug", buildSettings: [
                                                "CASCADING": "$(TARGET_SETTING) $(inherited)",
                                                "TARGET_SETTING": "target_b",
                                            ]),
                                            TestBuildConfiguration("Release", buildSettings: [
                                                "CASCADING": "$(TARGET_SETTING) $(inherited)",
                                                "TARGET_SETTING": "target_a",
                                            ]),
                                           ]
                                          ),
                    ]
                )
            ]).load(getCore())
        let project = testWorkspace.projects[0]
        let targetA = project.targets[0]
        let targetB = project.targets[1]

        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)

        // A set to be able to conveniently tell if we've found a Settings object before.
        var foundSettings = [ObjectIdentifier: Settings]()

        func check(_ settings: Settings, _ expectedSettings: Settings? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
            let objId = ObjectIdentifier(settings)
            if let expectedSettings {
                #expect(settings === expectedSettings, "did not get the Settings object that was expected", sourceLocation: sourceLocation)
                #expect(foundSettings[objId] === expectedSettings, "did not get the previously-looked-up Settings object that was expected", sourceLocation: sourceLocation)
            }
            else {
                if foundSettings[objId] != nil {
                    Issue.record("unexpectedly found a previously-looked-up Settings object", sourceLocation: sourceLocation)
                }
                else {
                    foundSettings[objId] = settings
                }
            }
        }

        // The naming conventions for these settings is: Object name, Configuration name, Purpose
        let settings_TargetA_Debug_Build = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug"), target: targetA, purpose: .build)
        check(settings_TargetA_Debug_Build)

        check(buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug"), target: targetA, purpose: .build), settings_TargetA_Debug_Build)

        let settings_TargetB_Debug_Build = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug"), target: targetB, purpose: .build)
        check(settings_TargetB_Debug_Build)

        let settings_TargetA_Release_Build = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Release"), target: targetA, purpose: .build)
        check(settings_TargetA_Release_Build)

        check(buildRequestContext.getCachedSettings(BuildParameters(configuration: "Release"), target: targetA, purpose: .build), settings_TargetA_Release_Build)

        let settings_TargetA_Debug_Editor = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug"), target: targetA, purpose: .editor)
        check(settings_TargetA_Debug_Editor)

        check(buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug"), target: targetA, purpose: .editor), settings_TargetA_Debug_Editor)

        let settings_Project_Debug_Build = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug"), project: project, purpose: .build)
        check(settings_Project_Debug_Build)

        check(buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug"), project: project, purpose: .build), settings_Project_Debug_Build)

        let settings_Project_Debug_Editor = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug"), project: project, purpose: .editor)
        check(settings_Project_Debug_Editor)

        check(buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug"), project: project, purpose: .editor), settings_Project_Debug_Editor)

        #expect(foundSettings.count == 6)
    }

}

@Suite fileprivate struct XCConfigTests: CoreBasedTests {
    static let configIncludeCycle: [(Path, String)] = [
        (.root.join("tmp/A.xcconfig"), (
            "#include \"B.xcconfig\"\nSETTING_A=VALUE1")),
        (.root.join("tmp/B.xcconfig"), (
            "#include \"A.xcconfig\"\nSETTING_B=VALUE2\nSETTING_BA=$(SETTING_A)")),
        (.root.join("/tmp/C.xcconfig"), (
            "#include \"C.xcconfig\"\nSETTING_C=VALUE3"))
    ]

    static let samePathInIncludeGraph: [(Path, String)] = [
        (.root.join("tmp/A.xcconfig"), (
            "#include \"B.xcconfig\"\n#include \"C.xcconfig\"")),
        (.root.join("tmp/B.xcconfig"), (
            "B_XCCONFIG_USER_SETTING = from-B_xcconfig\n")),
        (.root.join("tmp/C.xcconfig"), (
            "C_XCCONFIG_USER_SETTING = from-C_xcconfig\n")),
        (.root.join("tmp/D.xcconfig"), (
            "#include \"C.xcconfig\"")),
        (.root.join("tmp/E.xcconfig"), (
            "#include \"B.xcconfig\""))
    ]

    static let missingNestedFileFilesOrdered: [(Path, String)] = [
        (.root.join("tmp/Test.xcconfig"), (
            "#include \"xcconfigs/Base1.xcconfig\"\n" +
            "XCCONFIG_HEADER_SEARCH_PATHS = /tmp/path /tmp/other-path\n")),
        (.root.join("tmp/xcconfigs/Base1.xcconfig"), (
            "#include \"\(Path.root.join("tmp/xcconfigs/Base0.xcconfig").strWithPosixSlashes)\"")
        )
    ]
    static let missingNestedFileFiles = Dictionary(uniqueKeysWithValues: missingNestedFileFilesOrdered)
    static let threeLevelNestedFilesOrdered: [(Path, String)] =
    XCConfigTests.missingNestedFileFilesOrdered +
    [
        (.root.join("tmp/xcconfigs/Base0.xcconfig"), (
            "XCCONFIG_USER_SETTING = from-xcconfig\n"))
    ]

    let threeLevelNestedPaths = Array(XCConfigTests.threeLevelNestedFilesOrdered.map { $0.0 })
    let threeLevelNestedFiles = Dictionary(uniqueKeysWithValues: XCConfigTests.threeLevelNestedFilesOrdered)
    let configIncludeCycleFiles = Dictionary(uniqueKeysWithValues: XCConfigTests.configIncludeCycle)
    let samePathInIncludeGraphFiles = Dictionary(uniqueKeysWithValues: XCConfigTests.samePathInIncludeGraph)

    func setupTestingContext(_ files: [Path: String], symlinks: [Path: String] = [:]) async throws -> WorkspaceContext {
        let testWorkspace = try await TestWorkspace("Workspace", projects: [ TestProject("aProject", groupTree: TestGroup("SomeFiles", children: [TestFile(Path.root.join("tmp/Test.xcconfig").str)]), buildConfigurations:[ TestBuildConfiguration("Config1", baseConfig: "Test.xcconfig") ]) ]).load(getCore())
        return try await contextForTestData(testWorkspace, files: files, symlinks: symlinks)
    }

    @Test(.skipHostOS(.windows, "one of the paths is not normalized"))
    func infoGathersNestedConfigs() async throws {
        let context = try await setupTestingContext(threeLevelNestedFiles)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let info = buildRequestContext.loadSettingsFromConfig(data: ByteString(encodingAsUTF8: "#include \"\(Path.root.join("tmp/Test.xcconfig").strWithPosixSlashes)\"\n"), path: Path.root.join("mock/base/path"), namespace: MacroNamespace(), searchPaths: [Path]())
        #expect(info.dependencyPaths == [Path.root.join("mock/base/path")] + threeLevelNestedPaths)
    }

    @Test(.skipHostOS(.windows, "paths are reversed on Windows?"))
    func simpleCycleInConfigs() async throws {
        let context = try await setupTestingContext(configIncludeCycleFiles)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let expectedDiagnostics = [[
            "\(Path.root.join("tmp/B.xcconfig").str):1: warning: Skipping the inclusion of 'A.xcconfig' from 'B.xcconfig' as it would create a cycle.",
            "Cycle Path: 'A.xcconfig' -> 'B.xcconfig' -> 'A.xcconfig'",
            "Cycle Details:",
            "'\(Path.root.join("tmp/A.xcconfig").str)' includes '\(Path.root.join("tmp/B.xcconfig").str)'",
            "'\(Path.root.join("tmp/B.xcconfig").str)' includes '\(Path.root.join("tmp/A.xcconfig").str)'",
            "",
        ].joined(separator: "\n")]
        let info = buildRequestContext.loadSettingsFromConfig(data: ByteString(encodingAsUTF8: "#include \"\(Path.root.join("tmp/A.xcconfig").strWithPosixSlashes)\"\n"), path: Path.root.join("mock/base/path"), namespace: MacroNamespace(), searchPaths: [Path]())
        #expect(info.diagnostics.map { $0.formatLocalizedDescription(.debug) } == expectedDiagnostics)

        // Validate that the table is still populated with the data from the files, even if a cycle is detected.
        let scope = MacroEvaluationScope(table: info.table)
        #expect(scope.evaluateAsString(try #require(info.table.namespace.lookupMacroDeclaration("SETTING_A"))) == "VALUE1")
        #expect(scope.evaluateAsString(try #require(info.table.namespace.lookupMacroDeclaration("SETTING_B"))) == "VALUE2")
        #expect(scope.evaluateAsString(try #require(info.table.namespace.lookupMacroDeclaration("SETTING_BA"))) == "VALUE1")
    }

    @Test
    func singleFileCycleInConfigs() async throws {
        let context = try await setupTestingContext(configIncludeCycleFiles)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let expectedDiagnostics = [[
            "\(Path.root.join("tmp/C.xcconfig").str):1: warning: Skipping the inclusion of 'C.xcconfig' from 'C.xcconfig' as it would create a cycle.",
            "Cycle Path: 'C.xcconfig' -> 'C.xcconfig'",
            "Cycle Details:",
            "'\(Path.root.join("tmp/C.xcconfig").str)' includes '\(Path.root.join("tmp/C.xcconfig").str)'",
            "",
        ].joined(separator: "\n")]
        let info = buildRequestContext.loadSettingsFromConfig(data: ByteString(encodingAsUTF8: "#include \"\(Path.root.join("tmp/C.xcconfig").strWithPosixSlashes)\"\n"), path: Path.root.join("mock/base/path"), namespace: MacroNamespace(), searchPaths: [Path]())
        #expect(info.diagnostics.map { $0.formatLocalizedDescription(.debug) } == expectedDiagnostics)
    }

    @Test(.skipHostOS(.windows, "paths are reversed on Windows?"))
    func symlinkCycleInConfigs() async throws {
        let context = try await setupTestingContext(configIncludeCycleFiles, symlinks: [Path.root.join("tmp/symlink.xcconfig"): Path.root.join("tmp/A.xcconfig").str])
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let expectedDiagnostics = [[
            "\(Path.root.join("tmp/B.xcconfig").str):1: warning: Skipping the inclusion of \'A.xcconfig\' from \'B.xcconfig\' as it would create a cycle.",
            "Cycle Path: \'A.xcconfig\' -> \'B.xcconfig\' -> \'A.xcconfig\'",
            "Cycle Details:",
            "\'\(Path.root.join("tmp/A.xcconfig").str)\' includes \'\(Path.root.join("tmp/B.xcconfig").str)\'",
            "\'\(Path.root.join("tmp/B.xcconfig").str)\' includes \'\(Path.root.join("tmp/A.xcconfig").str)\'",
            "",
        ].joined(separator: "\n")]
        let info = buildRequestContext.loadSettingsFromConfig(data: ByteString(encodingAsUTF8: "#include \"\(Path.root.join("tmp/A.xcconfig").strWithPosixSlashes)\"\n"), path: Path.root.join("mock/base/path"), namespace: MacroNamespace(), searchPaths: [Path]())
        #expect(info.diagnostics.map { $0.formatLocalizedDescription(.debug) } == expectedDiagnostics)
    }

    @Test
    func duplicatePathsInIncludeGraph() async throws {
        let context = try await setupTestingContext(samePathInIncludeGraphFiles)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let data: String = """
        #include \"\(Path.root.join("tmp/A.xcconfig").strWithPosixSlashes)\"
        #include \"\(Path.root.join("tmp/D.xcconfig").strWithPosixSlashes)\"
        #include \"\(Path.root.join("tmp/E.xcconfig").strWithPosixSlashes)\"
        
        """

        let info = buildRequestContext.loadSettingsFromConfig(data: ByteString(encodingAsUTF8: data), path: Path.root.join("mock/base/path"), namespace: MacroNamespace(), searchPaths: [Path]())

        let scope = MacroEvaluationScope(table: info.table)
        let macroB = try #require(scope.namespace.lookupMacroDeclaration("B_XCCONFIG_USER_SETTING"))
        let macroC = try #require(scope.namespace.lookupMacroDeclaration("C_XCCONFIG_USER_SETTING"))
        #expect(info.diagnostics.count == 0)
        #expect(scope.evaluateAsString(macroB) == "from-B_xcconfig")
        #expect(scope.evaluateAsString(macroC) == "from-C_xcconfig")
    }

    @Test
    func cycleWithNonExistentOptionalIncludeAndDuplicatePath() async throws {
        let context = try await setupTestingContext([
            .root.join("tmp/A.xcconfig"): "KEY_A = VALUE_A\n#include? \"\(Path.root.join("tmp/O").strWithPosixSlashes)\"\n",
            .root.join("tmp/B.xcconfig"): "#include \"A\"\nKEY_B = VALUE_B\n",
        ])
        let data: String = """
        #include "\(Path.root.join("tmp/A").strWithPosixSlashes)"
        #include "\(Path.root.join("tmp/B").strWithPosixSlashes)"
        
        """

        let buildRequestContext = BuildRequestContext(workspaceContext: context)

        let info = buildRequestContext.loadSettingsFromConfig(data: ByteString(encodingAsUTF8: data), path: Path.root.join("mock/base/path"), namespace: MacroNamespace(), searchPaths: [Path]())

        let scope = MacroEvaluationScope(table: info.table)
        let macroA = try #require(scope.namespace.lookupMacroDeclaration("KEY_A"))
        let macroB = try #require(scope.namespace.lookupMacroDeclaration("KEY_B"))
        #expect(info.diagnostics.count == 0)
        #expect(scope.evaluateAsString(macroA) == "VALUE_A")
        #expect(scope.evaluateAsString(macroB) == "VALUE_B")
    }

    @Test(.skipHostOS(.windows, "one of the paths is not normalized"))
    func loadsNestedConfig() async throws {
        let context = try await setupTestingContext(threeLevelNestedFiles)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let path = Path.root.join("tmp/Test.xcconfig")

        let info = buildRequestContext.getCachedMacroConfigFile(path, context: .baseConfiguration)
        let scope = MacroEvaluationScope(table: info.table)
        let macro = try #require(scope.namespace.lookupMacroDeclaration("XCCONFIG_USER_SETTING"))
        #expect(scope.evaluateAsString(macro) == "from-xcconfig")
        #expect(info.dependencyPaths == [path] + Array(threeLevelNestedPaths.dropFirst()))
    }

    @Test
    func changeNestedConfig() async throws {
        let context = try await setupTestingContext(threeLevelNestedFiles)
        let path = Path.root.join("tmp/Test.xcconfig")

        do {
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let info = buildRequestContext.getCachedMacroConfigFile(path, context: .baseConfiguration)
            let scope = MacroEvaluationScope(table: info.table)
            let macro = try #require(scope.namespace.lookupMacroDeclaration("XCCONFIG_USER_SETTING"))
            #expect(scope.evaluateAsString(macro) == "from-xcconfig")
        }

        try context.fs.write(Path.root.join("tmp/xcconfigs/Base0.xcconfig"), contents: "XCCONFIG_USER_SETTING = changed\n")

        do {
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let info = buildRequestContext.getCachedMacroConfigFile(path, context: .baseConfiguration)
            let scope = MacroEvaluationScope(table: info.table)
            let macro = try #require(scope.namespace.lookupMacroDeclaration("XCCONFIG_USER_SETTING"))
            #expect(scope.evaluateAsString(macro) == "changed")
        }
    }

    @Test
    func createNestedConfig() async throws {
        let context = try await setupTestingContext(XCConfigTests.missingNestedFileFiles)
        let path = Path.root.join("tmp/Test.xcconfig")

        do {
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let info = buildRequestContext.getCachedMacroConfigFile(path, context: .baseConfiguration)
            let scope = MacroEvaluationScope(table: info.table)
            let macro = scope.namespace.lookupMacroDeclaration("XCCONFIG_USER_SETTING")
            #expect(macro == nil)
        }

        try context.fs.write(Path.root.join("tmp/xcconfigs/Base0.xcconfig"), contents: "XCCONFIG_USER_SETTING = created\n")

        do {
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let info = buildRequestContext.getCachedMacroConfigFile(path, context: .baseConfiguration)
            let scope = MacroEvaluationScope(table: info.table)
            let macro = try #require(scope.namespace.lookupMacroDeclaration("XCCONFIG_USER_SETTING"))
            #expect(scope.evaluateAsString(macro) == "created")
        }
    }

    @Test
    func settingsSignature() async throws {
        let context = try await setupTestingContext(threeLevelNestedFiles)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        var settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject)
        let originalSignature = settings.macroConfigSignature

        settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject)
        #expect(originalSignature == settings.macroConfigSignature)
    }

    @Test
    func settingsSignatureChangesWhenXCConfigsChange() async throws {
        let context = try await setupTestingContext(threeLevelNestedFiles)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        var settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject)
        let originalSignature = settings.macroConfigSignature

        try context.fs.write(Path.root.join("tmp/xcconfigs/Base0.xcconfig"), contents: "XCCONFIG_USER_SETTING = changed\n")

        settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject)
        #expect(originalSignature != settings.macroConfigSignature)
    }

    func evaluateXCConfigFiles(_ files: [Path: String], primary: Path) async throws {
        let context = try await setupTestingContext(files)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let info = buildRequestContext.getCachedMacroConfigFile(primary, context: .baseConfiguration)
        #expect(info.diagnostics.count == 0)
        let scope = MacroEvaluationScope(table: info.table)

        if let macro = scope.namespace.lookupMacroDeclaration("XCCONFIG_USER_SETTING") {
            #expect(scope.evaluateAsString(macro) == "yay")
        } else {
            Issue.record("No value for `XCCONFIG_USER_SETTING`")
        }
    }

    @Test
    func recursiveSearchPaths() async throws {
        let files: [Path: String] = [
            .root.join("tmp/xcconfigs/Debug.xcconfig"): "#include \"Nested/Base.xcconfig\"\n",
            .root.join("tmp/xcconfigs/Nested/Base.xcconfig"): "#include \"Nested/Nested.xcconfig\"\n",
            .root.join("tmp/xcconfigs/Nested/Nested.xcconfig"): "XCCONFIG_USER_SETTING = yay\n",
        ]

        try await evaluateXCConfigFiles(files, primary: .root.join("tmp/xcconfigs/Debug.xcconfig"))
    }

    @Test
    func includeWithoutFileExtensionIfOneIsNeeded() async throws {
        let files: [Path: String] = [
            .root.join("tmp/xcconfigs/Debug.xcconfig"): "#include \"Included\"\n",
            .root.join("tmp/xcconfigs/Included.xcconfig"): "XCCONFIG_USER_SETTING = yay\n",
        ]

        try await evaluateXCConfigFiles(files, primary: .root.join("tmp/xcconfigs/Debug.xcconfig"))
    }

    @Test
    func includeWithoutFileExtension() async throws {
        let files: [Path: String] = [
            .root.join("tmp/xcconfigs/Debug.xcconfig"): "#include \"Included\"\n",
            .root.join("tmp/xcconfigs/Included"): "XCCONFIG_USER_SETTING = yay\n",
        ]

        try await evaluateXCConfigFiles(files, primary: .root.join("tmp/xcconfigs/Debug.xcconfig"))
    }

    @Test
    func includeWithAbsolutePathAndMissingFileExtension() async throws {
        let files: [Path: String] = [
            .root.join("tmp/xcconfigs/Debug.xcconfig"): "#include \"\(Path.root.join("tmp/xcconfigs/Included").strWithPosixSlashes)\"\n",
            .root.join("tmp/xcconfigs/Included.xcconfig"): "XCCONFIG_USER_SETTING = yay\n",
        ]

        try await evaluateXCConfigFiles(files, primary: .root.join("tmp/xcconfigs/Debug.xcconfig"))
    }

    /// Tests that two targets referencing the same xcconfig file with includes of other xcconfig files looked up by search path don't incorrectly share the same context.
    @Test
    func includeCacheSharing() async throws {
        let testWorkspace = try await TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "aProject",
                    sourceRoot: Path.root.join("tmp/TargetA"),
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile(Path.root.join("tmp/Test.xcconfig").str),
                            TestFile(Path.root.join("tmp/TargetA/TargetConfig.xcconfig").str),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Config1", baseConfig: "Test.xcconfig")
                    ],
                    targets: [
                        TestStandardTarget("A", type: .application)
                    ]),
                TestProject(
                    "bProject",
                    sourceRoot: Path.root.join("tmp/TargetB"),
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile(Path.root.join("tmp/TargetB/TargetConfig.xcconfig").str),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Config1", baseConfig: "Test.xcconfig")
                    ],
                    targets: [
                        TestStandardTarget("B", type: .application)
                    ])
            ]).load(getCore())
        let context = try await contextForTestData(testWorkspace, files: [
            .root.join("tmp/Test.xcconfig"): "#include \"TargetConfig\"",
            .root.join("tmp/TargetA/TargetConfig.xcconfig"): "PRODUCT_NAME = A",
            .root.join("tmp/TargetB/TargetConfig.xcconfig"): "PRODUCT_NAME = B",
        ])

        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let aSettings = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Config1"), target: testWorkspace.projects[0].targets[0])
        let bSettings = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Config1"), target: testWorkspace.projects[1].targets[0])

        #expect(aSettings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME) == "A")
        #expect(bSettings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME) == "B")
    }

    @Suite fileprivate struct BuiltinMacrosTests: CoreBasedTests {
        @Test
        func builtinMacrosIfSetStringLiteral() async throws {
            var table = try await MacroValueAssignmentTable(namespace: getCore().specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.CPP_PREFIX_HEADER, literal: "prefix.h")
            let scope = MacroEvaluationScope(table: table)

            let prefixHeaderValues = BuiltinMacros.ifSet(BuiltinMacros.CPP_PREFIX_HEADER, in: scope) { $0 }
            #expect(prefixHeaderValues == ["prefix.h"])

            let multiplePrefixHeaderValues = BuiltinMacros.ifSet(BuiltinMacros.CPP_PREFIX_HEADER, in: scope) { ["blah", $0] }
            #expect(multiplePrefixHeaderValues == ["blah", "prefix.h"])
        }

        @Test
        func builtinMacrosIfSetStringListLiteral() async throws {
            var table = try await MacroValueAssignmentTable(namespace: getCore().specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.OTHER_CFLAGS, literal: ["-Wall", "-O3"])
            let scope = MacroEvaluationScope(table: table)

            let prefixHeaderValues = BuiltinMacros.ifSet(BuiltinMacros.OTHER_CFLAGS, in: scope) { $0 }
            #expect(prefixHeaderValues == ["-Wall", "-O3"])

            let otherCflagsValues = BuiltinMacros.ifSet(BuiltinMacros.OTHER_CFLAGS, in: scope) { ["blah", $0] }
            #expect(otherCflagsValues == ["blah", "-Wall", "blah", "-O3"])
        }
    }
}
