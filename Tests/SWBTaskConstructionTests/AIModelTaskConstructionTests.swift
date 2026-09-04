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

@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

import class SWBMacro.StringMacroDeclaration

@Suite
fileprivate struct AIModelTaskConstructionTests: CoreBasedTests {
    @available(macOS 27.0, *)
    @Test(.requireSDKs(.macOS))
    func aimodelCompilerPackageWithDefaultInferenceMode() async throws {
        try await checkAIModelBuild { tmpDir, results in
            let toolchainDir = try #require(results.core.toolchainRegistry.defaultToolchain?.path)

            results.checkTask(.matchRuleType("AIModelCompile")) { task in
                task.checkSandboxedCommandLine([
                    "package",
                    "\(tmpDir.str)/MyModel.aimodel",
                    "--platform", "macOS",
                    "--min-deployment-version", "27.0",
                    "--output", "\(tmpDir.str)/build/Debug/AI Model App.app/Contents/Resources/MyModel.aimodel",
                    "--toolchain-dir", toolchainDir.str,
                ])

                // The generated profile is written into the target's temp dir, and is an input of the task
                // so that regenerating it forces the task to rerun.
                task.checkInputs(contain: [
                    .pathPattern(.and(.prefix("\(tmpDir.str)/build/AI Model Project.build/Debug/AI Model App.build"), .suffix(".sb"))),
                ])
            }
        }
    }

    @available(macOS 27.0, *)
    @Test(.requireSDKs(.macOS))
    func aimodelCompilerSandboxingCanBeDisabled() async throws {
        try await checkAIModelBuild(disableTaskSandboxing: true) { _, results in
            results.checkTask(.matchRuleType("AIModelCompile")) { task in
                task.checkCommandLineMatches([
                    .suffix("aimodelc"),
                    "package",
                    .suffix("MyModel.aimodel"),
                    "--platform",
                    "macOS",
                    "--min-deployment-version",
                    "27.0",
                    "--output",
                    .suffix("AI Model App.app/Contents/Resources/MyModel.aimodel"),
                    "--toolchain-dir",
                    .suffix("XcodeDefault.xctoolchain"),
                ])
                task.checkCommandLineNoMatch([.equal("/usr/bin/sandbox-exec"), .anySequence])
            }
        }
    }

    // MARK: - Helpers

    /// Plans a build of a single-target app which compiles `MyModel.aimodel`.
    /// - Parameters:
    ///   - runDestination: Where we want this model to run.
    ///   - deploymentTarget: Something like "27.0".
    ///   - disableTaskSandboxing: Sets `DISABLE_TASK_SANDBOXING` in the project's `Debug` configuration.
    ///   - check: Receives the project's source root, and the planning results to assert against.
    func checkAIModelBuild(
        runDestination: SWBCore.RunDestinationInfo = .macOS,
        deploymentTarget: String = "27.0",
        disableTaskSandboxing: Bool = false,
        check: (Path, TaskConstructionTester.PlanningResults) throws -> Void
    ) async throws {
        try await withTemporaryDirectory { tmpDir in

            let core = try await getCore()

            let deploymentTargetKey = try #require(
                runDestination.buildVersionPlatform(core)?.deploymentTargetSettingName(infoLookup: core)
            )

            var buildSettings = try await [

                // Options specific to the AI Model compiler.
                deploymentTargetKey: deploymentTarget,

                // Options required by the swift compiler.
                "SWIFT_EXEC": swiftCompilerPath.str,
                "SWIFT_VERSION": swiftVersion,

                // Miscellaneous options.
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.apple.ai-model-project",
                "GENERATE_INFOPLIST_FILE": "YES",
            ]
            if disableTaskSandboxing {
                buildSettings["DISABLE_TASK_SANDBOXING"] = "YES"
            }

            let testProject = TestProject(
                "AI Model Project",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("Main.swift"),
                        TestFile("MyModel.aimodel"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: buildSettings
                    )
                ],
                targets: [
                    TestStandardTarget(
                        "AI Model App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "Main.swift",
                                "MyModel.aimodel"
                            ])
                        ]
                    )
                ]
            )

            let tester = try TaskConstructionTester(core, testProject)

            try await tester.checkBuild(
                BuildParameters(configuration: "Debug"),
                runDestination: runDestination
            ) { results in
                try check(tmpDir, results)
            }
        }
    }
}
