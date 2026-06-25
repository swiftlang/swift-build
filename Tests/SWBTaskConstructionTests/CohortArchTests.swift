//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025-2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing
import SWBUtil
import SWBProtocol
@_spi(Testing) import SWBCore
import SWBTaskConstruction
import SWBTestSupport

@Suite
fileprivate struct CohortArchTests: CoreBasedTests {

    // MARK: Initialization


    private var LIBTOOL: String!
    private var LD: String!

    init() async throws {
        LIBTOOL = try await libtoolPath.str
        LD = try await {
            let core = try await getCore()
            let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain, "couldn't find the default toolchain")
            let executableSearchPaths = core.createExecutableSearchPaths(userInfo: nil, platform: nil, toolchains: [defaultToolchain], fs: localFS)

            let ld = executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "ld")

            return try #require(ld, "couldn't find ld in default toolchain").str
        }()
    }


    // MARK: Utility variables and methods


    private let baseArch = "arch.base"
    private let cohortArch = "arch.cohort"
    private let soloArch = "arch.solo"

    /// Create and return a Core object with the synthetic architecture xcspecs these tests use.
    private func makeCore(_ tmpDir: NamedTemporaryDirectory) async throws -> Core {
        // Write the synthetic spec file.
        try await localFS.writePlist(tmpDir.path.join("TestArchs.xcspec"), .plArray([
            .plDict([
                "_Domain": .plString("embedded"),
                "Identifier": .plString(baseArch),
                "Type": .plString("Architecture"),
                "CohortArchitecture": .plString(baseArch),
            ]),
            .plDict([
                "_Domain": .plString("embedded"),
                "Identifier": .plString(cohortArch),
                "Type": .plString("Architecture"),
                "CohortArchitecture": .plString(baseArch),
            ]),
            .plDict([
                "_Domain": .plString("embedded"),
                "Identifier": .plString(soloArch),
                "Type": .plString("Architecture"),
                // No CohortArchitecture property
            ]),
        ]))

        let core = try await Self.makeCore(simulatedInferiorProductsPath: tmpDir.path)

        return core
    }

    private let appTargetName = "ApplicationTarget"
    private let fwkTargetName = "FrameworkTarget"
    private let libTargetName = "LibraryTarget"

    private let abiBaselinesDir = Path.root.join("tmp/abi_baselines")
    private let abiOutputDir = Path.root.join("tmp/abi_output")

    private let CONFIGURATION = "Config"

    /// Create and return a `TestWorkspace` common to many of the tests in this suite.
    private func makeTestWorkspace() async throws -> TestWorkspace {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                path: "Sources",
                children: [
                    // Application target files.
                    TestFile("AppFile.m"),

                    // Framework target files.
                    TestFile("CFile.c"),
                    TestFile("CPPFile.cpp"),
                    TestFile("SwiftFile.swift"),
                    TestFile("Framework-Prefix.pch"),

                    // Static library target files.
                    TestFile("LibraryFileOne.m"),
                    TestFile("LibraryFileTwo.m"),
                ]
            ),
            buildConfigurations: [TestBuildConfiguration(
                CONFIGURATION,
                buildSettings: [
                    "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                    "ARCHS": "",        // Will be filled in by the build request
                    "CLANG_USE_RESPONSE_FILE": "NO",
                    "CODE_SIGN_IDENTITY": "-",
                    "PRELINK_TOOL": LD,
                    "LIBTOOL": LIBTOOL,
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "iphoneos",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                ]
            )],
            targets: [
                // An application target, also the top-level target.
                TestStandardTarget(
                    appTargetName,
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration(CONFIGURATION)],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AppFile.m",
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("\(fwkTargetName).framework"),
                            TestBuildFile(("lib\(libTargetName).a")),
                        ]),
                    ],
                    dependencies: [
                        TestTargetDependency(fwkTargetName),
                        TestTargetDependency(libTargetName),
                    ]
                ),
                // A framework target using a C file and a Swift file.
                TestStandardTarget(
                    fwkTargetName,
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration(CONFIGURATION, buildSettings: [
                        "CLANG_ENABLE_MODULES": "YES",
                        "CLANG_ENABLE_EXPLICIT_MODULES": "YES",
                        "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                        "GCC_PREFIX_HEADER": "Sources/Framework-Prefix.pch",
                        "GCC_PRECOMPILE_PREFIX_HEADER": "YES",

                        // Swift ABI checker settings.
                        "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                        "RUN_SWIFT_ABI_CHECKER_TOOL": "YES",
                        "SWIFT_ABI_CHECKER_BASELINE_DIR": abiBaselinesDir.str,
                        "RUN_SWIFT_ABI_GENERATION_TOOL": "YES",
                        "SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR": abiOutputDir.str,

                        // Moduler verifier settings.
                        "DEFINES_MODULE": "YES",
                        "ENABLE_MODULE_VERIFIER": "YES",
                        "MODULE_VERIFIER_KIND": "external",     // external gives us fewer tasks to match; can switch to builtin in the future if necessary
                    ])],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "CFile.c",
                            "CPPFile.cpp",
                            "SwiftFile.swift",
                        ]),
                    ]
                ),
                // A static library target which prelinks its objects.
                TestStandardTarget(
                    libTargetName,
                    type: .staticLibrary,
                    buildConfigurations: [TestBuildConfiguration(CONFIGURATION,
                        buildSettings: [
                            "GENERATE_PRELINK_OBJECT_FILE": "YES",
                        ]
                    )],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "LibraryFileOne.m",
                            "LibraryFileTwo.m",
                        ]),
                    ]
                ),
            ]
        )
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        return testWorkspace
    }


    // MARK: Tests


    /// General test for cohort arch support.
    ///
    /// The general principle is that different targets are exercising different pieces of functionality which are behave differently when building with cohort archs, so not everything is clustered under a single target.
    @Test(.requireSDKs(.iOS))
    func testCohortArchSupport() async throws {
        try await withTemporaryDirectory(fs: localFS) { (tmpDir: NamedTemporaryDirectory) in
            let core = try await makeCore(tmpDir)

            let testWorkspace = try await makeTestWorkspace()
            let tester = try TaskConstructionTester(core, testWorkspace)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            let IPHONEOS_DEPLOYMENT_TARGET = core.loadSDK(.iOS).defaultDeploymentTarget

            let fs = PseudoFS()
            try await fs.writeJSON(abiBaselinesDir.join("ABI/\(baseArch)-ios.json"), .plDict([:]))
            try await fs.writeJSON(abiBaselinesDir.join("ABI/\(soloArch)-ios.json"), .plDict([:]))

            let archs = [baseArch, cohortArch]
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "ARCHS": archs.joined(separator: " "),
                "ENABLE_COHORT_ARCHS": "YES",
            ])
            guard let target = tester.workspace.projects[0].targets.first.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }) else {
                Issue.record("Could not find top level target for project")
                return
            }
            let request = BuildRequest(parameters: parameters, buildTargets: [target], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            let runDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: "iphoneos", targetArchitecture: baseArch, supportedArchitectures: archs, disableOnlyActiveArch: true)
            await tester.checkBuild(runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes(["AppIntentsSSUTraining", "ClangStatCache", "CodeSign", "CreateBuildDirectory", "Gate", "GenerateDSYMFile", "GenerateTAPI", "IntentDefinitionCompile", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "Validate"])

                results.checkNoDiagnostics()

                results.checkTarget(fwkTargetName) { target in
                    // ExtractAppIntentsMetadata uses and generated some files based on the arch, but only for the base arch, not the cohort arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("ExtractAppIntentsMetadata")) { task in
                        task.checkCommandLineContainsUninterrupted(["--target-triple", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--target-triple", "\(cohortArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--binary-file", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).framework/\(target.target.name)"])
                        // Inputs and outputs that are present for the base arch and not the cohort arch.
                        task.checkCommandLineContainsUninterrupted(["--dependency-file", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/\(target.target.name)_dependency_info.dat"])
                        task.checkCommandLineContainsUninterrupted(["--stringsdata-file", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/ExtractedAppShortcutsMetadata.stringsdata"])
                        task.checkCommandLineContainsUninterrupted(["--source-file-list", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/\(target.target.name).SwiftFileList"])
                        task.checkCommandLineContainsUninterrupted(["--swift-const-vals-list", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/\(target.target.name).SwiftConstValuesFileList"])
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name)_dependency_info.dat")
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/ExtractedAppShortcutsMetadata.stringsdata")
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name).SwiftFileList")
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name).SwiftConstValuesFileList")
                    }

                    // Check the ScanDependencies tasks which exist for clang explicit modules.
                    results.checkTask(.matchTarget(target), .matchRuleItem("ScanDependencies"), .matchRuleItemBasename("CFile.o"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/CFile.o"])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleItem("ScanDependencies"), .matchRuleItemBasename("Framework-Prefix.pch"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        task.checkCommandLineMatches(["-o", StringPattern.suffix("Framework-Prefix.pch.gch")])
                    }

                    // There doesn't seem to be an equivalent way to check for Swift explicit modules in a task construction test.

                    // Check the precompiled header tasks.
                    results.checkTask(.matchTarget(target), .matchRuleItem("ProcessPCH"), .matchRuleItemBasename("Framework-Prefix.pch"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        task.checkCommandLineMatches(["-o", StringPattern.suffix("Framework-Prefix.pch.gch")])
                        #expect(task.execDescription == "Precompile Framework-Prefix.pch (\(archs.joined(separator: ", ")))")
                    }
                    results.checkTask(.matchTarget(target), .matchRuleItem("ProcessPCH++"), .matchRuleItemBasename("Framework-Prefix.pch"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        task.checkCommandLineMatches(["-o", StringPattern.suffix("Framework-Prefix.pch.gch")])
                        #expect(task.execDescription == "Precompile Framework-Prefix.pch (\(archs.joined(separator: ", ")))")
                    }

                    // Check the compilation tasks.  We expect there to be tasks for the base arch, but not the cohort arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CFile.o"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/CFile.o"])
                        #expect(task.execDescription == "Compile CFile.c (\(archs.joined(separator: ", ")))")
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CFile.o"))
                    results.checkTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CPPFile.o"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/CPPFile.o"])
                        #expect(task.execDescription == "Compile CPPFile.cpp (\(archs.joined(separator: ", ")))")
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CPPFile.o"))
                    results.checkTask(.matchTarget(target), .matchRuleItem("SwiftDriver Compilation Requirements"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch,])
                        #expect(task.execDescription == "Unblock downstream dependents of \(target.target.name) (\(archs.joined(separator: ", ")))")
                    }
                    results.checkTask(.matchTarget(target), .matchRuleItem("SwiftDriver Compilation"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch,])
                        #expect(task.execDescription == "Compile \(target.target.name) (\(archs.joined(separator: ", ")))")
                    }

                    // Check that we copy the content to the .swiftmodule for only the base arch.
                    // We will implicitly catch any unexpected copies below when we check that we've matched all tasks.
                    results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(baseArch)-apple-ios.swiftmodule")), .matchRuleItemPattern(.suffix("\(baseArch)/FrameworkTarget.swiftmodule"))) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/Project/\(baseArch)-apple-ios.swiftsourceinfo")), .matchRuleItemPattern(.suffix("\(baseArch)/FrameworkTarget.swiftsourceinfo"))) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(baseArch)-apple-ios.abi.json")), .matchRuleItemPattern(.suffix("\(baseArch)/FrameworkTarget.abi.json"))) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(baseArch)-apple-ios.swiftdoc")), .matchRuleItemPattern(.suffix("\(baseArch)/FrameworkTarget.swiftdoc"))) { _ in }

                    // Check that we are only generating the .swiftinterface file for the base arch (we're generating them because BUILD_LIBRARY_FOR_DISTRIBUTION is enabled),
                    // and that we're only running the ABI checker and generating ABI baselines for the base arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(baseArch)-apple-ios.swiftinterface")), .matchRuleItemPattern(.suffix("\(baseArch)/FrameworkTarget.swiftinterface"))) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(baseArch)-apple-ios.private.swiftinterface")), .matchRuleItemPattern(.suffix("\(baseArch)/FrameworkTarget.private.swiftinterface"))) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleItem("CheckSwiftABI"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-baseline-path", "\(abiBaselinesDir.str)/ABI/\(baseArch)-ios.json"])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleItem("GenerateSwiftABIBaseline"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-o", "\(abiOutputDir.str)/\(baseArch)-ios.json"])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleItem("SwiftDriver Interface Verification"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        #expect(task.execDescription == "Verify module interface of \(target.target.name) (\(archs.joined(separator: ", ")))")
                    }

                    // Check the linker tasks and the contents of the link-file-lists.
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix("\(target.target.name).LinkFileList"))) { task, contents in
                        task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/\(target.target.name).LinkFileList"])
                        let contentsLines = contents.asString.dropLast().components(separatedBy: .newlines)
                        #expect(contentsLines == [
                            "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/CFile.o",
                            "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/CPPFile.o",
                            "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/SwiftFile.o",
                      ])
                        #expect(task.execDescription == "Write \((target.target.name)).LinkFileList (\(archs.joined(separator: ", ")))")
                    }
                    results.checkTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name)) { task in
                        task.checkCommandLineContains([
                            ["clang++"],
                            ["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)", "-target-arch-variant", cohortArch],
                            ["-o", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).framework/\(target.target.name)"]
                        ].reduce([], +))
                        #expect(task.execDescription == "Link \(target.target.name) (\(archs.joined(separator: ", ")))")
                    }

                    // There's only one of these.
                    results.checkTask(.matchTarget(target), .matchRuleItem("SwiftMergeGeneratedHeaders")) { task in
                        task.checkCommandLineContainsUninterrupted(["-arch", baseArch])
                        // We don't generate headers for the cohort archs.
                        task.checkCommandLineDoesNotContain(cohortArch)
                    }

                    // Check that the module verifier only runs on the base arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemBasename("module.modulemap")) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleItem("VerifyModule")) { task in
                        task.checkCommandLineContainsUninterrupted(["--target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineDoesNotContain("\(cohortArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)")
                    }

                    results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                    results.checkNoTask(.matchTarget(target))
                }

                results.checkTarget(libTargetName) { target in
                    // Check the compilation tasks.  We expect there to be tasks for the base arch, but not the cohort arch.
                    for filename in ["LibraryFileOne", "LibraryFileTwo"] {
                        results.checkTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("\(filename).o")) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                            task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/\(filename).o"])
                        }
                        results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("\(filename).o"))
                    }

                    // Check that we're prelinking the object files into a single object file.
                    results.checkTask(.matchTarget(target), .matchRuleItem("PrelinkedObjectLink"), .matchRuleItemBasename("lib\(target.target.name).a-\(baseArch)-prelink.o")) { task in
                        task.checkCommandLineContains([
                            [LD, "-r"],
                            ["-arch", baseArch, "-arch-variant", cohortArch],
                            ["\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/LibraryFileOne.o",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/LibraryFileTwo.o"],
                            ["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/lib\(target.target.name).a-\(baseArch)-prelink.o"]
                        ].reduce([], +))
                        #expect(task.execDescription == "Link lib\(target.target.name).a-\(baseArch)-prelink.o")
                    }

                    // Check the libtool tasks are only linking the single object file from the prelink.
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix("\(target.target.name).LinkFileList"))) { task, contents in
                        task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/\(target.target.name).LinkFileList"])
                        let contentsLines = contents.asString.dropLast().components(separatedBy: .newlines)
                        #expect(contentsLines == [
                            "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/lib\(target.target.name).a-\(baseArch)-prelink.o",
                      ])
                        #expect(task.execDescription == "Write \((target.target.name)).LinkFileList (\(archs.joined(separator: ", ")))")
                    }
                    results.checkTask(.matchTarget(target), .matchRuleItem("Libtool"), .matchRuleItemBasename("lib\(target.target.name).a")) { task in
                        task.checkCommandLineContains([
                            [LIBTOOL, "-static"],
                            ["-arch_only", baseArch, "-arch_variant", cohortArch],
                            ["-o", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/lib\(target.target.name).a"]
                        ].reduce([], +))
                        #expect(task.execDescription == "Create static library lib\(target.target.name).a (\(archs.joined(separator: ", ")))")
                    }

                    results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                    results.checkNoTask(.matchTarget(target))
                }

                results.checkTarget(appTargetName) { target in
                    // Check the compilation tasks.  We expect there to be tasks for the base arch, but not the cohort arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("AppFile.m"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/AppFile.o"])
                    }

                    // Check the linker task and the contents of the link-file-list.
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix("\(target.target.name).LinkFileList"))) { task, contents in
                        task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/\(target.target.name).LinkFileList"])
                        let contentsLines = contents.asString.dropLast().components(separatedBy: .newlines)
                        #expect(contentsLines == [
                            "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/AppFile.o",
                      ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContains([
                            ["clang"],
                            ["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)", "-target-arch-variant", cohortArch],
                            ["-o", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).app/\(target.target.name)"]
                        ].reduce([], +))
                    }

                    results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                    results.checkNoTask(.matchTarget(target))
                }

                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkNoTask()
            }
        }
    }

    /// Test building the cohort archs along with the solo arch,
    @Test(.requireSDKs(.iOS))
    func testCohortArchsWithSoloArch() async throws {
        try await withTemporaryDirectory(fs: localFS) { (tmpDir: NamedTemporaryDirectory) in
            let core = try await makeCore(tmpDir)

            let testWorkspace = try await makeTestWorkspace()
            let tester = try TaskConstructionTester(core, testWorkspace)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            let IPHONEOS_DEPLOYMENT_TARGET = core.loadSDK(.iOS).defaultDeploymentTarget

            let fs = PseudoFS()
            try await fs.writeJSON(abiBaselinesDir.join("ABI/\(baseArch)-ios.json"), .plDict([:]))
            try await fs.writeJSON(abiBaselinesDir.join("ABI/\(soloArch)-ios.json"), .plDict([:]))

            let archs = [soloArch, baseArch, cohortArch]
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "ARCHS": archs.joined(separator: " "),
                "ENABLE_COHORT_ARCHS": "YES",
            ])
            guard let target = tester.workspace.projects[0].targets.first.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }) else {
                Issue.record("Could not find top level target for project")
                return
            }
            let request = BuildRequest(parameters: parameters, buildTargets: [target], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            let runDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: "iphoneos", targetArchitecture: baseArch, supportedArchitectures: archs, disableOnlyActiveArch: true)
            await tester.checkBuild(runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes(["AppIntentsSSUTraining", "CodeSign", "CreateBuildDirectory", "Gate", "GenerateDSYMFile", "GenerateTAPI", "IntentDefinitionCompile", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "Validate"])

                results.checkNoDiagnostics()

                results.checkTarget(fwkTargetName) { target in
                    // ExtractAppIntentsMetadata uses and generated some files based on the arch, but only for the base arch and the solo arch, not the cohort arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("ExtractAppIntentsMetadata")) { task in
                        task.checkCommandLineContainsUninterrupted(["--target-triple", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--target-triple", "\(cohortArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--target-triple", "\(soloArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--binary-file", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).framework/\(target.target.name)"])
                        // Inputs and outputs that are present for the base archand the solo arch, and not the cohort arch.
                        for arch in [soloArch, baseArch] {
                            task.checkCommandLineContainsUninterrupted(["--dependency-file", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/\(target.target.name)_dependency_info.dat"])
                            task.checkCommandLineContainsUninterrupted(["--stringsdata-file", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/ExtractedAppShortcutsMetadata.stringsdata"])
                            task.checkCommandLineContainsUninterrupted(["--source-file-list", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/\(target.target.name).SwiftFileList"])
                            task.checkCommandLineContainsUninterrupted(["--swift-const-vals-list", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/\(target.target.name).SwiftConstValuesFileList"])
                        }
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name)_dependency_info.dat")
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/ExtractedAppShortcutsMetadata.stringsdata")
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name).SwiftFileList")
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name).SwiftConstValuesFileList")
                    }

                    // Check that we are only generating the .swiftinterface file for the base and solo archs (we're generating them because BUILD_LIBRARY_FOR_DISTRIBUTION is enabled),
                    // and that we're only running the ABI checker and generating ABI baselines for the base arch.
                    for arch in [soloArch, baseArch] {
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(arch)-apple-ios.swiftinterface")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.swiftinterface"))) { _ in }
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(arch)-apple-ios.private.swiftinterface")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.private.swiftinterface"))) { _ in }
                        results.checkTask(.matchTarget(target), .matchRuleItem("CheckSwiftABI"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineContainsUninterrupted(["-baseline-path", "\(abiBaselinesDir.str)/ABI/\(arch)-ios.json"])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleItem("GenerateSwiftABIBaseline"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineContainsUninterrupted(["-o", "\(abiOutputDir.str)/\(arch)-ios.json"])
                        }
                    }

                    // Check that we have link tasks.
                    for arch in [soloArch, baseArch] {
                        results.checkTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContains([
                                ["clang++"],
                                ["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"],
                                arch == baseArch ? ["-target-arch-variant", cohortArch] : [],
                                ["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/Binary/\(target.target.name)"]
                            ].reduce([], +))
                        }
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(cohortArch))

                    // Check that there's a lipo task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkCommandLineContains([
                            ["lipo", "-create"],
                            ["\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(soloArch)/Binary/\(target.target.name)",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/Binary/\(target.target.name)"],
                            ["-output", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).framework/\(target.target.name)"]
                        ].reduce([], +))
                    }

                    // Check that the module verifier runs on the base arch and the solo arch, but not the cohort arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("VerifyModule")) { task in
                        task.checkCommandLineContainsUninterrupted(["--target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--target", "\(soloArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineDoesNotContain("\(cohortArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)")
                    }

                }

                results.checkTarget(libTargetName) { target in
                    // Check that we have link tasks.
                    for arch in [soloArch, baseArch] {
                        results.checkTask(.matchTarget(target), .matchRuleItem("Libtool"), .matchRuleItemBasename("lib\(target.target.name).a"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContains([
                                [LIBTOOL, "-static"],
                                ["-arch_only", arch],
                                arch == baseArch ? ["-arch_variant", cohortArch] : [],
                                ["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/Binary/lib\(target.target.name).a"]
                            ].reduce([], +))
                        }
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("Libtool"), .matchRuleItemBasename("lib\(target.target.name).a"), .matchRuleItem(cohortArch))

                    // Check that there's a lipo task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkCommandLineContains([
                            ["lipo", "-create"],
                            ["\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(soloArch)/Binary/lib\(target.target.name).a",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/Binary/lib\(target.target.name).a"],
                            ["-output", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/lib\(target.target.name).a"]
                        ].reduce([], +))
                    }
                }

                results.checkTarget(appTargetName) { target in
                    // Check that we have link tasks.
                    for arch in [soloArch, baseArch] {
                        results.checkTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContains([
                                ["clang"],
                                ["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"],
                                arch == baseArch ? ["-target-arch-variant", cohortArch] : [],
                                ["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/Binary/\(target.target.name)"]
                            ].reduce([], +))
                        }
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(cohortArch))

                    // Check that there's a lipo task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkCommandLineContains([
                            ["lipo", "-create"],
                            ["\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(soloArch)/Binary/\(target.target.name)",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/Binary/\(target.target.name)"],
                            ["-output", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).app/\(target.target.name)"]
                        ].reduce([], +))
                    }
                }
            }
        }
    }

    /// Test enabling `ENABLE_COHORT_ARCHS` when the only arch in the cohort we're building for is the base arch.
    ///
    /// The original version of the cohort arch logic contained a bug where the base arch would be elided from the set of archs to build in this scenario.
    @Test(.requireSDKs(.iOS))
    func testCohortArchEnabledWithOnlyOneArch() async throws {
        try await withTemporaryDirectory(fs: localFS) { (tmpDir: NamedTemporaryDirectory) in
            let core = try await makeCore(tmpDir)

            let testWorkspace = try await makeTestWorkspace()
            let tester = try TaskConstructionTester(core, testWorkspace)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            let IPHONEOS_DEPLOYMENT_TARGET = core.loadSDK(.iOS).defaultDeploymentTarget

            let fs = PseudoFS()
            try await fs.writeJSON(abiBaselinesDir.join("ABI/\(baseArch)-ios.json"), .plDict([:]))
            try await fs.writeJSON(abiBaselinesDir.join("ABI/\(soloArch)-ios.json"), .plDict([:]))

            let archs = [soloArch, baseArch]
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "ARCHS": archs.joined(separator: " "),
                "ENABLE_COHORT_ARCHS": "YES",
            ])
            guard let target = tester.workspace.projects[0].targets.first.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }) else {
                Issue.record("Could not find top level target for project")
                return
            }
            let request = BuildRequest(parameters: parameters, buildTargets: [target], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            let runDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: "iphoneos", targetArchitecture: baseArch, supportedArchitectures: archs, disableOnlyActiveArch: true)
            await tester.checkBuild(runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes(["AppIntentsSSUTraining", "CodeSign", "CreateBuildDirectory", "Gate", "GenerateDSYMFile", "GenerateTAPI", "IntentDefinitionCompile", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "Validate"])

                results.checkNoDiagnostics()

                results.checkTarget(fwkTargetName) { target in
                    // ExtractAppIntentsMetadata uses and generated some files based on the arch, but only for the base arch and the solo arch, not the cohort arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("ExtractAppIntentsMetadata")) { task in
                        task.checkCommandLineContainsUninterrupted(["--target-triple", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--target-triple", "\(soloArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineDoesNotContain("\(cohortArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)")
                        task.checkCommandLineContainsUninterrupted(["--binary-file", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).framework/\(target.target.name)"])
                        // Inputs and outputs that are present for the base archand the solo arch, and not the cohort arch.
                        for arch in [soloArch, baseArch] {
                            task.checkCommandLineContainsUninterrupted(["--dependency-file", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/\(target.target.name)_dependency_info.dat"])
                            task.checkCommandLineContainsUninterrupted(["--stringsdata-file", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/ExtractedAppShortcutsMetadata.stringsdata"])
                            task.checkCommandLineContainsUninterrupted(["--source-file-list", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/\(target.target.name).SwiftFileList"])
                            task.checkCommandLineContainsUninterrupted(["--swift-const-vals-list", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/\(target.target.name).SwiftConstValuesFileList"])
                        }
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name)_dependency_info.dat")
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/ExtractedAppShortcutsMetadata.stringsdata")
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name).SwiftFileList")
                        task.checkCommandLineDoesNotContain("\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name).SwiftConstValuesFileList")
                    }

                    // Check that we are only generating the .swiftinterface file for the base and solo archs (we're generating them because BUILD_LIBRARY_FOR_DISTRIBUTION is enabled),
                    // and that we're only running the ABI checker and generating ABI baselines for the base arch.
                    for arch in [soloArch, baseArch] {
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(arch)-apple-ios.swiftinterface")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.swiftinterface"))) { _ in }
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(arch)-apple-ios.private.swiftinterface")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.private.swiftinterface"))) { _ in }
                        results.checkTask(.matchTarget(target), .matchRuleItem("CheckSwiftABI"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineContainsUninterrupted(["-baseline-path", "\(abiBaselinesDir.str)/ABI/\(arch)-ios.json"])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleItem("GenerateSwiftABIBaseline"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineContainsUninterrupted(["-o", "\(abiOutputDir.str)/\(arch)-ios.json"])
                        }
                    }

                    // Check that we have link tasks.
                    for arch in [soloArch, baseArch] {
                        results.checkTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContains([
                                ["clang++"],
                                ["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"],
                                ["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/Binary/\(target.target.name)"]
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-target-arch-variant")
                        }
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(cohortArch))

                    // Check that there's a lipo task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkCommandLineContains([
                            ["lipo", "-create"],
                            ["\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(soloArch)/Binary/\(target.target.name)",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/Binary/\(target.target.name)"],
                            ["-output", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).framework/\(target.target.name)"]
                        ].reduce([], +))
                    }
                }

                results.checkTarget(libTargetName) { target in
                    // Check that we have link tasks.
                    for arch in [soloArch, baseArch] {
                        results.checkTask(.matchTarget(target), .matchRuleItem("Libtool"), .matchRuleItemBasename("lib\(target.target.name).a"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContains([
                                [LIBTOOL, "-static"],
                                ["-arch_only", arch],
                                ["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/Binary/lib\(target.target.name).a"]
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-arch_variant")
                        }
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("Libtool"), .matchRuleItemBasename("lib\(target.target.name).a"), .matchRuleItem(cohortArch))

                    // Check that there's a lipo task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkCommandLineContains([
                            ["lipo", "-create"],
                            ["\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(soloArch)/Binary/lib\(target.target.name).a",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/Binary/lib\(target.target.name).a"],
                            ["-output", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/lib\(target.target.name).a"]
                        ].reduce([], +))
                    }
                }

                results.checkTarget(appTargetName) { target in
                    // Check that we have link tasks.
                    for arch in [soloArch, baseArch] {
                        results.checkTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContains([
                                ["clang"],
                                ["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"],
                                ["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/Binary/\(target.target.name)"]
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-target-arch-variant")
                        }
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(cohortArch))

                    // Check that there's a lipo task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkCommandLineContains([
                            ["lipo", "-create"],
                            ["\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(soloArch)/Binary/\(target.target.name)",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/Binary/\(target.target.name)"],
                            ["-output", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).app/\(target.target.name)"]
                        ].reduce([], +))
                    }
                }
            }
        }
    }

    /// Test that we always select the same base arch for the cohort even when passing run destinations with different target architectures.
    ///
    /// In all cases, `arch.base` should be the primary arch and `arch.cohort` the variant arch.
    @Test(.requireSDKs(.iOS))
    func testCohortBaseArchStability() async throws {
        try await withTemporaryDirectory(fs: localFS) { (tmpDir: NamedTemporaryDirectory) in
            let core = try await makeCore(tmpDir)

            let testWorkspace = try await makeTestWorkspace()
            let tester = try TaskConstructionTester(core, testWorkspace)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            let IPHONEOS_DEPLOYMENT_TARGET = core.loadSDK(.iOS).defaultDeploymentTarget

            let fs = PseudoFS()
            try await fs.writeJSON(abiBaselinesDir.join("ABI/\(baseArch)-ios.json"), .plDict([:]))
            try await fs.writeJSON(abiBaselinesDir.join("ABI/\(soloArch)-ios.json"), .plDict([:]))

            let archs = [baseArch, cohortArch]
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "ARCHS": archs.joined(separator: " "),
                "ENABLE_COHORT_ARCHS": "YES",
            ])
            guard let target = tester.workspace.projects[0].targets.first.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }) else {
                Issue.record("Could not find top level target for project")
                return
            }
            let request = BuildRequest(parameters: parameters, buildTargets: [target], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            // Test with a run destination where the base arch is the target.
            let baseRunDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: "iphoneos", targetArchitecture: baseArch, supportedArchitectures: archs, disableOnlyActiveArch: true)
            await tester.checkBuild(runDestination: baseRunDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes(["AppIntentsSSUTraining", "CodeSign", "CreateBuildDirectory", "Gate", "GenerateDSYMFile", "GenerateTAPI", "IntentDefinitionCompile", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "Validate"])

                results.checkNoDiagnostics()

                results.checkTarget(fwkTargetName) { target in
                    // Check the clang and swift tasks to make sure we're seeing them with the correct options.
                    results.checkTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CFile.o"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/CFile.o"])
                        #expect(task.execDescription == "Compile CFile.c (\(archs.joined(separator: ", ")))")
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CFile.o"))

                    results.checkTask(.matchTarget(target), .matchRuleItem("SwiftDriver Compilation"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch,])
                        #expect(task.execDescription == "Compile \(target.target.name) (\(archs.joined(separator: ", ")))")
                    }
                }
            }

            // Test with a run destination where the cohort arch is the target.
            let cohortRunDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: "iphoneos", targetArchitecture: cohortArch, supportedArchitectures: archs, disableOnlyActiveArch: true)
            await tester.checkBuild(runDestination: cohortRunDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes(["AppIntentsSSUTraining", "CodeSign", "CreateBuildDirectory", "Gate", "GenerateDSYMFile", "GenerateTAPI", "IntentDefinitionCompile", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "Validate"])

                results.checkNoDiagnostics()

                results.checkTarget(fwkTargetName) { target in
                    // Check the clang and swift tasks to make sure we're seeing them with the correct options.
                    results.checkTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CFile.o"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch])
                        task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/CFile.o"])
                        #expect(task.execDescription == "Compile CFile.c (\(archs.joined(separator: ", ")))")
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CFile.o"))

                    results.checkTask(.matchTarget(target), .matchRuleItem("SwiftDriver Compilation"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-target-arch-variant", cohortArch,])
                        #expect(task.execDescription == "Compile \(target.target.name) (\(archs.joined(separator: ", ")))")
                    }
                }
            }
        }
    }

    /// Test that cohort arch support is disabled for archs which declare they are part of a cohort when `ENABLE_COHORT_ARCHS` is `NO`.
    ///
    /// This is to make sure we can disable cohort arch support successfully if we have to.
    @Test(.requireSDKs(.iOS))
    func testDisabledCohortArchSupport() async throws {
        try await withTemporaryDirectory(fs: localFS) { (tmpDir: NamedTemporaryDirectory) in
            let core = try await makeCore(tmpDir)

            let testWorkspace = try await makeTestWorkspace()
            let tester = try TaskConstructionTester(core, testWorkspace)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            let IPHONEOS_DEPLOYMENT_TARGET = core.loadSDK(.iOS).defaultDeploymentTarget

            let fs = PseudoFS()
            try await fs.writeJSON(abiBaselinesDir.join("ABI/\(baseArch)-ios.json"), .plDict([:]))

            let archs = [baseArch, cohortArch]
            let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                "ARCHS": archs.joined(separator: " "),
                "ENABLE_COHORT_ARCHS": "NO",
                "GCC_PRECOMPILE_PREFIX_HEADER": "NO",       // We're not testing PCH generation here
            ])
            guard let fwkTarget = tester.workspace.projects[0].targets[safe: 1].map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }) else {
                Issue.record("Could not find framework target for project")
                return
            }
            let request = BuildRequest(parameters: parameters, buildTargets: [fwkTarget], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
            let runDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: "iphoneos", targetArchitecture: baseArch, supportedArchitectures: archs, disableOnlyActiveArch: true)
            await tester.checkBuild(runDestination: runDestination, buildRequest: request, fs: fs) { results in
                results.consumeTasksMatchingRuleTypes(["AppIntentsSSUTraining", "ClangStatCache", "CodeSign", "CreateBuildDirectory", "Gate", "GenerateDSYMFile", "GenerateTAPI", "IntentDefinitionCompile", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "Validate"])

                results.checkNoDiagnostics()

                results.checkTarget(fwkTargetName) { target in
                    // ExtractAppIntentsMetadata uses the SwiftFileList, so check that it only uses the arm64e one, since we won't generate one for the cohort arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("ExtractAppIntentsMetadata")) { task in
                        task.checkCommandLineContainsUninterrupted(["--target-triple", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--target-triple", "\(cohortArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--source-file-list", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/\(target.target.name).SwiftFileList"])
                        task.checkCommandLineContainsUninterrupted(["--source-file-list", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/\(target.target.name).SwiftFileList"])
                        // These are the outputs of the task
                        task.checkCommandLineContainsUninterrupted(["--stringsdata-file", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/ExtractedAppShortcutsMetadata.stringsdata"])
                        task.checkCommandLineContainsUninterrupted(["--stringsdata-file", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/ExtractedAppShortcutsMetadata.stringsdata"])
                    }

                    // Check that we have separate tasks for each arch.
                    for arch in archs {
                        // Check the ScanDependencies tasks which exist for clang explicit modules.
                        results.checkTask(.matchTarget(target), .matchRuleItem("ScanDependencies"), .matchRuleItemBasename("CFile.o"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineDoesNotContain("-target-arch-variant")
                            task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/CFile.o"])
                        }

                        // There doesn't seem to be an equivalent way to check for Swift explicit modules in a task construction test.

                        // Check the compilation tasks.
                        results.checkTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CFile.o"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineDoesNotContain("-target-arch-variant")
                            task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/CFile.o"])
                        }
                        results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CFile.o"), .matchRuleItem(arch))
                        results.checkTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CPPFile.o"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineDoesNotContain("-target-arch-variant")
                            task.checkCommandLineContainsUninterrupted(["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/CPPFile.o"])
                        }
                        results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileC"), .matchRuleItemBasename("CPPFile.o"), .matchRuleItem(arch))
                        results.checkTask(.matchTarget(target), .matchRuleItem("SwiftDriver Compilation Requirements"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineDoesNotContain("-macho-arch-variant-\(baseArch)")
                            task.checkCommandLineDoesNotContain("-macho-arch-variant-\(cohortArch)")
                        }
                        results.checkTask(.matchTarget(target), .matchRuleItem("SwiftDriver Compilation"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineDoesNotContain("-macho-arch-variant-\(baseArch)")
                            task.checkCommandLineDoesNotContain("-macho-arch-variant-\(cohortArch)")
                        }

                        // Check that we copy the content to the .swiftmodule for each arch.
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(arch)-apple-ios.swiftmodule")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.swiftmodule"))) { _ in }
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/Project/\(arch)-apple-ios.swiftsourceinfo")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.swiftsourceinfo"))) { _ in }
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(arch)-apple-ios.abi.json")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.abi.json"))) { _ in }
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(arch)-apple-ios.swiftdoc")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.swiftdoc"))) { _ in }

                        // Check that we are generating the .swiftinterface file for each arch (we're generating them because BUILD_LIBRARY_FOR_DISTRIBUTION is enabled).
                        // We *probably* should not be generating this for the cohort arch, even when not using the efficient workflow, but that is part of a larger chunk of work in the future. <rdar://163808075>
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(arch)-apple-ios.swiftinterface")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.swiftinterface"))) { _ in }
                        results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemPattern(.suffix("FrameworkTarget.swiftmodule/\(arch)-apple-ios.private.swiftinterface")), .matchRuleItemPattern(.suffix("\(arch)/FrameworkTarget.private.swiftinterface"))) { _ in }

                        results.checkTask(.matchTarget(target), .matchRuleItem("SwiftDriver Interface Verification"), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                            task.checkCommandLineDoesNotContain("-target-arch-variant")
                        }

                        // Check the linker tasks and the contents of the link-file-lists.
                        results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix("\(arch)/\(target.target.name).LinkFileList"))) { task, contents in
                            task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/\(target.target.name).LinkFileList"])
                            let contentsLines = contents.asString.dropLast().components(separatedBy: .newlines)
                            #expect(contentsLines == [
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/CFile.o",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/CPPFile.o",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/SwiftFile.o",
                          ])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleItem("Ld"), .matchRuleItemBasename(target.target.name), .matchRuleItem(arch)) { task in
                            task.checkCommandLineContains([
                                ["clang++"],
                                ["-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"],
                                ["-o", "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(arch)/Binary/\(target.target.name)"]
                            ].reduce([], +))
                        }
                    }

                    // Check tasks which are only generated for one arch.
                    results.checkTask(.matchTarget(target), .matchRuleItem("SwiftMergeGeneratedHeaders")) { task in
                        task.checkCommandLineContainsUninterrupted(["-arch", baseArch])
                        task.checkCommandLineContainsUninterrupted(["-arch", cohortArch])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleItem("CheckSwiftABI"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-baseline-path", "\(abiBaselinesDir.str)/ABI/\(baseArch)-ios.json"])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleItem("GenerateSwiftABIBaseline"), .matchRuleItem(baseArch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["-o", "\(abiOutputDir.str)/\(baseArch)-ios.json"])
                    }

                    // Check that there's a lipo task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkCommandLineContains([
                            ["lipo", "-create"],
                            ["\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(baseArch)/Binary/\(target.target.name)",
                                "\(SRCROOT)/build/aProject.build/\(CONFIGURATION)-iphoneos/\(target.target.name).build/Objects-normal/\(cohortArch)/Binary/\(target.target.name)"],
                            ["-output", "\(SRCROOT)/build/\(CONFIGURATION)-iphoneos/\(target.target.name).framework/\(target.target.name)"]
                        ].reduce([], +))
                    }

                    // Check that the module verifier runs on both archs.
                    results.checkTask(.matchTarget(target), .matchRuleItem("Copy"), .matchRuleItemBasename("module.modulemap")) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleItem("VerifyModule")) { task in
                        task.checkCommandLineContainsUninterrupted(["--target", "\(baseArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                        task.checkCommandLineContainsUninterrupted(["--target", "\(cohortArch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)"])
                    }

                    results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                    results.checkNoTask(.matchTarget(target))
                }

                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkNoTask()
            }
        }
    }

    /// DocC depends on symbol graphs for exactly the archs that are compiled: only base archs when cohorts are folded, all archs when built separately.
    @Test(.requireSDKs(.iOS))
    func testCohortArchSymbolGraphForDocumentation() async throws {
        try await withTemporaryDirectory(fs: localFS) { (tmpDir: NamedTemporaryDirectory) in
            let core = try await makeCore(tmpDir)
            let doccToolPath = try await self.doccToolPath

            let docTargetName = "DocFramework"
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    path: "Sources",
                    children: [
                        TestFile("SwiftFile.swift"),
                        TestFile("DocFramework.docc"),
                    ]
                ),
                buildConfigurations: [TestBuildConfiguration(
                    CONFIGURATION,
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "ARCHS": "",        // Will be filled in by the build request
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "DOCC_EXEC": doccToolPath.str,
                    ]
                )],
                targets: [
                    TestStandardTarget(
                        docTargetName,
                        type: .framework,
                        buildConfigurations: [TestBuildConfiguration(CONFIGURATION)],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SwiftFile.swift",
                                "DocFramework.docc",
                            ]),
                        ]
                    ),
                ]
            )
            let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
            let tester = try TaskConstructionTester(core, testWorkspace)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()
            let sourcesFolder = Path(SRCROOT).join("Sources")
            try fs.createDirectory(sourcesFolder, recursive: true)
            try fs.write(sourcesFolder.join("SwiftFile.swift"), contents: "/* Some Swift content */\n")
            let docsCatalog = sourcesFolder.join("DocFramework.docc")
            try fs.createDirectory(docsCatalog, recursive: true)
            try fs.write(docsCatalog.join("DocFramework.md"), contents: "# ``DocFramework``")

            let archs = [baseArch, cohortArch]
            let runDestination = RunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: "iphoneos", targetArchitecture: baseArch, supportedArchitectures: archs, disableOnlyActiveArch: true)

            // DocC depends on a symbol graph for each compiled arch: just the base arch when folded, every arch otherwise.
            func checkSymbolGraphInputs(enableCohortArchs: Bool, expectCohortMemberInput: Bool) async throws {
                let parameters = BuildParameters(action: .docBuild, configuration: CONFIGURATION, overrides: [
                    "ARCHS": archs.joined(separator: " "),
                    "ENABLE_COHORT_ARCHS": enableCohortArchs ? "YES" : "NO",
                ])
                let target = try #require(tester.workspace.projects[0].targets.first.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }))
                let request = BuildRequest(parameters: parameters, buildTargets: [target], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                await tester.checkBuild(runDestination: runDestination, buildRequest: request, fs: fs) { results in
                    results.checkNoDiagnostics()
                    results.checkTask(.matchRuleItem("CompileDocumentation")) { task in
                        let inputs = task.inputs.map(\.path.str).filter { $0.contains("/symbol-graph/swift/") }
                        #expect(inputs.contains { $0.contains("/symbol-graph/swift/\(baseArch)-") },
                                "Expected a base-arch symbol graph input, found: \(inputs)")
                        #expect(inputs.contains { $0.contains("/symbol-graph/swift/\(cohortArch)-") } == expectCohortMemberInput,
                                "Cohort member symbol graph input: expected \(expectCohortMemberInput), found: \(inputs)")
                    }
                }
            }

            try await checkSymbolGraphInputs(enableCohortArchs: true, expectCohortMemberInput: false)
            try await checkSymbolGraphInputs(enableCohortArchs: false, expectCohortMemberInput: true)
        }
    }

}
