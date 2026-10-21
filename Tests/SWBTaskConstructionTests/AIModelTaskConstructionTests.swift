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
        try await checkModelCompileCommandLineStrings(
            options: .init(
                modelName: "MyModel",
                runDestination: .macOS,
                deploymentTarget: "27.0"
            ),
            expectedCommandLineArguments: [
                "aimodelc",
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
            ]
        )
    }

    // MARK: - Helpers

    /// Helper method that uses a test project and build configuration, and yields only the
    /// sequence of command line arguments generated for the `AIModelCompile` task.
    /// - Parameters:
    ///   - compilerOptions: Collection of parameters affecting the relevant task.
    ///   - expectedCommandLineArguments: Matched against the generated command.
    func checkModelCompileCommandLineStrings(
        options compilerOptions: ModelCompilerTestOptions,
        expectedCommandLineArguments: [StringPattern]
    ) async throws {
        try await withTemporaryDirectory { tmpDir in

            let core = try await getCore()

            let deploymentTargetKey = try #require(
                compilerOptions.runDestination.buildVersionPlatform(core)?.deploymentTargetSettingName(infoLookup: core)
            )

            let buildSettings = try await [

                // Options specific to the AI Model compiler.
                deploymentTargetKey: compilerOptions.deploymentTarget,

                // Options required by the swift compiler.
                "SWIFT_EXEC": swiftCompilerPath.str,
                "SWIFT_VERSION": swiftVersion,

                // Miscellaneous options.
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.apple.ai-model-project",
                "GENERATE_INFOPLIST_FILE": "YES",
            ]

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

            await tester.checkBuild(
                BuildParameters(configuration: "Debug"),
                runDestination: compilerOptions.runDestination
            ) { results in

                results.checkTask(.matchRuleType("AIModelCompile")) { task in
                    task.checkCommandLineMatches(expectedCommandLineArguments)
                }
            }
        }
    }

    /// These options allow asset testing configuration parameters to be passed through a few
    /// functional layers without exploding the parameter count.
    struct ModelCompilerTestOptions {

        /// Name of the model to be compiled.
        var modelName: String

        /// Where we want this asset to run.
        var runDestination: SWBCore.RunDestinationInfo

        /// Something like "27.0".
        var deploymentTarget: String
    }
}

