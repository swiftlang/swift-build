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
import SWBTestSupport
import SWBUtil
import struct SWBProtocol.BuildConfigurationFilter

@Suite
fileprivate struct BuildConfigurationFilteringSwiftPackageCopyFilesTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func filteredPackageFrameworkExcludedFromAutoEmbed() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath

        let appProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources",
                children: [
                    TestFile("AppSource.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["AppSource.m"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("PackageProduct::PkgProduct")),
                        ]),
                    ],
                    dependencies: [
                        TestTargetDependency("PackageProduct::PkgProduct"),
                    ]
                ),
            ]
        )

        let pkgProject = TestPackageProject(
            "Package",
            groupTree: TestGroup(
                "PackageSources",
                children: [
                    TestFile("PkgFwkASource.m"),
                    TestFile("PkgFwkBSource.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                ]),
            ],
            targets: [
                // PkgFwkB is filtered to Release inside the package product's frameworks
                // phase. PkgFwkA is unfiltered. Under Debug, only PkgFwkA should be
                // auto-embedded into the consuming app.
                TestPackageProductTarget(
                    "PackageProduct::PkgProduct",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("PkgFwkA")),
                        TestBuildFile(.target("PkgFwkB"), buildConfigurationFilters: BuildConfigurationFilter.releaseFilters),
                    ]),
                    dependencies: ["PkgFwkA", "PkgFwkB"]
                ),
                TestStandardTarget(
                    "PkgFwkA",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["PkgFwkASource.m"]),
                    ]
                ),
                TestStandardTarget(
                    "PkgFwkB",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["PkgFwkBSource.m"]),
                    ]
                ),
            ]
        )

        let testWorkspace = TestWorkspace("Test", projects: [appProject, pkgProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(BuildParameters(configuration: "Debug"), runDestination: .macOS) { results in
            // The unfiltered package framework should be auto-embedded into the app.
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleItemPattern(.suffix("AppTarget.app/Contents/Frameworks/PkgFwkA.framework"))) { _ in }

            // The release-only package framework must not be auto-embedded under Debug.
            results.checkNoTask(.matchTargetName("AppTarget"), .matchRuleItemPattern(.suffix("AppTarget.app/Contents/Frameworks/PkgFwkB.framework")))
        }
    }
}
