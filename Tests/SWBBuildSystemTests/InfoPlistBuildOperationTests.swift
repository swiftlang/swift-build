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

import SWBCore
import SWBTestSupport
import SWBUtil
import Testing
import SWBProtocol
import SWBTaskExecution

@Suite
fileprivate struct InfoPlistBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func infoPlistPreprocessingMerging() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir.path,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("infoplist-prefix.h"),
                        TestFile("SourceFile.m"),
                        TestFile("Tool.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
                        "INFOPLIST_FILE": "Tool.plist",
                        "INFOPLIST_PREPROCESS": "YES",
                        "DSTROOT": tmpDir.path.join("dstroot").str,

                        // Disable the SetOwnerAndGroup action by setting them to empty values.
                        "INSTALL_GROUP": "",
                        "INSTALL_OWNER": "",
                    ]),
                    TestBuildConfiguration("Release", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
                        "INFOPLIST_FILE": "Tool.plist",
                        "INFOPLIST_PREPROCESS": "YES",
                        "DSTROOT": tmpDir.path.join("dstroot").str,

                        // Disable the SetOwnerAndGroup action by setting them to empty values.
                        "INSTALL_GROUP": "",
                        "INSTALL_OWNER": "",
                    ]),
                ],
                targets: [
                    TestAggregateTarget("All", dependencies: ["Tool", "App"]),
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                            TestBuildConfiguration("Release"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.m",
                            ]),
                        ]
                    ),
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                            TestBuildConfiguration("Release"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.m",
                            ]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.write(tmpDir.path.join("SourceFile.m"), contents: ByteString("int main() { return 0; }"))
            func writeToolPlist(different: Bool) async throws {
                try await tester.fs.writeFileContents(tmpDir.path.join("Tool.plist")) { contents in
                    contents <<<
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    <plist version="1.0">
                    <dict>

                    """
                    for arch in ["arm64", "x86_64"] {
                        contents <<< "#if __is_target_arch(\(arch))\n"
                        contents <<< "<key>arch</key>\n"
                        contents <<< "<string>\(different ? arch : "undefined_arch")</string>\n"
                        contents <<< "#endif\n"
                    }
                    contents <<< "</dict></plist>\n"
                }
            }
            try await writeToolPlist(different: false)

            try await tester.checkBuild(parameters: BuildParameters(action: .install, configuration: "Release"), runDestination: .anyMac) { results in
                results.checkNoDiagnostics()
                for arch in ["arm64", "x86_64"] {
                    // There should be an Info.plist processing task, and associated Preprocess (we explicitly enable it).
                    results.checkTask(.matchTargetName("Tool"), .matchRule(["Preprocess", "\(SRCROOT)/build/aProject.build/Release/Tool.build/normal/\(arch)/Preprocessed-Info.plist", "\(SRCROOT)/Tool.plist"])) { task in
                        task.checkCommandLine(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/cc", "-E", "-P", "-x", "c", "-Wno-trigraphs", "\(SRCROOT)/Tool.plist", "-F\(SRCROOT)/build/Release", "-target", "\(arch)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-o", "\(SRCROOT)/build/aProject.build/Release/Tool.build/normal/\(arch)/Preprocessed-Info.plist"])
                    }
                }

                for arch in ["arm64", "x86_64"] {
                    // There should be an Info.plist processing task, and associated Preprocess (we explicitly enable it).
                    results.checkTask(.matchTargetName("App"), .matchRule(["Preprocess", "\(SRCROOT)/build/aProject.build/Release/App.build/normal/\(arch)/Preprocessed-Info.plist", "\(SRCROOT)/Tool.plist"])) { task in
                        task.checkCommandLine(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/cc", "-E", "-P", "-x", "c", "-Wno-trigraphs", "\(SRCROOT)/Tool.plist", "-F\(SRCROOT)/build/Release", "-target", "\(arch)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-o", "\(SRCROOT)/build/aProject.build/Release/App.build/normal/\(arch)/Preprocessed-Info.plist"])
                    }
                }

                results.checkTask(.matchTargetName("App"), .matchRuleType("MergeInfoPlistFile")) { task in
                    task.checkCommandLine([
                        "builtin-mergeInfoPlist",
                        "\(SRCROOT)/build/aProject.build/Release/App.build/Preprocessed-Info.plist",
                        "\(SRCROOT)/build/aProject.build/Release/App.build/normal/arm64/Preprocessed-Info.plist",
                        "\(SRCROOT)/build/aProject.build/Release/App.build/normal/x86_64/Preprocessed-Info.plist"])
                }
            }

            // Now write the plist against with per-arch contents and the build should fail
            try await writeToolPlist(different: true)

            try await tester.checkBuild(parameters: BuildParameters(action: .install, configuration: "Release"), runDestination: .anyMac) { results in
                _ = results.checkTask(.matchTargetName("App"), .matchRuleType("MergeInfoPlistFile")) { task in
                    results.checkError(.equal("Info.plist preprocessing produced variable content across multiple architectures and/or build variants, which is not allowed for bundle targets.\n\(["arm64", "x86_64"].map { arch in "\(SRCROOT)/build/aProject.build/Release/App.build/normal/\(arch)/Preprocessed-Info.plist: Using preprocessed file: \(SRCROOT)/build/aProject.build/Release/App.build/normal/\(arch)/Preprocessed-Info.plist" }.joined(separator: "\n")) (for task: \(task.ruleInfo))"))
                }

                results.checkNoDiagnostics()
            }

            // Build with no architectures and we should produce an error.
            try await tester.checkBuild(parameters: BuildParameters(action: .install, configuration: "Release", overrides: ["ARCHS": "soup"]), runDestination: .anyMac) { results in
                _ = results.checkTask(.matchTargetName("App"), .matchRuleType("MergeInfoPlistFile")) { task in
                    results.checkError(.equal("Info.plist preprocessing did not produce content for any architecture and build variant combination. (for task: \(task.ruleInfo))"))
                }

                results.checkWarning(.prefix("None of the architectures in ARCHS (soup) are valid."))
                results.checkWarning(.prefix("None of the architectures in ARCHS (soup) are valid."))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func infoPlistIncrementalBehavior() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir.path,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("SourceFile.m"),
                        TestFile("Tool.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "INFOPLIST_FILE": "Tool.plist",
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.m",
                            ]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            try tester.fs.write(tmpDir.path.join("SourceFile.m"), contents: ByteString("int main() { return 0; }"))
            try await tester.fs.writeFileContents(tmpDir.path.join("Tool.plist")) { contents in
                contents <<<
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                </dict></plist>
                """
            }
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .anyMac, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTaskExists(.matchTargetName("App"), .matchRuleType("ProcessInfoPlistFile"))
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", commandLineOverrides: ["FOO": "Bar"]), runDestination: .anyMac, persistent: true) { results in
                results.checkNoDiagnostics()
                results.consumeTasksMatchingRuleTypes(["ClangStatCache"])
                // We should only run the Info.plist processortask for the app when arbitrary build settings change.
                results.checkTaskExists(.matchTargetName("App"), .matchRuleType("ProcessInfoPlistFile"))
                results.checkNoTask()
            }
        }
    }
}
