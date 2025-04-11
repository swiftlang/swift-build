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
import SWBTestSupport
import SwiftBuildTestSupport

@_spi(Testing) import SWBUtil
import struct SWBProtocol.RunDestinationInfo
import SWBCore
import class SwiftBuild.SWBBuildService
import SWBTaskExecution

#if canImport(Darwin)
import MachO
#endif

@Suite(.requireXcode16())
fileprivate struct MergeableLibrariesBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.iOS))
    func automaticMergedFrameworkCreation() async throws {
        try await testAutomaticMergedFrameworkCreation(useAppStoreCodelessFrameworksWorkaround: true)
        try await testAutomaticMergedFrameworkCreation(useAppStoreCodelessFrameworksWorkaround: false)
    }

    /// Test automatically creating a merged framework via `MERGED_BINARY_TYPE = automatic` causing its immediate dependencies to be mergeable libraries.
    private func testAutomaticMergedFrameworkCreation(useAppStoreCodelessFrameworksWorkaround: Bool) async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDirPath.join("Workspace"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                // App sources
                                TestFile("Application.swift"),

                                // Mergeable framework and library sources
                                TestFile("ClassOne.swift"),
                                TestFile("ClassTwo.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "COPY_PHASE_STRIP": "NO",
                                "CODE_SIGN_IDENTITY": "-",
                                "GCC_GENERATE_DEBUGGING_SYMBOLS": "YES",
                                "GCC_OPTIMIZATION_LEVEL": "0",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "INSTALL_PATH": "",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "SWIFT_INSTALL_OBJC_HEADER": "NO",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "TAPI_EXEC": tapiToolPath.str,
                                "LIBTOOL": libtoolPath.str,

                                // Force file attribute changes off by default.
                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": "",
                                "INSTALL_MODE_FLAG": "",
                                "SDK_STAT_CACHE_ENABLE": "NO",

                                "ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT": useAppStoreCodelessFrameworksWorkaround ? "NO" : "YES"
                            ])
                        ],
                        targets: [
                            // App target
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug",
                                                           buildSettings: [
                                                            "INSTALL_PATH": "/Applications",
                                                            "SKIP_EMBEDDED_FRAMEWORKS_VALIDATION": "YES",
                                                           ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "Application.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "MergedFwkTarget.framework",
                                    ]),
                                    // Embed
                                    TestCopyFilesBuildPhase([
                                        TestBuildFile("MergedFwkTarget.framework", codeSignOnCopy: true),
                                        TestBuildFile("FwkTarget1.framework", codeSignOnCopy: true),
                                        TestBuildFile("FwkTarget2.framework", codeSignOnCopy: true),
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                ],
                                dependencies: ["MergedFwkTarget"]
                            ),
                            // Merged framework target
                            TestStandardTarget(
                                "MergedFwkTarget",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug",
                                                           buildSettings: [
                                                            "MERGED_BINARY_TYPE": "automatic",
                                                           ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        // There are intentionally no sources for this target, since a common mode is to have a merged framework which does nothing but merge several other frameworks together.
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "FwkTarget1.framework",
                                        "FwkTarget2.framework",
                                    ]),
                                ],
                                // We want to test both explicit and implicit dependencies so not all targets are listed here.
                                dependencies: ["FwkTarget1"]
                            ),
                            // Mergeable framework and library targets
                            TestStandardTarget(
                                "FwkTarget1",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug"),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "ClassOne.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                    ]),
                                ]
                            ),
                            TestStandardTarget(
                                "FwkTarget2",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug"),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "ClassTwo.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                    ]),
                                ]
                            ),
                        ]
                    )
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let signableTargets: Set<String> = Set(tester.workspace.projects[0].targets.map({ $0.name }))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Application.swift")) { contents in
                contents <<< "import UIKit\n";
                contents <<< "    @main\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n";
                contents <<< "    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {\n        return true\n    }\n"
                contents <<< "}\n";
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/ClassOne.swift")) { contents in
                contents <<< "public import UIKit\n\n"
                contents <<< "public func ClassOne(label: UILabel) async {\n    await MainActor.run { label.text = \"Framework One\" }\n}\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/ClassTwo.swift")) { contents in
                contents <<< "public import UIKit\n\n"
                contents <<< "public func ClassTwo(label: UILabel) async {\n    await MainActor.run { label.text = \"Framework Two\" }\n}\n"
            }

            let taskTypesToExclude = Set([
                "Gate", "WriteAuxiliaryFile", "CreateBuildDirectory", "SymLink", "MkDir", "ProcessInfoPlistFile",
                "ClangStatCache", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining",
                "SwiftDriver", "SwiftEmitModule", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders",
                "CopySwiftLibs","RegisterExecutionPolicyException", "RegisterWithLaunchServices", "Validate", "Touch",
                "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports",
            ])

            // Perform a debug build, to check that reexport was properly done, and merging was not.
            do {
                let buildType = "Debug"
                let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: tmpDirPath, for: buildType)
                let parameters = BuildParameters(configuration: "Debug", overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                    "GCC_OPTIMIZATION_LEVEL": "0",
                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                ])
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                try await tester.checkBuild(buildType, parameters: parameters, runDestination: .iOS, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                    // Abort if the build failed (build errors are a proxy for this as the build result is not encoded in the result object).  checkBuild() will emit test issues for any build issues generated.
                    if !results.getDiagnostics(.error).isEmpty {
                        return
                    }

                    results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                    // Check mergeable framework targets.
                    for targetName in ["FwkTarget1", "FwkTarget2"] {
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineDoesNotContain("-make_mergeable")
                            task.checkCommandLineContains(["-o", "\(SYMROOT)/Debug-iphoneos/\(targetName).framework/\(targetName)"])
                        }
                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateTAPI")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    // Check MergedFwkTarget
                    do {
                        let targetName = "MergedFwkTarget"
                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile"))
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains(["-Xlinker", "-no_merge_framework", "-Xlinker", "FwkTarget1"])
                            task.checkCommandLineContains(["-Xlinker", "-no_merge_framework", "-Xlinker", "FwkTarget2"])
                            task.checkCommandLineContains(["-o", "\(SYMROOT)/Debug-iphoneos/\(targetName).framework/\(targetName)"])
                            task.checkCommandLineDoesNotContain("-merge_framework")
                            task.checkCommandLineDoesNotContain("-make_mergeable")
                        }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).framework")) { _ in }
                        // Check that the mergeable frameworks' binaries were copied in and re-signed.
                        for fwkTargetName in ["FwkTarget1", "FwkTarget2"] {
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                                task.checkCommandLineContains(["-include_only_subpath", "\(fwkTargetName)"])
                                task.checkCommandLineContains(["-include_only_subpath", "_CodeSignature"])
                            }
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkTargetName).framework")) { _ in }
                        }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    // Check AppTarget
                    do {
                        let targetName = "AppTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { _ in }
                        // Check that we're excluding the binary when embedding the mergeable targets, but not the merged target.
                        for copiedTargetName in ["FwkTarget1", "FwkTarget2"] {
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(copiedTargetName).framework")) { task in
                                task.checkCommandLineContains(["-exclude_subpath", copiedTargetName])

                                if useAppStoreCodelessFrameworksWorkaround {
                                    results.checkNote(.prefix("Injecting stub binary into codeless framework"))
                                }
                            }
                            _ = results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(copiedTargetName).framework")) { task in
                                if !useAppStoreCodelessFrameworksWorkaround {
                                    // CodeSignTaskAction adds --generate-pre-encrypt-hashes dynamically because it's signing a codeless framework.
                                    results.checkNote(.equal("Signing codeless framework with --generate-pre-encrypt-hashes (for task: \(task.ruleInfo))"))
                                }
                            }
                        }
                        do {
                            let copiedTargetName = "MergedFwkTarget"
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(copiedTargetName).framework")) { task in
                                task.checkCommandLineDoesNotContainUninterrupted(["-exclude_subpath", copiedTargetName])
                            }
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(copiedTargetName).framework")) { _ in }
                        }
                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).app")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    results.checkNoTask(.matchRuleType("Strip"))
                    results.checkNoTask()

#if canImport(Darwin)
                    // Examine that the contents on disk have the expected properties.
                    // First, check that the mergeable frameworks in the SYMROOT were *not* built as mergeable.
                    // Second, check that the mergeable frameworks embedded in the app don't contain their binaries.
                    // Third, check that the mergeable frameworks embedded in the merged framework do contain their binaries.
                    for fwkTargetName in ["FwkTarget1", "FwkTarget2"] {
                        // Reexported
                        do {
                            let fwkPath = Path("\(SYMROOT)/Debug-iphoneos/\(fwkTargetName).framework")
                            #expect(tester.fs.exists(fwkPath), "Could not find framework '\(fwkPath.str)'")
                            let machoPath = fwkPath.join(fwkTargetName)
                            #expect(tester.fs.exists(machoPath), "Could not find framework binary '\(machoPath.str)'")

                            try checkForMergeableMetadata(in: machoPath, fs: tester.fs, expected: false, reason: "it should not have been built mergeable")
                        }

                        // Lacking binary in app
                        do {
                            let fwkPath = Path("\(SYMROOT)/Debug-iphoneos/AppTarget.app/Frameworks/\(fwkTargetName).framework")
                            #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                            let machoPath = fwkPath.join(fwkTargetName)
                            if useAppStoreCodelessFrameworksWorkaround {
                                #expect(tester.fs.exists(machoPath), "Missing framework binary '\(machoPath.str)'")

                                // The binary should be an iOS dylib
                                let macho = try MachO(reader: BinaryReader(data: tester.fs.read(machoPath)))
                                let (slices, linkage) = try macho.slicesIncludingLinkage()
                                #expect(try slices.flatMap { try $0.buildVersions().map(\.platform) }.only == .iOS)
                                #expect(linkage == .macho(.dylib))
                            } else {
                                #expect(!tester.fs.exists(machoPath), "Found unexpected framework binary '\(machoPath.str)'")
                            }
                        }

                        // Including binary in merged framework
                        do {
                            let fwkPath = Path("\(SYMROOT)/Debug-iphoneos/MergedFwkTarget.framework/\(reexportedBinariesDirectoryName)/\(fwkTargetName).framework")
                            #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                            let machoPath = fwkPath.join(fwkTargetName)
                            #expect(tester.fs.exists(machoPath), "Could not find binary '\(machoPath.str)'")
                        }
                    }

                    // Second, check the contents of the merged binary for expected characteristics.
                    do {
                        let targetName = "MergedFwkTarget"
                        let fwkPath = Path("\(SYMROOT)/Debug-iphoneos/\(targetName).framework")
                        #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                        let machoPath = fwkPath.join(targetName)
                        #expect(tester.fs.exists(machoPath), "Could not find framework binary '\(machoPath.str)'")

                        // Check the merged binary.
                        let reader = try BinaryReader(data: tester.fs.read(machoPath))
                        let machO = try MachO(reader: reader)
                        let slices = try machO.slices()
                        #expect(slices.count > 0, "Framework binary contains no slices '\(machoPath.str)'")
                        for slice in slices {
                            // Check that the merged binary is reexporting the mergeable frameworks.
                            let linkedLibraries = try slice.linkedLibraries()
                            for libraryName in ["FwkTarget1", "FwkTarget2"] {
                                let foundLibraries = linkedLibraries.filter { (pathStr: String, linkageType: MachO.Slice.LinkageType) in
                                    Path(pathStr).basename == libraryName
                                }
                                if let library = foundLibraries.first {
                                    #expect(library.linkageType == .reexport)
                                }
                                else {
                                    Issue.record("Could not find load command for reexported framework '\(libraryName)")
                                }
                            }

                            // Check that the merged binary has an rpath into ReexportedBinaries.
                            let expectedRpath = "@loader_path/\(reexportedBinariesDirectoryName)"
                            let foundRpath = (try slice.rpaths().first(where: { $0 == expectedRpath }) != nil)
                            #expect(foundRpath, "Could not find rpath '\(expectedRpath)'")
                        }

                        // Check that the symbols from the mergeable frameworks are *not* present.
                        try await checkForSymbols(in: machoPath, symbolPatterns: ["FwkTarget1.+ClassOne.+label.+UILabel", "FwkTarget2.+ClassTwo.+label.+UILabel"], expected: false)
                    }
#endif
                }
            }

            // Perform a release build, to check merging and associated behaviors.
            do {
                let buildType = "Release"
                let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: tmpDirPath, for: buildType)
                let parameters = BuildParameters(configuration: "Debug", overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "DEPLOYMENT_LOCATION": "YES",
                    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                    "GCC_OPTIMIZATION_LEVEL": "s",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O",
                ])
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                try await tester.checkBuild(buildType, parameters: parameters, runDestination: .iOS, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                    // Abort if the build failed (build errors are a proxy for this as the build result is not encoded in the result object).  checkBuild() will emit test issues for any build issues generated.
                    if !results.getDiagnostics(.error).isEmpty {
                        return
                    }

                    results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                    // Check mergeable framework targets
                    for targetName in ["FwkTarget1", "FwkTarget2"] {
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains("-make_mergeable")
                            task.checkCommandLineContains(["-o", "\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework/\(targetName)"])
                        }
                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateDSYMFile")) { _ in }
                        // Mergeable libraries are not stripped.
                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("Strip"))
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    // Check MergedFwkTarget
                    do {
                        let targetName = "MergedFwkTarget"
                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile"))
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains(["-Xlinker", "-merge_framework", "-Xlinker", "FwkTarget1"])
                            task.checkCommandLineContains(["-Xlinker", "-merge_framework", "-Xlinker", "FwkTarget2"])
                            task.checkCommandLineContains(["-o", "\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework/\(targetName)"])
                            task.checkCommandLineDoesNotContain("-make_mergeable")
                            task.checkCommandLineDoesNotContain("-no_merge_framework")
                        }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Strip")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateDSYMFile")) { task in
                            task.checkCommandLineContains(["-D", "\(SYMROOT)/Debug-iphoneos"])
                        }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    // Check AppTarget
                    do {
                        let targetName = "AppTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { _ in }
                        // Check that we're excluding the binary when embedding the mergeable targets, but not the merged target.
                        for copiedTargetName in ["FwkTarget1", "FwkTarget2"] {
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(copiedTargetName).framework")) { task in
                                task.checkCommandLineContains(["-exclude_subpath", copiedTargetName])

                                if useAppStoreCodelessFrameworksWorkaround {
                                    results.checkNote(.prefix("Injecting stub binary into codeless framework"))
                                }
                            }
                            _ = results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(copiedTargetName).framework")) { task in
                                if !useAppStoreCodelessFrameworksWorkaround {
                                    // CodeSignTaskAction adds --generate-pre-encrypt-hashes dynamically because it's signing a codeless framework.
                                    results.checkNote(.equal("Signing codeless framework with --generate-pre-encrypt-hashes (for task: \(task.ruleInfo))"))
                                }
                            }
                        }
                        do {
                            let copiedTargetName = "MergedFwkTarget"
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(copiedTargetName).framework")) { task in
                                task.checkCommandLineDoesNotContainUninterrupted(["-exclude_subpath", copiedTargetName])
                            }
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(copiedTargetName).framework")) { _ in }
                        }
                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateDSYMFile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Strip")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    results.checkNoTask()

#if canImport(Darwin)
                    // Examine that the contents on disk have the expected properties.
                    // First, check that the mergeable frameworks in the SYMROOT were built as mergeable.
                    // Second, check that the mergeable frameworks in the product don't contain their binaries.
                    for fwkTargetName in ["FwkTarget1", "FwkTarget2"] {
                        // Mergeable
                        do {
                            let fwkPath = Path("\(OBJROOT)/UninstalledProducts/iphoneos/\(fwkTargetName).framework")
                            #expect(tester.fs.exists(fwkPath), "Could not find framework '\(fwkPath.str)'")
                            let machoPath = fwkPath.join(fwkTargetName)

                            try checkForMergeableMetadata(in: machoPath, fs: tester.fs, expected: true, reason: "it should have been built mergeable")
                        }

                        // Lacking binary
                        do {
                            let fwkPath = Path("\(DSTROOT)/Applications/AppTarget.app/Frameworks/\(fwkTargetName).framework")
                            #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                            let machoPath = fwkPath.join(fwkTargetName)
                            if useAppStoreCodelessFrameworksWorkaround {
                                #expect(tester.fs.exists(machoPath), "Missing framework binary '\(machoPath.str)'")

                                // The binary should be an iOS dylib
                                let macho = try MachO(reader: BinaryReader(data: tester.fs.read(machoPath)))
                                let (slices, linkage) = try macho.slicesIncludingLinkage()
                                #expect(try slices.flatMap { try $0.buildVersions().map(\.platform) }.only == .iOS)
                                #expect(linkage == .macho(.dylib))
                            } else {
                                #expect(!tester.fs.exists(machoPath), "Found unexpected framework binary '\(machoPath.str)'")
                            }
                        }
                    }

                    // Finally, check that the merged library contains the symbols from the mergeable libraries.
                    do {
                        let targetName = "MergedFwkTarget"
                        let fwkPath = Path("\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework")
                        #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                        let machoPath = fwkPath.join(targetName)
                        #expect(tester.fs.exists(machoPath), "Could not find framework binary '\(machoPath.str)'")

                        // Check that the merged framework is *not* linking the mergeable frameworks.
                        try checkForLinkedLibraries(in: machoPath, libraryNames: ["FwkTarget1", "FwkTarget2"], fs: tester.fs, expected: false)

                        // Check that the symbols from the mergeable frameworks are present, meaning that they were merged in.
                        try await checkForSymbols(in: machoPath, symbolPatterns: ["T.+FwkTarget1.+ClassOne.+label.+UILabel.+", "T.+FwkTarget2.+ClassTwo.+label.+UILabel.+"], expected: true)
                    }
#endif
                }
            }
        }
    }

    /// Test that building a merged library with targets spanning two projects uses the correct build path.
    @Test(.requireSDKs(.iOS))
    func mergedFrameworkCreationWithMultipleProjects() async throws {
        try await testMergedFrameworkCreationWithMultipleProjects(useAppStoreCodelessFrameworksWorkaround: true)
        try await testMergedFrameworkCreationWithMultipleProjects(useAppStoreCodelessFrameworksWorkaround: false)
    }

    private func testMergedFrameworkCreationWithMultipleProjects(useAppStoreCodelessFrameworksWorkaround: Bool) async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDirPath.join("Workspace"),
                projects: [
                    TestProject(
                        "AppProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("Application.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Config",
                            buildSettings: [
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "COPY_PHASE_STRIP": "NO",
                                "CODE_SIGN_IDENTITY": "-",
                                "GCC_GENERATE_DEBUGGING_SYMBOLS": "YES",
                                "GCC_OPTIMIZATION_LEVEL": "0",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "INSTALL_PATH": "",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "SWIFT_INSTALL_OBJC_HEADER": "NO",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "TAPI_EXEC": tapiToolPath.str,
                                "LIBTOOL": libtoolPath.str,

                                // Force file attribute changes off by default.
                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": "",
                                "INSTALL_MODE_FLAG": "",
                                "SDK_STAT_CACHE_ENABLE": "NO",
                                "ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT": useAppStoreCodelessFrameworksWorkaround ? "NO" : "YES",
                                "SKIP_EMBEDDED_FRAMEWORKS_VALIDATION": "YES",
                            ])
                        ],
                        targets: [
                            // App target
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Config",
                                                           buildSettings: [
                                                            "INSTALL_PATH": "/Applications",
                                                            "MERGED_BINARY_TYPE": "manual",
                                                           ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "Application.swift",
                                    ]),
                                    // FIXME: rdar://119275052 This is not quite right: These references should go through a project reference, but the test infrastructure doesn't support project references. Instead we take advantage of rdar://119010301 which will create a product reference even though the producing target is in another project.
                                    TestFrameworksBuildPhase([
                                        "FwkTarget.framework",
                                    ]),
                                    // Embed
                                    TestCopyFilesBuildPhase([
                                        TestBuildFile("FwkTarget.framework", codeSignOnCopy: true),
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                ]
                            ),
                        ]
                    ),
                    TestProject(
                        "FwkProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("ClassOne.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Config",
                            buildSettings: [
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "COPY_PHASE_STRIP": "NO",
                                "CODE_SIGN_IDENTITY": "-",
                                "GCC_GENERATE_DEBUGGING_SYMBOLS": "YES",
                                "GCC_OPTIMIZATION_LEVEL": "0",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "INSTALL_PATH": "",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "SWIFT_INSTALL_OBJC_HEADER": "NO",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "TAPI_EXEC": tapiToolPath.str,
                                "LIBTOOL": libtoolPath.str,

                                // Force file attribute changes off by default.
                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": "",
                                "INSTALL_MODE_FLAG": "",
                                "SDK_STAT_CACHE_ENABLE": "NO",
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "FwkTarget",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Config",
                                                           buildSettings: [
                                                            "MERGEABLE_LIBRARY": "YES",
                                                           ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "ClassOne.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                    ]),
                                ]
                            ),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT_App = testWorkspace.sourceRoot.join("AppProject")
            let SRCROOT_Fwk = testWorkspace.sourceRoot.join("FwkProject")
            let signableTargets: Set<String> = Set(tester.workspace.projects.flatMap({$0.targets}).map({ $0.name }))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT_App.join("Sources/Application.swift")) { contents in
                contents <<< "import UIKit\n";
                contents <<< "    @main\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n";
                contents <<< "    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {\n        return true\n    }\n"
                contents <<< "}\n";
            }
            try await tester.fs.writeFileContents(SRCROOT_Fwk.join("Sources/ClassOne.swift")) { contents in
                contents <<< "public import UIKit\n\n"
                contents <<< "public func ClassOne(label: UILabel) async {\n    await MainActor.run { label.text = \"Framework One\" }\n}\n"
            }

            let taskTypesToExclude = Set([
                "Gate", "WriteAuxiliaryFile", "CreateBuildDirectory", "SymLink", "MkDir", "ProcessInfoPlistFile",
                "ClangStatCache", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining",
                "SwiftDriver", "SwiftEmitModule", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders",
                "CopySwiftLibs","RegisterExecutionPolicyException", "RegisterWithLaunchServices", "Validate", "Touch",
                "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports",
            ])

            // Perform a debug build, to check that reexport was properly done, and merging was not.
            do {
                let buildType = "Debug"
                let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: tmpDirPath, for: buildType)
                let parameters = BuildParameters(configuration: "Debug", overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEBUG_INFORMATION_FORMAT": "dwarf",        // No dSYM for debug builds
                    "GCC_OPTIMIZATION_LEVEL": "0",
                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                ])
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                try await tester.checkBuild(buildType, parameters: parameters, runDestination: .iOS, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                    // Abort if the build failed (build errors are a proxy for this as the build result is not encoded in the result object).  checkBuild() will emit test issues for any build issues generated.
                    if !results.getDiagnostics(.error).isEmpty {
                        return
                    }

                    results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                    // Check FwkTarget
                    do {
                        let targetName = "FwkTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineDoesNotContain("-make_mergeable")
                            task.checkCommandLineContains(["-o", "\(SYMROOT)/Config-iphoneos/\(targetName).framework/\(targetName)"])
                        }
                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateTAPI")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    // Check AppTarget
                    do {
                        let targetName = "AppTarget"
                        let fwkTargetName = "FwkTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { _ in }
                        // Check that we're embedding and signing the mergeable framework twice: Once with the binary (in ReexportedBinaries), and once without the binary (in Frameworks).
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("Frameworks/\(fwkTargetName).framework"))) { task in
                            task.checkCommandLineContains(["-exclude_subpath", fwkTargetName])

                            if useAppStoreCodelessFrameworksWorkaround {
                                results.checkNote(.prefix("Injecting stub binary into codeless framework"))
                            }
                        }
                        _ = results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix("Frameworks/\(fwkTargetName).framework"))) { task in
                            if !useAppStoreCodelessFrameworksWorkaround {
                                // CodeSignTaskAction adds --generate-pre-encrypt-hashes dynamically because it's signing a codeless framework.
                                results.checkNote(.equal("Signing codeless framework with --generate-pre-encrypt-hashes (for task: \(task.ruleInfo))"))
                            }
                        }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("ReexportedBinaries/\(fwkTargetName).framework"))) { task in
                            task.checkCommandLineContains(["-include_only_subpath", fwkTargetName])
                            task.checkCommandLineContains(["-include_only_subpath", "_CodeSignature"])
                        }
                        _ = results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemPattern(.suffix("ReexportedBinaries/\(fwkTargetName).framework"))) { _ in }
                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).app")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    results.checkNoTask(.matchRuleType("Strip"))
                    results.checkNoTask()

#if canImport(Darwin)
                    // Examine that the contents on disk have the expected properties.
                    // First, check that the mergeable frameworks in the SYMROOT were *not* built as mergeable.
                    // Second, check that the mergeable frameworks embedded in the app's Framework folder don't contain their binaries.
                    // Third, check that the mergeable frameworks embedded in the app's ReexportedBinaries folder do contain their binaries.
                    do {
                        let fwkTargetName = "FwkTarget"
                        // Reexported
                        do {
                            let fwkPath = Path("\(SYMROOT)/Config-iphoneos/\(fwkTargetName).framework")
                            #expect(tester.fs.exists(fwkPath), "Could not find framework '\(fwkPath.str)'")
                            let machoPath = fwkPath.join(fwkTargetName)
                            #expect(tester.fs.exists(machoPath), "Could not find framework binary '\(machoPath.str)'")

                            try checkForMergeableMetadata(in: machoPath, fs: tester.fs, expected: false, reason: "it should not have been built mergeable")
                        }

                        // Lacking binary in app's Frameworks folder.
                        do {
                            let fwkPath = Path("\(SYMROOT)/Config-iphoneos/AppTarget.app/Frameworks/\(fwkTargetName).framework")
                            #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                            let machoPath = fwkPath.join(fwkTargetName)
                            if useAppStoreCodelessFrameworksWorkaround {
                                #expect(tester.fs.exists(machoPath), "Missing framework binary '\(machoPath.str)'")

                                // The binary should be an iOS dylib
                                let macho = try MachO(reader: BinaryReader(data: tester.fs.read(machoPath)))
                                let (slices, linkage) = try macho.slicesIncludingLinkage()
                                #expect(try slices.flatMap { try $0.buildVersions().map(\.platform) }.only == .iOS)
                                #expect(linkage == .macho(.dylib))
                            } else {
                                #expect(!tester.fs.exists(machoPath), "Found unexpected framework binary '\(machoPath.str)'")
                            }
                        }

                        // Including binary in app's ReexportedBinaries folder.
                        do {
                            let fwkPath = Path("\(SYMROOT)/Config-iphoneos/AppTarget.app/\(reexportedBinariesDirectoryName)/\(fwkTargetName).framework")
                            #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                            let machoPath = fwkPath.join(fwkTargetName)
                            #expect(tester.fs.exists(machoPath), "Could not find binary '\(machoPath.str)'")
                        }
                    }

                    // Second, check the contents of the app binary for expected characteristics.
                    // Check that the merged app binary contains the symbols from the mergeable libraries.
                    do {
                        let targetName = "AppTarget"
                        let fwkTargetName = "FwkTarget"
                        let appPath = Path("\(SYMROOT)/Config-iphoneos/\(targetName).app")
                        #expect(tester.fs.isDirectory(appPath), "Could not find app '\(appPath.str)'")
                        let machoPath = appPath.join(targetName)
                        #expect(tester.fs.exists(machoPath), "Could not find app binary '\(machoPath.str)'")

                        // Check the app binary.
                        let reader = try BinaryReader(data: tester.fs.read(machoPath))
                        let machO = try MachO(reader: reader)
                        let slices = try machO.slices()
                        #expect(slices.count > 0, "Framework binary contains no slices '\(machoPath.str)'")
                        for slice in slices {
                            // Check that the app binary is reexporting the mergeable frameworks.
                            let linkedLibraries = try slice.linkedLibraries()
                            let foundLibraries = linkedLibraries.filter { (pathStr: String, linkageType: MachO.Slice.LinkageType) in
                                Path(pathStr).basename == fwkTargetName
                            }
                            if let library = foundLibraries.first {
                                #expect(library.linkageType == .reexport)
                            }
                            else {
                                Issue.record("Could not find load command for reexported framework '\(fwkTargetName)")
                            }

                            // Check that the merged binary has an rpath into ReexportedBinaries.
                            let expectedRpath = "@loader_path/\(reexportedBinariesDirectoryName)"
                            let foundRpath = (try slice.rpaths().first(where: { $0 == expectedRpath }) != nil)
                            #expect(foundRpath, "Could not find rpath '\(expectedRpath)'")
                        }

                        // Check that the symbols from the mergeable frameworks are *not* present.
                        try await checkForSymbols(in: machoPath, symbolPatterns: ["FwkTarget.+ClassOne.+label.+UILabel"], expected: false)
                    }
#endif
                }
            }

            // Perform a release build, to check merging and associated behaviors.
            do {
                let buildType = "Release"
                let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: tmpDirPath, for: buildType)
                let parameters = BuildParameters(configuration: "Config", overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "DEPLOYMENT_LOCATION": "YES",
                    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                    "GCC_OPTIMIZATION_LEVEL": "s",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O",
                    "STRIP_STYLE": "debugging",                    // So we can examine the merged binary to confirm that merging happened
                ])
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                try await tester.checkBuild(buildType, parameters: parameters, runDestination: .iOS, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                    // Abort if the build failed (build errors are a proxy for this as the build result is not encoded in the result object).  checkBuild() will emit test issues for any build issues generated.
                    if !results.getDiagnostics(.error).isEmpty {
                        return
                    }

                    results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                    // Check FwkTarget
                    do {
                        let targetName = "FwkTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains("-make_mergeable")
                            task.checkCommandLineContains(["-o", "\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework/\(targetName)"])
                        }
                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateDSYMFile")) { task in
                            task.checkCommandLineContains(["-o", "\(SYMROOT)/Config-iphoneos/\(targetName).framework.dSYM"])
                        }
                        // Mergeable libraries are not stripped.
                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("Strip"))
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    // Check AppTarget
                    do {
                        let targetName = "AppTarget"
                        let fwkTargetName = "FwkTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains(["-Xlinker", "-merge_library", "-Xlinker", "\(OBJROOT)/UninstalledProducts/iphoneos/\(fwkTargetName).framework/\(fwkTargetName)"])
                            task.checkCommandLineContains(["-o", "\(DSTROOT)/Applications/\(targetName).app/\(targetName)"])
                            task.checkCommandLineDoesNotContain("-make_mergeable")
                            task.checkCommandLineDoesNotContain("-no_merge_framework")
                        }
                        // Check that we're excluding the binary when embedding the mergeable targets, but not the merged target.
                        do {
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkTargetName).framework")) { task in
                                task.checkCommandLineContains(["-exclude_subpath", fwkTargetName])
                            }
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkTargetName).framework")) { _ in }
                        }
                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateDSYMFile")) { task in
                            task.checkCommandLineContains(["-D", "\(SYMROOT)/Config-iphoneos"])
                        }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Strip")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    results.checkNoTask()

#if canImport(Darwin)
                    // Check that the mergeable framework in the product doesn't contain its binary.
                    do {
                        let fwkTargetName = "FwkTarget"
                        let fwkPath = Path("\(DSTROOT)/Applications/AppTarget.app/Frameworks/\(fwkTargetName).framework")
                        #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                        let machoPath = fwkPath.join(fwkTargetName)
                        if useAppStoreCodelessFrameworksWorkaround {
                            #expect(tester.fs.exists(machoPath), "Missing framework binary '\(machoPath.str)'")

                            // The binary should be an iOS dylib
                            let macho = try MachO(reader: BinaryReader(data: tester.fs.read(machoPath)))
                            let (slices, linkage) = try macho.slicesIncludingLinkage()
                            #expect(try slices.flatMap { try $0.buildVersions().map(\.platform) }.only == .iOS)
                            #expect(linkage == .macho(.dylib))
                        } else {
                            #expect(!tester.fs.exists(machoPath), "Found unexpected framework binary '\(machoPath.str)'")
                        }
                    }

                    // Check that the merged app binary contains the symbols from the mergeable libraries.
                    do {
                        let targetName = "AppTarget"
                        let fwkTargetName = "FwkTarget"
                        let appPath = Path("\(DSTROOT)/Applications/\(targetName).app")
                        #expect(tester.fs.isDirectory(appPath), "Could not find app '\(appPath.str)'")
                        let machoPath = appPath.join(targetName)
                        #expect(tester.fs.exists(machoPath), "Could not find app binary '\(machoPath.str)'")

                        // Check that the merged framework is *not* linking the mergeable framework.
                        try checkForLinkedLibraries(in: machoPath, libraryNames: [fwkTargetName], fs: tester.fs, expected: false)

                        // Check that the symbols from the mergeable framework are present, meaning that they were merged in.
                        try await checkForSymbols(in: machoPath, symbolPatterns: ["T.+FwkTarget.+ClassOne.+label.+UILabel.+"], expected: true)
                    }
#endif
                }
            }
        }
    }

    /// Test building an app against an XCFramework where the XCFramework contains mergeable metadata.
    ///
    /// This exercises both merging the XCFramework, and treating it as a regular dylib.
    @Test(.requireSDKs(.iOS))
    func usingMergeableXCFramework() async throws {
        try await testUsingMergeableXCFramework(useAppStoreCodelessFrameworksWorkaround: true)
    }

    func testUsingMergeableXCFramework(useAppStoreCodelessFrameworksWorkaround: Bool) async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let xcode = try await InstalledXcode.currentlySelected()
            let core = try await getCore()
            let service = try await SWBBuildService()

            // Create the XCFrameworks.
            let fwkBaseName = "Framework"
            let fwkSourceContents = "public class ClassOne {\n    public static func value() -> String {\n        return \"ClassOne\"\n    }\n}\n"
            let iosFwk = try await xcode.compileFramework(path: tmpDirPath.join(fwkBaseName), baseName: fwkBaseName, platform: .iOS, infoLookup: core, archs: ["arm64"], sourceContents: fwkSourceContents, useSwift: true, linkerOptions: [.makeMergeable])
            let fwkOutputPath = tmpDirPath.join("Workspace/aProject/Sources/\(fwkBaseName).xcframework")
            do {
                let commandLine = ["createXCFramework", "-framework", iosFwk.str, "-output", fwkOutputPath.str]
                let (success, message) = await service.createXCFramework(commandLine, currentWorkingDirectory: tmpDirPath.str, developerPath: nil)
                guard success else {
                    Issue.record("unable to build '\(fwkOutputPath.basename)': \(message)")
                    return
                }
            }

            let libBaseName = "Library"
            let libSourceContents = "public class ClassTwo {\n    public static func value() -> String {\n        return \"ClassTwo\"\n    }\n}\n"
            let iosLib = try await xcode.compileDynamicLibrary(path: tmpDirPath.join(libBaseName), baseName: libBaseName, platform: .iOS, infoLookup: core, archs: ["arm64"], sourceContents: libSourceContents, useSwift: true, linkerOptions: [.makeMergeable])
            let libOutputPath = tmpDirPath.join("Workspace/aProject/Sources/\(libBaseName).xcframework")
            do {
                let commandLine = ["createXCFramework", "-library", iosLib.str, "-output", libOutputPath.str]
                let (success, message) = await service.createXCFramework(commandLine, currentWorkingDirectory: tmpDirPath.str, developerPath: nil)
                guard success else {
                    Issue.record("unable to build '\(libOutputPath.basename)': \(message)")
                    return
                }
            }

            let CONFIGURATION = "Config"
            let testWorkspace = try await TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDirPath.join("Workspace"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                // App sources
                                TestFile("Application.swift"),

                                // XCFrameworks
                                TestFile("Framework.xcframework"),
                                TestFile("Library.xcframework"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            CONFIGURATION,
                            buildSettings: [
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "COPY_PHASE_STRIP": "NO",
                                "CODE_SIGN_IDENTITY": "-",
                                "GCC_GENERATE_DEBUGGING_SYMBOLS": "YES",
                                "GCC_OPTIMIZATION_LEVEL": "0",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "INSTALL_PATH": "",
                                "APP_MERGE_LINKED_LIBRARIES": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "STRIP_STYLE": "debugging",                                     // So we can examine whether the app ends up with symbols from the merged libraries
                                "SWIFT_INSTALL_OBJC_HEADER": "NO",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "TAPI_EXEC": tapiToolPath.str,
                                "LIBTOOL": libtoolPath.str,

                                // Force file attribute changes off by default.
                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": "",
                                "INSTALL_MODE_FLAG": "",
                                "SDK_STAT_CACHE_ENABLE": "NO",

                                "ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT": useAppStoreCodelessFrameworksWorkaround ? "NO" : "YES",
                            ])
                        ],
                        targets: [
                            // App target
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration(CONFIGURATION,
                                                           buildSettings: [
                                                            "INSTALL_PATH": "/Applications",
                                                            "MERGE_LINKED_LIBRARIES": "$(APP_MERGE_LINKED_LIBRARIES)",      // Builds below can override APP_MERGE_LINKED_LIBRARIES to NO to disable merging.
                                                            "SKIP_EMBEDDED_FRAMEWORKS_VALIDATION": "YES",
                                                           ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "Application.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "Framework.xcframework",
                                        "Library.xcframework",
                                    ]),
                                    // Embed
                                    TestCopyFilesBuildPhase([
                                        TestBuildFile("Framework.xcframework", codeSignOnCopy: true),
                                        TestBuildFile("Library.xcframework", codeSignOnCopy: true),
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                ]
                            ),
                        ]
                    )
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOTpath = testWorkspace.sourceRoot.join("aProject")
            let SRCROOT = SRCROOTpath.str
            let signableTargets: Set<String> = Set(tester.workspace.projects[0].targets.map({ $0.name }))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOTpath.join("Sources/Application.swift")) { contents in
                contents <<< "import UIKit\n";
                contents <<< "    @main\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n";
                contents <<< "    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {\n        return true\n    }\n"
                contents <<< "}\n";
            }

            let toolchain = try #require(core.toolchainRegistry.defaultToolchain)

            let taskTypesToExclude = Set([
                "Gate", "WriteAuxiliaryFile", "CreateBuildDirectory", "SymLink", "MkDir", "ProcessInfoPlistFile",
                "ClangStatCache", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining",
                "SwiftDriver", "SwiftEmitModule", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders",
                "CopySwiftLibs","RegisterExecutionPolicyException", "RegisterWithLaunchServices", "Validate", "Touch",
                "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports",
            ])

            // Perform a release build where we merge the framework and library.
            do {
                let buildType = "Merge"
                let runDestination = RunDestinationInfo.iOS
                let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: tmpDirPath, for: buildType)
                let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "DEPLOYMENT_LOCATION": "YES",
                    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                    "GCC_OPTIMIZATION_LEVEL": "s",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O",
                ])
                let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                try await tester.checkBuild(buildType, parameters: parameters, runDestination: runDestination, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                    // Abort if the build failed (build errors are a proxy for this as the build result is not encoded in the result object).  checkBuild() will emit test issues for any build issues generated.
                    if !results.getDiagnostics(.error).isEmpty {
                        return
                    }

                    results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                    results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                        task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Sources/\(fwkBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                    }
                    results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                        task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Sources/\(libBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                    }

                    // Check the tasks in the target.
                    do {
                        let targetName = "AppTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }

                        // Check that we're merging the XCFrameworks.
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains([
                                ["\(toolchain.path.str)/usr/bin/clang"],
                                ["-Xlinker", "-merge_framework", "-Xlinker", "\(fwkBaseName)"],
                                ["-Xlinker", "-merge-l\(libBaseName)"],
                                ["-o", "\(DSTROOT)/Applications/\(targetName).app/\(targetName)"],
                            ].reduce([], +))
                        }

                        // Check that we're excluding the binary when embedding the framework, and not embedding the library at all.
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkBaseName).framework")) { task in
                            task.checkCommandLineContains(["-exclude_subpath", "\(fwkBaseName)"])

                            if useAppStoreCodelessFrameworksWorkaround {
                                results.checkNote(.prefix("Injecting stub binary into codeless framework"))
                            }
                        }
                        _ = results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkBaseName).framework")) { task in
                            if !useAppStoreCodelessFrameworksWorkaround {
                                // CodeSignTaskAction adds --generate-pre-encrypt-hashes dynamically because it's signing a codeless framework.
                                results.checkNote(.equal("Signing codeless framework with --generate-pre-encrypt-hashes (for task: \(task.ruleInfo))"))
                            }
                        }

                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("lib\(libBaseName).dylib"))
                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("lib\(libBaseName).dylib"))

                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateDSYMFile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Strip")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    results.checkNoTask()

#if canImport(Darwin)
                    // Check that the mergeable framework in the product doesn't contain its binary.
                    do {
                        let fwkPath = Path("\(DSTROOT)/Applications/AppTarget.app/Frameworks/\(fwkBaseName).framework")
                        #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                        let machoPath = fwkPath.join(fwkBaseName)
                        if useAppStoreCodelessFrameworksWorkaround {
                            #expect(tester.fs.exists(machoPath), "Missing framework binary '\(machoPath.str)'")

                            // The binary should be an iOS dylib
                            let macho = try MachO(reader: BinaryReader(data: tester.fs.read(machoPath)))
                            let (slices, linkage) = try macho.slicesIncludingLinkage()
                            #expect(try slices.flatMap { try $0.buildVersions().map(\.platform) }.only == .iOS)
                            #expect(linkage == .macho(.dylib))
                        } else {
                            #expect(!tester.fs.exists(machoPath), "Found unexpected framework binary '\(machoPath.str)'")
                        }
                    }

                    // Check that the merged app binary contains the symbols from the mergeable libraries.
                    do {
                        let targetName = "AppTarget"
                        let appPath = Path("\(DSTROOT)/Applications/\(targetName).app")
                        #expect(tester.fs.isDirectory(appPath), "Could not find app '\(appPath.str)'")
                        let machoPath = appPath.join(targetName)
                        #expect(tester.fs.exists(machoPath), "Could not find app binary '\(machoPath.str)'")

                        // Check that the merged framework is *not* linking the mergeable libraries.
                        try checkForLinkedLibraries(in: machoPath, libraryNames: [fwkBaseName, libBaseName], fs: tester.fs, expected: false)

                        // Check that the symbols from the mergeable frameworks are present, meaning that they were merged in.
                        try await checkForSymbols(in: machoPath, symbolPatterns: ["Framework.+ClassOne.+value", "Library.+ClassTwo.+value"], expected: true)
                    }
#endif
                }
            }

            // Perform a release build where we *don't* merge the framework and library, but treat them like normal dylibs
            do {
                let buildType = "Link"
                let runDestination = RunDestinationInfo.iOS
                let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: tmpDirPath, for: buildType)
                let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "DEPLOYMENT_LOCATION": "YES",
                    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                    "GCC_OPTIMIZATION_LEVEL": "s",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O",
                    "APP_MERGE_LINKED_LIBRARIES": "NO",
                ])
                let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                try await tester.checkBuild(buildType, parameters: parameters, runDestination: runDestination, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                    // Abort if the build failed (build errors are a proxy for this as the build result is not encoded in the result object).  checkBuild() will emit test issues for any build issues generated.
                    if !results.getDiagnostics(.error).isEmpty {
                        return
                    }

                    results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                    results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                        task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Sources/\(fwkBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                    }
                    results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                        task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Sources/\(libBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                    }

                    // Check the tasks in the target.
                    do {
                        let targetName = "AppTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }

                        // Check that we're merging the XCFrameworks.
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains([
                                ["\(toolchain.path.str)/usr/bin/clang"],
                                ["-framework", "\(fwkBaseName)"],
                                ["-l\(libBaseName)"],
                                ["-o", "\(DSTROOT)/Applications/\(targetName).app/\(targetName)"],
                            ].reduce([], +))
                            task.checkCommandLineDoesNotContain("-merge_framework")
                            task.checkCommandLineDoesNotContain("-merge-l\(libBaseName)")
                        }

                        // Check that we're *not* excluding the binary when embedding the framework, and that we *are* embedding the library.
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkBaseName).framework")) { task in
                            task.checkCommandLineDoesNotContain("-exclude_subpath")
                            task.checkCommandLineContains(["-strip_subpath", "\(fwkBaseName).framework/\(fwkBaseName)"])
                        }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkBaseName).framework")) { _ in }

                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("lib\(libBaseName).dylib")) { task in
                            task.checkCommandLineContains(["-strip_subpath", "lib\(libBaseName).dylib"])
                        }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("lib\(libBaseName).dylib")) { _ in }

                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateDSYMFile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Strip")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    results.checkNoTask()

#if canImport(Darwin)
                    // Check that the mergeable framework in the app *does* contain its binary.
                    do {
                        let fwkPath = Path("\(DSTROOT)/Applications/AppTarget.app/Frameworks/\(fwkBaseName).framework")
                        #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                        let machoPath = fwkPath.join(fwkBaseName)
                        #expect(tester.fs.exists(machoPath), "Missing framework binary '\(machoPath.str)'")

                        // Check that its binary does not contain an LC_ATOM_INFO action as that should have been removed during embedding.
                        try checkForMergeableMetadata(in: machoPath, fs: tester.fs, expected: false, reason: "it should have been removed during embedding")
                    }

                    // Check that the app does contain the library.
                    do {
                        let machoPath = Path("\(DSTROOT)/Applications/AppTarget.app/Frameworks/lib\(libBaseName).dylib")
                        #expect(tester.fs.exists(machoPath), "Missing library '\(machoPath.str)'")

                        // Check that it does not contain an LC_ATOM_INFO action as that should have been removed during embedding.
                        try checkForMergeableMetadata(in: machoPath, fs: tester.fs, expected: false, reason: "it should have been removed during embedding")
                    }

                    // Check that the merged app binary does not contain the symbols from the mergeable libraries.
                    do {
                        let targetName = "AppTarget"
                        let appPath = Path("\(DSTROOT)/Applications/\(targetName).app")
                        #expect(tester.fs.isDirectory(appPath), "Could not find app '\(appPath.str)'")
                        let machoPath = appPath.join(targetName)
                        #expect(tester.fs.exists(machoPath), "Could not find app binary '\(machoPath.str)'")

                        // Check that the merged framework *is* linking the mergeable libraries.
                        try checkForLinkedLibraries(in: machoPath, libraryNames: [fwkBaseName, libBaseName], fs: tester.fs, expected: true)

                        // Check that the symbols from the mergeable frameworks are absent, because we didn't merge them.
                        try await checkForSymbols(in: machoPath, symbolPatterns: ["Framework.+ClassOne.+value", "Library.+ClassTwo.+value"], expected: false)
                    }
#endif
                }
            }
        }
    }


    /// Test building an app with an intervening framework which is merging an XCFramework.
    @Test(.requireSDKs(.iOS))
    func usingMergeableXCFrameworkWithInterveningFramework() async throws {
        try await testUsingMergeableXCFrameworkWithInterveningFramework(useAppStoreCodelessFrameworksWorkaround: true)
    }

    func testUsingMergeableXCFrameworkWithInterveningFramework(useAppStoreCodelessFrameworksWorkaround: Bool) async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let xcode = try await InstalledXcode.currentlySelected()
            let core = try await getCore()
            let service = try await SWBBuildService()

            // Create the XCFrameworks.
            let fwkBaseName = "Framework"
            let fwkSourceContents = "public class ClassOne {\n    public static func value() -> String {\n        return \"ClassOne\"\n    }\n}\n"
            let iosFwk = try await xcode.compileFramework(path: tmpDirPath.join(fwkBaseName), baseName: fwkBaseName, platform: .iOS, infoLookup: core, archs: ["arm64"], sourceContents: fwkSourceContents, useSwift: true, linkerOptions: [.makeMergeable])
            let fwkOutputPath = tmpDirPath.join("Workspace/aProject/Sources/\(fwkBaseName).xcframework")
            do {
                let commandLine = ["createXCFramework", "-framework", iosFwk.str, "-output", fwkOutputPath.str]
                let (success, message) = await service.createXCFramework(commandLine, currentWorkingDirectory: tmpDirPath.str, developerPath: nil)
                guard success else {
                    Issue.record("unable to build '\(fwkOutputPath.basename)': \(message)")
                    return
                }
            }

            let libBaseName = "Library"
            let libSourceContents = "public class ClassTwo {\n    public static func value() -> String {\n        return \"ClassTwo\"\n    }\n}\n"
            let iosLib = try await xcode.compileDynamicLibrary(path: tmpDirPath.join(libBaseName), baseName: libBaseName, platform: .iOS, infoLookup: core, archs: ["arm64"], sourceContents: libSourceContents, useSwift: true, linkerOptions: [.makeMergeable])
            let libOutputPath = tmpDirPath.join("Workspace/aProject/Sources/\(libBaseName).xcframework")
            do {
                let commandLine = ["createXCFramework", "-library", iosLib.str, "-output", libOutputPath.str]
                let (success, message) = await service.createXCFramework(commandLine, currentWorkingDirectory: tmpDirPath.str, developerPath: nil)
                guard success else {
                    Issue.record("unable to build '\(libOutputPath.basename)': \(message)")
                    return
                }
            }

            let CONFIGURATION = "Config"
            let testWorkspace = try await TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDirPath.join("Workspace"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                // App sources
                                TestFile("Application.swift"),

                                // Fwk sources
                                TestFile("ClassOne.swift"),

                                // XCFrameworks
                                TestFile("Framework.xcframework"),
                                TestFile("Library.xcframework"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            CONFIGURATION,
                            buildSettings: [
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "COPY_PHASE_STRIP": "NO",
                                "CODE_SIGN_IDENTITY": "-",
                                "GCC_GENERATE_DEBUGGING_SYMBOLS": "YES",
                                "GCC_OPTIMIZATION_LEVEL": "0",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "INSTALL_PATH": "",
                                "APP_MERGE_LINKED_LIBRARIES": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "STRIP_STYLE": "debugging",                                     // So we can examine whether the app ends up with symbols from the merged libraries
                                "SWIFT_INSTALL_OBJC_HEADER": "NO",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SWIFT_VERSION": swiftVersion,
                                "TAPI_EXEC": tapiToolPath.str,
                                "LIBTOOL": libtoolPath.str,

                                // Force file attribute changes off by default.
                                "INSTALL_OWNER": "",
                                "INSTALL_GROUP": "",
                                "INSTALL_MODE_FLAG": "",
                                "SDK_STAT_CACHE_ENABLE": "NO",

                                "ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT": useAppStoreCodelessFrameworksWorkaround ? "NO" : "YES",
                            ])
                        ],
                        targets: [
                            // App target
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration(CONFIGURATION,
                                                           buildSettings: [
                                                            "INSTALL_PATH": "/Applications",
                                                            "SKIP_EMBEDDED_FRAMEWORKS_VALIDATION": "YES",
                                                           ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "Application.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "MergedFwkTarget.framework",
                                    ]),
                                    // Embed
                                    TestCopyFilesBuildPhase([
                                        TestBuildFile("MergedFwkTarget.framework", codeSignOnCopy: true),
                                        TestBuildFile("Framework.xcframework", codeSignOnCopy: true),
                                        TestBuildFile("Library.xcframework", codeSignOnCopy: true),
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                ]
                            ),
                            // Framework target
                            TestStandardTarget(
                                "MergedFwkTarget",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(CONFIGURATION,
                                                           buildSettings: [
                                                            "INSTALL_PATH": "",
                                                            "MERGE_LINKED_LIBRARIES": "$(APP_MERGE_LINKED_LIBRARIES)",      // Builds below can override APP_MERGE_LINKED_LIBRARIES to NO to disable merging.
                                                           ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "ClassOne.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "Framework.xcframework",
                                        "Library.xcframework",
                                    ]),
                                ]
                            ),
                        ]
                    )
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOTpath = testWorkspace.sourceRoot.join("aProject")
            let SRCROOT = SRCROOTpath.str
            let signableTargets: Set<String> = Set(tester.workspace.projects[0].targets.map({ $0.name }))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOTpath.join("Sources/Application.swift")) { contents in
                contents <<< "import UIKit\n";
                contents <<< "    @main\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n";
                contents <<< "    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {\n        return true\n    }\n"
                contents <<< "}\n";
            }
            try await tester.fs.writeFileContents(SRCROOTpath.join("Sources/ClassOne.swift")) { contents in
                contents <<< "public import UIKit\n\n"
                contents <<< "public func ClassOne(label: UILabel) async  {\n    await MainActor.run { label.text = \"Framework One\" }\n}\n"
            }

            let taskTypesToExclude = Set([
                "Gate", "WriteAuxiliaryFile", "CreateBuildDirectory", "SymLink", "MkDir", "ProcessInfoPlistFile",
                "ClangStatCache", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining",
                "SwiftDriver", "SwiftEmitModule", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders",
                "CopySwiftLibs","RegisterExecutionPolicyException", "RegisterWithLaunchServices", "Validate", "Touch",
                "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports",
            ])

            // Perform a release build where we merge the XCFramework.
            do {
                let buildType = "Merge"
                let runDestination = RunDestinationInfo.iOS
                let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: tmpDirPath, for: buildType)
                let parameters = BuildParameters(configuration: CONFIGURATION, overrides: [
                    "SYMROOT": SYMROOT,
                    "OBJROOT": OBJROOT,
                    "DSTROOT": DSTROOT,
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "DEPLOYMENT_LOCATION": "YES",
                    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                    "GCC_OPTIMIZATION_LEVEL": "s",
                    "SWIFT_OPTIMIZATION_LEVEL": "-O",
                ])
                let BUILT_PRODUCTS_DIR = "\(SYMROOT)/\(CONFIGURATION)" + (runDestination != .macOS ? "-\(runDestination.platform)" : "")
                let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
                let request = BuildRequest(parameters: parameters, buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
                try await tester.checkBuild(buildType, parameters: parameters, runDestination: runDestination, buildRequest: request, persistent: true, signableTargets: signableTargets) { results in
                    // Abort if the build failed (build errors are a proxy for this as the build result is not encoded in the result object).  checkBuild() will emit test issues for any build issues generated.
                    if !results.getDiagnostics(.error).isEmpty {
                        return
                    }

                    results.consumeTasksMatchingRuleTypes(taskTypesToExclude)

                    results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(fwkBaseName).xcframework")) { task in
                        task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Sources/\(fwkBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                    }
                    results.checkTask(.matchRuleType("ProcessXCFramework"), .matchRuleItemBasename("\(libBaseName).xcframework")) { task in
                        task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Sources/\(libBaseName).xcframework", "--platform", "ios", "--target-path", "\(BUILT_PRODUCTS_DIR)"])
                    }

                    // Check MergedFwkTarget
                    do {
                        let targetName = "MergedFwkTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { task in
                            task.checkCommandLineContains(["-Xlinker", "-merge_framework", "-Xlinker", "\(fwkBaseName)"])
                            task.checkCommandLineContains(["-Xlinker", "-merge-l\(libBaseName)"])
                            task.checkCommandLineContains(["-o", "\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework/\(targetName)"])
                            task.checkCommandLineDoesNotContain("-make_mergeable")
                            task.checkCommandLineDoesNotContain("-no_merge_framework")
                        }
                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateTAPI")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Strip")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateDSYMFile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    // Check AppTarget
                    do {
                        let targetName = "AppTarget"
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("SwiftCompile")) { _ in }

                        // Check that we're merging the XCFrameworks.
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Ld")) { _ in }

                        // Check that we're excluding the binary when embedding the framework, and not embedding the library at all.
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(fwkBaseName).framework")) { task in
                            task.checkCommandLineContains(["-exclude_subpath", "\(fwkBaseName)"])

                            if useAppStoreCodelessFrameworksWorkaround {
                                results.checkNote(.prefix("Injecting stub binary into codeless framework"))
                            }
                        }
                        _ = results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(fwkBaseName).framework")) { task in
                            if !useAppStoreCodelessFrameworksWorkaround {
                                // CodeSignTaskAction adds --generate-pre-encrypt-hashes dynamically because it's signing a codeless framework.
                                results.checkNote(.equal("Signing codeless framework with --generate-pre-encrypt-hashes (for task: \(task.ruleInfo))"))
                            }
                        }

                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("lib\(libBaseName).dylib"))
                        results.checkNoTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("lib\(libBaseName).dylib"))

                        do {
                            let copiedTargetName = "MergedFwkTarget"
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemBasename("\(copiedTargetName).framework")) { task in
                                task.checkCommandLineDoesNotContainUninterrupted(["-exclude_subpath", copiedTargetName])
                            }
                            results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(copiedTargetName).framework")) { _ in }
                        }

                        results.checkTasks(.matchTargetName(targetName), .matchRuleType("Copy")) { _ in /* likely Swift-related */ }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("GenerateDSYMFile")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("Strip")) { _ in }
                        results.checkTask(.matchTargetName(targetName), .matchRuleType("CodeSign")) { _ in }
                        results.checkNoTask(.matchTargetName(targetName))
                    }

                    results.checkNoTask()

#if canImport(Darwin)
                    // Check that the mergeable framework in the product doesn't contain its binary.
                    do {
                        let fwkPath = Path("\(DSTROOT)/Applications/AppTarget.app/Frameworks/\(fwkBaseName).framework")
                        #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                        let machoPath = fwkPath.join(fwkBaseName)
                        if useAppStoreCodelessFrameworksWorkaround {
                            #expect(tester.fs.exists(machoPath), "Missing framework binary '\(machoPath.str)'")

                            // The binary should be an iOS dylib
                            let macho = try MachO(reader: BinaryReader(data: tester.fs.read(machoPath)))
                            let (slices, linkage) = try macho.slicesIncludingLinkage()
                            #expect(try slices.flatMap { try $0.buildVersions().map(\.platform) }.only == .iOS)
                            #expect(linkage == .macho(.dylib))
                        } else {
                            #expect(!tester.fs.exists(machoPath), "Found unexpected framework binary '\(machoPath.str)'")
                        }
                    }

                    // Check that the merged framework binary contains the symbols from the mergeable libraries.
                    do {
                        let targetName = "MergedFwkTarget"
                        let fwkPath = Path("\(OBJROOT)/UninstalledProducts/iphoneos/\(targetName).framework")
                        #expect(tester.fs.isDirectory(fwkPath), "Could not find framework '\(fwkPath.str)'")
                        let machoPath = fwkPath.join(targetName)
                        #expect(tester.fs.exists(machoPath), "Could not find framework binary '\(machoPath.str)'")

                        // Check that the merged framework is *not* linking the mergeable libraries.
                        try checkForLinkedLibraries(in: machoPath, libraryNames: [fwkBaseName, libBaseName], fs: tester.fs, expected: false)

                        // Check that the symbols from the mergeable frameworks are present, meaning that they were merged in.
                        try await checkForSymbols(in: machoPath, symbolPatterns: ["Framework.+ClassOne.+value", "Library.+ClassTwo.+value"], expected: true)
                    }
#endif
                }
            }
        }
    }


    // MARK: - Utility methods


    /// Utility method to try to be tolerant of Swift symbol mangling in the output of `nm`.
    /// - parameter symbolPatterns: A list of regular expression static strings to search for in the output.
    fileprivate func checkForSymbols(in machoPath: Path, symbolPatterns: [StaticString], expected: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let symbols = try await InstalledXcode.currentlySelected().xcrun(["nm", machoPath.str]).split(separator: "\n")
        for pattern in symbolPatterns {
            let regex = RegEx(patternLiteral: pattern)
            let foundLines = symbols.filter({ regex.firstMatch(in: String($0)) != nil })
            if expected {
                #expect(foundLines.count == 1, "Couldn't find symbol matching /\(pattern)/ in '\(machoPath.str)'", sourceLocation: sourceLocation)
            }
            else {
                #expect(foundLines.isEmpty, "Unexpectedly found symbol matching /\(pattern)/ in '\(machoPath.str)'", sourceLocation: sourceLocation)
            }
        }
    }

    /// Utility method to check whether a binary is or is not linking libraries of the given name. It does this by checking the slices of the binary to see if they are each linking all of the libraries.
    /// - parameter expected: If `true`, then emits a test failure if the library is not linked. If `false`, then emits a test failure if it is linked.
    fileprivate func checkForLinkedLibraries(in machoPath: Path, libraryNames: [String], fs: any FSProxy, expected: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
#if canImport(Darwin)
        let reader = try BinaryReader(data: fs.read(machoPath))
        let machO = try MachO(reader: reader)
        let slices = try machO.slices()
        #expect(slices.count > 0, "Binary contains no slices", sourceLocation: sourceLocation)
        for slice in slices {
            let linkedLibraries = Set(try slice.linkedLibraryPaths().map({ Path($0).basename }))
            for libraryName in libraryNames {
                if expected {
                    #expect(linkedLibraries.contains(libraryName), "Could not find expected linkage of '\(libraryName)'", sourceLocation: sourceLocation)
                }
                else {
                    #expect(!linkedLibraries.contains(libraryName), "Found unexpected linkage of '\(libraryName)'", sourceLocation: sourceLocation)
                }
            }
        }
#endif
    }

    /// Utility method to check whether a binary contains `LC_ATOM_INFO` in any of its slices.
    /// - parameter expected: If `true`, then emits a test failure if `LC_ATOM_INFO` is absent. If `false`, then emits a test failure if it is present.
    /// - parameter reason: A string describing the reason the `LC_ATOM_INFO` is expected to be present or absent, to be emitted in the test failure.
    fileprivate func checkForMergeableMetadata(in machoPath: Path, fs: any FSProxy, expected: Bool, reason: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
#if canImport(Darwin)
        let reader = try BinaryReader(data: fs.read(machoPath))
        let machO = try MachO(reader: reader)
        let slices = try machO.slices()
        #expect(slices.count > 0, "Binary contains no slices", sourceLocation: sourceLocation)
        for slice in slices {
            let loadCommands = try slice.loadCommands()
            let atomInfoCmds = loadCommands.filter({ $0.base.cmd == 0x36 /* LC_ATOM_INFO */ })
            if expected {
                let string = "Could not find LC_ATOM_INFO load command in binary" + (reason.flatMap({ " (\($0))" }) ?? "") + "."
                #expect(!atomInfoCmds.isEmpty, Comment(rawValue: string), sourceLocation: sourceLocation)
            }
            else {
                let string = "Found unexpected LC_ATOM_INFO load command in binary" + (reason.flatMap({ " (\($0))" }) ?? "") + "."
                #expect(atomInfoCmds.isEmpty, Comment(rawValue: string), sourceLocation: sourceLocation)
            }
        }
#endif
    }

}
