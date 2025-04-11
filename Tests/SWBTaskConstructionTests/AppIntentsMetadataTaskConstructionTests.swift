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

import Testing

import SWBCore
import SWBProtocol
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil
import Foundation
import SWBTaskExecution

@Suite(.requireXcode16())
fileprivate struct AppIntentsMetadataTaskConstructionTests: CoreBasedTests {
    let appShortcutsStringsFileName = "AppShortcuts.strings"
    let assistantIntentsStringsFileName = "AssistantIntents.strings"

    @Test(.requireSDKs(.iOS))
    func appIntentsMetadataWithoutYamlGeneration() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let swiftFeatures = try await self.swiftFeatures
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName),
                        TestFile(assistantIntentsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName), TestBuildFile(assistantIntentsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
            let tester = try TaskConstructionTester(core, testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        let commandLineBeforeConst = [executableName.asString,
                                                      "--toolchain-dir", "\(defaultToolchain.path.str)",
                                                      "--module-name", "LinkTest",
                                                      "--sdk-root", core.loadSDK(.iOS).path.str,
                                                      "--xcode-version", core.xcodeProductBuildVersionString,
                                                      "--platform-family", "iOS",
                                                      "--deployment-target", core.loadSDK(.iOS).defaultDeploymentTarget,
                                                      "--bundle-identifier", "com.foo.bar",
                                                      "--output", "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app",
                                                      "--target-triple", "arm64-apple-ios\(core.loadSDK(.iOS).version)",
                                                      "--binary-file", "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/LinkTest",
                                                      "--dependency-file", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/LinkTest_dependency_info.dat",
                                                      "--stringsdata-file", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/ExtractedAppShortcutsMetadata.stringsdata",
                                                      "--source-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/LinkTest.SwiftFileList",
                                                      "--metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList",
                                                      "--static-metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyStaticMetadataFileList"]

                        let commandLineAfterConst = (swiftFeatures.has(.constExtractCompleteMetadata) ? ["--compile-time-extraction"] : []) +
                        ["--deployment-aware-processing", "--validate-assistant-intents"]
                        let commandLine: [String]
                        if swiftFeatures.has(.emitContValuesSidecar) {
                            commandLine = commandLineBeforeConst +
                            ["--swift-const-vals-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/LinkTest.SwiftConstValuesFileList"] +
                            commandLineAfterConst
                        } else {
                            commandLine = commandLineBeforeConst + commandLineAfterConst
                        }

                        task.checkCommandLine(commandLine)
                    }

                    var expectedInputs: [NodePattern] = [
                        .path("\(SRCROOT)/source.swift"),
                        .path("\(SRCROOT)/AppShortcuts.strings"),
                        .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/LinkTest"),
                        .namePattern(.suffix("LinkTest.DependencyMetadataFileList")),
                        .namePattern(.suffix("LinkTest.DependencyStaticMetadataFileList")),
                        .namePattern(.suffix("dependency_info.dat")),
                        .namePattern(.suffix("LinkTest.SwiftFileList")),
                        .namePattern(.suffix("LinkTest.SwiftConstValuesFileList")),
                        .namePattern(.and(.prefix("target-"), .suffix("-ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-fused-phase0-copy-bundle-resources&compile-sources"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                    ]
                    if swiftFeatures.has(.emitContValuesSidecar) {
                        expectedInputs.insert(.namePattern(.suffix("source.swiftconstvalues")), at: 1)
                    }

                    task.checkInputs(expectedInputs)

                    task.checkOutputs([
                        /* rdar://93626172 (Re-enable AppIntentsMetadataProcessor outputs)
                         .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents/objects.appintentsmanifest"),
                         .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents/version.json"),
                         .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents/extract.actionsdata")
                         */
                        .path("\(SRCROOT)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/ExtractedAppShortcutsMetadata.stringsdata"),
                        .name("ExtractAppIntentsMetadata \(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents")
                    ])

                    results.checkNoDiagnostics()
                }

                results.checkWriteAuxiliaryFileTask(.matchRuleItemPattern(.suffix("LinkTest.SwiftConstValuesFileList"))) { task, contents in
                    task.checkRuleInfo(["WriteAuxiliaryFile", .suffix("LinkTest.SwiftConstValuesFileList")])
                    task.checkOutputs(contain: [.namePattern(.suffix("LinkTest.SwiftConstValuesFileList"))])
                    if swiftFeatures.has(.emitContValuesSidecar) {
                        #expect(contents.asString.hasSuffix("source.swiftconstvalues\n"))
                    } else {
                        #expect(contents.asString.isEmpty)
                    }
                }

                results.checkTask(.matchRuleType("ValidateAppShortcutStringsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appshortcutstringsprocessor" {
                        task.checkCommandLine([executableName.asString,
                                               "--source-file", "\(SRCROOT)/\(appShortcutsStringsFileName)",
                                               "--source-file", "\(SRCROOT)/\(assistantIntentsStringsFileName)",
                                               "--input-data-path", "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents",
                                               "--platform-family",  "iOS",
                                               "--deployment-target", core.loadSDK(.iOS).defaultDeploymentTarget,
                                               "--validate-assistant-intents",
                                               "--metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList"
                                              ])
                    }

                    task.checkInputs([
                        .path("\(SRCROOT)/\(appShortcutsStringsFileName)"),
                        .path("\(SRCROOT)/\(assistantIntentsStringsFileName)"),
                        .path("\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList"),
                        .name("ExtractAppIntentsMetadata \(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents"),
                        .namePattern(.and(.prefix("target-"), .suffix("-ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-fused-phase0-copy-bundle-resources&compile-sources"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                    ])

                    task.checkOutputs([
                        .namePattern(.and(.prefix("ValidateAppShortcutStringsMetadata target-LinkTest-T-LinkTest-"), .and(.contains("\(SRCROOT)/\(assistantIntentsStringsFileName)"), .contains("\(SRCROOT)/\(appShortcutsStringsFileName)")) )),
                    ])

                    results.checkNoDiagnostics()
                }

                results.checkNoTask(.matchRuleType("AppIntentsSSUTraining"))
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func appIntentsMetadataWithYamlGeneration() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let swiftFeatures = try await self.swiftFeatures
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
            let tester = try TaskConstructionTester(core, testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        let commandLineBeforeConst = [executableName.asString,
                                                      "--toolchain-dir", "\(defaultToolchain.path.str)",
                                                      "--module-name", "LinkTest",
                                                      "--sdk-root", results.runDestinationSDK.path.str,
                                                      "--xcode-version", core.xcodeProductBuildVersionString,
                                                      "--platform-family", "iOS",
                                                      "--deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                                      "--bundle-identifier", "com.foo.bar",
                                                      "--output", "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app",
                                                      "--target-triple", "arm64-apple-ios\(results.runDestinationSDK.version)",
                                                      "--binary-file", "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/LinkTest",
                                                      "--dependency-file", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/LinkTest_dependency_info.dat",
                                                      "--stringsdata-file", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/ExtractedAppShortcutsMetadata.stringsdata",
                                                      "--source-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/LinkTest.SwiftFileList",
                                                      "--metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList",
                                                      "--static-metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyStaticMetadataFileList"]
                        let commandLineAfterConst = (swiftFeatures.has(.constExtractCompleteMetadata) ? ["--compile-time-extraction"] : []) +
                        ["--deployment-aware-processing", "--validate-assistant-intents"]
                        let commandLine: [String]
                        if swiftFeatures.has(.emitContValuesSidecar) {
                            commandLine = commandLineBeforeConst +
                            ["--swift-const-vals-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/LinkTest.SwiftConstValuesFileList"] +
                            commandLineAfterConst
                        } else {
                            commandLine = commandLineBeforeConst + commandLineAfterConst
                        }

                        task.checkCommandLine(commandLine)
                    }

                    var expectedInputs: [NodePattern] = [
                        .path("\(SRCROOT)/source.swift"),
                        .path("\(SRCROOT)/AppShortcuts.strings"),
                        .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/LinkTest"),
                        .namePattern(.suffix("LinkTest.DependencyMetadataFileList")),
                        .namePattern(.suffix("LinkTest.DependencyStaticMetadataFileList")),
                        .namePattern(.suffix("dependency_info.dat")),
                        .namePattern(.suffix("LinkTest.SwiftFileList")),
                        .namePattern(.suffix("LinkTest.SwiftConstValuesFileList")),
                        .namePattern(.and(.prefix("target-"), .suffix("-ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-fused-phase0-copy-bundle-resources&compile-sources"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                    ]
                    if swiftFeatures.has(.emitContValuesSidecar) {
                        expectedInputs.insert(.namePattern(.suffix("source.swiftconstvalues")), at: 1)
                    }

                    task.checkInputs(expectedInputs)

                    task.checkOutputs([
                        /* rdar://93626172 (Re-enable AppIntentsMetadataProcessor outputs)
                         .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents/objects.appintentsmanifest"),
                         .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents/version.json"),
                         .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents/extract.actionsdata")
                         */
                        .path("\(SRCROOT)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/ExtractedAppShortcutsMetadata.stringsdata"),
                        .name("ExtractAppIntentsMetadata \(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents")
                    ])

                    results.checkNoDiagnostics()
                }

                results.checkWriteAuxiliaryFileTask(.matchRuleItemPattern(.suffix("LinkTest.SwiftConstValuesFileList"))) { task, contents in
                    task.checkRuleInfo(["WriteAuxiliaryFile", .suffix("LinkTest.SwiftConstValuesFileList")])
                    task.checkOutputs(contain: [.namePattern(.suffix("LinkTest.SwiftConstValuesFileList"))])
                    if swiftFeatures.has(.emitContValuesSidecar) {
                        #expect(contents.asString.hasSuffix("source.swiftconstvalues\n"))
                    } else {
                        #expect(contents.asString.isEmpty)
                    }
                }

                results.checkTask(.matchRuleType("ValidateAppShortcutStringsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appshortcutstringsprocessor" {
                        task.checkCommandLine([executableName.asString,
                                               "--source-file", "\(SRCROOT)/\(appShortcutsStringsFileName)",
                                               "--input-data-path", "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents",
                                               "--platform-family",  "iOS",
                                               "--deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                                               "--validate-assistant-intents",
                                               "--metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList"
                                              ])
                    }

                    task.checkInputs([
                        .path("\(SRCROOT)/\(appShortcutsStringsFileName)"),
                        .path("\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList"),
                        .name("ExtractAppIntentsMetadata \(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents"),
                        .namePattern(.and(.prefix("target-"), .suffix("-ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-fused-phase0-copy-bundle-resources&compile-sources"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                    ])

                    task.checkOutputs([
                        .namePattern(.and(.prefix("ValidateAppShortcutStringsMetadata target-LinkTest-T-LinkTest-"), .suffix("\(SRCROOT)/\(appShortcutsStringsFileName)"))),
                    ])

                    results.checkNoDiagnostics()
                }

                results.checkTask(.matchRuleType("AppIntentsSSUTraining")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsnltrainingprocessor" {
                        task.checkCommandLine([executableName.asString,
                                               "--infoplist-path",
                                               "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Info.plist",
                                               "--temp-dir-path",
                                               "\(SRCROOT)/build/aProject.build/Debug-iphoneos/LinkTest.build/ssu",
                                               "--bundle-id",
                                               "com.foo.bar",
                                               "--product-path",
                                               "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app",
                                               "--extracted-metadata-path",
                                               "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents",
                                               "--metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList",
                                               "--archive-ssu-assets"
                                              ])
                    }

                    task.checkInputs([
                        .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Info.plist"),
                        .path("\(SRCROOT)/\(appShortcutsStringsFileName)"),
                        .namePattern(.and(.prefix("ValidateAppShortcutStringsMetadata target-LinkTest-T-LinkTest-"), .suffix("\(SRCROOT)/\(appShortcutsStringsFileName)"))),
                        .namePattern(.and(.prefix("ExtractAppIntentsMetadata"), .suffix("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents"))),
                        .namePattern(.suffix("LinkTest.DependencyMetadataFileList")),
                        .namePattern(.and(.prefix("target-"), .suffix("-ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-fused-phase0-copy-bundle-resources&compile-sources"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug-iphoneos/LinkTest.build/ssu/root.ssu.yaml"),
                    ])

                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func appIntentsMetadataWithYamlGenerationForRelease() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(action: .build, configuration: "Release"), runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("AppIntentsSSUTraining")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsnltrainingprocessor" {
                        task.checkCommandLineDoesNotContain("--deployment-postprocessing")
                    }
                    results.checkNoDiagnostics()
                }
            }
            await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("AppIntentsSSUTraining")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsnltrainingprocessor" {
                        task.checkCommandLineContains(["--deployment-postprocessing"])
                    }
                    results.checkNoDiagnostics()
                }
            }
            await tester.checkBuild(BuildParameters(action: .archive, configuration: "Release"), runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("AppIntentsSSUTraining")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsnltrainingprocessor" {
                        task.checkCommandLineContains(["--deployment-postprocessing"])
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func appIntentsMetadataWithAppNameOverrideAndDisable() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "LM_ENABLE_APP_NAME_OVERRIDE": "YES",
                                    "LM_ENABLE_STRING_VALIDATION": "NO",
                                    "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ValidateAppShortcutStringsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appshortcutstringsprocessor" {
                        task.checkCommandLine([executableName.asString,
                                               "--source-file",
                                               "\(SRCROOT)/\(appShortcutsStringsFileName)",
                                               "--input-data-path",
                                               "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents",
                                               "--disable",
                                               "--app-name-override",
                                               "--platform-family",  "iOS",
                                               "--deployment-target", core.loadSDK(.iOS).defaultDeploymentTarget,
                                               "--validate-assistant-intents",
                                               "--metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList"
                                              ])
                    }

                    task.checkInputs([
                        .path("\(SRCROOT)/\(appShortcutsStringsFileName)"),
                        .path("\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList"),
                        .name("ExtractAppIntentsMetadata \(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents"),
                        .namePattern(.and(.prefix("target-"), .suffix("-ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-fused-phase0-copy-bundle-resources&compile-sources"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                    ])

                    task.checkOutputs([
                        .namePattern(.and(.prefix("ValidateAppShortcutStringsMetadata target-LinkTest-T-LinkTest-"), .suffix("\(SRCROOT)/\(appShortcutsStringsFileName)"))),
                    ])

                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func skipInstall() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic"
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .iOS) { results in
                results.checkNoTask(.matchRuleType("ExtractAppIntentsMetadata"))
                results.checkNoTask(.matchRuleType("ValidateAppShortcutStringsMetadata"))
                results.checkNoTask(.matchRuleType("AppIntentsSSUTraining"))
                results.checkNoErrors()
            }
        }
    }

    // Ensure const metadata emission by the compiler is enabled by-default for public SDK clients.
    @Test(.requireSDKs(.macOS))
    func enableDefaultConstValueExtractIfPublicSDK() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "macosx",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkWriteAuxiliaryFileTask(.matchRuleItemPattern(.suffix("LinkTest.SwiftConstValuesFileList"))) { task, contents in
                    task.checkRuleInfo(["WriteAuxiliaryFile", .suffix("LinkTest.SwiftConstValuesFileList")])
                    task.checkOutputs(contain: [.namePattern(.suffix("LinkTest.SwiftConstValuesFileList"))])
                    #expect(contents.asString.hasSuffix("source.swiftconstvalues\n"))
                }
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-emit-const-values"])
                }
            }
        }
    }

    // Ensure const metadata emission by the compiler functions in WMO mode.
    @Test(.requireSDKs(.iOS), .requireLLBuild(apiVersion: 12))
    func constValueExtractWMO() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileA1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",
                                    "SWIFT_WHOLE_MODULE_OPTIMIZATION": "YES",
                                    "SWIFT_ENABLE_LIBRARY_EVOLUTION": "YES",
                                    "SDKROOT": "iphoneos",
                                    "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileA1.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .anyiOSDevice, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()

                let targetNameSuffix = "A"
                let targetName = "Target\(targetNameSuffix)"
                results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName(targetName)) { driverTask in
                    driverTask.checkCommandLineMatches(["builtin-SwiftDriver", "--", .anySequence])
                    #expect(driverTask.execDescription == "Planning Swift module \(targetName) (arm64e)")
                    results.checkNoUncheckedTasksRequested(driverTask)
                }

                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTargetName(targetName)) { compilationBlockingTask in
                    compilationBlockingTask.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements"])
                    #expect(compilationBlockingTask.execDescription == "Unblock downstream dependents of \(targetName) (arm64e)")

                    results.checkTaskRequested(compilationBlockingTask, .matchTargetName(targetName), .matchRule(["SwiftEmitModule", "normal", "arm64e", "Emitting module for \(targetName)"]))
                }

                results.checkTask(.matchRuleType("SwiftDriver Compilation"), .matchTargetName(targetName)) { compilationTask in
                    compilationTask.checkCommandLineMatches(["builtin-Swift-Compilation"])
                    compilationTask.checkCommandLineContains(["-emit-const-values"])
                    #expect(compilationTask.execDescription == "Compile \(targetName) (arm64e)")
                    results.checkTaskRequested(compilationTask, .matchTargetName(targetName), .matchRuleType("SwiftCompile"), .matchRuleItem(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str))
                }

                results.checkTask(.matchTargetName(targetName), .matchRulePattern(["SwiftCompile", "normal", "arm64e", "Compiling file\(targetNameSuffix)1.swift", .equal(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str)])) { compileFileTask in
                    compileFileTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, .equal(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str), .anySequence, "-o", .suffix("file\(targetNameSuffix)1.o")])
                }

                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    task.checkCommandLineMatches([.suffix("appintentsmetadataprocessor"), .anySequence, "--swift-const-vals-list", .suffix("TargetA.SwiftConstValuesFileList"), .anySequence])
                    results.checkNoDiagnostics()
                }

            }
        }
    }

    // Ensure SSU tasks are enabled by-default for public SDK clients.
    @Test(.requireSDKs(.iOS))
    func sSUTasksIfPublicSDK() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("AppIntentsSSUTraining")) { task in
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    // Ensure SSU tasks are enabled by-default for public SDK clients,
    // but can be overridden with 'APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING=NO'
    @Test(.requireSDKs(.iOS))
    func overrideSSUTasksIfPublicSDK() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar"
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING": "NO",
                                    "LM_ENABLE_LINK_GENERATION": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkNoTask(.matchRuleType("AppIntentsSSUTraining"))
            }
        }
    }

    // Ensure SSU tasks are enabled by-default for public SDK clients, except for non-iOS platforms
    @Test(.requireSDKs(.macOS))
    func SSUTasksIfPublicSDKForNonIOS() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "macosx",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkNoTask(.matchRuleType("AppIntentsSSUTraining"))
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func ignoreQueryGenericsErrors() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "LM_IGNORE_QUERY_GENERICS_ERRORS": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        task.checkCommandLineContains(["--ignore-query-generics-errors"])
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func forceLinkGeneration() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "LM_FORCE_LINK_GENERATION": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        task.checkCommandLineContains(["--force"])
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func skipInstallViaConfig() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic"
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_METADATA_EXTRACTION": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .iOS) { results in
                results.checkNoTask(.matchRuleType("ExtractAppIntentsMetadata"))
                results.checkNoTask(.matchRuleType("ValidateAppShortcutStringsMetadata"))
                results.checkNoTask(.matchRuleType("AppIntentsSSUTraining"))
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func skipCompileTimeExtractionViaConfig() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "LM_COMPILE_TIME_EXTRACTION": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        task.checkCommandLineDoesNotContain("--compile-time-extraction")
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func disableAppIntentsDeploymentAwareProcessing() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "ENABLE_APPINTENTS_DEPLOYMENT_AWARE_PROCESSING": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        task.checkCommandLineDoesNotContain("--deployment-aware-processing")
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func disableAssistantIntentsProviderValidation() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "ENABLE_ASSISTANT_INTENTS_PROVIDER_VALIDATION": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        task.checkCommandLineDoesNotContain("---validate-assistant-intents")
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func multipleBuildVariants() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let swiftFeatures = try await self.swiftFeatures
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "BUILD_VARIANTS": "normal debug",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
            let tester = try TaskConstructionTester(core, testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        let commandLineBeforeConst = [executableName.asString,
                                                      "--toolchain-dir", "\(defaultToolchain.path.str)",
                                                      "--module-name", "LinkTest",
                                                      "--sdk-root", core.loadSDK(.iOS).path.str,
                                                      "--xcode-version", core.xcodeProductBuildVersionString,
                                                      "--platform-family", "iOS",
                                                      "--deployment-target", core.loadSDK(.iOS).defaultDeploymentTarget,
                                                      "--bundle-identifier", "com.foo.bar",
                                                      "--output", "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app",
                                                      "--target-triple", "arm64-apple-ios\(core.loadSDK(.iOS).version)",
                                                      "--binary-file", "\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/LinkTest",
                                                      "--dependency-file", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/LinkTest_dependency_info.dat",
                                                      "--dependency-file", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-debug/arm64/LinkTest_dependency_info.dat",
                                                      "--stringsdata-file", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/ExtractedAppShortcutsMetadata.stringsdata",
                                                      "--stringsdata-file", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-debug/arm64/ExtractedAppShortcutsMetadata.stringsdata",
                                                      "--source-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/LinkTest.SwiftFileList",
                                                      "--source-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-debug/arm64/LinkTest.SwiftFileList",
                                                      "--metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList",
                                                      "--static-metadata-file-list", "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyStaticMetadataFileList"]

                        let commandLineAfterConst = (swiftFeatures.has(.constExtractCompleteMetadata) ? ["--compile-time-extraction"] : []) +
                        ["--deployment-aware-processing", "--validate-assistant-intents"]
                        let commandLine: [String]
                        if swiftFeatures.has(.emitContValuesSidecar) {
                            commandLine = commandLineBeforeConst +
                            [
                                "--swift-const-vals-list",
                                "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/LinkTest.SwiftConstValuesFileList",
                                "--swift-const-vals-list",
                                "\(tmpDir.str)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-debug/arm64/LinkTest.SwiftConstValuesFileList"
                            ] +
                            commandLineAfterConst
                        } else {
                            commandLine = commandLineBeforeConst + commandLineAfterConst
                        }

                        task.checkCommandLine(commandLine + ["--no-app-shortcuts-localization"])
                    }

                    var expectedInputs: [NodePattern] = [
                        .path("\(SRCROOT)/source.swift"),
                        .path("\(SRCROOT)/build/Debug-iphoneos/LinkTest.app/LinkTest"),
                        .namePattern(.suffix("LinkTest.DependencyMetadataFileList")),
                        .namePattern(.suffix("LinkTest.DependencyStaticMetadataFileList")),
                        .namePattern(.suffix("dependency_info.dat")),
                        .namePattern(.suffix("LinkTest.SwiftFileList")),
                        .namePattern(.suffix("LinkTest.SwiftConstValuesFileList")),
                        .namePattern(.suffix("dependency_info.dat")),
                        .namePattern(.suffix("LinkTest.SwiftFileList")),
                        .namePattern(.suffix("LinkTest.SwiftConstValuesFileList")),
                        .namePattern(.and(.prefix("target-"), .suffix("-ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-fused-phase0-compile-sources"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                    ]
                    if swiftFeatures.has(.emitContValuesSidecar) {
                        expectedInputs.insert(.namePattern(.suffix("source.swiftconstvalues")), at: 1)
                        expectedInputs.insert(.namePattern(.suffix("source.swiftconstvalues")), at: 2)
                    }

                    task.checkInputs(expectedInputs)

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-normal/arm64/ExtractedAppShortcutsMetadata.stringsdata"),
                        .path("\(SRCROOT)/build/aProject.build/Debug-iphoneos/LinkTest.build/Objects-debug/arm64/ExtractedAppShortcutsMetadata.stringsdata"),
                        .name("ExtractAppIntentsMetadata \(SRCROOT)/build/Debug-iphoneos/LinkTest.app/Metadata.appintents")
                    ])

                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func appIntentsMetadataDependencies() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName),
                        TestFile("FrameworkA_File.swift"),
                        TestFile("FrameworkB_File.swift"),
                        TestFile("FrameworkC_File.swift"),
                        TestFile("StaticLibraryA_File.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ],
                        dependencies: ["FrameworkTargetA"]
                    ),
                    TestStandardTarget(
                        "StaticLibraryTargetA",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["StaticLibraryA_File.swift"]),
                            TestFrameworksBuildPhase([])
                        ],
                        dependencies: []
                    ),

                    TestStandardTarget(
                        "FrameworkTargetA",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["FrameworkA_File.swift"]),
                            TestFrameworksBuildPhase([])
                        ],
                        dependencies: ["FrameworkTargetB", "StaticLibraryTargetA"]
                    ),
                    TestStandardTarget(
                        "FrameworkTargetB",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["FrameworkB_File.swift"]),
                            TestFrameworksBuildPhase([])
                        ],
                        dependencies: ["FrameworkTargetC"]
                    ),
                    TestStandardTarget(
                        "FrameworkTargetC",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING": "NO"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["FrameworkC_File.swift"]),
                            TestFrameworksBuildPhase([])
                        ]
                    ),
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyMetadataFileList"])) { task, contents in
                    let inputFiles = [
                        "\(SRCROOT)/build/Debug-iphoneos/FrameworkTargetA.framework/Metadata.appintents/extract.actionsdata",
                        "\(SRCROOT)/build/Debug-iphoneos/FrameworkTargetB.framework/Metadata.appintents/extract.actionsdata",
                        "\(SRCROOT)/build/Debug-iphoneos/FrameworkTargetC.framework/Metadata.appintents/extract.actionsdata"
                    ]
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == inputFiles + [""])
                }
                results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/LinkTest.build/LinkTest.DependencyStaticMetadataFileList"])) { task, contents in
                    let inputFiles = [
                        "\(SRCROOT)/build/Debug-iphoneos/StaticLibraryTargetA.appintents/Metadata.appintents/extract.actionsdata"
                    ]
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == inputFiles + [""])
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func quietWarnings() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "LM_FILTER_WARNINGS": "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        task.checkCommandLineContains(["--quiet-warnings"])
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func bundleIdentifier() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        task.checkCommandLineContainsUninterrupted(["--bundle-identifier", "com.foo.bar"])
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func emptyBundleIdentifier() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "LIBTOOL": libtoolPath.str,
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LinkStaticLibTest",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "PRODUCT_BUNDLE_IDENTIFIER": "",
                                ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName == "appintentsmetadataprocessor" {
                        task.checkCommandLineDoesNotContain("--bundle-identifier")
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }
}
