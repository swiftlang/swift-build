//
//  ProductTypesTests.swift
//  SWBCoreTests
//
//  Copyright © 2024 Apple Inc. All rights reserved.
//

import Testing

@_spi(Testing) import SWBCore
import SWBTestSupport
import SWBUtil
import SWBProtocol

@Suite
fileprivate struct ProductTypesTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func testDeepFramework_FrameworksSymlink() async throws {
        let core = try await getCore()
        let testWorkspace = TestWorkspace("Workspace",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup("SomeFiles", children: [
                        TestFile("aFramework.m"),
                        TestFile("embeddedFramework.m"),
                    ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ])
                    ],
                    targets: [
                        TestStandardTarget(
                            "aFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Release"),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["aFramework.m"]),
                                TestCopyFilesBuildPhase([
                                    "embeddedFramework.framework",
                                ], destinationSubfolder: .frameworks),
                                TestFrameworksBuildPhase([
                                    "embeddedFramework.framework",
                                ]),
                            ],
                            dependencies: [
                                "embeddedFramework",
                            ]
                        ),
                        TestStandardTarget(
                            "embeddedFramework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Release"),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["embeddedFramework.m"]),
                                TestFrameworksBuildPhase(),
                            ]
                        )
                    ]
                ),
            ]
        )

        let fs = PseudoFS()

        let tester = try TaskConstructionTester(core, testWorkspace)
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS, fs: fs) { results in
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "WriteAuxiliaryFile", "Gate", "RegisterExecutionPolicyException", "SetOwnerAndGroup", "SetMode", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "ProcessInfoPlist"])

            results.checkTarget("aFramework") { target in
                results.checkTaskExists(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/aFramework.framework/Versions/A/Frameworks"]))
                results.checkTaskExists(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/aFramework.framework/Frameworks", "Versions/Current/Frameworks"]))

                // We don't care about the details of the remaining MkDir and SymLink tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir")) { tasks in
                    #expect(tasks.count == 4)
                }
                results.checkTasks(.matchTarget(target), .matchRuleType("SymLink")) { tasks in
                    #expect(tasks.count == 5)
                }

                results.checkTaskExists(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/aFramework.framework/Versions/A/Frameworks/embeddedFramework.framework", "/tmp/Workspace/aProject/build/Release/embeddedFramework.framework"]))

                results.checkTaskExists(.matchTarget(target), .matchRuleType("GenerateTAPI"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CompileC"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Strip"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CodeSign"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Touch"))

                results.checkNoTask(.matchTarget(target))
            }

            results.checkTarget("embeddedFramework") { target in
                results.checkNoTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/embeddedFramework.framework/Versions/A/Frameworks"]))
                results.checkNoTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/embeddedFramework.framework/Frameworks", "Versions/Current/Frameworks"]))

                // We don't care about the details of the remaining MkDir and SymLink tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir")) { tasks in
                    #expect(tasks.count == 4)
                }
                results.checkTasks(.matchTarget(target), .matchRuleType("SymLink")) { tasks in
                    #expect(tasks.count == 5)
                }

                results.checkTaskExists(.matchTarget(target), .matchRuleType("GenerateTAPI"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CompileC"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Strip"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CodeSign"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Touch"))

                results.checkNoTask(.matchTarget(target))
            }

            #expect(results.otherTargets.isEmpty)

            results.checkNoTask()
        }
    }
}
