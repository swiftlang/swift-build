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
import struct SWBProtocol.PlatformFilter
import SWBUtil

/// Verifies how `BuildFileFilteringContext.filterState` evaluates a build file that carries
/// both platform and build configuration filters, including which exclusion reason wins when
/// both filters mismatch.
@Suite
fileprivate struct BuildFileFilteringInteractionTests: CoreBasedTests {
    private enum Expected {
        case included
        case excludedByPlatform
        case excludedByBuildConfiguration
    }

    /// Builds a minimal one-target/one-source workspace where the source file carries both filters,
    /// then asserts the expected outcome under the active context (macOS / Debug).
    private func testInteraction(
        platformFilters: Set<PlatformFilter>,
        buildConfigurationFilters: Set<BuildConfigurationFilter>,
        expected: Expected,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let core: Core
        do {
            core = try await getCore()
        } catch {
            Issue.record("\(error)")
            return
        }

        let runDestination: RunDestinationInfo = .macOS
        let buildConfiguration = "Debug"

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Main.m"),
                    TestFile("Filtered.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": runDestination.sdk,
                    "SDK_VARIANT": runDestination.sdkVariant ?? "",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Main.m",
                            TestBuildFile("Filtered.m", platformFilters: platformFilters, buildConfigurationFilters: buildConfigurationFilters),
                        ]),
                    ]
                ),
            ]
        )
        let testWorkspace = TestWorkspace("Test", projects: [testProject])

        try await TaskConstructionTester(core, testWorkspace).checkBuild(BuildParameters(configuration: buildConfiguration), runDestination: runDestination, userPreferences: UserPreferences.defaultForTesting.with(enableDebugActivityLogs: true)) { results in
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "CreateUniversalBinary", "Gate", "GenerateDSYMFile", "Ld", "MkDir", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "RegisterWithLaunchServices", "SymLink", "Touch", "WriteAuxiliaryFile", "Validate"])

            // The unfiltered source file must always be compiled.
            results.checkTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("Main.m")) { tasks in
                #expect(tasks.count != 0)
            }

            switch expected {
            case .included:
                results.checkTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("Filtered.m")) { tasks in
                    #expect(tasks.count != 0, "Expected source file to be compiled but it was excluded")
                }
            case .excludedByPlatform:
                results.checkNoTask(.matchRuleType("CompileC"), .matchRuleItemBasename("Filtered.m"))
                let platformFiltersString = platformFilters.sorted().map { $0.platform + ($0.environment.nilIfEmpty.map { "-\($0)" } ?? "") }.joined(separator: ", ").nilIfEmpty ?? "<none>"
                results.checkNote("Skipping '/tmp/Test/aProject/Filtered.m' because its platform filter (\(platformFiltersString)) does not match the platform filter of the current context (\(runDestination.platformFilterString)). (in target 'AppTarget' from project 'aProject')")
            case .excludedByBuildConfiguration:
                results.checkNoTask(.matchRuleType("CompileC"), .matchRuleItemBasename("Filtered.m"))
                let buildConfigurationFiltersString = buildConfigurationFilters.sorted().map(\.buildConfiguration).joined(separator: ", ").nilIfEmpty ?? "<none>"
                results.checkNote("Skipping '/tmp/Test/aProject/Filtered.m' because its build configuration filter (\(buildConfigurationFiltersString)) does not match the build configuration filter of the current context (\(buildConfiguration)). (in target 'AppTarget' from project 'aProject')")
            }

            results.checkNoTask(sourceLocation: sourceLocation)
            results.checkNoDiagnostics()
        }
    }

    /// Both filters match the current context. The file is included.
    @Test(.requireSDKs(.macOS))
    func bothFiltersMatch() async throws {
        try await testInteraction(
            platformFilters: PlatformFilter.macOSFilters,
            buildConfigurationFilters: BuildConfigurationFilter.debugFilters,
            expected: .included
        )
    }

    /// Only the platform filter mismatches. The file is excluded with a platform-filter note.
    @Test(.requireSDKs(.macOS))
    func onlyPlatformFilterMismatches() async throws {
        try await testInteraction(
            platformFilters: PlatformFilter.iOSFilters,
            buildConfigurationFilters: BuildConfigurationFilter.debugFilters,
            expected: .excludedByPlatform
        )
    }

    /// Only the build configuration filter mismatches. The file is excluded with a build-configuration-filter note.
    @Test(.requireSDKs(.macOS))
    func onlyBuildConfigurationFilterMismatches() async throws {
        try await testInteraction(
            platformFilters: PlatformFilter.macOSFilters,
            buildConfigurationFilters: BuildConfigurationFilter.releaseFilters,
            expected: .excludedByBuildConfiguration
        )
    }

    /// Both filters mismatch. The implementation evaluates platform first, so the platform-filter reason wins.
    @Test(.requireSDKs(.macOS))
    func bothFiltersMismatch_platformPrecedence() async throws {
        try await testInteraction(
            platformFilters: PlatformFilter.iOSFilters,
            buildConfigurationFilters: BuildConfigurationFilter.releaseFilters,
            expected: .excludedByPlatform
        )
    }
}
