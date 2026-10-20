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
import SwiftBuild
import SWBProtocol
import SwiftBuildTestSupport
import SWBTestSupport
import SWBUtil

@Suite(.requireHostOS(.macOS))
fileprivate struct DependencyClosureTests: CoreBasedTests {
    @Test
    func computeDependencyClosureBasic() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let f1Target = TestStandardTarget(
                    "F1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let f2Target = TestStandardTarget(
                    "F2",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F1")]
                )

                let f3Target = TestStandardTarget(
                    "F3",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let appTarget = TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F2"), .init("F3")]
                )

                try await testSession.session.sendPIF(.init(TestWorkspace("Test", sourceRoot: tmpDirPath, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test", children: [
                            TestFile("TestFile1.c"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        targets: [
                            f1Target,
                            f2Target,
                            f3Target,
                            appTarget
                        ]
                    )
                ]).toObjects().propertyListItem))

                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [f1Target.guid, f2Target.guid, f3Target.guid, appTarget.guid])
                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [f2Target.guid], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [f1Target.guid, f2Target.guid])
                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [f3Target.guid], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [f3Target.guid])

                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f2Target.guid), SWBTargetGUID(rawValue: f3Target.guid)],
                         SWBTargetGUID(rawValue: f3Target.guid): [],
                         SWBTargetGUID(rawValue: f2Target.guid): [SWBTargetGUID(rawValue: f1Target.guid)],
                         SWBTargetGUID(rawValue: f1Target.guid): []
                        ])
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: f2Target.guid)], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: f2Target.guid): [SWBTargetGUID(rawValue: f1Target.guid)],
                         SWBTargetGUID(rawValue: f1Target.guid): []])
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: f3Target.guid)], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: f3Target.guid): []])
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func computeDependencyClosureWithPlatformFilters() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let f1Target = TestStandardTarget(
                    "F1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let f2Target = TestStandardTarget(
                    "F2",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F1")]
                )

                let f3Target = TestStandardTarget(
                    "F3",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let appTarget = TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F2", platformFilters: PlatformFilter.macOSFilters), .init("F3", platformFilters: PlatformFilter.iOSFilters)]
                )

                try await testSession.session.sendPIF(.init(TestWorkspace("Test", sourceRoot: tmpDirPath, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test", children: [
                            TestFile("TestFile1.c"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        targets: [
                            f1Target,
                            f2Target,
                            f3Target,
                            appTarget
                        ]
                    )
                ]).toObjects().propertyListItem))

                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyMac), includeImplicitDependencies: true) ==
                        [f1Target.guid, f2Target.guid, appTarget.guid])
                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyiOSDevice), includeImplicitDependencies: true) ==
                        [f3Target.guid, appTarget.guid])

                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyMac), includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f2Target.guid)],
                         SWBTargetGUID(rawValue: f2Target.guid): [SWBTargetGUID(rawValue: f1Target.guid)],
                         SWBTargetGUID(rawValue: f1Target.guid): []])
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: SWBBuildParameters(configuration: "Debug", activeRunDestination: .anyiOSDevice), includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f3Target.guid)],
                         SWBTargetGUID(rawValue: f3Target.guid): []])
            }
        }
    }

    @Test
    func computeDependencyClosureWithImplicitDependencies() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let f1Target = TestStandardTarget(
                    "F1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let f2Target = TestStandardTarget(
                    "F2",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ]),
                        TestFrameworksBuildPhase([.init("F1.framework")])
                    ]
                )

                let f3Target = TestStandardTarget(
                    "F3",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ]
                )

                let appTarget = TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                        ])
                    ],
                    dependencies: [.init("F2"), .init("F3")]
                )

                try await testSession.session.sendPIF(.init(TestWorkspace("Test", sourceRoot: tmpDirPath, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test", children: [
                            TestFile("TestFile1.c"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        targets: [
                            f1Target,
                            f2Target,
                            f3Target,
                            appTarget
                        ]
                    )
                ]).toObjects().propertyListItem))

                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [f1Target.guid, f2Target.guid, f3Target.guid, appTarget.guid])
                #expect(try await testSession.session.computeDependencyClosure(targetGUIDs: [appTarget.guid], buildParameters: SWBBuildParameters(), includeImplicitDependencies: false) ==
                        [f2Target.guid, f3Target.guid, appTarget.guid])

                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f2Target.guid), SWBTargetGUID(rawValue: f3Target.guid)],
                         SWBTargetGUID(rawValue: f3Target.guid): [],
                         SWBTargetGUID(rawValue: f2Target.guid): [SWBTargetGUID(rawValue: f1Target.guid)],
                         SWBTargetGUID(rawValue: f1Target.guid): []
                        ])
                #expect(try await testSession.session.computeDependencyGraph(targetGUIDs: [SWBTargetGUID(rawValue: appTarget.guid)], buildParameters: SWBBuildParameters(), includeImplicitDependencies: false) ==
                        [SWBTargetGUID(rawValue: appTarget.guid): [SWBTargetGUID(rawValue: f2Target.guid), SWBTargetGUID(rawValue: f3Target.guid)],
                         SWBTargetGUID(rawValue: f3Target.guid): [],
                         SWBTargetGUID(rawValue: f2Target.guid): [],
                        ])
            }
        }
    }

    /// Identical requests in flight share a computation, but each must get a reply.
    @Test
    func concurrentDependencyGraphRequests() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                func target(_ name: String, dependencies: [String] = []) -> TestStandardTarget {
                    TestStandardTarget(name, type: .framework, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"])], dependencies: dependencies.map { .init($0) })
                }
                let f1Target = target("F1")
                let f2Target = target("F2", dependencies: ["F1"])
                let appTarget = target("App", dependencies: ["F2"])
                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: temporaryDirectory.path, projects: [
                    TestProject("Test", groupTree: TestGroup("Test"), buildConfigurations: [TestBuildConfiguration("Debug")], targets: [f1Target, f2Target, appTarget])
                ]))

                let f1 = SWBTargetGUID(rawValue: f1Target.guid)
                let f2 = SWBTargetGUID(rawValue: f2Target.guid)
                let app = SWBTargetGUID(rawValue: appTarget.guid)
                try await withThrowingTaskGroup(of: (SWBTargetGUID, [SWBTargetGUID: [SWBTargetGUID]]).self) { group in
                    for root in Array(repeating: app, count: 8) + Array(repeating: f2, count: 8) {
                        group.addTask {
                            (root, try await testSession.session.computeDependencyGraph(targetGUIDs: [root], buildParameters: SWBBuildParameters(), includeImplicitDependencies: true))
                        }
                    }
                    for try await (root, graph) in group {
                        if root == app {
                            #expect(graph == [app: [f2], f2: [f1], f1: []])
                        } else {
                            #expect(graph == [f2: [f1], f1: []])
                        }
                    }
                }
            }
        }
    }
}
