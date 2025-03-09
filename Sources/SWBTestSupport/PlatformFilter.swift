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

package import Testing

import SWBUtil
import SWBCore
package import SWBProtocol

extension CoreBasedTests {
    package func testPlatformFiltering(_ targetType: TestStandardTarget.TargetType = .application, runDestination: RunDestinationInfo, platformFilters: Set<SWBTestSupport.PlatformFilter> = [], expectFiltered: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let core: Core
        do {
            core = try await getCore()
        } catch {
            Issue.record("\(error)")
            return
        }

        if core.sdkRegistry.lookup(runDestination.sdk) == nil {
            Issue.record("Destination \(runDestination.platformFilterString) with filters \(platformFilters) - skipping because SDK '\(runDestination.sdk)' is not installed")
            return
        }

        //try await XCTContext.runActivity(named: "Destination \(runDestination.platformFilterString) with filters \(platformFilters)") { _ in
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
                    TestBuildConfiguration( "Debug", buildSettings: [
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
                                TestBuildFile("AppFilteredSource.m", platformFilters: platformFilters),
                            ]),
                            TestFrameworksBuildPhase([
                                TestBuildFile(.target("FwkTarget"), platformFilters: platformFilters),
                                TestBuildFile(.target("PackageProduct::PkgTarget"), platformFilters: platformFilters)
                            ]),
                        ],
                        dependencies: [
                            TestTargetDependency("FwkTarget", platformFilters: platformFilters),
                            TestTargetDependency("PackageProduct::PkgTarget", platformFilters: platformFilters)
                        ]
                    ),
                    TestStandardTarget(
                        "FwkTarget",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
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
                    TestBuildConfiguration( "Debug", buildSettings: [
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

            let filtersString = platformFilters.sorted().map { $0.platform + ($0.environment.nilIfEmpty.map { "-\($0)"} ?? "") }.joined(separator: ", ") // Just for test logging.

            try await TaskConstructionTester(core, testWorkspace).checkBuild(BuildParameters(configuration: "Debug"), runDestination: runDestination, userPreferences: UserPreferences.defaultForTesting.with(enableDebugActivityLogs: true)) { results in
                results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "CreateUniversalBinary", "Gate", "GenerateDSYMFile", "Ld", "MkDir", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "RegisterWithLaunchServices", "SymLink", "Touch", "WriteAuxiliaryFile", "Validate"])

                // We should always build this
                results.checkTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("AppSource.m")) { tasks in
                    #expect(tasks.count != 0)
                }

                // This build file should potentially be filtered out
                if expectFiltered {
                    results.checkNoTask(.matchRuleType("CompileC"), .matchRuleItemBasename("AppFilteredSource.m"))
                    results.checkNoTask(.matchRuleType("CompileSwiftSources"))

                    results.checkNote("Skipping '/tmp/Test/aProject/AppFilteredSource.m' because its platform filter (\(filtersString)) does not match the platform filter of the current context (\(runDestination.platformFilterString)). (in target 'AppTarget' from project 'aProject')")
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

                    results.checkNote("Skipping '/tmp/Test/aProject/build/Debug\(runDestination.builtProductsDirSuffix)/FwkTarget.framework' because its platform filter (\(filtersString)) does not match the platform filter of the current context (\(runDestination.platformFilterString)). (in target 'AppTarget' from project 'aProject')")

                    results.checkNote("Skipping '/tmp/Test/Package/build/Debug\(runDestination.builtProductsDirSuffix)/PackageProduct::PkgTarget' because its platform filter (\(filtersString)) does not match the platform filter of the current context (\(runDestination.platformFilterString)). (in target 'AppTarget' from project 'aProject')")
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
        //}
    }
}

extension PlatformFilter {
    /// The set of default filters when filtering for **Mac Catalyst**.
    package static let macCatalystFilters: Set<PlatformFilter> = [
        PlatformFilter(platform: "ios", environment: "macabi")
    ]

    /// The set of default filters when filtering for **macOS**.
    package static let macOSFilters: Set<PlatformFilter> = [
        PlatformFilter(platform: "macos")
    ]

    /// The set of default filters when filtering for **iOS**; this (implicitly) iincludes both device and simulator.
    package static let iOSFilters: Set<PlatformFilter> = [
        PlatformFilter(platform: "ios")
    ]

    /// The set of default filters when filtering for **tvOS**; this (implicitly) includes both device and simulator.
    package static let tvOSFilters: Set<PlatformFilter> = [
        PlatformFilter(platform: "tvos")
    ]

    /// The set of default filters when filtering for **watchOS**; (implicitly) this includes both device and simulator.
    package static let watchOSFilters: Set<PlatformFilter> = [
        PlatformFilter(platform: "watchos")
    ]

    /// The set of default filters when filtering for ** DriverKit**.
    package static let driverKitFilters: Set<PlatformFilter> = [
        PlatformFilter(platform: "driverkit")
    ]
}

extension PlatformFilter {
    /// The set of default filters when filtering for **Linux**.
    package static let linuxFilters: Set<PlatformFilter> = [
        PlatformFilter(platform: "linux", environment: "gnu")
    ]
}
