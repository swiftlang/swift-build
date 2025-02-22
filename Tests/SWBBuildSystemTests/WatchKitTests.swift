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
import SWBBuildSystem
import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import Testing

@Suite
fileprivate struct WatchKitTests: CoreBasedTests {
    @Test(.requireSDKs(.watchOS), arguments: [RunDestinationInfo.anywatchOSDevice, RunDestinationInfo.anywatchOSSimulator], ["6.0", "5.3"])
    func WKExtensionMainLinking(runDestination: RunDestinationInfo, deploymentTarget: String) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [
                            TestFile("File.m"),
                        ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGNING_ALLOWED": "NO",
                                "CODE_SIGN_IDENTITY": "",
                                "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": "5.0",
                                "SDKROOT": runDestination.sdk,
                                "WATCHOS_DEPLOYMENT_TARGET": deploymentTarget,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "WKExt", type: .watchKitExtension,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["File.m"]),
                                ])])])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Create the input files.
            let objcFile = testWorkspace.sourceRoot.join("aProject/File.m")
            try await tester.fs.writeFileContents(objcFile) { stream in }

            try await tester.checkBuild(runDestination: runDestination, persistent: true) { results in
                results.checkWarning(.and(.contains("libCrashReporterClient.a"), .contains("was built for newer watchOS")), failIfNotFound: false)
                results.checkWarning(.and(.contains("libCrashReporterClient.a"), .contains("was built for newer watchOS")), failIfNotFound: false)
                results.checkNoDiagnostics()

                let tasks = results.checkTasks(.matchTargetName("WKExt"), .matchRuleType("Ld")) { $0 }
                for task in tasks {
                    let deploymentTargetHasCorrectedMain = try Version(deploymentTarget) >= Version(6)
                    let codec = UNIXShellCommandCodec(encodingStrategy: .backslashes, encodingBehavior: .fullCommandLine)
                    let hasWKExtensionMainLegacyFlag = task.commandLineAsStrings.contains("-lWKExtensionMainLegacy")
                    let archUsesLegacyMainShim: Bool
                    let arch = try #require(task.ruleInfo[safe: 3])
                    switch arch {
                    case "armv7k" where !deploymentTargetHasCorrectedMain,
                        "arm64_32" where !deploymentTargetHasCorrectedMain:
                        archUsesLegacyMainShim = true
                        #expect(hasWKExtensionMainLegacyFlag, "Missing legacy main shim for \(arch) architecture in command line: \(codec.encode(Array(task.commandLineAsStrings)))")
                    case "armv7k", "arm64_32",
                        "arm64", "arm64e", "x86_64":
                        archUsesLegacyMainShim = false
                        #expect(!hasWKExtensionMainLegacyFlag, "Unexpected legacy main shim for \(arch) architecture in command line: \(codec.encode(Array(task.commandLineAsStrings)))")
                    default:
                        Issue.record("Unexpected watchOS architecture \(arch)")
                        continue
                    }

                    let machoPath = task.commandLine[task.commandLine.count - 1].asString
                    let output = try await InstalledXcode.currentlySelected().xcrun(["nm", machoPath])
                    #expect(!output.contains("_main"))
                    if !archUsesLegacyMainShim {
                        #expect(output.contains("U _WKExtensionMain"), "U _WKExtensionMain missing when deploying to \(deploymentTarget)")
                        #expect(!output.contains("T _WKExtensionMain"), "T _WKExtensionMain incorrectly present when deploying to \(deploymentTarget)")
                    } else {
                        #expect(output.contains("T _WKExtensionMain"), "T _WKExtensionMain missing when deploying to \(deploymentTarget)")
                        #expect(!output.contains("U _WKExtensionMain"), "U _WKExtensionMain incorrectly present when deploying to \(deploymentTarget)")
                    }
                }
            }
        }
    }

    struct WatchBackDeploymentArtifactsParameters {
        let runDestination: RunDestinationInfo
        let architectures: Set<String>
        let binaryPath: String

        static func parameters() -> [Self] {
            var parameters: [Self] = []
            for path in ["Library/Application Support/WatchKit/WK", "usr/lib/libWKExtensionMainLegacy.a"] {
                parameters.append(.init(runDestination: .watchOS, architectures: Set(["arm64_32", "arm64", "arm64e", "armv7k"]), binaryPath: path))
                parameters.append(.init(runDestination: .watchOSSimulator, architectures: Set(["arm64", "x86_64"]), binaryPath: path))
            }
            return parameters
        }
    }

    @Test(.requireSDKs(.watchOS), arguments: WatchBackDeploymentArtifactsParameters.parameters())
    func watchBackDeploymentArtifacts(parameters: WatchBackDeploymentArtifactsParameters) async throws {
        let sdkPath = try await getCore().loadSDK(parameters.runDestination).path
        let macho = try MachO(data: localFS.read(sdkPath.join(parameters.binaryPath)))

        // Check expected architectures
        try XCTAssertSuperset(try Set(macho.slices().map { $0.arch }), parameters.architectures)

        // Check expected deployment target
        for slice in try macho.slices() {
            let buildVersions = try Set(slice.buildVersions().map { $0.minOSVersion })
            switch slice.arch {
            case "armv7k", "arm64_32", "x86_64":
                #expect(buildVersions == [Version(2)])
            case "arm64" where sdkPath.str.contains("WatchSimulator"):
                #expect(buildVersions == [Version(7)])
            case "arm64", "arm64e":
                #expect(buildVersions == [Version(9)])
            case "i386":
                break
            default:
                Issue.record("Unexpected architecture \(slice.arch)")
            }
        }
    }
}
