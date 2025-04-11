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
fileprivate struct SwiftABICheckerTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.iOS))
    func swiftABICheckerBasic() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "arm64 arm64e",
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "RUN_SWIFT_ABI_CHECKER_TOOL": "YES",
                    "SWIFT_VERSION": swiftVersion,
                    "FRAMEWORK_SEARCH_PATHS": "/Target/Framework/Search/Path/A",
                    "SYSTEM_FRAMEWORK_SEARCH_PATHS": "/Target/System/Framework/Search/Path/A",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "SWIFT_EXEC": swiftCompilerPath.str,
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
        // Check the `Debug` build.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .anyiOSDevice) { results in
            results.checkNoDiagnostics()
            results.consumeTasksMatchingRuleTypes(["Gate", "SymLink", "CpHeader", "MkDir", "Touch"])
            results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { #expect($0.count > 0) }
            for arch in ["arm64e", "arm64"] {
                results.checkTask(.matchRule(["CheckSwiftABI", "normal", arch])) { task in
                    task.checkCommandLineContains([
                        "swift-api-digester",
                        "-diagnose-sdk",
                        "-target", "\(arch)-apple-ios\(core.loadSDK(.iOS).defaultDeploymentTarget)",
                        "-F", "/TEST/build/Debug-iphoneos",
                        "-module", "Fwk",
                        "-F", "/Target/System/Framework/Search/Path/A"
                    ])
                }
            }
            results.checkNoTask(.matchRuleType("SwiftDriver"))
        }
    }
    @Test(.requireSDKs(.iOS))
    func swiftABIBaselineGenerationBasic() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "arm64 arm64e",
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "RUN_SWIFT_ABI_GENERATION_TOOL": "YES",
                    "SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR": "/tmp/user_given_generated_baseline",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "FRAMEWORK_SEARCH_PATHS": "/Target/Framework/Search/Path/A",
                    "SYSTEM_FRAMEWORK_SEARCH_PATHS": "/Target/System/Framework/Search/Path/A",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
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
        // Check the `Debug` build.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .anyiOSDevice) { results in
            results.checkNoDiagnostics()
            results.consumeTasksMatchingRuleTypes(["Gate", "SymLink", "CpHeader", "Touch"])
            results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { #expect($0.count > 0) }
            for arch in ["arm64", "arm64e"] {
                results.checkTask(.matchRule(["GenerateSwiftABIBaseline", "normal", arch])) { task in
                    task.checkCommandLineContains([
                        "swift-api-digester",
                        "-dump-sdk", "-target", "\(arch)-apple-ios\(core.loadSDK(.iOS).defaultDeploymentTarget)",
                        "-F", "/TEST/build/Debug-iphoneos",
                        "-module", "Fwk", "-o",
                        "/Target/System/Framework/Search/Path/A",
                    ])
                    // Ensure SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR is used.
                    task.checkOutputs([
                        .pathPattern(.contains("user_given_generated_baseline"))
                    ])
                }
            }
            results.checkNoTask(.matchRuleType("SwiftDriver"))
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftABICheckerUsingSpecifiedBaseline() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "arm64e",
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "RUN_SWIFT_ABI_CHECKER_TOOL": "YES",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "FRAMEWORK_SEARCH_PATHS": "/Target/Framework/Search/Path/A",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                    "SWIFT_ABI_CHECKER_BASELINE_DIR": "/tmp/mybaseline",
                    "SWIFT_ABI_CHECKER_EXCEPTIONS_FILE": "/tmp/allow.txt",
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

        let fs = PseudoFS()
        try fs.createDirectory(.root.join("tmp"))
        try fs.write(.root.join("tmp").join("allow.txt"), contents: "")
        try await fs.writeJSON(.root.join("tmp/mybaseline/ABI/arm64e-ios.json"), .plDict([:]))

        // Check the `Debug` build.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.consumeTasksMatchingRuleTypes(["Gate", "SymLink", "CpHeader", "MkDir", "Touch"])
            results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { #expect($0.count > 0) }
            results.checkTask(.matchRuleType("CheckSwiftABI")) { task in
                task.checkCommandLineContains([
                    "swift-api-digester",
                    "-diagnose-sdk",
                    "-abort-on-module-fail",
                    "-abi",
                    "-compiler-style-diags",
                    "-target",
                    "arm64e-apple-ios\(core.loadSDK(.iOS).version)",
                    "-F",
                    "/TEST/build/Debug-iphoneos",
                    "-F",
                    "/Target/Framework/Search/Path/A",
                    "-sdk",
                    "\(core.loadSDK(.iOS).path.str)",
                    "-module",
                    "Fwk",
                    "-use-interface-for-module",
                    "-serialize-diagnostics-path",
                    "/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Fwk/SwiftABIChecker/normal/arm64e-ios.dia",
                    "-baseline-path",
                    "/tmp/mybaseline/ABI/arm64e-ios.json",
                    "-breakage-allowlist-path",
                    "/tmp/allow.txt",
                    "-I",
                    "/TEST/build/Debug-iphoneos"
                ])
            }
            results.checkNoTask(.matchRuleType("SwiftDriver"))
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftABICheckerTaskSequence() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "arm64 arm64e",
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "RUN_SWIFT_ABI_CHECKER_TOOL": "YES",
                    "RUN_SWIFT_ABI_GENERATION_TOOL": "YES",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "CODE_SIGNING_ALLOWED": "NO",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
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
        // Check the `Debug` build.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOS) { results in
            results.checkNoDiagnostics()
            // Check CheckSwiftABI is always after GenerateSwiftABIBaseline
            results.checkTasks(.matchRuleType("CheckSwiftABI")) { tasks in
                for task in tasks {
                    let variant = task.ruleInfo[1] // "normal"
                    let arch = task.ruleInfo[2] // "arm64" or "arm64e"
                    results.checkTaskFollows(task, .matchRule(["GenerateSwiftABIBaseline", variant, arch]))
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftABICheckerDriverNoBaseline() async throws {
        let fs = PseudoFS()
        let tmp = try fs.createTemporaryDirectory(parent: fs.realpath(Path.root.join("tmp")))
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "arm64",
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "RUN_SWIFT_ABI_CHECKER_TOOL_DRIVER": "YES",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "CODE_SIGNING_ALLOWED": "NO",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                    "SWIFT_ABI_CHECKER_BASELINE_DIR": tmp.str,
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
        // Check the `Debug` build.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOS, fs: fs) { results in
            results.checkWarning(.prefix("cannot find Swift ABI baseline"))
        }
    }
    @Test(.requireSDKs(.iOS))
    func swiftABICheckerDriver() async throws {
        let fs = PseudoFS()
        let tmp = try fs.createTemporaryDirectory(parent: fs.realpath(Path.root.join("tmp")))
        try fs.write(Path("\(tmp.str)/arm64-apple-ios.abi.json"), contents: "[]")
        try fs.write(Path("\(tmp.str)/arm64e-apple-ios.abi.json"), contents: "[]")
        let swiftCompilerPath = try await self.swiftCompilerPath
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "arm64 arm64e",
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "RUN_SWIFT_ABI_CHECKER_TOOL_DRIVER": "YES",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "CODE_SIGNING_ALLOWED": "NO",
                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                    "SWIFT_ABI_CHECKER_BASELINE_DIR": tmp.str,
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
        // Check the `Debug` build.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { tasks in
                #expect(tasks.count > 0)
                for task in tasks {
                    task.checkCommandLineContains([swiftCompilerPath.str,
                                                   "-digester-mode", "abi",
                                                   "-compare-to-baseline-path"
                                                  ])
                }
            }
        }
    }
}
