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
import SWBTestSupport

import SWBUtil
import SWBCore
import SWBProtocol
import SWBTaskExecution

/// Test stale file removal characteristics of the build description.
@Suite
fileprivate struct StaleFileRemovalTests: CoreBasedTests {
    enum Sanitizers {
        case address
        case thread
        case undefinedBehavior

        var settingName: String {
            switch self {
            case .address:
                return "ENABLE_ADDRESS_SANITIZER"
            case .thread:
                return "ENABLE_THREAD_SANITIZER"
            case .undefinedBehavior:
                return "ENABLE_UNDEFINED_BEHAVIOR_SANITIZER"
            }
        }

        var shorthand: String {
            switch self {
            case .address:
                return "asan"
            case .thread:
                return "tsan"
            case .undefinedBehavior:
                return "ubsan"
            }
        }
    }

    /// Test the basic characteristics of stale file removal in the build description and manifest.
    @Test(.requireSDKs(.macOS, .iOS, .driverKit))
    func staleFileRemovalBasics() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) in
            try await withAsyncDeferrable { deferrable -> Void in
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath,
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources",
                                children: [
                                    TestFile("main.m"),
                                    TestFile("ClassOne.m"),
                                    TestFile("foo.xcframework"),
                                ]
                            ),
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                    ]
                                ),
                                TestBuildConfiguration(
                                    "Release",
                                    buildSettings: [
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                    ]
                                ),
                            ],
                            targets: [
                                TestStandardTarget(
                                    "Application",
                                    type: .application,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [:]),
                                        TestBuildConfiguration("Release", buildSettings: [:]),
                                    ],
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "main.m",
                                        ]),
                                        TestFrameworksBuildPhase([
                                            "foo.xcframework",
                                        ]),
                                    ],
                                    dependencies: [
                                        "Framework",
                                    ]
                                ),
                                TestStandardTarget(
                                    "Framework",
                                    type: .framework,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [:]),
                                        TestBuildConfiguration("Release", buildSettings: [:]),
                                    ],
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "ClassOne.m",
                                        ]),
                                        TestFrameworksBuildPhase([
                                            "foo.xcframework",
                                        ]),
                                    ]
                                ),
                            ])
                    ])
                let workspace = try await testWorkspace.load(getCore())
                let numTargets = workspace.projects.first?.targets.count ?? 0
                guard numTargets > 0 else {
                    Issue.record("Test workspace has no targets.")
                    return
                }

                let fs = PseudoFS()

                let xcframework = try XCFramework(version: Version(1, 0), libraries: [
                    XCFramework.Library(libraryIdentifier: "x86_64-apple-macos11.0", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
                    XCFramework.Library(libraryIdentifier: "x86_64-apple-ios14.0-maccatalyst", supportedPlatform: "ios", supportedArchitectures: ["x86_64"], platformVariant: "macabi", libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
                    XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos11.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
                    XCFramework.Library(libraryIdentifier: "arm64-apple-iphonesimulator11.0", supportedPlatform: "ios", supportedArchitectures: ["x86_64"], platformVariant: "simulator", libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
                    XCFramework.Library(libraryIdentifier: "x86_64-apple-driverkit19.0", supportedPlatform: "driverkit", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
                ])
                let xcframeworkPath = tmpDirPath.join("aProject").join("foo.xcframework")
                try fs.createDirectory(xcframeworkPath, recursive: true)
                try await fs.writeXCFramework(xcframeworkPath, xcframework, infoLookup: getCore())

                // Use a shared manager.
                let manager = BuildDescriptionManager(fs: fs, buildDescriptionMemoryCacheEvictionPolicy: .never)
                await deferrable.addBlock { await manager.waitForBuildDescriptionSerialization() }

                // Iterate over various elements which contribute to the stale file removal identifier.
                for configuration in ["Debug", "Release"] {
                    for (destination, archs) in [
                        (RunDestinationInfo.macOS, ["x86_64"]),
                        (RunDestinationInfo.macCatalyst, ["x86_64"]),
                        (RunDestinationInfo.driverKit, ["x86_64"]),
                        (RunDestinationInfo.iOS, ["arm64", "arm64e"]),
                        (RunDestinationInfo.iOSSimulator, ["x86_64"]),
                    ] {
                        let sanitizerCombinations: [[Sanitizers]] = [
                            [],
                            [.address],
                            [.thread],
                            [.undefinedBehavior],
                            [.address, .undefinedBehavior],
                            [.thread, .undefinedBehavior],
                            // The compiler doesn't allow combining the address and thread sanitizers in a single build.
                        ]
                        for sanitizers in sanitizerCombinations {
                            var overrides = [
                                "SDKROOT": destination.sdk,
                                "ARCHS": archs.joined(separator: " "),
                            ]
                            if let sdkVariant = destination.sdkVariant {
                                overrides["SDK_VARIANT"] = sdkVariant
                            }
                            for sanitizer in sanitizers {
                                overrides[sanitizer.settingName] = "YES"
                            }
                            let planRequest = try await self.planRequest(for: workspace, configuration: configuration, activeRunDestination: .macOS, overrides: overrides, fs: fs, includingTargets: { _ in true })
                            let delegate = MockTestBuildDescriptionConstructionDelegate()
                            let _ = try await manager.getNewOrCachedBuildDescription(planRequest, clientDelegate: MockTestTaskPlanningClientDelegate(), constructionDelegate: delegate)!

                            guard let manifest = delegate.manifest else {
                                Issue.record("Manifest data was not created.")
                                return
                            }

                            // Go through the manifest to find each stale file removal task.
                            var sfrCommandKeys = [String]()
                            for (commandKey, command) in manifest.commandDefinitions {
                                // Found a command for a target.
                                if commandKey.hasSuffix("-stale-file-removal>") {
                                    sfrCommandKeys.append(commandKey)

                                    // Get its output.  Presently this is the same as the command's key, but it need not be.
                                    let output = command.dictValue?["outputs"]?.stringArrayValue?.first(where: { $0.hasSuffix("-stale-file-removal>") })

                                    guard let sfrOutput = output else {
                                        Issue.record("Couldn't find stale file removal output node for command '\(commandKey)' in manifest.")
                                        continue
                                    }

                                    let isGlobalSfrNode = commandKey.hasPrefix("<workspace-")

                                    if isGlobalSfrNode {
                                        #expect(sfrOutput.contains("-\(configuration)"), "Stale file removal output string doesn't include expected configuration component '-\(configuration)': \(sfrOutput)")
                                    } else {
                                        #expect(sfrOutput.contains("-\(configuration)"), "Stale file removal output string doesn't include expected configuration component '-\(configuration)': \(sfrOutput)")

                                        let platform = destination == .macCatalyst ? "maccatalyst" : destination.platform
                                        #expect(sfrOutput.contains("-\(platform)"), "Stale file removal output string doesn't include expected platform component '-\(destination.platform)': \(sfrOutput)")
                                    }

                                    for sanitizer in sanitizers {
                                        #expect(sfrOutput.contains("-\(sanitizer.shorthand)"), "Stale file removal output string doesn't include expected sanitizer component '-\(sanitizer.shorthand)': \(sfrOutput)")
                                    }
                                    let archsComponent = archs.sorted().map({ "-\($0)" }).joined()
                                    #expect(sfrOutput.contains("\(archsComponent)"), "Stale file removal output string doesn't include expected architectures component '\(archsComponent)': \(sfrOutput)")

                                    // Now go through the commands to find ones which have inputs which match the output we found.
                                    var foundAnyDependingCommands = false
                                    for (commandKey, command) in manifest.commandDefinitions {
                                        if isGlobalSfrNode {
                                            // The global SFR node should only be depended on by the <all> node.
                                            guard commandKey == "<all>" else {
                                                continue
                                            }
                                        } else {
                                            // Skip virtual commands such as <all> and SFR commands (which are also virtual but let's be cautious here).
                                            guard !commandKey.hasPrefix("<"), !commandKey.hasSuffix("-stale-file-removal>") else {
                                                continue
                                            }
                                        }

                                        // Look through the inputs.
                                        for plInput in command.dictValue?["inputs"]?.arrayValue ?? [] {
                                            if let inputStr = plInput.stringValue, inputStr == sfrOutput {
                                                foundAnyDependingCommands = true
                                            }
                                        }
                                        guard !foundAnyDependingCommands else {
                                            break
                                        }
                                    }

                                    // When this fails, it's because we found an SFR task with the given output node (computed in BuildDescriptionBuilder.construct()), but we couldn't fine any concrete tasks with an input which matches it, which possibly means that the identifier computed in TargetOrderTaskProducer.staleFileRemovalNode is wrong.
                                    #expect(foundAnyDependingCommands, "Could not find any commands in the manifest with an input of the stale file removal output node '\(sfrOutput)'.")
                                }
                            }

                            #expect(sfrCommandKeys.count == numTargets + 1)
                        }
                    }
                }
            }
        }
    }
}
