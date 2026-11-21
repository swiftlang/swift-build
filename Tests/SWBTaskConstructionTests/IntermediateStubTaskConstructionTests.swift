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

import SWBCore
import SWBTestSupport
import SWBUtil
import SWBTaskConstruction
import SWBProtocol

@Suite
fileprivate struct IntermediateStubTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func intermediateStubGeneration() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                ])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])
                    ]),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                task.checkInputs([.path("/tmp/Test/aProject/build/Debug/Fwk.framework/Versions/A/Fwk"),
                                  .namePattern(.suffix("-ProductPostprocessingTaskProducer")),
                                  .namePattern(.suffix("-entry"))])
                task.checkOutputs([.path("/tmp/Test/aProject/build/EagerLinkingTBDs/Debug/Fwk.framework/Versions/A/Fwk.tbd"),
                                   .name("Eager Linking TBD Production /tmp/Test/aProject/build/EagerLinkingTBDs/Debug/Fwk.framework/Versions/A/Fwk.tbd")])
                task.checkCommandLine([tapiToolPath.str, "stubify", "-isysroot", core.loadSDK(.macOS).path.str, "-F/tmp/Test/aProject/build/Debug", "-L/tmp/Test/aProject/build/Debug", "/tmp/Test/aProject/build/Debug/Fwk.framework/Versions/A/Fwk", "-o", "/tmp/Test/aProject/build/EagerLinkingTBDs/Debug/Fwk.framework/Versions/A/Fwk.tbd"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func targetSupportingInstallAPIGeneratesNoStubs() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "SUPPORTS_TEXT_BASED_API": "YES",
                ])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTask(.matchRule(["GenerateTAPI", "/tmp/Test/aProject/build/Debug/Fwk.framework/Versions/A/Fwk.tbd", "normal", results.runDestinationTargetArchitecture])) { _ in }
            results.checkNoTask(.matchRuleType("GenerateTAPI"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func targetWithUnsupportedMachOTypeGeneratesNoStubs() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "LIBTOOL": libtoolPath.str,
                ])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoTask(.matchRuleType("GenerateTAPI"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func targetInstallingStubsGeneratesNoIntermediateStubs() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "GENERATE_TEXT_BASED_STUBS": "YES",
                ])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTask(.matchRule(["GenerateTAPI", "/tmp/Test/aProject/build/Debug/Fwk.framework/Versions/A/Fwk.tbd"])) { _ in }
            results.checkNoTask(.matchRuleType("GenerateTAPI"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func targetWithReexportsGeneratesNoIntermediateStubs() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                ])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: ["REEXPORTED_FRAMEWORK_NAMES": "Foundation"]), runDestination: .macOS) { results in
            results.checkNoTask(.matchRuleType("GenerateTAPI"))
        }

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: ["OTHER_LDFLAGS": "-reexport-lfoo"]), runDestination: .macOS) { results in
            results.checkNoTask(.matchRuleType("GenerateTAPI"))
        }
    }

    /// Builds the given targets of a project and returns the intermediate stub outputs.
    private func intermediateStubOutputs(building targetNames: [String], tester: TaskConstructionTester, checkTaskGraphIntegrity: Bool = true) async throws -> [String] {
        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let buildTargets = try targetNames.map { name in
            BuildRequest.BuildTargetInfo(parameters: parameters, target: try #require(tester.workspace.targets(named: name).first))
        }
        let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        var outputs: [String] = []
        await tester.checkBuild(runDestination: .macOS, buildRequest: request, checkTaskGraphIntegrity: checkTaskGraphIntegrity) { results in
            results.checkTasks(.matchRuleType("GenerateTAPI")) { tasks in
                outputs = tasks.flatMap { $0.outputs.compactMap { ($0 as? PlannedPathNode)?.path.str } }.filter { $0.hasSuffix(".tbd") }.sorted()
            }
        }
        return outputs
    }

    /// A project in which `Fwk` is specialized for macOS or Mac Catalyst depending on which app is built.
    private func specializableFrameworkTester() async throws -> TaskConstructionTester {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                    TestFile("mac.swift"),
                    TestFile("catalyst.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                ])],
            targets: [
                TestStandardTarget(
                    "Mac App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["mac.swift"]),
                        TestFrameworksBuildPhase([TestBuildFile(.target("Fwk"))]),
                    ],
                    dependencies: ["Fwk"]),
                TestStandardTarget(
                    "Catalyst App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["catalyst.swift"]),
                        TestFrameworksBuildPhase([TestBuildFile(.target("Fwk"))]),
                    ],
                    dependencies: ["Fwk"]),
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"]),
                    ]),
            ])
        return try await TaskConstructionTester(getCore(), testProject)
    }

    @Test(.requireSDKs(.macOS))
    func singlePlatformBuildGeneratesIntermediateStub() async throws {
        let tester = try await specializableFrameworkTester()
        let outputs = try await intermediateStubOutputs(building: ["Mac App"], tester: tester)

        #expect(outputs == ["/tmp/Test/aProject/build/EagerLinkingTBDs/Debug/Fwk.framework/Versions/A/Fwk.tbd"])
    }

    /// A framework specialized for several platforms in one build writes its stubs to platform-specific directories, so the platforms must not be treated as clashing product names.
    @Test(.requireSDKs(.macOS))
    func multiplatformFrameworkGeneratesIntermediateStubPerPlatform() async throws {
        let tester = try await specializableFrameworkTester()
        let outputs = try await intermediateStubOutputs(building: ["Mac App", "Catalyst App"], tester: tester)

        #expect(outputs == [
            "/tmp/Test/aProject/build/EagerLinkingTBDs/Debug-maccatalyst/Fwk.framework/Versions/A/Fwk.tbd",
            "/tmp/Test/aProject/build/EagerLinkingTBDs/Debug/Fwk.framework/Versions/A/Fwk.tbd",
        ])
    }

    /// Targets which share a product name on the same platform compute the same stub path, so no stubs are generated for them.
    @Test(.requireSDKs(.macOS))
    func sameProductNameOnSamePlatformGeneratesNoIntermediateStubs() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("FwkA.swift"),
                    TestFile("FwkB.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "Fwk",
                    "SDKROOT": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                ])],
            targets: [
                TestStandardTarget(
                    "FwkA",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["FwkA.swift"])
                    ]),
                TestStandardTarget(
                    "FwkB",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["FwkB.swift"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        // Both targets produce the same product, which task graph validation would otherwise report.
        let outputs = try await intermediateStubOutputs(building: ["FwkA", "FwkB"], tester: tester, checkTaskGraphIntegrity: false)

        #expect(outputs.isEmpty)
    }
}
