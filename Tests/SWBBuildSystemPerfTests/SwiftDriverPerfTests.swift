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

import Testing
import SWBBuildSystem

import SWBCore
import SWBProtocol
import SWBUtil
import SWBTestSupport

@Suite(.performance)
fileprivate struct SwiftDriverPerfTests: CoreBasedTests, PerfTests {
    struct Config {
        // Reduce the number of files in CI to reduce the likelihood of hitting timeouts.
        static let numSwiftFiles = getEnvironmentVariable("CI") != nil ? 3 : 300
        static let numTargets = 5
        static let iterations = 2
    }

    // MARK: - Performance implication when building with integrated Swift driver

    private func configureBuild(clean: Bool) async throws -> ((BuildOperationTester.BuildResults) -> Void) async -> Void {
        let tmpDir = try NamedTemporaryDirectory()
        let targets = (0..<Config.numTargets).map { targetNum -> (any TestTarget) in
            TestStandardTarget(
                "Target\(targetNum)", type: .framework,
                buildPhases: [
                    TestSourcesBuildPhase((0..<Config.numSwiftFiles).map({ TestBuildFile("Target-\(targetNum)-File-\($0).swift") })),
                ],
                provisioningSourceData: [
                    SWBProtocol.ProvisioningSourceData(
                        configurationName: "Debug",
                        provisioningStyle: .manual,
                        bundleIdentifierFromInfoPlist: "$(PRODUCT_BUNDLE_IDENTIFIER)")])
        }

        let swiftVersion = try await self.swiftVersion
        let testProject = TestProject(
            "aProject",
            defaultConfigurationName: "Debug",
            groupTree: TestGroup("Root", children: (0..<Config.numTargets).flatMap { targetNum in
                (0..<Config.numSwiftFiles).map { TestFile("Target-\(targetNum)-File-\($0).swift") }
            }),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_VERSION": swiftVersion,

                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",

                    "DSTROOT": tmpDir.path.join("dstroot").str,
                ]
            )],
            targets: targets
        )
        let testWorkspace = TestWorkspace("aWorkspace",
                                          sourceRoot: tmpDir.path.join("Test"),
                                          projects: [testProject])
        let SRCROOT = testWorkspace.sourceRoot.join("aProject")

        // Write the source files.
        for targetNum in 0..<Config.numTargets {
            for fileNum in 0..<Config.numSwiftFiles {
                try await localFS.writeFileContents(SRCROOT.join("Target-\(targetNum)-File-\(fileNum).swift")) { contents in
                    contents <<< "func foobar\(targetNum)\(fileNum)() {}\n"
                }
            }
        }

        let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        return { resultsCheck in

            _ = tmpDir // hold a strong reference here :)

            for _ in 0..<Config.iterations {

                do {
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, serial: true) { results in
                        resultsCheck(results)
                    }

                    if clean {
                        try await tester.checkBuild(runDestination: .macOS, buildCommand: BuildCommand.cleanBuildFolder(style: .regular), body: { _ in })
                    }
                } catch {
                    Issue.record("Can't test build: \(error)")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftDriverBuildPerformance() async throws {
        let build = try await configureBuild(clean: true)

        await measure {
            await build { results in
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuildPerformance() async throws {
        let swiftVersion = try await self.swiftVersion
        try await withTemporaryDirectory { tmpDir in
            let filenames = (0..<(getEnvironmentVariable("CI") != nil ? 100 : 1000)).map { "File-\($0).swift" }
            let testWorkspace = TestWorkspace("aWorkspace",
                                              sourceRoot: tmpDir.path.join("Test"),
                                              projects: [TestProject(
                                                "aProject",
                                                defaultConfigurationName: "Debug",
                                                groupTree: TestGroup("Root", children: filenames.map { TestFile($0) }),
                                                buildConfigurations: [TestBuildConfiguration(
                                                    "Debug",
                                                    buildSettings: [
                                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                                        "SWIFT_VERSION": swiftVersion,
                                                        "DSTROOT": tmpDir.path.join("dstroot").str,
                                                    ]
                                                )],
                                                targets: [
                                                    TestStandardTarget(
                                                        "Framework", type: .framework,
                                                        buildPhases: [
                                                            TestSourcesBuildPhase(filenames.map { TestBuildFile($0) }),
                                                        ])
                                                ]
                                              )])
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            for name in filenames {
                try await localFS.writeFileContents(SRCROOT.join(name)) { contents in
                    contents <<< """
                    class \(name.mangledToC99ExtendedIdentifier()) {
                        let x = 1
                        func bar() {}
                    }
                    """
                }
            }

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
            }
            try await tester.checkNullBuild(runDestination: .macOS)
            try await measure {
                try localFS.touch(SRCROOT.join(filenames.randomElement()))
                try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                    results.checkNoDiagnostics()
                }
            }
        }
    }
}

