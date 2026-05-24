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

package import Testing

import SWBUtil
package import SWBCore
package import struct SWBProtocol.BuildConfigurationFilter

extension CoreBasedTests {
    package func testBuildConfigurationFiltering(_ targetType: TestStandardTarget.TargetType = .application, runDestination: RunDestinationInfo, buildConfiguration: String, buildConfigurationFilters: Set<SWBTestSupport.BuildConfigurationFilter> = [], expectFiltered: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
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

extension BuildConfigurationFilter {
    /// The set of default filters when filtering for **Debug**.
    package static let debugFilters: Set<BuildConfigurationFilter> = [
        BuildConfigurationFilter(buildConfiguration: "Debug")
    ]

    /// The set of default filters when filtering for **Release**.
    package static let releaseFilters: Set<BuildConfigurationFilter> = [
        BuildConfigurationFilter(buildConfiguration: "Release")
    ]
}
