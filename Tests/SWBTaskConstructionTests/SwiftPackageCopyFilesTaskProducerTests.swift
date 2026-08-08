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

import Foundation
import Testing

@_spi(Testing) import SWBCore
import struct SWBProtocol.BuildConfigurationFilter
import struct SWBProtocol.PlatformFilter
@testable import SWBTaskConstruction
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct SwiftPackageCopyFilesTaskProducerTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func packageBinaryXCFrameworkFiltersAreAggregated() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let infoLookup = try await getCore()
            let xcode = try await InstalledXcode.currentlySelected()
            let macOSFrameworkPath = try await xcode.compileFramework(
                path: tmpDirPath.join("macos"),
                platform: .macOS,
                infoLookup: infoLookup,
                archs: ["x86_64"],
                useSwift: true,
                static: false
            )
            let iOSFrameworkPath = try await xcode.compileFramework(
                path: tmpDirPath.join("iphoneos"),
                platform: .iOS,
                infoLookup: infoLookup,
                archs: ["arm64", "arm64e"],
                useSwift: true,
                static: false
            )
            let iOSSimulatorFrameworkPath = try await xcode.compileFramework(
                path: tmpDirPath.join("iphonesimulator"),
                platform: .iOSSimulator,
                infoLookup: infoLookup,
                archs: ["x86_64"],
                useSwift: true,
                static: false
            )

            let outputPath = tmpDirPath.join("sample.xcframework")
            let commandLine = [
                "createXCFramework",
                "-framework", macOSFrameworkPath.str,
                "-framework", iOSFrameworkPath.str,
                "-framework", iOSSimulatorFrameworkPath.str,
                "-output", outputPath.str,
            ]
            let (result, message) = XCFramework.createXCFramework(
                commandLine: commandLine,
                currentWorkingDirectory: tmpDirPath,
                infoLookup: infoLookup
            )
            try #require(result, "unable to build xcframework: \(message)")

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources"),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Configuration1",
                                buildSettings: [
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ]
                            ),
                        ],
                        targets: [
                            TestStandardTarget(
                                "F4",
                                type: .application,
                                buildPhases: [
                                    TestFrameworksBuildPhase([
                                        TestBuildFile(
                                            .target("PackageProduct1")
                                        ),
                                        TestBuildFile(
                                            .target("PackageProduct2")
                                        ),
                                    ]),
                                ],
                                dependencies: [
                                    "PackageProduct1",
                                    "PackageProduct2"
                                ]
                            ),
                        ]
                    ),
                    TestPackageProject(
                        "aPackageProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile(
                                    "sample.xcframework",
                                    path: outputPath.str,
                                    sourceTree: .absolute
                                ),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Configuration1",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ]
                            ),
                        ],
                        targets: [
                            TestPackageProductTarget(
                                "PackageProduct1",
                                frameworksBuildPhase: TestFrameworksBuildPhase([
                                    TestBuildFile(.target("Target1")),
                                ]),
                                dependencies: ["Target1"]
                            ),
                            TestPackageProductTarget(
                                "PackageProduct2",
                                frameworksBuildPhase: TestFrameworksBuildPhase([
                                    TestBuildFile(.target("Target2")),
                                ]),
                                dependencies: ["Target2"]
                            ),
                            TestStandardTarget(
                                "Target1",
                                type: .objectFile,
                                buildPhases: [
                                    TestFrameworksBuildPhase([
                                        TestBuildFile(
                                            "sample.xcframework",
                                            platformFilters: [
                                                PlatformFilter(platform: "macos"),
                                                PlatformFilter(platform: "ios"),
                                                PlatformFilter(
                                                    platform: "ios",
                                                    environment: "simulator"
                                                ),
                                            ],
                                            buildConfigurationFilters: [
                                                BuildConfigurationFilter(
                                                    buildConfiguration: "Configuration1"
                                                ),
                                                BuildConfigurationFilter(
                                                    buildConfiguration: "Configuration2"
                                                ),
                                            ]
                                        ),
                                    ]),
                                ]
                            ),
                            TestStandardTarget(
                                "Target2",
                                type: .objectFile,
                                buildPhases: [
                                    TestFrameworksBuildPhase([
                                        TestBuildFile(
                                            "sample.xcframework",
                                            platformFilters: [
                                                PlatformFilter(platform: "macos"),
                                                PlatformFilter(platform: "tvos"),
                                                PlatformFilter(
                                                    platform: "tvos",
                                                    environment: "simulator"
                                                ),
                                            ],
                                            buildConfigurationFilters: [
                                                BuildConfigurationFilter(
                                                    buildConfiguration: "Configuration1"
                                                ),
                                                BuildConfigurationFilter(
                                                    buildConfiguration: "Configuration3"
                                                ),
                                            ]
                                        ),
                                    ]),
                                ]
                            ),
                        ]
                    ),
                ]
            )

            let tester = try await TaskConstructionTester(
                getCore(),
                testWorkspace
            )

            let request = BuildRequest(
                parameters: BuildParameters(configuration: "Configuration1"),
                buildTargets: [
                    BuildRequest.BuildTargetInfo(
                        parameters: BuildParameters(configuration: "Configuration1"),
                        target: try #require(
                            Array(tester.workspace.allTargets).only {
                                $0.name == "F4"
                            }
                        )
                    ),
                ],
                continueBuildingAfterErrors: false,
                useParallelTargets: true,
                useImplicitDependencies: true,
                useDryRun: false
            )

            try await tester.checkBuild(
                runDestination: .macOS,
                buildRequest: request,
                fs: localFS
            ) { results in
                results.checkNoDiagnostics()

                let productPlan = try #require(
                    results.buildPlan.productPlans.only {
                        $0.forTarget?.target.name == "F4"
                    }
                )

                let context = try #require(
                    productPlan.taskProducerContext as? TargetTaskProducerContext
                )

                let buildFiles = SwiftPackageCopyFilesTaskProducer
                    .buildFilesForPackages(
                        context: context,
                        frameworksBuildPhase: (
                            context.configuredTarget?.target as? StandardTarget
                        )?.frameworksBuildPhase
                    )

                let binaryTargetBuildFile = try #require(buildFiles.only)

                #expect(
                    try context.resolveBuildFileReference(
                        binaryTargetBuildFile
                    ).absolutePath == outputPath
                )

                #expect(
                    binaryTargetBuildFile.platformFilters == [
                        SWBCore.PlatformFilter(platform: "ios"),
                        SWBCore.PlatformFilter(
                            platform: "ios",
                            environment: "simulator"
                        ),
                        SWBCore.PlatformFilter(platform: "macos"),
                        SWBCore.PlatformFilter(platform: "tvos"),
                        SWBCore.PlatformFilter(
                            platform: "tvos",
                            environment: "simulator"
                        ),
                    ]
                )
                #expect(
                    binaryTargetBuildFile.buildConfigurationFilters == [
                        SWBCore.BuildConfigurationFilter(
                            buildConfiguration: "Configuration1"
                        ),
                        SWBCore.BuildConfigurationFilter(
                            buildConfiguration: "Configuration2"
                        ),
                        SWBCore.BuildConfigurationFilter(
                            buildConfiguration: "Configuration3"
                        ),
                    ]
                )
            }
        }
    }
}
