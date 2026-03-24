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
import SWBProtocol
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct CleanOperationTests: CoreBasedTests {
    private func arenaInfo(from path: Path) -> ArenaInfo {
        return ArenaInfo(derivedDataPath: path.dirname, buildProductsPath: path, buildIntermediatesPath: path, pchPath: path, indexRegularBuildProductsPath: nil, indexRegularBuildIntermediatesPath: nil, indexPCHPath: path, indexDataStoreFolderPath: nil, indexEnableDataStore: false)
    }

    private func withTestHarness(install: Bool = false,
                                 useRootDstroot: Bool = false,
                                 perform: (BuildOperationTester,  Path, Path) async throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let dstRoot = useRootDstroot ? tmpDirPath : tmpDirPath.join("dest")
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreFoo.m"),
                                TestFile("Thing.swift"),
                                TestFile("Info.plist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "VERSIONING_SYSTEM": "apple-generic",
                                "CURRENT_PROJECT_VERSION": "3.1",
                                "INFOPLIST_FILE": "Info.plist",
                                "DEFINES_MODULE": "YES",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "SWIFT_VERSION": swiftVersion,
                                "DSTROOT": dstRoot.str,
                                "DEPLOYMENT_LOCATION": install ? "YES" : "NO",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m", "Thing.swift"]),
                                    TestFrameworksBuildPhase([]),
                                    TestHeadersBuildPhase([TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/CoreFoo.h")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/CoreFoo.m")) { _ in }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Thing.swift")) { _ in }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Info.plist"), .plDict(["key": .plString("value")]))

            try await perform(tester, tmpDirPath, dstRoot)
        }
    }

    /// Check that the build service doesn't fail when cleaning an empty workspace.
    @Test(.requireSDKs(.macOS))
    func cleanEmpty() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDirPath.join("Test"), projects: [])

            // simulated: true avoids the test harness hitting an early failure
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Test without an arena - should fail because no projects and no workspace arena provides no means to get the build intermediates path.
            await #expect(performing: {
                try await tester.checkBuild(runDestination: .macOS, buildRequest: BuildRequest(parameters: BuildParameters(configuration: "Debug"), buildTargets: [], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .cleanBuildFolder(style: .regular)), persistent: true) { results in
                    results.checkNoDiagnostics()
                }
            }, throws: { error in
                String(describing: error) == "There is no workspace arena to determine the build cache directory path."
            })

            // Test with an arena - should succeed because while there are no projects, we can still get the build intermediates path from the workspace arena.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: BuildRequest(parameters: BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDirPath.join("build"))), buildTargets: [], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .cleanBuildFolder(style: .regular)), persistent: true) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cleanFramework() async throws {
        try await withTestHarness { tester, tmpDirPath, _ in
            let buildFolderPaths = [
                tmpDirPath.join("Test/aProject/build"),
                tmpDirPath.join("Test/aProject/build/Debug"),
                tmpDirPath.join("Test/aProject/build/EagerLinkingTBDs/Debug"),
                tmpDirPath.join("Test/aProject/build/ExplicitPrecompiledModules"),
                tmpDirPath.join("Test/aProject/build/SwiftExplicitPrecompiledModules"),
                // While this is a cache folder, it exists under a build folder so it will be deleted.
                tmpDirPath.join("Test/aProject/build/SharedPrecompiledHeaders"),
            ]
            let cacheFolderPaths = [
                tmpDirPath.join("Test/CompilationCache.noindex"),
            ]

            let parameters = BuildParameters(configuration: "Debug", overrides: ["COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("Test/CompilationCache.noindex").str])

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Check if build folder tasks have run as expected.
                for folderPath in buildFolderPaths + cacheFolderPaths {
                    results.checkTask(.matchRule(["CreateBuildDirectory", folderPath.str])) { _ in }
                }

                results.checkNoTask(.matchRuleType("CreateBuildDirectory"))
            }

            // Check if build folders exist as expected.
            for folder in buildFolderPaths {
                #expect(tester.fs.exists(folder))
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // Check if build folders no longer exist as expected.
            for folder in buildFolderPaths {
                #expect(!tester.fs.exists(folder))
            }

            // Check that cache folders still exist as expected.
            for folder in cacheFolderPaths {
                #expect(tester.fs.exists(folder))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cleanFrameworkInstall() async throws {
        try await withTestHarness(install: true) { tester, tmpDirPath, dstRoot in
            let buildFolderPaths = [
                tmpDirPath.join("Test/aProject/build"),
                tmpDirPath.join("Test/aProject/build/Debug"),
                tmpDirPath.join("Test/aProject/build/EagerLinkingTBDs/Debug"),
                tmpDirPath.join("Test/aProject/build/ExplicitPrecompiledModules"),
                tmpDirPath.join("Test/aProject/build/SwiftExplicitPrecompiledModules"),
                tmpDirPath.join("dest"),
                // While this is a cache folder, it exists under a build folder so it will be deleted.
                tmpDirPath.join("Test/aProject/build/SharedPrecompiledHeaders"),
            ]
            let cacheFolderPaths = [
                tmpDirPath.join("Test/CompilationCache.noindex"),
            ]

            let parameters = BuildParameters(configuration: "Debug", overrides: ["COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("Test/CompilationCache.noindex").str])

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                // Check if build folder tasks have run as expected.
                for folderPath in buildFolderPaths + cacheFolderPaths {
                    results.checkTask(.matchRule(["CreateBuildDirectory", folderPath.str])) { _ in }
                }

                results.checkNoTask(.matchRuleType("CreateBuildDirectory"))
            }

            // Check if build folders exist as expected.
            for folder in buildFolderPaths + cacheFolderPaths {
                #expect(tester.fs.exists(folder))
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // Check if build folders no longer exist as expected.
            for folder in buildFolderPaths {
                #expect(!tester.fs.exists(folder))
            }

            // Check if cache folders still exist as expected.
            for folder in cacheFolderPaths {
                #expect(tester.fs.exists(folder))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cleanLegacy() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let buildFolderPaths = [ tmpDirPath.join("build/a"), tmpDirPath.join("build/b") ]

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [ TestFile("foo.c") ]),
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"])],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: ["OBJROOT": buildFolderPaths[0].str, "SYMROOT": buildFolderPaths[0].str, "DSTROOT": buildFolderPaths[0].str])],
                                buildPhases: [ TestSourcesBuildPhase(["foo.c"]) ]),
                            TestStandardTarget(
                                "OtherFramework", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: ["OBJROOT": buildFolderPaths[1].str, "SYMROOT": buildFolderPaths[1].str, "DSTROOT": buildFolderPaths[1].str])],
                                buildPhases: [ TestSourcesBuildPhase(["foo.c"]) ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/foo.c")) { _ in }

            let coreFooArenaInfo = arenaInfo(from: buildFolderPaths[0])
            let coreFooParameters = BuildParameters(configuration: "Debug", arena: coreFooArenaInfo)
            let otherFrameworkArenaInfo = arenaInfo(from: buildFolderPaths[1])
            let otherFrameworkParameters = BuildParameters(configuration: "Debug", arena: otherFrameworkArenaInfo)

            let parameters = BuildParameters(configuration: "Debug")
            let targets = tester.workspace.projects[0].targets
            let buildTargets = [
                BuildRequest.BuildTargetInfo(parameters: coreFooParameters, target: targets[0]),
                BuildRequest.BuildTargetInfo(parameters: otherFrameworkParameters, target: targets[1]),
            ]

            let buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { tasks in
                    #expect(tasks.count == 12)
                }

                results.checkNoTask(.matchRuleType("CreateBuildDirectory"))
            }
            for folder in buildFolderPaths {
                #expect(tester.fs.exists(folder))
            }

            let cleanRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .cleanBuildFolder(style: .legacy))
            try await tester.checkBuild(runDestination: .macOS, buildRequest: cleanRequest, persistent: true) { results in
                results.checkNoDiagnostics()
            }
            for folder in buildFolderPaths {
                #expect(!tester.fs.exists(folder))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cleanDoesNotDeleteManuallyCreatedFolders() async throws {
        try await withTestHarness { tester, tmpDirPath, _ in
            let buildFolderPaths = [ tmpDirPath.join("Test/aProject/build"), tmpDirPath.join("Test/aProject/build/Debug"), tmpDirPath.join("Test/aProject/build/EagerLinkingTBDs/Debug"), tmpDirPath.join("Test/aProject/build/ExplicitPrecompiledModules"), tmpDirPath.join("Test/aProject/build/SwiftExplicitPrecompiledModules"), ]
            let cacheFolderPaths = [ tmpDirPath.join("Test/CompilationCache.noindex"), tmpDirPath.join("Test/aProject/build/SharedPrecompiledHeaders") ]

            for folder in buildFolderPaths {
                try tester.fs.createDirectory(folder, recursive: true)
            }

            let parameters = BuildParameters(configuration: "Debug", overrides: ["COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("Test/CompilationCache.noindex").str])

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                for buildFolderPath in buildFolderPaths + cacheFolderPaths {
                    results.checkTask(.matchRule(["CreateBuildDirectory", buildFolderPath.str])) { _ in }
                }

                results.checkNoTask(.matchRuleType("CreateBuildDirectory"))
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), persistent: true) { results in
                // Check that expected warnings were emitted.
                for buildFolderPath in buildFolderPaths {
                    results.checkError(.equal("Could not delete `\(buildFolderPath.str)` because it was not created by the build system and it is not a subfolder of derived data.\nTo mark this directory as deletable by the build system, run `xattr -w com.apple.xcode.CreatedByBuildSystem true \(buildFolderPath.str)` when it is created."))
                }
                results.checkNoDiagnostics()
            }

            // Check that build folders haven't been deleted after the build.
            for folder in buildFolderPaths {
                #expect(tester.fs.exists(folder))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cleanBuildFolderContainingProject() async throws {
        try await withTestHarness(useRootDstroot: true) { tester, tmpDirPath, _ in
            let buildFolderPaths = [tmpDirPath]

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .legacy), persistent: true) { results in
                results.checkWarning(.equal("Refusing to delete `\(tmpDirPath.str)` because it contains one of the projects in this workspace: `\(tmpDirPath.str)/Test/aProject/aProject.xcodeproj`."))
                results.checkNoDiagnostics()
            }

            // Check that build folders have not been deleted after the build.
            #expect(tester.fs.exists(buildFolderPaths[0]))
        }
    }

    private func withBasedProjectHarness(perform: (BuildOperationTester, Path, Path) async throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let sourceRoot = tmpDirPath.join("Test")
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: sourceRoot,
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: []),
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [:])],
                        targets: [
                            TestExternalTarget("external", toolPath: "\(try await getCore().developerPath.path.str)/usr/bin/make", arguments: "$(ACTION)", workingDirectory: sourceRoot.str, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [:])], dependencies: [], passBuildSettingsInEnvironment: true)
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            try await perform(tester, tmpDirPath, sourceRoot)
        }
    }

    private func testCleanExternalTargets(type: BuildLocationStyle) async throws {
        try await withBasedProjectHarness { tester, _, sourceRoot in
            try await tester.fs.writeFileContents(sourceRoot.join("Makefile")) { stream in
                stream <<< "all:\n"
                stream <<< "\techo $(TARGET_NAME) >\(sourceRoot.str)/out.txt\n"
                stream <<< "clean:\n"
                stream <<< "\trm -f \(sourceRoot.str)/out.txt\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            #expect(tester.fs.exists(sourceRoot.join("out.txt")))
            // Check that `passBuildSettingsInEnvironment` works by verifying the contents of the generated file.
            #expect(try tester.fs.read(sourceRoot.join("out.txt")) == "external\n")

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: type), persistent: true) { results in
                results.checkTask(.matchRule(["\(try await getCore().developerPath.path.str)/usr/bin/make", "clean"])) { _ in }
                results.checkNoTask()
                results.checkNoErrors()
            }

            #expect(!tester.fs.exists(sourceRoot.join("out.txt")))
        }
    }

    @Test(.requireSDKs(.macOS))
    func cleanExternalTargetsLegacy() async throws {
        try await testCleanExternalTargets(type: .legacy)
    }

    // We do not clean external targets with regular build locations, yet, enabling that is tracked by rdar://problem/41538039
    /*func testCleanExternalTargetsRegular() async throws {
     try await testCleanExternalTargets(type: .regular)
     }*/

    @Test(.requireSDKs(.macOS))
    func cleanExternalTargetsError() async throws {
        try await withBasedProjectHarness { tester, _, _ in
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .legacy), persistent: false) { results in
                // CleanOperation.cleanExternalTarget() captures all of the output of the inferior tool - stdout and stderr - as part of the error message, which can include unrelated garbage (e.g. ObjC runtime reports of symbol collisions, reports of xcodebuild being relaunched under ASan), some of which might be expected, so we just check that there's an error which contains the expected string content to be robust to those scenarios.
                results.checkError(.and(.prefix("Failed to clean target \'external\': "), .contains("make: *** No rule to make target `clean\'.  Stop.\n (for task: [\"\(try await getCore().developerPath.path.str)/usr/bin/make\", \"clean\"])")))
                results.checkNoDiagnostics()
            }
        }
    }

    // MARK: - cleanBuildFolderAndCaches tests

    @Test(.requireSDKs(.macOS))
    func clearCaches() async throws {
        try await withTestHarness { tester, tmpDirPath, _ in
            // Set up explicit arena for the build
            let buildFolder = tmpDirPath.join("Test/aProject/build")
            let arena = arenaInfo(from: buildFolder)
            let parameters = BuildParameters(configuration: "Debug", arena: arena)

            // The cache directories should be in the derivedDataPath (parent of build folder)
            let derivedDataPath = arena.derivedDataPath
            let moduleCacheDir = derivedDataPath.join("ModuleCache.noindex")
            let compilationCacheDir = derivedDataPath.join("CompilationCache.noindex")

            // Run an initial build with the arena to set everything up
            let buildTargets = tester.workspace.projects[0].targets.map { target in
                BuildRequest.BuildTargetInfo(parameters: parameters, target: target)
            }
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // Verify the cache directories exist
            #expect(tester.fs.exists(moduleCacheDir))
            #expect(tester.fs.exists(compilationCacheDir))

            // Now run the clearCaches command with the same arena
            let clearRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .cleanCaches(style: .regular))
            try await tester.checkBuild(runDestination: .macOS, buildRequest: clearRequest, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // Verify the cache directories were deleted
            #expect(!tester.fs.exists(moduleCacheDir), "Module cache directory should have been deleted")
            #expect(!tester.fs.exists(compilationCacheDir), "Compilation cache directory should have been deleted")
        }
    }

    @Test(.requireSDKs(.macOS))
    func clearCachesEmpty() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDirPath.join("Test"), projects: [])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Test with an arena - should succeed even if no cache directories exist
            try await tester.checkBuild(runDestination: .macOS, buildRequest: BuildRequest(parameters: BuildParameters(configuration: "Debug", arena: arenaInfo(from: tmpDirPath.join("build"))), buildTargets: [], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .cleanCaches(style: .regular)), persistent: true) { results in
                results.checkNoDiagnostics()
            }
        }
    }
}
