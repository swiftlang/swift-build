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
            results.checkTask(.matchRule(["GenerateTAPI", "/tmp/Test/aProject/build/Debug/Fwk.framework/Versions/A/Fwk.tbd", "normal", "x86_64"])) { _ in }
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
}
