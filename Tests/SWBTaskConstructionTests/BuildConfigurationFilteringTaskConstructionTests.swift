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
import SWBTestSupport
import SWBCore
import struct SWBProtocol.BuildConfigurationFilter
import SWBUtil

@Suite
fileprivate struct BuildConfigurationFilteringTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func buildConfigurationFiltering_Debug() async throws {
        // No filter
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", expectFiltered: false)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", buildConfigurationFilters: BuildConfigurationFilter.debugFilters, expectFiltered: false)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", buildConfigurationFilters: BuildConfigurationFilter.debugAndReleaseFilters, expectFiltered: false)

        // Filter
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", buildConfigurationFilters: BuildConfigurationFilter.releaseFilters, expectFiltered: true)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", buildConfigurationFilters: BuildConfigurationFilter.unknownFilters, expectFiltered: true)
    }

    @Test(.requireSDKs(.macOS))
    func buildConfigurationFiltering_Release() async throws {
        // No filter
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", expectFiltered: false)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", buildConfigurationFilters: BuildConfigurationFilter.releaseFilters, expectFiltered: false)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", buildConfigurationFilters: BuildConfigurationFilter.debugAndReleaseFilters, expectFiltered: false)

        // Filter
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", buildConfigurationFilters: BuildConfigurationFilter.debugFilters, expectFiltered: true)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", buildConfigurationFilters: BuildConfigurationFilter.unknownFilters, expectFiltered: true)
    }

    @Test(.requireSDKs(.macOS))
    func filteredPublicHeaderExcludedFromTAPIFileList() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("FwkFiltered.h"),
                    TestFile("Fwk.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_ENABLE_PROJECT_HEADERS": "YES",
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "SKIP_INSTALL": "NO",
                ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_ENABLE_PROJECT_HEADERS": "YES",
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "SKIP_INSTALL": "NO",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public),
                            TestBuildFile("FwkFiltered.h", headerVisibility: .public, buildConfigurationFilters: BuildConfigurationFilter.releaseFilters),
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()
        try await fs.writePlist(Path("/TEST/Info.plist"), .plDict([:]))

        // The expected TAPI file list under Debug contains only the unfiltered public header.
        // FwkFiltered.h is filtered to Release and must be excluded.
        let expectedHeaders: PropertyListItem = .plArray([
            .plDict([
                "type": .plString("public"),
                "path": .plString("/TEST/build/Debug/Fwk.framework/Headers/Fwk.h")
            ])
        ])

        try await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            // The filtered header must not have a CpHeader task.
            results.checkNoTask(.matchRuleType("CpHeader"), .matchRuleItemBasename("FwkFiltered.h"))

            // The unfiltered header must have a CpHeader task.
            results.checkTask(.matchRuleType("CpHeader"), .matchRuleItemBasename("Fwk.h")) { _ in }

            // The TAPI file list must omit the filtered header.
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Fwk.json")) { _, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["headers"] == expectedHeaders)
            }
        }
    }

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

fileprivate extension BuildConfigurationFilter {
    /// The set of default filters when filtering for both Debug and Release.
    static let debugAndReleaseFilters: Set<BuildConfigurationFilter> = BuildConfigurationFilter.debugFilters.union(BuildConfigurationFilter.releaseFilters)

    /// Set of filters for an unknown build configuration.
    static let unknownFilters: Set<BuildConfigurationFilter> = Set([BuildConfigurationFilter(buildConfiguration: "Unknown")])
}

fileprivate extension CoreBasedTests {
    func testBuildConfigurationFiltering(_ targetType: TestStandardTarget.TargetType = .application, runDestination: RunDestinationInfo, buildConfiguration: String, buildConfigurationFilters: Set<BuildConfigurationFilter> = [], expectFiltered: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let core: Core
        do {
            core = try await getCore()
        } catch {
            Issue.record("\(error)")
            return
        }

        if core.sdkRegistry.lookup(runDestination.sdk) == nil {
            Issue.record("Destination \(runDestination.platformFilterString) with build configuration filters \(buildConfigurationFilters) - skipping because SDK '\(runDestination.sdk)' is not installed")
            return
        }

        let swiftCompilerPath = try await self.swiftCompilerPath
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("AppSource.m"),
                    TestFile("AppFilteredSource.m"),
                    TestFile("FwkSource.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": runDestination.sdk,
                    "SDK_VARIANT": runDestination.sdkVariant ?? "",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                    ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": runDestination.sdk,
                    "SDK_VARIANT": runDestination.sdkVariant ?? "",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: targetType,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AppSource.m",
                            TestBuildFile("AppFilteredSource.m", buildConfigurationFilters: buildConfigurationFilters),
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("FwkTarget"), buildConfigurationFilters: buildConfigurationFilters),
                            TestBuildFile(.target("PackageProduct::PkgTarget"), buildConfigurationFilters: buildConfigurationFilters)
                        ]),
                    ],
                    dependencies: [
                        TestTargetDependency("FwkTarget", buildConfigurationFilters: buildConfigurationFilters),
                        TestTargetDependency("PackageProduct::PkgTarget", buildConfigurationFilters: buildConfigurationFilters)
                    ]
                ),
                TestStandardTarget(
                    "FwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)"
                            ]),
                        TestBuildConfiguration("Release", buildSettings: [
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)"
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "FwkSource.m",
                            ]),
                    ]
                ),
            ]
        )
        let testPackage = TestPackageProject(
            "Package",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("PkgSource.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": runDestination.sdk,
                    "SDK_VARIANT": runDestination.sdkVariant ?? "",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                    ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": runDestination.sdk,
                    "SDK_VARIANT": runDestination.sdkVariant ?? "",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                    ]),
            ],
            targets: [
                TestPackageProductTarget(
                    "PackageProduct::PkgTarget",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("PkgTarget"))
                    ]),
                    dependencies: ["PkgTarget"]
                ),
                TestStandardTarget(
                    "PkgTarget", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase(["PkgSource.swift"])
                    ]
                ),
            ]
        )
        let testWorkspace = TestWorkspace("Test", projects: [testProject, testPackage])

        let filtersString = buildConfigurationFilters.sorted().map(\.buildConfiguration).joined(separator: ", ").nilIfEmpty ?? "<none>"

        try await TaskConstructionTester(core, testWorkspace).checkBuild(BuildParameters(configuration: buildConfiguration), runDestination: runDestination, userPreferences: UserPreferences.defaultForTesting.with(enableDebugActivityLogs: true)) { results in
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "CreateUniversalBinary", "Gate", "GenerateDSYMFile", "Ld", "MkDir", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "RegisterWithLaunchServices", "SymLink", "Touch", "WriteAuxiliaryFile", "Validate"])

            // We should always build this
            results.checkTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("AppSource.m")) { tasks in
                #expect(tasks.count != 0)
            }

            // This build file should potentially be filtered out
            if expectFiltered {
                results.checkNoTask(.matchRuleType("CompileC"), .matchRuleItemBasename("AppFilteredSource.m"))
                results.checkNoTask(.matchRuleType("CompileSwiftSources"))

                results.checkNote("Skipping '/tmp/Test/aProject/AppFilteredSource.m' because its build configuration filter (\(filtersString)) does not match the build configuration filter of the current context (\(buildConfiguration)). (in target 'AppTarget' from project 'aProject')")
            } else {
                results.checkTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("AppFilteredSource.m")) { tasks in
                    #expect(tasks.count != 0, "Expected at least one task for conditionalized Objective-C source file, but the source file was incorrectly filtered out")
                }
                results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { tasks in
                    #expect(tasks.count != 0, "Expected at least one task for conditionalized Swift source file, but the source file was incorrectly filtered out")
                }
            }

            // This target dependency should potentially be filtered out
            if expectFiltered {
                results.checkNoTask(.matchTargetName("FwkTarget"))
                results.checkNoTask(.matchTargetName("PkgTarget"))

                results.checkNote("Skipping '/tmp/Test/aProject/build/\(buildConfiguration)\(runDestination.builtProductsDirSuffix)/FwkTarget.framework' because its build configuration filter (\(filtersString)) does not match the build configuration filter of the current context (\(buildConfiguration)). (in target 'AppTarget' from project 'aProject')")

                results.checkNote("Skipping '/tmp/Test/Package/build/\(buildConfiguration)\(runDestination.builtProductsDirSuffix)/PackageProduct::PkgTarget' because its build configuration filter (\(filtersString)) does not match the build configuration filter of the current context (\(buildConfiguration)). (in target 'AppTarget' from project 'aProject')")
            } else {
                results.checkTasks(.matchTargetName("FwkTarget")) { tasks in
                    #expect(tasks.count != 0, "Expected at least one task for dependent framework target, but the dependent target was incorrectly filtered out")
                }
                results.checkTasks(.matchTargetName("PkgTarget")) { tasks in
                    #expect(tasks.count != 0, "Expected at least one task for dependent package target, but the dependent target was incorrectly filtered out")
                }
            }

            results.checkNoTask(sourceLocation: sourceLocation)

            // There shouldn't be any other diagnostics.
            results.checkNoDiagnostics()
        }
    }
}
