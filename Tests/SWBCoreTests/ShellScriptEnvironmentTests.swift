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
import SWBUtil
import SWBCore
import SWBTestSupport
import SWBProtocol

@Suite fileprivate struct ShellScriptEnvironmentTests: CoreBasedTests {
    @Test(.requireHostOS(.macOS))
    func computeScriptEnvironment() async throws {
        let core = try await getCore()
        let testWorkspace = try TestWorkspace(
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
                                "ARCHS": "arm64",
                                "BUILD_VARIANTS": "normal",
                                "PRODUCT_NAME": "Target1",
                            ])],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])])
                ])
            ]).load(core)
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]
        let srcroot = testProject.sourceRoot

        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        let env = SWBCore.computeScriptEnvironment(.shellScriptPhase, scope: settings.globalScope, settings: settings, workspaceContext: context)

        let expected: [String: String] =         [
            "ACTION": "build",
            "ALWAYS_SEARCH_USER_PATHS": "YES",
            "BUILD_DIR": srcroot.join("build").str,
            "BUILD_ROOT": srcroot.join("build").str,
            "BUILT_PRODUCTS_DIR": srcroot.join("build/Debug").str,
            "CODESIGNING_FOLDER_PATH": srcroot.join("build/Debug/Target1.app").str,
            "CODE_SIGNING_ALLOWED": "YES",
            "CODE_SIGN_IDENTITY": "-",
            "CONFIGURATION": "Debug",
            "CONFIGURATION_BUILD_DIR": srcroot.join("build/Debug").str,
            "CONFIGURATION_TEMP_DIR": srcroot.join("build/aProject.build/Debug").str,
            "CONTENTS_FOLDER_PATH_SHALLOW_BUNDLE_NO": "Target1.app/Contents",
            "DEBUGGING_SYMBOLS": "YES",
            "DEFAULT_DEXT_INSTALL_PATH": "/System/Library/DriverExtensions",
            "DEFINES_MODULE": "NO",
            "DEPLOYMENT_LOCATION": "NO",
            "DERIVED_FILES_DIR": srcroot.join("build/aProject.build/Debug/Target1.build/DerivedSources").str,
            "DERIVED_FILE_DIR": srcroot.join("build/aProject.build/Debug/Target1.build/DerivedSources").str,
            "DERIVED_SOURCES_DIR": srcroot.join("build/aProject.build/Debug/Target1.build/DerivedSources").str,
            "DOCUMENTATION_FOLDER_PATH": "Target1.app/Contents/Resources/English.lproj/Documentation",
            "DWARF_DSYM_FILE_NAME": "Target1.app.dSYM",
            "ENABLE_ON_DEMAND_RESOURCES": "NO",
            "ENABLE_TESTABILITY": "NO",
            "EXECUTABLES_FOLDER_PATH": "Target1.app/Contents/Executables",
            "EXECUTABLE_FOLDER_PATH": "Target1.app/Contents/MacOS",
            "EXECUTABLE_NAME": "Target1",
            "EXECUTABLE_PATH": "Target1.app/Contents/MacOS/Target1",
            "FILE_LIST": srcroot.join("build/aProject.build/Debug/Target1.build/Objects/LinkFileList").str,
            "FIXED_FILES_DIR": srcroot.join("build/aProject.build/Debug/Target1.build/FixedFiles").str,
            "FRAMEWORKS_FOLDER_PATH": "Target1.app/Contents/Frameworks",
            "FRAMEWORK_SEARCH_PATHS": srcroot.join("build/Debug ").str,
            "FRAMEWORK_VERSION": "A",
            "FULL_PRODUCT_NAME": "Target1.app",
            "HEADER_SEARCH_PATHS": srcroot.join("build/Debug/include ").str,
            "INFOPLIST_PATH": "Target1.app/Contents/Info.plist",
            "INFOSTRINGS_PATH": "Target1.app/Contents/Resources/English.lproj/InfoPlist.strings",
            "INSTALL_DIR": "/tmp/aProject.dst/Applications",
            "JAVA_FOLDER_PATH": "Target1.app/Contents/Resources/Java",
            "LD_RUNPATH_SEARCH_PATHS_YES": "@loader_path/../Frameworks",
            "LIBRARY_DEXT_INSTALL_PATH": "/Library/DriverExtensions",
            "LIBRARY_KEXT_INSTALL_PATH": "/Library/Extensions",
            "LIBRARY_SEARCH_PATHS": srcroot.join("build/Debug ").str,
            "LINK_FILE_LIST_normal_arm64": srcroot.join("build/aProject.build/Debug/Target1.build/Objects-normal/arm64/Target1.LinkFileList").str,
            "LOCROOT": srcroot.str,
            "LOCSYMROOT": srcroot.str,
            "METAL_LIBRARY_OUTPUT_DIR": srcroot.join("build/Debug/Target1.app/Contents/Resources").str,
            "MODULES_FOLDER_PATH": "Target1.app/Contents/Modules",
            "OBJECT_FILE_DIR": srcroot.join("build/aProject.build/Debug/Target1.build/Objects").str,
            "OBJECT_FILE_DIR_normal": srcroot.join("build/aProject.build/Debug/Target1.build/Objects-normal").str,
            "OBJROOT": srcroot.join("build").str,
            "ONLY_ACTIVE_ARCH": "NO",
            "PER_VARIANT_OBJECT_FILE_DIR": srcroot.join("build/aProject.build/Debug/Target1.build/Objects-normal").str,
            "PKGINFO_PATH": "Target1.app/Contents/PkgInfo",
            "PRIVATE_HEADERS_FOLDER_PATH": "Target1.app/Contents/PrivateHeaders",
            "PRODUCT_MODULE_NAME": "Target1",
            "PRODUCT_NAME": "Target1",
            "PRODUCT_TYPE": "com.apple.product-type.application",
            "PROJECT": "aProject",
            "PROJECT_DERIVED_FILE_DIR": srcroot.join("build/aProject.build/DerivedSources").str,
            "PROJECT_DIR": srcroot.join("").str,
            "PROJECT_FILE_PATH": srcroot.join("aProject.xcodeproj").str,
            "PROJECT_NAME": "aProject",
            "PROJECT_TEMP_DIR": srcroot.join("build/aProject.build").str,
            "PROJECT_TEMP_ROOT": srcroot.join("build").str,
            "PUBLIC_HEADERS_FOLDER_PATH": "Target1.app/Contents/Headers",
            "REZ_COLLECTOR_DIR": srcroot.join("build/aProject.build/Debug/Target1.build/ResourceManagerResources").str,
            "SCRIPTS_FOLDER_PATH": "Target1.app/Contents/Resources/Scripts",
            "SHARED_DERIVED_FILE_DIR": srcroot.join("build/Debug/DerivedSources").str,
            "SHARED_FRAMEWORKS_FOLDER_PATH": "Target1.app/Contents/SharedFrameworks",
            "SHARED_SUPPORT_FOLDER_PATH": "Target1.app/Contents/SharedSupport",
            "SKIP_INSTALL": "NO",
            "SOURCE_ROOT": srcroot.join("").str,
            "SRCROOT": srcroot.str,
            "SWIFT_RESPONSE_FILE_PATH_normal_arm64": srcroot.join("build/aProject.build/Debug/Target1.build/Objects-normal/arm64/Target1.SwiftFileList").str,
            "SYMROOT": srcroot.join("build").str,
            "SYSTEM_EXTENSIONS_FOLDER_PATH": "Target1.app/Contents/Library/SystemExtensions",
            "TARGETNAME": "Target1",
            "TARGET_BUILD_DIR": srcroot.join("build/Debug").str,
            "TARGET_NAME": "Target1",
            "TARGET_TEMP_DIR": srcroot.join("build/aProject.build/Debug/Target1.build").str,
            "TEMP_DIR": srcroot.join("build/aProject.build/Debug/Target1.build").str,
            "TEMP_FILES_DIR": srcroot.join("build/aProject.build/Debug/Target1.build").str,
            "TEMP_FILE_DIR": srcroot.join("build/aProject.build/Debug/Target1.build").str,
            "TEMP_ROOT": srcroot.join("build").str,
            "VALIDATE_DEVELOPMENT_ASSET_PATHS": "YES_ERROR",
            "VERSIONPLIST_PATH": "Target1.app/Contents/version.plist",
            "WRAPPER_EXTENSION": "app",
            "WRAPPER_NAME": "Target1.app",
            "WRAPPER_SUFFIX": ".app",
        ]

        // Check that all of the settings defined as expected in the dictionary above appear as described.
        for (key, value) in expected {
            guard let got = env[key] else {
                Issue.record("No value for key \(key)")
                continue
            }
            #expect(got == value)
        }

        let availablePlatforms = try #require(env["AVAILABLE_PLATFORMS"])
        #expect(Set(availablePlatforms.split(separator: " ").map(String.init)) == Set(core.platformRegistry.platforms.map(\.name)))
    }

    /// Test that default and overriding build settings defined in a toolchain are exported.
    @Test(.requireHostOS(.macOS), .skipIfEnvironmentVariableSet(key: .externalToolchainsDir))
    func exportingToolchainSettings() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            // Toolchains are only loaded from the localFS, so we can't use a PseudoFS here.
            let fs = localFS

            // Write a toolchain with the properties we want to validate.
            let toolchainDirPath = tmpDirPath.join("Toolchains")
            let toolchainPath = toolchainDirPath.join("Extra.xctoolchain")
            try fs.createDirectory(toolchainPath, recursive: true)
            try await fs.writePlist(toolchainPath.join("ToolchainInfo.plist"), [
                "CFBundleIdentifier": "com.apple.ExtraToolchain",
                "DefaultBuildSettings": [
                    "TOOLCHAIN_DEFAULT_BUILD_SETTING_FOO" : "bar",
                ],
                "OverrideBuildSettings": [
                    "TOOLCHAIN_OVERRIDE_BUILD_SETTING_BAZ": "quux",
                ],
            ])

            // Configure the test data.
            let environment: Environment = [.externalToolchainsDir: toolchainDirPath.str]
            let core = try await Self.makeCore(environment: .init(environment))
            let testWorkspace = try TestWorkspace(
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
                                    "ARCHS": "arm64",
                                    "BUILD_VARIANTS": "normal",
                                    "PRODUCT_NAME": "Target1",
                                ])],
                            buildPhases: [TestSourcesBuildPhase(["main.swift"])
                                         ]
                        )
                    ])
                ]).load(core)
            let context = try await contextForTestData(testWorkspace, core: core, environment: .init(environment))
            let buildRequestContext = BuildRequestContext(workspaceContext: context)
            let testProject = context.workspace.projects[0]
            let testTarget = testProject.targets[0]

            let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:], toolchainOverride: "com.apple.ExtraToolchain")
            let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

            let env = SWBCore.computeScriptEnvironment(.shellScriptPhase, scope: settings.globalScope, settings: settings, workspaceContext: context)

            // Check that all of the settings defined as expected in the dictionary above appear as described.
            let expected: [String: String] = [
                "TOOLCHAIN_DEFAULT_BUILD_SETTING_FOO" : "bar",
                "TOOLCHAIN_OVERRIDE_BUILD_SETTING_BAZ": "quux",
            ]

            for (key, value) in expected {
                guard let got = env[key] else {
                    Issue.record("No value for key \(key)")
                    continue
                }
                #expect(got == value)
            }
        }
    }

    @Test
    func ensureEnvironmentIsMissingValues() async throws {
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
                                "ARCHS": "arm64",
                                "BUILD_VARIANTS": "normal",
                                "PRODUCT_NAME": "Target1",
                                "BUILD_DESCRIPTION_CACHE_DIR": "/var/should/not/export"
                            ])],
                        buildPhases: [TestSourcesBuildPhase(["main.swift"])])
                ])
            ]).load(getCore())
        let context = try await contextForTestData(testWorkspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let parameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext, parameters: parameters, project: testProject, target: testTarget)

        let env = SWBCore.computeScriptEnvironment(.shellScriptPhase, scope: settings.globalScope, settings: settings, workspaceContext: context)

        let shouldNotBeExported = [
            "BUILD_DESCRIPTION_CACHE_DIR",
        ]

        for setting in shouldNotBeExported {
            #expect(!env.contains(setting), "The build setting '\(setting)' should not be exported into the shell environment.")
        }
    }
}
