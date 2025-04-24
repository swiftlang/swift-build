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
fileprivate struct AppIntentsNLTrainingTests: CoreBasedTests {
    let appShortcutsStringsFileName = "AppShortcuts.strings"
    let appIntentsSourceFileName = "source.swift"
    let infoPlistFileName = "Info.plist"

    @Test(.requireSDKs(.iOS))
    func appIntentsNLTraining() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "AppIntentsProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile(appShortcutsStringsFileName),
                        TestFile(appIntentsSourceFileName),
                        TestFile(infoPlistFileName)
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "ARCHS": "$(ARCHS_STANDARD)",
                        "CODE_SIGN_IDENTITY": "-",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "VERSIONING_SYSTEM": "apple-generic",
                        "INFOPLIST_FILE": "Sources/Info.plist",
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "testTarget", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "USE_HEADERMAP": "NO",
                                "DEFINES_MODULE": "YES",
                                "PACKAGE_RESOURCE_BUNDLE_NAME": "best_resources",
                                "APPLY_RULES_IN_COPY_FILES": "YES",
                                // Disable the SetOwnerAndGroup action by setting them to empty values.
                                "INSTALL_GROUP": "",
                                "INSTALL_OWNER": "",
                            ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase([TestBuildFile(appShortcutsStringsFileName)]),
                            TestSourcesBuildPhase([TestBuildFile(appIntentsSourceFileName)]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writePlist(SRCROOT.join("Sources/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleName": .plString("$(EXECUTABLE_NAME)"),
                "CFBundleIdentifier": .plString("com.foo.bar")
            ]))

            try await tester.fs.writeFileContents(projectDir.join(appShortcutsStringsFileName)) { stream in
                stream <<<
                    """
                    /* Valid strings file with correct utterance syntax for \(appShortcutsStringsFileName) (contains ${applicationName}) */
                    "Call ${applicationName}" = "Call ${applicationName}";
                    """
            }

            try await tester.fs.writeFileContents(projectDir.join(appIntentsSourceFileName)) { stream in
                stream <<<
                    """
                    import AppIntents
                    import SwiftUI

                    @main
                    struct TestAppIntentsEmptyApp: App {
                        var body: some Scene {
                            WindowGroup {
                                ContentView()
                            }
                        }
                    }

                    struct ContentView: View {
                        var body: some View {
                            VStack {
                                Image(systemName: "globe")
                                    .imageScale(.large)
                                    .foregroundColor(.accentColor)
                                Text("Hello, world!")
                            }
                            .padding()
                        }
                    }

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
                                    "Call \\(.applicationName)",
                                ],
                                shortTitle: "Call",
                                systemImageName: "phone.fill"
                            )
                        }

                        static let shortcutTileColor: ShortcutTileColor = .orange
                    }
                    """
            }

            let parameters = BuildParameters(action: .install, configuration: "Debug")
            try await tester.checkBuild(parameters: parameters, runDestination: .iOS) { results in
                results.checkNoErrors()
            }
        }
    }
}

