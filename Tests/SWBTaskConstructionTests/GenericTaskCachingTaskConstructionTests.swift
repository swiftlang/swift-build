//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing

import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct GenericTaskCachingTaskConstructionTests: CoreBasedTests {
    struct Configuration: Sendable, CustomTestStringConvertible {
        var settings: [String: String]
        var actool: Bool
        var ibtool: Bool
        var realitytool: Bool

        var testDescription: String {
            settings.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        }
    }

    static let configurations: [Configuration] = [
        Configuration(settings: [:], actool: false, ibtool: false, realitytool: false),
        Configuration(settings: ["ENABLE_GENERIC_TASK_CACHING": "NO"], actool: false, ibtool: false, realitytool: false),
        Configuration(settings: ["ENABLE_GENERIC_TASK_CACHING": "YES"], actool: true, ibtool: true, realitytool: true),
        Configuration(settings: ["ENABLE_GENERIC_TASK_CACHING": "YES", "ENABLE_ACTOOL_TASK_CACHING": "NO"], actool: false, ibtool: true, realitytool: true),
        Configuration(settings: ["ENABLE_GENERIC_TASK_CACHING": "YES", "ENABLE_IBTOOL_TASK_CACHING": "NO"], actool: true, ibtool: false, realitytool: true),
        Configuration(settings: ["ENABLE_GENERIC_TASK_CACHING": "YES", "ENABLE_REALITYTOOL_TASK_CACHING": "NO"], actool: true, ibtool: true, realitytool: false),
        Configuration(settings: ["ENABLE_ACTOOL_TASK_CACHING": "YES"], actool: true, ibtool: false, realitytool: false),
        Configuration(settings: ["ENABLE_IBTOOL_TASK_CACHING": "YES"], actool: false, ibtool: true, realitytool: false),
        Configuration(settings: ["ENABLE_REALITYTOOL_TASK_CACHING": "YES"], actool: false, ibtool: false, realitytool: true),
    ]

    @Test(.requireSDKs(.macOS), arguments: configurations)
    func perToolCachingSettings(_ configuration: Configuration) async throws {
        let actoolPath = try await self.actoolPath
        let ibtoolPath = try await self.ibtoolPath
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Assets.xcassets"),
                        TestFile("View.storyboard"),
                        TestFile("Reality.rkassets"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "macosx",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "ASSETCATALOG_EXEC": actoolPath.str,
                            "IBC_EXEC": ibtoolPath.str,
                            "CCHROOT": tmpDir.join("cchroot").str,
                        ].addingContents(of: configuration.settings)),
                ],
                targets: [
                    TestStandardTarget(
                        "FrameworkTarget",
                        type: .framework,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("Assets.xcassets"),
                                TestBuildFile("View.storyboard"),
                                TestBuildFile("Reality.rkassets"),
                            ]),
                        ]
                    ),
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOS) { results in
                func toolIdentifier(_ cached: Bool) -> String? {
                    cached ? "generic-caching" : nil
                }

                results.checkTask(.matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem("thinned")) { task in
                    #expect(throws: Never.self) { try task.checkTaskAction(toolIdentifier: toolIdentifier(configuration.actool)) }
                    task.checkEnvironment(["IBToolNeverDeque": configuration.actool ? "1" : nil])
                }
                results.checkTask(.matchRuleType("CompileStoryboard")) { task in
                    #expect(throws: Never.self) { try task.checkTaskAction(toolIdentifier: toolIdentifier(configuration.ibtool)) }
                    task.checkEnvironment(["IBToolNeverDeque": configuration.ibtool ? "1" : nil])
                }
                results.checkTask(.matchRuleType("RealityAssetsCompile")) { task in
                    #expect(throws: Never.self) { try task.checkTaskAction(toolIdentifier: toolIdentifier(configuration.realitytool)) }
                }
            }
        }
    }
}
