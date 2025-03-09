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

import struct Foundation.Data

import Testing

import SWBCore
import SWBTestSupport
import SWBUtil
import SWBProtocol

import SWBTaskConstruction

@Suite
fileprivate struct InstallAPITaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func TBDSigning() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Mock.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "-",
                    "DONT_GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "SKIP_INSTALL": "NO",
                    "TAPI_EXEC": tapiToolPath.str])],
            targets: [
                TestAggregateTarget(
                    "ALL",
                    dependencies: [
                        "Tool", "Fwk", "FwkNoPlist", "FwkNoSrc", "Dylib", "DylibNoSrc"]),
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["Mock.c"])]),
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Fwk", buildSettings: ["INFOPLIST_FILE": "Info.plist"])],
                    buildPhases: [
                        TestSourcesBuildPhase(["Mock.c"])]),
                TestStandardTarget(
                    "FwkNoPlist",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Mock.c"])]),
                TestStandardTarget(
                    "FwkNoSrc",
                    type: .framework,
                    buildPhases: []),
                TestStandardTarget(
                    "Dylib",
                    type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Mock.c"])]),
                TestStandardTarget(
                    "DylibNoSrc",
                    type: .dynamicLibrary,
                    buildPhases: [])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()
        try fs.createDirectory(tester.workspace.projects[0].sourceRoot, recursive: true)
        try fs.write(tester.workspace.projects[0].sourceRoot.join("Info.plist"), contents: "<dict/>")

        // We should only try to sign valid API-able product types.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkError("Cannot code sign because the target does not have an Info.plist file and one is not being generated automatically. Apply an Info.plist file to the target using the INFOPLIST_FILE build setting or generate one automatically by setting the GENERATE_INFOPLIST_FILE build setting to YES (recommended). (in target 'FwkNoPlist' from project 'aProject')")
            results.checkError("Cannot code sign because the target does not have an Info.plist file and one is not being generated automatically. Apply an Info.plist file to the target using the INFOPLIST_FILE build setting or generate one automatically by setting the GENERATE_INFOPLIST_FILE build setting to YES (recommended). (in target 'FwkNoPlist' from project 'aProject')")
            results.checkError("Cannot code sign because the target does not have an Info.plist file and one is not being generated automatically. Apply an Info.plist file to the target using the INFOPLIST_FILE build setting or generate one automatically by setting the GENERATE_INFOPLIST_FILE build setting to YES (recommended). (in target 'FwkNoSrc' from project 'aProject')")
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("Fwk.tbd")) { _ in }
            results.checkNoTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("FwkNoPlist.tbd"))
            results.checkNoTask(.matchRuleType("GenerateTAPI"), .matchRuleItemBasename("FwkNoSrc.tbd"))
            results.checkNoTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("FwkNoSrc.tbd"))
            results.checkTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("Dylib.tbd")) { _ in }
            results.checkNoTask(.matchRuleType("GenerateTAPI"), .matchRuleItemBasename("DylibNoSrc.tbd"))
            results.checkNoTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("DylibNoSrc.tbd"))
            results.checkNoTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("Tool.tbd"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkBasics() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("Fwk.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "-",
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "SKIP_INSTALL": "NO"])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()

        try await fs.writePlist(Path("/TEST/Info.plist"), .plDict([:]))

        let tapiToolPath = try await self.tapiToolPath

        // Check the `installapi` build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            // There should be 3 interesting tasks (aside from symlink/touch tasks):
            // * CpHeader for umbrella header
            // * SymLink of the .tbd file
            // * Generate API
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                        .anySequence,

                    "-x", "objective-c", .anySequence,
                    "--demangle", .anySequence,

                    // Check search paths.
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug",
                    "-I/TEST/build/Debug/include", .anySequence,

                    // Check IO options.
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",
                ])
                task.checkCommandLineNoMatch([.anySequence, .prefix("-std="), .anySequence, .prefix("--dsym="), .prefix("-extra"), .anySequence, .prefix("-exclude"), .anySequence, "--product-name=Fwk"])

            }
            results.checkNoTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("Fwk.framework.dSYM"))

        }

        // Check the `install` build, which should run the same steps but also provide the binary for comparison purposes.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: ["RETAIN_RAW_BINARIES": "YES"]), runDestination: .macOS, fs: fs) { results in
            // There should be 4 interesting tasks (aside from symlink/touch tasks):
            // * CpHeader for umbrella header
            // * SymLink of the .tbd file
            // * Generate API
            // * CodeSign of the TBD file
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }
            var generateTapiTask: (any PlannedTask)! = nil
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi",
                    "-verify-against", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                    "--verify-mode=ErrorsOnly",
                    .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                        .anySequence,

                    // Check search paths.
                    "-F/TEST/build/Debug/BuiltProducts",
                    "-L/TEST/build/Debug/BuiltProducts",
                    "-I/TEST/build/Debug/BuiltProducts/include",

                        .anySequence,

                    // Check IO options.
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                    "-filelist", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",
                ])
                generateTapiTask = task
            }
            results.checkTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLineMatches([
                    .suffix("codesign"), .anySequence,
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd"])
            }
            results.checkNoTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("Fwk.framework.dSYM"))

            // Also check the ordering of postprocessing tasks.
            guard generateTapiTask != nil else {
                Issue.record("No GenerateTAPI task was generated")
                return
            }
            var copyAsideTask: (any PlannedTask)! = nil
            results.checkTask(.matchRule(["Copy", "/TEST/build/Fwk.framework", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework"])) { task in
                copyAsideTask = task
            }
            guard copyAsideTask != nil else {
                Issue.record("No copy-aside copy task was generated")
                return
            }
            var stripTask: (any PlannedTask)! = nil
            results.checkTask(.matchRule(["Strip", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk"])) { task in
                stripTask = task
            }
            guard stripTask != nil else {
                Issue.record("No Strip task was generated")
                return
            }
            results.checkTaskFollows(copyAsideTask, antecedent: generateTapiTask)
            results.checkTaskFollows(stripTask, antecedent: copyAsideTask)
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkBasicsWithExtraSettings() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("Fwk.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "-",
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_LANGUAGE": "objective-c++",
                    "TAPI_LANGUAGE_STANDARD": "c++20",
                    "TAPI_DEMANGLE": "NO",
                    "TAPI_EXTRA_PRIVATE_HEADERS": "**/tmp/FooSecret.h FrameworkHeaders/FooPrivate.h",
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "SKIP_INSTALL": "NO"])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()

        try await fs.writePlist(Path("/TEST/Info.plist"), .plDict([:]))

        let tapiToolPath = try await self.tapiToolPath

        // Check the `installapi` build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            // There should be 3 interesting tasks (aside from symlink/touch tasks):
            // * CpHeader for umbrella header
            // * SymLink of the .tbd file
            // * Generate API
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                        .anySequence,

                    "-x", "objective-c++", .anySequence,
                    "-std=c++20", .anySequence,

                    // Check Extra Header Args
                    "-extra-private-header", "**/tmp/FooSecret.h",
                    "-extra-private-header", "FrameworkHeaders/FooPrivate.h",
                    .anySequence,

                    // Check search paths.
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug",
                    "-I/TEST/build/Debug/include", .anySequence,

                    // Check IO options.
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",
                ])
                task.checkCommandLineNoMatch([.anySequence, "--demangle", .anySequence, .prefix("-exclude")])

            }
        }

        // Check the `install` build, which should run the same steps but also provide the binary for comparison purposes.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: ["RETAIN_RAW_BINARIES": "YES"]), runDestination: .macOS, fs: fs) { results in
            // There should be 4 interesting tasks (aside from symlink/touch tasks):
            // * CpHeader for umbrella header
            // * SymLink of the .tbd file
            // * Generate API
            // * CodeSign of the TBD file
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }
            var generateTapiTask: (any PlannedTask)! = nil
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi",
                    "-verify-against", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                    "--verify-mode=ErrorsOnly",
                    .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                        .anySequence,

                    "-x", "objective-c++", .anySequence,
                    "-std=c++20", .anySequence,

                    // Check Extra Header Args
                    "-extra-private-header", "**/tmp/FooSecret.h",
                    "-extra-private-header", "FrameworkHeaders/FooPrivate.h",
                    .anySequence,

                    // Check search paths.
                    "-F/TEST/build/Debug/BuiltProducts",
                    "-L/TEST/build/Debug/BuiltProducts",
                    "-I/TEST/build/Debug/BuiltProducts/include",

                        .anySequence,

                    // Check IO options.
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                    "-filelist", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",
                ])
                task.checkCommandLineNoMatch([.anySequence, "--demangle", .anySequence, .prefix("-exclude")])
                generateTapiTask = task
            }
            results.checkTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLineMatches([
                    .suffix("codesign"), .anySequence,
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd"])
            }

            // Also check the ordering of postprocessing tasks.
            guard generateTapiTask != nil else {
                Issue.record("No GenerateTAPI task was generated")
                return
            }
            var copyAsideTask: (any PlannedTask)! = nil
            results.checkTask(.matchRule(["Copy", "/TEST/build/Fwk.framework", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework"])) { task in
                copyAsideTask = task
            }
            guard copyAsideTask != nil else {
                Issue.record("No copy-aside copy task was generated")
                return
            }
            var stripTask: (any PlannedTask)! = nil
            results.checkTask(.matchRule(["Strip", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk"])) { task in
                stripTask = task
            }
            guard stripTask != nil else {
                Issue.record("No Strip task was generated")
                return
            }
            results.checkTaskFollows(copyAsideTask, antecedent: generateTapiTask)
            results.checkTaskFollows(stripTask, antecedent: copyAsideTask)
        }
    }


    @Test(.requireSDKs(.macOS))
    func frameworkBasicsProjectHeadersEnabled() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("FwkInternal.h"),
                    TestFile("Fwk.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "GCC_GENERATE_DEBUGGING_SYMBOLS" : "YES",
                    "DEBUG_INFORMATION_FORMAT" : "dwarf-with-dsym",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_ENABLE_PROJECT_HEADERS": "YES",
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "SKIP_INSTALL": "NO"])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public),
                            TestBuildFile("FwkInternal.h")])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()

        try await fs.writePlist(Path("/TEST/Info.plist"), .plDict([:]))

        let tapiToolPath = try await self.tapiToolPath

        let tapiVersion = try await discoveredTAPIToolInfo(at: tapiToolPath).toolVersion ?? Version()
        let expectedVersion = TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: tapiVersion).rawValue
        let expectedHeaders: PropertyListItem = .plArray([
            .plDict([
                "type": .plString("public"),
                "path": .plString("/TEST/build/Debug/Fwk.framework/Headers/Fwk.h")
            ]),
            .plDict([
                "type": .plString("project"),
                "path": .plString("/TEST/Sources/FwkInternal.h")
            ])
        ])


        // Check the `installapi` build.
        try await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Fwk.json")) { task, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["version"] == .plString("\(expectedVersion)"))
                // The header paths in the JSON file should for be the built copies, not the source copies.
                #expect(items["headers"] == expectedHeaders)
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),
                    .anySequence,

                    // Check build products search paths
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug",

                        .anySequence,

                    // Check SRCROOT search paths
                    "-iquote", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk-generated-files.hmap",
                    "-I/TEST/build/aProject.build/Debug/Fwk.build/Fwk-own-target-headers.hmap",
                    "-I/TEST/build/aProject.build/Debug/Fwk.build/Fwk-all-target-headers.hmap",
                    "-iquote", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk-project-headers.hmap",

                        .anySequence,

                    // Check IO options.
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",

                ])
            }
            results.checkNoTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("Fwk.framework.dSYM"))

        }

        // Check the `install` build, which should run the same steps but also provide the binary for comparison purposes.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: ["RETAIN_RAW_BINARIES": "YES"]), runDestination: .macOS, fs: fs) { results in
            // There should be 4 interesting tasks (aside from symlink/touch tasks):
            // * CpHeader for umbrella header
            // * SymLink of the .tbd file
            // * Generate dSYM
            // * Generate API
            // * CodeSign of the TBD file
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }
            results.checkTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("Fwk.framework.dSYM")) { task in
                task.checkCommandLine([ "dsymutil", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                                        "-o", "/TEST/build/Debug/Fwk.framework.dSYM"]) }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi",
                    "-verify-against", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                    "--verify-mode=ErrorsOnly",
                    .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                        .anySequence,

                    // Check build products search paths
                    "-F/TEST/build/Debug/BuiltProducts",
                    "-L/TEST/build/Debug/BuiltProducts",

                        .anySequence,

                    // Check SRCROOT search paths
                    "-iquote", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk-generated-files.hmap",
                    "-I/TEST/build/aProject.build/Debug/Fwk.build/Fwk-own-target-headers.hmap",
                    "-I/TEST/build/aProject.build/Debug/Fwk.build/Fwk-all-target-headers.hmap",
                    "-iquote", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk-project-headers.hmap",

                        .anySequence,

                    // Check IO options.
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",
                ])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkStubifyMode() async throws {
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("Fwk.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "GENERATE_TEXT_BASED_STUBS": "YES",
                    "SKIP_INSTALL": "NO"])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the `install` build performs the stubify step.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    "tapi", "stubify", "-isysroot", .any,

                    // Check search paths.
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug",

                    // Check IO options.
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func dylibBasics() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Core.h"),
                    TestFile("CoreInternal.h"),
                    TestFile("Core.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "-",
                    "EXECUTABLE_PREFIX": "lib",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "SKIP_INSTALL": "NO"])],
            targets: [
                TestStandardTarget(
                    "Core",
                    type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Core.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Core.h", headerVisibility: .public),
                            TestBuildFile("CoreInternal.h")])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let tapiVersion = try await discoveredTAPIToolInfo(at: tapiToolPath).toolVersion ?? Version()
        let expectedVersion = TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: tapiVersion).rawValue
        let expectedHeaders: PropertyListItem = .plArray([
            .plDict([
                "type": .plString("public"),
                "path": .plString("/tmp/aProject.dst/usr/local/include/Core.h")
            ])
        ])

        // Check the `installapi` build.
        try await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            // There should be 3 interesting tasks:
            // * CpHeader for header
            // * WriteAuxiliaryFile for JSON description
            // * Generate API
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Core.h",
                    "/tmp/aProject.dst/usr/local/include"])
            }
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Core.json")) { task, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["version"] == .plString("\(expectedVersion)"))
                // The header paths in the JSON file should for be the built copies, not the source copies.
                #expect(items["headers"] == expectedHeaders)
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                    "-dynamiclib",
                    .anySequence,

                    // Check search paths.
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug",
                    "-I/TEST/build/Debug/include",

                        .anySequence,

                    // Check IO options.
                    "-filelist", "/TEST/build/aProject.build/Debug/Core.build/Core.json",
                    "-o",
                    "/tmp/aProject.dst/usr/local/lib/libCore.tbd", .anySequence,
                    "--product-name=Core"

                ])
            }
        }

        // Check the `install` build, which should run the same steps but also provide the binary for comparison purposes.
        try await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Core.h",
                    "/tmp/aProject.dst/usr/local/include"])
            }
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Core.json")) { task, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["version"] == .plString("\(expectedVersion)"))
                // The header paths in the JSON file should for be the built copies, not the source copies.
                #expect(items["headers"] == expectedHeaders)
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi",
                    "-verify-against", "/tmp/aProject.dst/usr/local/lib/libCore.dylib",
                    "--verify-mode=ErrorsOnly",
                    .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),
                    "-dynamiclib",
                    .anySequence,

                    // Check search paths.
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug",
                    "-I/TEST/build/Debug/include",

                        .anySequence,

                    // Check IO options.
                    "-filelist", "/TEST/build/aProject.build/Debug/Core.build/Core.json",
                    "-o",
                    "/tmp/aProject.dst/usr/local/lib/libCore.tbd", .anySequence,
                    "--product-name=Core"
                ])
            }
            results.checkTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("libCore.tbd")) { task in
                task.checkCommandLineMatches([
                    .suffix("codesign"), .anySequence,
                    "/tmp/aProject.dst/usr/local/lib/libCore.tbd"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func dylibBasicsProjectHeadersEnabled() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Core.h"),
                    TestFile("CoreInternal.h"),
                    TestFile("Core.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "EXECUTABLE_PREFIX": "lib",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_ENABLE_PROJECT_HEADERS":  "YES",
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "SKIP_INSTALL": "NO"])],
            targets: [
                TestStandardTarget(
                    "Core",
                    type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Core.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Core.h", headerVisibility: .public),
                            TestBuildFile("CoreInternal.h")])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let tapiVersion = try await discoveredTAPIToolInfo(at: tapiToolPath).toolVersion ?? Version()
        let expectedVersion = TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: tapiVersion).rawValue
        let expectedHeaders: PropertyListItem = .plArray([
            .plDict([
                "type": .plString("public"),
                "path": .plString("/tmp/aProject.dst/usr/local/include/Core.h")
            ]),
            .plDict([
                "type": .plString("project"),
                "path": .plString("/TEST/Sources/CoreInternal.h")
            ])
        ])

        // Check the `installapi` build.
        try await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Core.json")) { task, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["version"] == .plString("\(expectedVersion)"))
                // The header paths in the JSON file should for be the built copies, not the source copies.
                #expect(items["headers"] == expectedHeaders)
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                    "-dynamiclib",
                    .anySequence,

                    // Check build products search paths.
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug",
                    .anySequence,

                    // Check SRCROOT search paths.
                    "-iquote", "/TEST/build/aProject.build/Debug/Core.build/Core-generated-files.hmap",
                    "-I/TEST/build/aProject.build/Debug/Core.build/Core-own-target-headers.hmap",
                    "-I/TEST/build/aProject.build/Debug/Core.build/Core-all-target-headers.hmap",
                    "-iquote", "/TEST/build/aProject.build/Debug/Core.build/Core-project-headers.hmap",
                    .anySequence,


                    // Check IO options.
                    "-filelist", "/TEST/build/aProject.build/Debug/Core.build/Core.json",
                    "-o",
                    "/tmp/aProject.dst/usr/local/lib/libCore.tbd", .anySequence,
                    "--product-name=Core"
                ])
            }
        }

        // Check the `install` build, which should run the same steps but also provide the binary for comparison purposes.
        try await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Core.h",
                    "/tmp/aProject.dst/usr/local/include"])
            }
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Core.json")) { task, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["version"] == .plString("\(expectedVersion)"))
                // The header paths in the JSON file should for be the built copies, not the source copies.
                #expect(items["headers"] == expectedHeaders)
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi",
                    "-verify-against", "/tmp/aProject.dst/usr/local/lib/libCore.dylib",
                    "--verify-mode=ErrorsOnly",
                    .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),
                    "-dynamiclib",
                    .anySequence,

                    // Check search paths.
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug",
                    .anySequence,

                    // Check SRCROOT search paths.
                    "-iquote", "/TEST/build/aProject.build/Debug/Core.build/Core-generated-files.hmap",
                    "-I/TEST/build/aProject.build/Debug/Core.build/Core-own-target-headers.hmap",
                    "-I/TEST/build/aProject.build/Debug/Core.build/Core-all-target-headers.hmap",
                    "-iquote", "/TEST/build/aProject.build/Debug/Core.build/Core-project-headers.hmap",
                    .anySequence,

                    // Check IO options.
                    "-filelist", "/TEST/build/aProject.build/Debug/Core.build/Core.json",
                    "-o",
                    "/tmp/aProject.dst/usr/local/lib/libCore.tbd", .anySequence,
                    "--product-name=Core"
                ])
            }
        }
    }


    @Test(.requireSDKs(.macOS))
    func dylibStubifyMode() async throws {
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Core.h"),
                    TestFile("Core.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "EXECUTABLE_PREFIX": "lib",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "GENERATE_TEXT_BASED_STUBS": "YES",
                    "SKIP_INSTALL": "NO"])],
            targets: [
                TestStandardTarget(
                    "Core",
                    type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Core.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Core.h", headerVisibility: .public)])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the `install` build performs the stubify step.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    "tapi", "stubify", "-isysroot", .any,

                    // Check search paths.
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug", .anySequence,

                    // Check IO options.
                    "/tmp/aProject.dst/usr/local/lib/libCore.dylib",
                    "-o",
                    "/tmp/aProject.dst/usr/local/lib/libCore.tbd"])
            }
        }
    }

    /// Test that we only run `tapi stubify` for targets whose Mach-O output is an `mh_dylib`. It does not apply for static libraries and should be ignored.
    @Test(.requireSDKs(.macOS))
    func noStubify() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Core.h"),
                    TestFile("Core.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "EXECUTABLE_PREFIX": "lib",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "GENERATE_TEXT_BASED_STUBS": "YES",
                    "SKIP_INSTALL": "NO",
                    "LIBTOOL": libtoolPath.str,
                ])],
            targets: [
                TestAggregateTarget(
                    "All",
                    dependencies: ["CoreKit", "Core", "CoreKitWrongType", "CoreWrongType"]),
                TestStandardTarget(
                    "CoreKit",
                    type: .staticFramework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Core.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Core.h", headerVisibility: .public)])]),
                TestStandardTarget(
                    "Core",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Core.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Core.h", headerVisibility: .public)])]),
                TestStandardTarget(
                    "CoreKitWrongType",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["MACH_O_TYPE": "staticlib"])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Core.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Core.h", headerVisibility: .public)])]),
                TestStandardTarget(
                    "CoreWrongType",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["MACH_O_TYPE": "staticlib", "PUBLIC_HEADERS_FOLDER_PATH": "/usr/local/CoreWrongType"])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Core.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Core.h", headerVisibility: .public)])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the `install` build performs the stubify step.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkNoTask(.matchRuleType("GenerateTAPI"))
        }
    }

    /// Check that we report errors on invalid InstallAPI attempts.
    @Test(.requireSDKs(.macOS))
    func installAPIErrors() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [TestFile("Fwk.c"), TestFile("Fwk.h")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SKIP_INSTALL": "NO",
                    "TAPI_EXEC": tapiToolPath.str,
                ])],
            targets: [
                TestAggregateTarget(
                    "ALL",
                    dependencies: [
                        "OkFwk1", "OkFwk2", "OkFwk3",
                        "OkBecauseIsApp1", "OkBecauseIsApp2", "OkBecauseIsApp3",
                        "OkBecauseIsStatic1", "OkBecauseIsStatic2",
                        "BadStaticLib1", "BadStaticLib2",
                        "BadFwkNoSrc",
                        "BadFwk",
                        "BadDynamicLib",
                        "BadStaticLibWrongType",
                        "BadStaticFrameworkWrongType"]),

                // These frameworks are ok because they have no installed headers.
                TestStandardTarget(
                    "OkFwk1",
                    type: .framework,
                    buildPhases: []),
                TestStandardTarget(
                    "OkFwk2",
                    type: .framework,
                    buildPhases: [TestHeadersBuildPhase([])]),
                TestStandardTarget(
                    "OkFwk3",
                    type: .framework,
                    buildPhases: [TestHeadersBuildPhase([
                        TestBuildFile("Fwk.h")])]),

                TestStandardTarget(
                    "OkBecauseIsApp1",
                    type: .application,
                    buildPhases: []),

                TestStandardTarget(
                    "OkBecauseIsApp2",
                    type: .application,
                    buildPhases: [TestHeadersBuildPhase([])]),

                TestStandardTarget(
                    "OkBecauseIsApp3",
                    type: .application,
                    buildPhases: [TestHeadersBuildPhase([
                        TestBuildFile("Fwk.h")])]),


                // This library should be skipped because it is static and contains no Swift sources.
                TestStandardTarget(
                    "OkBecauseIsStatic1",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PUBLIC_HEADERS_FOLDER_PATH": "/usr/local/static1/include",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Fwk.c")]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])]),

                // This library should be skipped because it is static and contains no Swift sources.
                TestStandardTarget(
                    "OkBecauseIsStatic2",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MACH_O_TYPE": "staticlib",
                            "PUBLIC_HEADERS_FOLDER_PATH": "/usr/local/static2/include",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Fwk.c")]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])]),

                // This library should produce an error because it is static and contains no Swift sources.
                TestStandardTarget(
                    "BadStaticLib1",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PUBLIC_HEADERS_FOLDER_PATH": "/usr/local/badstatic1/include",
                            "SUPPORTS_TEXT_BASED_API": "YES",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Fwk.c")]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])]),

                // This library should produce an error because it is static and contains no Swift sources.
                TestStandardTarget(
                    "BadStaticLib2",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MACH_O_TYPE": "staticlib",
                            "PUBLIC_HEADERS_FOLDER_PATH": "/usr/local/badstatic2/include",
                            "SUPPORTS_TEXT_BASED_API": "YES",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Fwk.c")]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])]),

                // This framework should be skipped because it contains no sources (and thus won't generate an actual binary).
                TestStandardTarget(
                    "BadFwkNoSrc",
                    type: .framework,
                    buildPhases: [TestHeadersBuildPhase([
                        TestBuildFile("Fwk.h", headerVisibility: .public)])]),

                // This framework should produce an error.
                TestStandardTarget(
                    "BadFwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Fwk.c")]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])]),

                // This library should produce an error.
                TestStandardTarget(
                    "BadDynamicLib",
                    type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Fwk.c")]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])]),

                // Only dynamic libraries and frameworks are supported
                TestStandardTarget(
                    "BadStaticLibWrongType",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MACH_O_TYPE": "mh_execute",
                            "SUPPORTS_TEXT_BASED_API": "YES",
                        ])
                    ],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("Fwk.c")])]),
                TestStandardTarget(
                    "BadStaticFrameworkWrongType",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MACH_O_TYPE": "mh_execute",
                            "SUPPORTS_TEXT_BASED_API": "YES",
                        ])
                    ],
                    buildPhases: [TestSourcesBuildPhase([TestBuildFile("Fwk.c")])]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkError(.equal("Framework requested to generate API, but has not adopted SUPPORTS_TEXT_BASED_API (in target 'BadFwk' from project 'aProject')"))
            results.checkError(.equal("Dynamic Library requested to generate API, but has not adopted SUPPORTS_TEXT_BASED_API (in target 'BadDynamicLib' from project 'aProject')"))
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftInstallAPIStaticLib() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "SKIP_INSTALL": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "MACH_O_TYPE": "staticlib"
                ])],
            targets: [
                TestAggregateTarget(
                    "ALL",
                    dependencies: ["FooDynamicLib", "FooStaticLib"]),
                TestStandardTarget(
                    "FooDynamicLib",
                    type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Foo.swift"])
                    ]),
                TestStandardTarget(
                    "FooStaticLib",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Foo.swift"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        func checkTarget(results: TaskConstructionTester.PlanningResults, target: ConfiguredTarget) {
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                // Check that Swift is being invoked even in InstallAPI mode.
                //
                // FIXME: We should check we forced WMO here, and didn't have incremental mode.
                task.checkCommandLineMatches([
                    "builtin-Swift-Compilation-Requirements", "--", .suffix("swiftc"), "-module-name", .anySequence, .and(.prefix("@"), .suffix("SwiftFileList")), .anySequence,
                    // Check we forced WMO mode.
                    "-whole-module-optimization", .anySequence
                ])

                // We shouldn't have a '-c'.
                task.checkCommandLineNoMatch(["-c"])
                task.checkCommandLineDoesNotContain("-emit-tbd")
            }
        }
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Release"), runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["Gate", "SymLink", "CpHeader", "MkDir", "Touch", "CreateBuildDirectory"])
            // Check that the VFS is generated.
            results.checkTaskExists(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml"))
            results.checkTarget("FooStaticLib") { target in checkTarget(results: results, target: target) }
            results.checkTarget("FooDynamicLib") { target in checkTarget(results: results, target: target) }
        }
    }

    @Test(.requireSDKs(.macOS))
    func tapiReexport() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "SKIP_INSTALL": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "REEXPORTED_LIBRARY_NAMES": "libA libB",
                    "REEXPORTED_LIBRARY_PATHS": "/tmp/libA /tmp/libB",
                    "REEXPORTED_FRAMEWORK_NAMES": "SubFrameA SubFrameB",
                ])],
            targets: [
                TestStandardTarget(
                    "FooFramework",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Foo.swift"])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            // Check that the VFS is generated.
            results.checkTaskExists(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml"))
            results.checkTarget("FooFramework") { target in
                results.checkNoDiagnostics()

                results.checkTask(.matchRuleType("GenerateTAPI"), .matchRuleItemBasename("FooFramework.tbd"), .matchTarget(target)) { task in
                    task.checkCommandLineContains([
                        tapiToolPath.str, "installapi",
                        "-reexport_framework", "SubFrameA", "-reexport_framework", "SubFrameB",
                        "-reexport-llibA", "-reexport-llibB",
                        "-reexport_library", "/tmp/libA", "-reexport_library", "/tmp/libB",
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftInstallAPI() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                    TestFile("App.swift")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "SKIP_INSTALL": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "TAPI_SHARED_CACHE_ELIGIBLE": "NO",
                    "TAPI_ENABLE_MODULES": "YES",
                    "DYLIB_CURRENT_VERSION": "2.0",
                    "DYLIB_COMPATIBILITY_VERSION": "1.0",
                ])],
            targets: [
                TestAggregateTarget("All", dependencies: ["App", "Fwk"]),
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])
                    ]),

                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["App.swift"])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let tapiVersion = try await discoveredTAPIToolInfo(at: tapiToolPath).toolVersion ?? Version()

        // Check the `installapi` build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["Gate", "SymLink", "CpHeader", "MkDir", "Touch", "CreateBuildDirectory"])
            // Check that the VFS is generated.
            results.checkTaskExists(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml"))
            results.checkTarget("Fwk") { target in
                // Check that Swift generated API.
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    // Check that Swift is being invoked even in InstallAPI mode.
                    //
                    // FIXME: We should check we forced WMO here, and didn't have incremental mode.
                    task.checkCommandLineMatches([
                        "builtin-Swift-Compilation-Requirements", "--", .suffix("swiftc"), "-module-name", "Fwk", .anySequence, .and(.prefix("@"), .suffix("SwiftFileList")), .anySequence,
                        "-emit-tbd", "-emit-tbd-path", "/TEST/build/aProject.build/Debug/Fwk.build/Objects-normal/x86_64/Swift-API.tbd", .anySequence,
                        // Check we pass the TBD install name.
                        "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                        // Check we pass the TBD dylib version flags
                        "-Xfrontend", "-tbd-current-version", "-Xfrontend", "2.0",
                        "-Xfrontend", "-tbd-compatibility-version", "-Xfrontend", "1.0", .anySequence,
                        // Check we forced WMO mode.
                        "-whole-module-optimization", .anySequence,
                        "-emit-objc-header", "-emit-objc-header-path", "/TEST/build/aProject.build/Debug/Fwk.build/Objects-normal/x86_64/Fwk-Swift.h"
                    ])

                    // We shouldn't have a '-c'.
                    task.checkCommandLineNoMatch(["-c"])
                }

                // Check that we generated correct TAPI installapi invocation.
                results.checkTask(.matchRuleType("GenerateTAPI"), .matchRuleItemBasename("Fwk.tbd"), .matchTarget(target)) { task in
                    // check TAPI options.
                    task.checkCommandLineMatches([
                        StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                        "-target", StringPattern.prefix("x86_64-apple"),

                            .anySequence,

                        // Check search paths.
                        "-F/TEST/build/Debug",
                        "-L/TEST/build/Debug",
                        "-I/TEST/build/Debug/include",

                            .anySequence,

                        // Check IO options.
                        "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                        "-filelist", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                        "-o", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",

                        // Check Swift options.
                        StringPattern.and(.prefix("-L/"), .contains(".xctoolchain/")),
                        StringPattern.and(.prefix("-L/"), .suffix(".sdk/usr/lib/swift")),
                        "-exclude-public-header", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers/Fwk-Swift.h",
                        "-swift-installapi-interface", .suffix("x86_64/Swift-API.tbd")
                    ] )

                    // Check version specific options
                    if tapiVersion >= Version(1600, 0, 6) {
                        task.checkCommandLineContains(["-not_for_dyld_shared_cache"])
                    }

                    task.checkCommandLineNoMatch([.suffix("Fwk.swift")])
                }

                // Check that we generate a copy of the compatibility header.
                results.checkTask(.matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Fwk-Swift.h"), .matchTarget(target)) { task in
                    task.checkCommandLine(["builtin-swiftHeaderTool", "-arch", "x86_64", "/TEST/build/aProject.build/Debug/Fwk.build/Objects-normal/x86_64/Fwk-Swift.h", "-o", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers/Fwk-Swift.h"])
                }
            }

            // Also, make sure an app target doesn't pass -emit-tbd to the
            // compiler or schedule TAPI invocations.
            results.checkTarget("App") { target in
                results.checkNoTask(.matchRuleType("MergeTAPI"), .matchTarget(target))
                results.checkNoTask(.matchRuleType("GenerateTAPI"), .matchTarget(target))
            }

            results.consumeTasksMatchingRuleTypes(["Copy", "WriteAuxiliaryFile", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders"])
            results.checkNoTask()
            results.checkWarning(.prefix("Skipping installAPI swiftmodule emission for target 'App'"))
            results.checkNoDiagnostics()
        }
    }

    /// This test makes sure RuleScriptExecution tasks are scheduled if
    /// `APPLY_RULES_IN_INSTALLAPI` is set, and also that they
    /// are not scheduled when it's not set.
    @Test(.requireSDKs(.macOS))
    func swiftInstallAPIBuildRuleScripts() async throws {
        let sdkRoot = "macosx"
        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File2.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "ARCHS": "x86_64",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                            "SUPPORTS_TEXT_BASED_API": "YES",
                            "SDKROOT": sdkRoot
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File2.swift"),
                        ]),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "*.swift",
                                      script: "cp $INPUT_FILE_PATH /tmp/b",
                                      outputs: ["/tmp/b"])
                    ]
                )
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTarget("TargetName") { target in
                results.checkNoTask(.matchRuleType("RuleScriptExecution"))
            }
        }
        let overrides = [
            "APPLY_RULES_IN_INSTALLAPI": "YES"
        ]
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug", overrides: overrides), runDestination: .macOS) { results in
            results.checkTarget("TargetName") { target in
                results.checkTask(.matchRuleType("RuleScriptExecution")) { task in
                    task.checkCommandLineContains(["/bin/sh", "-c", "cp $INPUT_FILE_PATH /tmp/b"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftInstallAPIDylibTarget() async throws {
        let sdkRoot = "macosx"
        let tapiToolPath = try await self.tapiToolPath
        let testProject = try await TestProject(
            "ProjectName",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File2.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "ARCHS": "x86_64",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                            "TAPI_VERIFY_MODE": "ErrorsOnly",
                            "TAPI_USE_SRCROOT": "NO",
                            "SUPPORTS_TEXT_BASED_API": "YES",
                            "SDKROOT": sdkRoot
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File2.swift"),
                        ]),
                    ]
                )
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["Gate", "SymLink", "CpHeader", "MkDir", "Touch", "CreateBuildDirectory"])

            // Check that the VFS is generated.
            results.checkTaskExists(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml"))

            results.checkTarget("TargetName") { target in
                results.checkNoDiagnostics()

                // Check that Swift generated API.
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    // Check that Swift is being invoked even in InstallAPI mode.
                    task.checkCommandLineMatches([
                        "builtin-Swift-Compilation-Requirements", "--", .suffix("swiftc"), .anySequence,
                        "-emit-tbd", "-emit-tbd-path", .suffix("x86_64/Swift-API.tbd"), .anySequence,
                        // Check we pass the TBD install name.
                        "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/usr/local/lib/ProductName.dylib",
                        // Check we pass the TBD dylib version flags
                        "-Xfrontend", "-tbd-current-version", "-Xfrontend", "1",
                        "-Xfrontend", "-tbd-compatibility-version", "-Xfrontend", "1", .anySequence,
                        "-Xfrontend", "-experimental-skip-non-inlinable-function-bodies", .anySequence,
                        // Check we forced WMO mode.
                        "-whole-module-optimization", .anySequence,
                        "-emit-objc-header", "-emit-objc-header-path", .suffix("x86_64/ProductName-Swift.h")
                    ])

                    // We shouldn't have a '-c'.
                    task.checkCommandLineNoMatch(["-c"])
                }

                // Check that we generated correct TAPI installapi invocation.
                results.checkTask(.matchRuleType("GenerateTAPI"), .matchRuleItemBasename("ProductName.tbd"), .matchTarget(target)) { task in
                    // check TAPI options.
                    task.checkCommandLineMatches([
                        StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                        "-target", StringPattern.prefix("x86_64-apple"),

                            .anySequence,

                        // Check search paths.
                        "-F/TEST/build/Debug",
                        "-L/TEST/build/Debug",
                        "-I/TEST/build/Debug/include",

                            .anySequence,

                        "-o", "/tmp/ProjectName.dst/usr/local/lib/ProductName.tbd",
                        StringPattern.and(.prefix("-L/"), .contains(".xctoolchain/")),
                        StringPattern.and(.prefix("-L/"), .suffix(".sdk/usr/lib/swift")),
                        "-exclude-public-header", "/TEST/build/ProjectName.build/Debug/TargetName.build/DerivedSources/ProductName-Swift.h",
                        "-swift-installapi-interface", .suffix("x86_64/Swift-API.tbd"), .anySequence, "--product-name=ProductName"
                    ])

                    task.checkCommandLineNoMatch([.suffix("File2.swift")])
                }

                // Check that we generate a copy of the compatibility header.
                results.checkTask(.matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("ProductName-Swift.h"), .matchTarget(target)) { task in
                    task.checkCommandLine(["builtin-swiftHeaderTool", "-arch", "x86_64", "/TEST/build/ProjectName.build/Debug/TargetName.build/Objects-normal/x86_64/ProductName-Swift.h", "-o", "/TEST/build/ProjectName.build/Debug/TargetName.build/DerivedSources/ProductName-Swift.h"])
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftInstallAPIMultiArch() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "arm64 arm64e",
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "SKIP_INSTALL": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                ])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the `installapi` build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .anyiOSDevice) { results in
            results.checkNoDiagnostics()

            // Check that the VFS is generated.
            results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml")) { _ in }

            // Check that Swift generated API.
            let archs = ["arm64", "arm64e"]
            for arch in archs {
                results.checkTask(.matchRule(["SwiftDriver Compilation Requirements", "Fwk", "normal", arch, "com.apple.xcode.tools.swift.compiler"])) { task in
                    // Check that Swift is being invoked even in InstallAPI mode.
                    //
                    // FIXME: We should check we forced WMO here, and didn't have incremental mode.
                    task.checkCommandLineMatches([
                        "builtin-Swift-Compilation-Requirements", "--", .suffix("swiftc"), "-module-name", "Fwk", .anySequence, .and(.prefix("@"), .suffix("SwiftFileList")), .anySequence,
                        "-emit-tbd", "-emit-tbd-path", .equal("/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Objects-normal/\(arch)/Swift-API.tbd"), .anySequence,
                        // Check we pass the TBD install name.
                        "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/Library/Frameworks/Fwk.framework/Fwk", .anySequence,
                        // Check we forced WMO mode.
                        "-whole-module-optimization", .anySequence,
                        "-emit-objc-header", "-emit-objc-header-path", .equal("/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Objects-normal/\(arch)/Fwk-Swift.h")
                    ])

                    // We shouldn't have a '-c'.
                    task.checkCommandLineNoMatch(["-c"])

                    // We shouldn't have individual input files
                    task.checkCommandLineNoMatch([.suffix("Fwk.swift")])
                }
            }

            // Check that we generated correct TAPI installapi invocation.
            results.checkTask(.matchRuleType("GenerateTAPI"), .matchRuleItemBasename("Fwk.tbd")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence] +

                                             archs.map{ [StringPattern.equal("-target"), StringPattern.prefix("\($0)-apple")] }.joined() +

                                             [.anySequence,

                                              // Check search paths.
                                              "-F/TEST/build/Debug-iphoneos",
                                              "-L/TEST/build/Debug-iphoneos",
                                              "-I/TEST/build/Debug-iphoneos/include", .anySequence,

                                              // Check IO options.
                                              "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",

                                              "-filelist", "/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Fwk.json",
                                              "-o", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd",

                                              // Check Swift options.
                                              StringPattern.and(.prefix("-L/"), .contains(".xctoolchain/")),
                                              StringPattern.and(.prefix("-L/"), .suffix(".sdk/usr/lib/swift")),
                                              "-exclude-public-header", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Headers/Fwk-Swift.h",
                                              "-swift-installapi-interface", .suffix("arm64/Swift-API.tbd"),
                                              "-swift-installapi-interface", .suffix("arm64e/Swift-API.tbd")
                                             ])
            }

            // Check that we generate a copy of the compatibility header.
            results.checkTask(.matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Fwk-Swift.h")) { task in
                task.checkCommandLine(["builtin-swiftHeaderTool",
                                       "-arch", "arm64", "/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Objects-normal/arm64/Fwk-Swift.h",
                                       "-arch", "arm64e", "/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Objects-normal/arm64e/Fwk-Swift.h",
                                       "-o", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Headers/Fwk-Swift.h"])
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftInstallAPIMultiVariants() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let swiftVersion = try await self.swiftVersion
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                    TestVariantGroup("Intents.intentdefinition", children: [
                        TestFile("Base.lproj/Intents.intentdefinition"),
                        TestFile("en.lproj/Intents.strings", regionVariantName: "en"),
                        TestFile("de.lproj/Intents.strings", regionVariantName: "de"),
                    ])]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "arm64 arm64e",
                    "BUILD_VARIANTS": "normal asan",
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "SKIP_INSTALL": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "INTENTS_CODEGEN_LANGUAGE": "Swift",
                ])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Fwk.swift",
                            TestBuildFile("Intents.intentdefinition", intentsCodegenVisibility: .public)]),])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        final class Delegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
            override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                if commandLine.first.map(Path.init)?.basename == "intentbuilderc",
                   let outputDir = commandLine.elementAfterElements(["-output"]).map(Path.init),
                   let classPrefix = commandLine.elementAfterElements(["-classPrefix"]),
                   let language = commandLine.elementAfterElements(["-language"]),
                   let visibility = commandLine.elementAfterElements(["-visibility"]) {
                    if visibility != "public" {
                        throw StubError.error("Visibility should be public")
                    }
                    switch language {
                    case "Swift":
                        return .result(status: .exit(0), stdout: Data(outputDir.join("\(classPrefix)Generated.swift").str.utf8), stderr: .init())
                    case "Objective-C":
                        return .result(status: .exit(0), stdout: Data([outputDir.join("\(classPrefix)Generated.h").str, outputDir.join("\(classPrefix)Generated.m").str].joined(separator: "\n").utf8), stderr: .init())
                    default:
                        throw StubError.error("unknown language '\(language)'")
                    }
                }
                return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
            }
        }

        // Check the `installapi` build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .anyiOSDevice, clientDelegate: Delegate()) { results in
            results.checkNoDiagnostics()

            // Check that the VFS is generated.
            results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml")) { _ in }

            // Check that Swift generated API.
            let archs = ["arm64", "arm64e"]
            let variants = ["asan", "normal"]
            for variant in variants {
                for arch in archs {
                    results.checkTask(.matchRule(["SwiftDriver Compilation Requirements", "Fwk", variant, arch, "com.apple.xcode.tools.swift.compiler"])) { task in
                        // Check that Swift is being invoked even in InstallAPI mode.
                        //
                        // FIXME: We should check we forced WMO here, and didn't have incremental mode.
                        task.checkCommandLineMatches([
                            "builtin-Swift-Compilation-Requirements", "--", .suffix("swiftc"), "-module-name", "Fwk", .anySequence, .and(.prefix("@"), .suffix("SwiftFileList")), .anySequence,
                            "-emit-tbd", "-emit-tbd-path", .equal("/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Objects-\(variant)/\(arch)/Swift-API.tbd"), .anySequence,
                            // Check we pass the TBD install name.
                            "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/Library/Frameworks/Fwk.framework/\(variant == "normal" ? "Fwk" : "Fwk_\(variant)")", .anySequence,
                            // Check we forced WMO mode.
                            "-whole-module-optimization", .anySequence,
                            "-emit-objc-header", "-emit-objc-header-path", .equal("/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Objects-\(variant)/\(arch)/Fwk-Swift.h")
                        ])

                        // We shouldn't have a '-c'.
                        task.checkCommandLineNoMatch(["-c"])

                        // We shouldn't have individual input files
                        task.checkCommandLineNoMatch([.suffix("Fwk.swift")])
                    }
                }

                let tapiTBDName = variant == "normal" ? "Fwk.tbd" : "Fwk_\(variant).tbd"

                // Check that we generated correct TAPI installapi invocation.
                results.checkTask(.matchRuleType("GenerateTAPI"), .matchRuleItemBasename(tapiTBDName)) { task in
                    // check TAPI options.
                    task.checkCommandLineMatches([
                        StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence] +

                                                 archs.map{ [StringPattern.equal("-target"), StringPattern.prefix("\($0)-apple")] }.joined() +

                                                 [.anySequence,

                                                  // Check search paths.
                                                  "-F/TEST/build/Debug-iphoneos",
                                                  "-L/TEST/build/Debug-iphoneos",
                                                  "-I/TEST/build/Debug-iphoneos/include", .anySequence,

                                                  // Check IO options.
                                                  "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                                                  "-filelist", "/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Fwk.json",
                                                  "-o", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/\(tapiTBDName)",

                                                  // Check Swift options.
                                                  StringPattern.and(.prefix("-L/"), .contains(".xctoolchain/")),
                                                  StringPattern.and(.prefix("-L/"), .suffix(".sdk/usr/lib/swift")),
                                                  "-exclude-public-header", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Headers/Fwk-Swift.h",
                                                  "-swift-installapi-interface", .suffix("arm64/Swift-API.tbd"),
                                                  "-swift-installapi-interface", .suffix("arm64e/Swift-API.tbd")
                                                 ])
                }
            }

            // Check that we generate a copy of the compatibility header.
            results.checkTask(.matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Fwk-Swift.h")) { task in
                task.checkCommandLine(["builtin-swiftHeaderTool",
                                       "-arch", "arm64", "/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Objects-normal/arm64/Fwk-Swift.h",
                                       "-arch", "arm64e", "/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/Objects-normal/arm64e/Fwk-Swift.h",
                                       "-o", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Headers/Fwk-Swift.h"])
            }

            results.checkTask(.matchRuleType("IntentDefinitionCodegen")) { task in
                task.checkCommandLine(["intentbuilderc", "generate", "-input", "/TEST/Sources/Base.lproj/Intents.intentdefinition", "-output", "/TEST/build/aProject.build/Debug-iphoneos/Fwk.build/DerivedSources/IntentDefinitionGenerated/Intents", "-classPrefix", "", "-language", "Swift", "-swiftVersion", swiftVersion, "-visibility", "public"])
            }

            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Copy", "Gate", "MkDir", "SymLink", "Touch", "WriteAuxiliaryFile", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements"])
            results.checkNoTask()
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftInstallAPIErrors() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Src.swift")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SKIP_INSTALL": "NO",
                    "TAPI_EXEC": tapiToolPath.str,
                    "SWIFT_VERSION": swiftVersion,
                ])],
            targets: [
                TestStandardTarget(
                    "BadApp",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["Src.swift"])],
                    dependencies: ["BadDylib", "BadFwk"]),
                TestStandardTarget(
                    "BadDylib",
                    type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Src.swift"])]),
                TestStandardTarget(
                    "BadFwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Src.swift"])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the `installapi` build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            // It is an error to have Swift code and not enable InstallAPI.
            // Only applies to frameworks and dylibs.
            results.checkError(.equal("Dynamic Library requested to generate API, but has not adopted SUPPORTS_TEXT_BASED_API (in target 'BadDylib' from project 'aProject')"))
            results.checkError(.equal("Framework requested to generate API, but has not adopted SUPPORTS_TEXT_BASED_API (in target 'BadFwk' from project 'aProject')"))
            results.checkNoDiagnostics()
        }

        // Check the `installapi` build with ALLOW_UNSUPPORTED_TEXT_BASED_API set.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug", overrides: ["ALLOW_UNSUPPORTED_TEXT_BASED_API": "YES"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftInstallAPISkipInstall() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Src.swift")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "iphoneos",
                    "SKIP_INSTALL": "NO",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,

                    "INSTALLAPI_IGNORE_SKIP_INSTALL": "YES",

                    // Conventional settings when using Swift InstallAPI
                    "SWIFT_OBJC_INTERFACE_HEADER_NAME": "",
                    "SWIFT_INSTALL_OBJC_HEADER": "NO",
                    "DEFINES_MODULE": "NO",
                ])],
            targets: [
                TestStandardTarget(
                    "BadApp",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["Src.swift"])],
                    dependencies: ["FwkPrivate", "FwkPublic"]),
                TestStandardTarget(
                    "FwkPrivate",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Src.swift"])]),
                TestStandardTarget(
                    "FwkPublic",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Src.swift"])],
                    dependencies: ["FwkPrivate"])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check the `installapi` build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .iOS) { results in
            let arch = results.runDestinationTargetArchitecture

            // We should have a Swift invocation for FwkPrivate even though it's not installed.
            // This is because FwkPublic may depend on it (as an embedded framework, imported with @_implementationOnly, etc.)
            // and therefore FwkPublic needs its module interface.
            results.checkTask(.matchTargetName("FwkPrivate"), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                task.checkCommandLineMatches([
                    "builtin-Swift-Compilation-Requirements", "--", .suffix("swiftc"), "-module-name", "FwkPrivate", .anySequence, .and(.prefix("@"), .suffix("SwiftFileList")), .anySequence,
                    "-emit-tbd", "-emit-tbd-path", .equal("/TEST/build/aProject.build/Debug-iphoneos/FwkPrivate.build/Objects-normal/\(arch)/Swift-API.tbd"), .anySequence,
                    // Check we pass the TBD install name.
                    "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/Library/Frameworks/FwkPrivate.framework/FwkPrivate", .anySequence,
                    // Check we forced WMO mode.
                    "-whole-module-optimization", .anySequence,
                ])

                // We shouldn't have a '-c'.
                task.checkCommandLineNoMatch(["-c"])

                // We shouldn't have individual input files
                task.checkCommandLineNoMatch([.suffix("Fwk.swift")])

                // We shouldn't emit an Objective-C compatibility header
                task.checkCommandLineNoMatch(["-emit-objc-header", "-emit-objc-header-path", .equal("/TEST/build/aProject.build/Debug-iphoneos/FwkPrivate.build/Objects-normal/\(arch)/FwkPrivate-Swift.h")])
            }

            results.checkTask(.matchTargetName("FwkPublic"), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                task.checkCommandLineMatches([
                    "builtin-Swift-Compilation-Requirements", "--", .suffix("swiftc"), "-module-name", "FwkPublic", .anySequence, .and(.prefix("@"), .suffix("SwiftFileList")), .anySequence,
                    "-emit-tbd", "-emit-tbd-path", .equal("/TEST/build/aProject.build/Debug-iphoneos/FwkPublic.build/Objects-normal/\(arch)/Swift-API.tbd"), .anySequence,
                    // Check we pass the TBD install name.
                    "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/Library/Frameworks/FwkPublic.framework/FwkPublic", .anySequence,
                    // Check we forced WMO mode.
                    "-whole-module-optimization", .anySequence,
                ])

                // We shouldn't have a '-c'.
                task.checkCommandLineNoMatch(["-c"])

                // We shouldn't have individual input files
                task.checkCommandLineNoMatch([.suffix("Fwk.swift")])

                // We shouldn't emit an Objective-C compatibility header
                task.checkCommandLineNoMatch(["-emit-objc-header", "-emit-objc-header-path", .equal("/TEST/build/aProject.build/Debug-iphoneos/FwkPublic.build/Objects-normal/\(arch)/FwkPublic-Swift.h")])
            }

            results.checkWarning(.prefix("Skipping installAPI swiftmodule emission for target 'BadApp'"))
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftInstallAPIPackageProducts() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let sdkRoot = "macosx"
        let testProject = try await TestPackageProject(
            "ProjectName",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File2.swift"),
                ]),
            targets: [
                TestAggregateTarget("Aggregate", dependencies: ["PackageProduct"]),
                TestStandardTarget(
                    "TargetName",
                    type: .objectFile,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "ARCHS": "x86_64",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                            "TAPI_VERIFY_MODE": "ErrorsOnly",
                            "TAPI_USE_SRCROOT": "NO",
                            "SDKROOT": sdkRoot,
                            // These will be provided in the PIF by SwiftPM.
                            "SUPPORTS_TEXT_BASED_API": "YES",
                            "TAPI_DYLIB_INSTALL_NAME": "ProductName",
                            // This will need to be passed by the user to make InstallAPI for packages opt-in.
                            "INSTALLAPI_IGNORE_SKIP_INSTALL": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File2.swift"),
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "PackageProduct",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "ARCHS": "x86_64",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                            "TAPI_VERIFY_MODE": "ErrorsOnly",
                            "TAPI_USE_SRCROOT": "NO",
                            "SDKROOT": sdkRoot,
                            // These will be provided in the PIF by SwiftPM.
                            "SUPPORTS_TEXT_BASED_API": "YES",
                            "TAPI_DYLIB_INSTALL_NAME": "ProductName",
                            // This will need to be passed by the user to make InstallAPI for packages opt-in.
                            "INSTALLAPI_IGNORE_SKIP_INSTALL": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestFrameworksBuildPhase([TestBuildFile(.target("TargetName"))]),
                        TestSourcesBuildPhase([]), // we need a sources build phase for `willProduceBinary` to return true
                    ]
                ),
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["Gate", "SymLink", "CpHeader", "MkDir", "Touch", "CreateBuildDirectory"])
            results.checkTarget("PackageProduct") { target in
                results.checkNoDiagnostics()

                // Check that we generated correct TAPI installapi invocation.
                results.checkTask(.matchRuleType("GenerateTAPI"), .matchRuleItemBasename("ProductName.tbd"), .matchTarget(target)) { task in
                    // check TAPI options.
                    task.checkCommandLineContains([tapiToolPath.str, "installapi", "--verify-mode=ErrorsOnly"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkBasicsSRCROOTSupportEnabled() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let libClangPath = try await self.libClangPath
        let clangCompilerPath = try await self.clangCompilerPath
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("FwkInternal.h"),
                    TestFile("Fwk.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "CC": clangCompilerPath.str,
                    "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                    "SKIP_INSTALL": "NO",
                    "DEFINES_MODULE": "YES",
                    "CLANG_ENABLE_MODULES": "YES",
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "YES"
                ])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public),
                            TestBuildFile("FwkInternal.h")])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()

        try await fs.writePlist(Path("/TEST/Info.plist"), .plDict([:]))

        let tapiVersion = try await discoveredTAPIToolInfo(at: tapiToolPath).toolVersion ?? Version()
        let expectedVersion = TAPIFileList.FormatVersion.latestSupported(forTAPIVersion: tapiVersion).rawValue
        let expectedHeaders: PropertyListItem = .plArray([
            .plDict([
                "type": .plString("public"),
                "path": .plString("/TEST/build/Debug/Fwk.framework/Headers/Fwk.h")
            ])
        ])
        // Check the `installapi` build.
        try await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Fwk.json")) { task, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["version"] == .plString("\(expectedVersion)"))
                #expect(items["headers"] == expectedHeaders)
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),
                    .anySequence,

                    // Check build products search paths
                    "-F/TEST/build/Debug",
                    "-L/TEST/build/Debug",

                        .anySequence,

                    // Check SRCROOT search paths
                    "-iquote", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk-generated-files.hmap",
                    "-I/TEST/build/aProject.build/Debug/Fwk.build/Fwk-own-target-headers.hmap",
                    "-I/TEST/build/aProject.build/Debug/Fwk.build/Fwk-all-target-headers.hmap",
                    "-iquote", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk-project-headers.hmap",

                        .anySequence,


                    // Check IO options.
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",
                ])
            }
        }

        // Check the `install` build, which should run the same steps but also provide the binary for comparison purposes.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: ["RETAIN_RAW_BINARIES": "YES"]), runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }

            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi",
                    "-verify-against", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                    "--verify-mode=ErrorsOnly",
                    .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                        .anySequence,

                    // Check build products search paths
                    "-F/TEST/build/Debug/BuiltProducts",
                    "-L/TEST/build/Debug/BuiltProducts",

                        .anySequence,

                    // Check SRCROOT search paths
                    "-iquote", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk-generated-files.hmap",
                    "-I/TEST/build/aProject.build/Debug/Fwk.build/Fwk-own-target-headers.hmap",
                    "-I/TEST/build/aProject.build/Debug/Fwk.build/Fwk-all-target-headers.hmap",
                    "-iquote", "/TEST/build/aProject.build/Debug/Fwk.build/Fwk-project-headers.hmap",

                        .anySequence,

                    // Check IO options.
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",
                ])
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func filelistSkipsExcludedHeaders() async throws {

        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("Fwk-iOS.h"),
                    TestFile("Fwk-Excluded.h"),
                    TestFile("Fwk.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "auto",
                    "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_ENABLE_PROJECT_HEADERS": "YES",
                    "EXCLUDED_SOURCE_FILE_NAMES": "Fwk-Excluded.h"])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public),
                            TestBuildFile("Fwk-iOS.h", headerVisibility: .public, platformFilters: PlatformFilter.iOSFilters),
                            TestBuildFile("Fwk-Excluded.h", headerVisibility: .public)])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()

        try await fs.writePlist(Path("/TEST/Info.plist"), .plDict([:]))

        let expectedMacOSHeaders: PropertyListItem = .plArray([
            .plDict([
                "type": .plString("public"),
                "path": .plString("/TEST/build/Debug/Fwk.framework/Headers/Fwk.h")
            ])
        ])

        let expectedIOSHeaders: PropertyListItem = .plArray([
            .plDict([
                "type": .plString("public"),
                "path": .plString("/TEST/build/Debug-iphoneos/Fwk.framework/Headers/Fwk.h")
            ]),
            .plDict([
                "type": .plString("public"),
                "path": .plString("/TEST/build/Debug-iphoneos/Fwk.framework/Headers/Fwk-iOS.h")
            ])
        ])

        try await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Fwk.json")) { task, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["headers"] == expectedMacOSHeaders)
            }
        }

        try await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .iOS, fs: fs) { results in
            results.checkNoDiagnostics()
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Fwk.json")) { task, contents in
                let data = try PropertyList.fromJSONData(contents)
                guard case let .plDict(items) = data else {
                    Issue.record("unexpected data: \(data)")
                    return
                }
                #expect(items["headers"] == expectedIOSHeaders)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkBasicsRPathAndDSYM() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let tapiVersion = try await discoveredTAPIToolInfo(at: tapiToolPath).toolVersion
        guard let version = tapiVersion,
              version >= TAPIToolSpec.dSYMSupportRequiredVersion else {
            return
        }

        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("Fwk.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "-",
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "GCC_GENERATE_DEBUGGING_SYMBOLS" : "YES",
                    "DEBUG_INFORMATION_FORMAT" : "dwarf-with-dsym",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_LANGUAGE": "objective-c++",
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                    "SKIP_INSTALL": "NO"])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()

        try await fs.writePlist(Path("/TEST/Info.plist"), .plDict([:]))

        // Check the `installapi` build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                        .anySequence,
                    "-rpath", "@executable_path/../Frameworks", .anySequence,
                    "-rpath", "@loader_path/../Frameworks", .anySequence,

                    "-x", "objective-c++", .anySequence,

                    // Check IO options.
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",
                ])
                task.checkCommandLineNoMatch([.prefix("--dsym=")])

            }
            results.checkNoTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("Fwk.framework.dSYM"))
        }

        // Check the `install` build, which should run the same steps but also provide the binary for comparison purposes.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: ["RETAIN_RAW_BINARIES": "YES"]), runDestination: .macOS, fs: fs) { results in

            // Validate that dSYM generation happens before GenerationTAPI task.
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }
            results.checkTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("Fwk.framework.dSYM")) { task in
                task.checkCommandLine([ "dsymutil", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                                        "-o", "/TEST/build/Debug/Fwk.framework.dSYM"])
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", .anySequence,
                    "-verify-against", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk", .anySequence,
                    "--verify-mode=ErrorsOnly", .anySequence,
                    "-target", StringPattern.prefix("x86_64-apple"),
                    .anySequence,

                    // Check RPaths.
                    "-rpath", "@executable_path/../Frameworks", .anySequence,
                    "-rpath", "@loader_path/../Frameworks", .anySequence,

                    "-x", "objective-c++", .anySequence,

                    // Check IO options.
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd", .anySequence,

                    // Check dSYM Path.
                    "--dsym=/TEST/build/Debug/Fwk.framework.dSYM"
                ])
            }
            results.checkTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLineMatches([
                    .suffix("codesign"), .anySequence,
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkBasicsDisableDSYM() async throws {
        let tapiToolPath = try await self.tapiToolPath
        let tapiVersion = try await discoveredTAPIToolInfo(at: tapiToolPath).toolVersion
        guard let version = tapiVersion,
              version >= TAPIToolSpec.dSYMSupportRequiredVersion else {
            return
        }

        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.h"),
                    TestFile("Fwk.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "-",
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "GCC_GENERATE_DEBUGGING_SYMBOLS" : "YES",
                    "TAPI_READ_DSYM" : "NO",
                    "DEBUG_INFORMATION_FORMAT" : "dwarf-with-dsym",
                    "TAPI_EXEC": tapiToolPath.str,
                    "TAPI_VERIFY_MODE": "ErrorsOnly",
                    "TAPI_USE_SRCROOT": "NO",
                    "TAPI_LANGUAGE": "objective-c++",
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                    "SKIP_INSTALL": "NO"])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.c"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Fwk.h", headerVisibility: .public)])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()

        try await fs.writePlist(Path("/TEST/Info.plist"), .plDict([:]))

        // Check the `installapi` build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", "--verify-mode=ErrorsOnly", .anySequence,

                    "-target", StringPattern.prefix("x86_64-apple"),

                        .anySequence,
                    "-rpath", "@executable_path/../Frameworks", .anySequence,
                    "-rpath", "@loader_path/../Frameworks", .anySequence,

                    "-x", "objective-c++", .anySequence,

                    // Check IO options.
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd",
                ])
                task.checkCommandLineNoMatch([.prefix("--dsym=")])

            }
            results.checkNoTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("Fwk.framework.dSYM"))
        }

        // Check the `install` build, which should run the same steps but also provide the binary for comparison purposes.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: ["RETAIN_RAW_BINARIES": "YES"]), runDestination: .macOS, fs: fs) { results in

            // Validate that dSYM generation happens before GenerationTAPI task.
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CpHeader")) { task in
                task.checkCommandLineMatches([
                    "builtin-copy", .anySequence, "/TEST/Sources/Fwk.h",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Headers"])
            }
            results.checkTask(.matchRuleType("SymLink"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLine([
                    "/bin/ln", "-sfh",
                    "Versions/Current/Fwk.tbd",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Fwk.tbd"])
            }
            results.checkTask(.matchRuleType("GenerateTAPI")) { task in
                // check TAPI options.
                task.checkCommandLineMatches([
                    StringPattern.equal(tapiToolPath.str), "installapi", .anySequence,
                    "-verify-against", "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk", .anySequence,
                    "--verify-mode=ErrorsOnly", .anySequence,
                    "-target", StringPattern.prefix("x86_64-apple"),
                    .anySequence,

                    // Check RPaths.
                    "-rpath", "@executable_path/../Frameworks", .anySequence,
                    "-rpath", "@loader_path/../Frameworks", .anySequence,

                    "-x", "objective-c++", .anySequence,

                    // Check IO options.
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework",
                    "-filelist" ,"/TEST/build/aProject.build/Debug/Fwk.build/Fwk.json",
                    "-o",
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd", .anySequence,
                ])
                task.checkCommandLineNoMatch([.prefix("--dsym=")])
            }
            results.checkTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("Fwk.tbd")) { task in
                task.checkCommandLineMatches([
                    .suffix("codesign"), .anySequence,
                    "/tmp/aProject.dst/Library/Frameworks/Fwk.framework/Versions/A/Fwk.tbd"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftModuleEmissionCriteria() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("App.swift"),
                    TestFile("Fwk.swift"),
                    TestFile("StaticLib.swift"),
                    TestFile("StaticLib2.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "SKIP_INSTALL": "NO"
                ])],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["App.swift"])
                    ], dependencies: ["Fwk"]),
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])
                    ], dependencies: ["StaticLib"]),
                TestStandardTarget(
                    "StaticLib",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["StaticLib.swift"])
                    ], dependencies: ["StaticLib2"]),
                TestStandardTarget(
                    "StaticLib2",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["StaticLib2.swift"])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        // Even though SUPPORTS_TEXT_BASED_API=YES is global for the project, don't emit a swiftmodule for the app target because it doesn't emit a TBD, and isn't a dependency of any target which emits a TBD.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkWarning(.prefix("Skipping installAPI swiftmodule emission for target 'App'"))
            results.checkNoDiagnostics()
            results.checkTarget("App") { appTarget in
                results.checkNoTask(.matchTarget(appTarget), .matchRuleType("SwiftDriver Compilation Requirements"))
            }
            results.checkTarget("Fwk") { fwkTarget in
                results.checkTaskExists(.matchTarget(fwkTarget), .matchRuleType("SwiftDriver Compilation Requirements"))
            }
            results.checkTarget("StaticLib") { libTarget in
                results.checkTaskExists(.matchTarget(libTarget), .matchRuleType("SwiftDriver Compilation Requirements"))
            }
            results.checkTarget("StaticLib2") { libTarget in
                results.checkTaskExists(.matchTarget(libTarget), .matchRuleType("SwiftDriver Compilation Requirements"))
            }
        }
    }
}
