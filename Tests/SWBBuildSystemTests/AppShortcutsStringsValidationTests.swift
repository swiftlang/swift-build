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

import SWBBuildSystem
import SWBCore
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SWBProtocol

@Suite(.requireXcode16())
fileprivate struct AppShortcutsStringsValidationTests: CoreBasedTests {
    let appShortcutsStringsFileName = "AppShortcuts.strings"

    @Test(.requireSDKs(.macOS))
    func appShortcutsStringsValidation_InvalidStringsFile() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion

        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "AppShortcutsProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "USE_HEADERMAP": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "testTarget", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                "DEFINES_MODULE": "YES",
                                "PACKAGE_RESOURCE_BUNDLE_NAME": "best_resources",
                                "APPLY_RULES_IN_COPY_FILES": "YES",
                                // Disable the SetOwnerAndGroup action by setting them to empty values.
                                "INSTALL_GROUP": "",
                                "INSTALL_OWNER": "",
                                // Test only strings validation
                                "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING": "NO",
                                "DSTROOT": tmpDir.join("dstroot").str,
                                "LM_ENABLE_LINK_GENERATION": "YES",
                            ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot
            let parameters = BuildParameters(action: .install, configuration: "Debug")

            try await tester.fs.writeFileContents(projectDir.join("source.swift")) { stream in
                stream <<<
                    """
                    struct Tester {}
                    """
            }

            try await tester.fs.writeFileContents(projectDir.join(appShortcutsStringsFileName)) { stream in
                stream <<<
                    """
                    "key" = "Invalid strings file"
                    """
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkError(.contains("Couldn't parse property list because the input data was in an invalid format"))
                results.checkWarning(.contains("Unable to find extract.actionsdata in '--input-data-path' directory path"))
                results.checkError(.contains("Command ValidateAppShortcutStringsMetadata failed."))
                results.checkError(.contains("Malformed AppShortcuts.strings file"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func appShortcutsStringsValidation() async throws {
        try await withTemporaryDirectory { tmpDir in

            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion

            let testProject = TestProject(
                "AppShortcutsProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile(appShortcutsStringsFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "USE_HEADERMAP": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "testTarget", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                "DEFINES_MODULE": "YES",
                                "PACKAGE_RESOURCE_BUNDLE_NAME": "best_resources",
                                "APPLY_RULES_IN_COPY_FILES": "YES",
                                // Disable the SetOwnerAndGroup action by setting them to empty values.
                                "INSTALL_GROUP": "",
                                "INSTALL_OWNER": "",
                                // Test only strings validation
                                "APP_SHORTCUTS_ENABLE_FLEXIBLE_MATCHING": "NO",
                                "DSTROOT": tmpDir.join("dstroot").str,
                                "LM_ENABLE_LINK_GENERATION": "YES",
                            ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot
            let parameters = BuildParameters(action: .install, configuration: "Debug")

            try await tester.fs.writeFileContents(projectDir.join("source.swift")) { stream in
                stream <<<
                    """
                    import AppIntents
                    struct TestIntent: AppIntent {
                        static let title: LocalizedStringResource = "Play Sound Effect"

                        func perform() async throws -> some IntentResult {
                            return .result()
                        }
                    }

                    struct TestAppShortcutsProvider: AppShortcutsProvider {
                        static var appShortcuts: [AppShortcut] {
                            AppShortcut(
                                intent: TestIntent(),
                                phrases: [
                                    "Call",
                                ],
                                shortTitle: "Call",
                                systemImageName: "phone.fill"
                            )
                        }

                        static let shortcutTileColor: ShortcutTileColor = .orange
                    }
                    """
            }

            try await tester.fs.writeFileContents(projectDir.join(appShortcutsStringsFileName)) { stream in
                stream <<<
                    """
                    /* Valid strings file without correct utterance syntax for \(appShortcutsStringsFileName) */
                    "Call" = "Incorrect utterance syntax 1";
                    """
            }

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            let metadataFolderPath = "\(SRCROOT)/build/UninstalledProducts/macosx/testTarget.bundle/Contents/Resources/Metadata.appintents"

            // Check that there is 1 error per invalid line
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("ValidateAppShortcutStringsMetadata")) { task in
                    let executableName = task.commandLine.first
                    if let executableName,
                       executableName.asString.hasSuffix("appshortcutstringsprocessor") {
                        task.checkCommandLine([executableName.asString,
                                               "--source-file", "\(SRCROOT)/\(appShortcutsStringsFileName)",
                                               "--input-data-path", metadataFolderPath,
                                               "--platform-family",  "macOS",
                                               "--deployment-target", core.loadSDK(.macOS).defaultDeploymentTarget,
                                               "--validate-assistant-intents",
                                               "--metadata-file-list", "\(tmpDir.str)/build/AppShortcutsProject.build/Debug/testTarget.build/testTarget.DependencyMetadataFileList"
                                              ])
                    }
                }
                // 2 Errors for missing application name as the phrases in the app shortcut are combined with the
                // with the phrases in the strings file.
                results.checkError(.contains("Invalid Utterance. Every App Shortcut utterance should have one '${applicationName}' in it."))
                results.checkError(.contains("Invalid Utterance. Every App Shortcut utterance should have one '${applicationName}' in it."))
                results.checkError(.contains("Command ValidateAppShortcutStringsMetadata failed."), failIfNotFound: false)
            }

            try await tester.fs.writeFileContents(projectDir.join(appShortcutsStringsFileName)) { stream in
                stream <<<
                    """
                    /* Valid strings file with correct utterance syntax for \(appShortcutsStringsFileName) (contains ${applicationName}) */
                    "key" = "Correct utterance ${applicationName}";
                    """
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkWarning(.contains("This phrase is not used in any App Shortcut or as a Negative Phrase."))
                results.checkNoErrors()
            }
        }
    }
}
