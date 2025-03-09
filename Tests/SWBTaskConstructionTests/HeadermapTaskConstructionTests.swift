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

@Suite
fileprivate struct HeadermapTaskConstructionTests: CoreBasedTests {
    // FIXME: Coverage of headmap generation is spotty.  <rdar://problem/36187970>

    /// Test that when a target has multiple headers of the same name, that we see the entries we expect.
    @Test(.requireSDKs(.macOS))
    func multipleHeadersOfSameName() async throws {
        let targetName = "Framework"
        let projectHeader1 = TestFile("Header1.h", guid: "FR_projectHeader1")
        let publicHeader1 = TestFile("Header1.h", guid: "FR_publicHeader1")
        let projectHeader2 = TestFile("Header2.h", guid: "FR_projectHeader2")
        let privateHeader2 = TestFile("Header2.h", guid: "FR_privateHeader2")
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.m"),
                    TestFile("MyInfo.plist"),
                    TestGroup(
                        "Common",
                        path: "Common",
                        children: [
                            projectHeader1,
                            projectHeader2,
                            TestFile("ProjectHeader.h"),
                        ]),
                    TestGroup(
                        "Internal",
                        path: "Internal",
                        children: [
                            privateHeader2,
                            TestFile("PrivateHeader.h"),
                        ]),
                    TestGroup(
                        "Public",
                        path: "Public",
                        children: [
                            publicHeader1,
                            TestFile("PublicHeader.h"),
                        ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile(publicHeader1, headerVisibility: .public),
                            TestBuildFile("PublicHeader.h", headerVisibility: .public),
                            TestBuildFile(privateHeader2, headerVisibility: .private),
                            TestBuildFile("PrivateHeader.h", headerVisibility: .private),
                            TestBuildFile(projectHeader1),
                            TestBuildFile(projectHeader2),
                            TestBuildFile("ProjectHeader.h"),
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check the debug build.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget(targetName) { target in
                // Confirm that the own-target-headers headermap contains the contents we expect.
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(targetName)-own-target-headers.hmap")) { headermap in
                    // ProjectHeader.h is the only project header in the target which is not overridden by a public or private header of the same name, so it's the only one for which we expect both a <name> and a <framework>/<name> entry, referring to the path in the sources.
                    headermap.checkEntry("\(targetName)/ProjectHeader.h", "\(SRCROOT)/Common/ProjectHeader.h")
                    headermap.checkEntry("ProjectHeader.h", "\(SRCROOT)/Common/ProjectHeader.h")

                    // The other headers we expect only a <name> entry, referring to the <framework>/<name> location in the product.
                    headermap.checkEntry("Header1.h", "\(targetName)/Header1.h")
                    headermap.checkEntry("Header2.h", "\(targetName)/Header2.h")
                    headermap.checkEntry("PrivateHeader.h", "\(targetName)/PrivateHeader.h")
                    headermap.checkEntry("PublicHeader.h", "\(targetName)/PublicHeader.h")

                    headermap.checkNoEntries()
                }
            }
        }
    }

    // Test a very subtle case of multiple headers with same name, where
    // order of their appearance in the group tree matters.
    @Test(.requireSDKs(.macOS))
    func multipleHeadersOfSameName2() async throws {
        let fwkHeader = TestFile("Cache.h", guid: "FR_cache1")
        let execHeader = TestFile("Cache.h", guid: "FR_cache2")
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("MyInfo.plist"),
                    TestGroup(
                        "Exec",
                        path: "exec",
                        children: [
                            execHeader,
                            TestFile("main.c"),
                        ]),
                    TestGroup(
                        "Fwk",
                        path: "fwk",
                        children: [
                            fwkHeader,
                            TestFile("something.c"),
                        ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "DEFINES_MODULE": "YES",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "fwk",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "something.c",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile(fwkHeader, headerVisibility: .public),
                        ]),
                    ]),
                TestStandardTarget(
                    "exec",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.c",
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let parameters = BuildParameters(configuration: "Debug")
        let target = tester.workspace.projects[0].targets[1]
        let buildTarget = BuildRequest.BuildTargetInfo(parameters: parameters, target: target)
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: [buildTarget], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        // Check the debug build.
        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkNoDiagnostics()
            results.checkTarget("exec") { target in
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("exec-project-headers.hmap")) { headermap in
                    headermap.checkEntry("Cache.h", "/tmp/Test/aProject/exec/Cache.h")
                    headermap.checkNoEntries()
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func headermapDeterminism() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Custom1.fake-lang"),
                    TestFile("Custom2.fake-lang"),
                    TestFile("Custom3.fake-lang"),
                    TestFile("regular1.defs"),
                    TestFile("regular2.defs"),
                    TestFile("some1.fake-gperf"),
                    TestFile("some2.fake-gperf"),
                    TestFile("main.c"),
                    TestFile("ProjHeader1.h"),
                    TestFile("ProjHeader2.h"),
                    TestFile("ProjHeader3.h"),
                    TestFile("TargetHeader1.h"),
                    TestFile("TargetHeader2.h"),
                    TestFile("TargetHeader3.h"),
                    TestFile("LibHeader.h"),
                    TestFile("APIHeader1.h"),
                    TestFile("APIHeader2.h"),
                    TestFile("SPIHeader1.h"),
                    TestFile("SPIHeader2.h"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "MIG_EXEC": migPath.str,
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "CODE_SIGN_IDENTITY": "",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("TargetHeader1.h"),
                            TestBuildFile("TargetHeader2.h"),
                            TestBuildFile("TargetHeader3.h"),
                        ]),
                        TestSourcesBuildPhase([
                            TestBuildFile("Custom1.fake-lang"),
                            TestBuildFile("regular1.defs"),
                            TestBuildFile("some1.fake-gperf"),
                            TestBuildFile("main.c"),
                        ]),
                        TestResourcesBuildPhase([
                            TestBuildFile("Custom2.fake-lang"),
                            TestBuildFile("Custom3.fake-lang"),
                            TestBuildFile("some2.fake-gperf"),
                        ]),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "*/*.fake-lang", script: "true", outputs: [
                            "${DERIVED_SOURCES_DIR}/${INPUT_FILE_BASE}",
                        ]),
                        TestBuildRule(filePattern: "*.fake-gperf", script: "true", outputs: [
                            "${DERIVED_SOURCES_DIR}/${INPUT_FILE_BASE}",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "Lib", type: .dynamicLibrary,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("LibHeader.h", headerVisibility: .public),
                            TestBuildFile("APIHeader1.h", headerVisibility: .public),
                            TestBuildFile("APIHeader2.h", headerVisibility: .public),
                            TestBuildFile("SPIHeader1.h", headerVisibility: .private),
                            TestBuildFile("SPIHeader2.h", headerVisibility: .private),
                            TestBuildFile("ProjHeader1.h"),
                            TestBuildFile("ProjHeader2.h"),
                            TestBuildFile("ProjHeader3.h"),
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let headermapBasenames = [
            "project-headers",
            "own-target-headers",
            "all-target-headers",
            "all-non-framework-target-headers",
            "generated-files",
        ]

        // Check that the headermap contents are deterministic.
        var hmapContents: [[UInt8]] = []
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Tool") { target in
                for basename in headermapBasenames {
                    results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("Tool-\(basename).hmap")) { headermap in
                        hmapContents.append(headermap.rawBytes)

                        //XCTContext.runActivity(named: "Validate headermap contents for \(basename)") { _ in
                            switch basename {
                            case "project-headers":
                                headermap.checkEntry("ProjHeader1.h", "/tmp/Test/aProject/Sources/ProjHeader1.h")
                                headermap.checkEntry("ProjHeader2.h", "/tmp/Test/aProject/Sources/ProjHeader2.h")
                                headermap.checkEntry("ProjHeader3.h", "/tmp/Test/aProject/Sources/ProjHeader3.h")
                                headermap.checkEntry("TargetHeader1.h", "/tmp/Test/aProject/Sources/TargetHeader1.h")
                                headermap.checkEntry("TargetHeader2.h", "/tmp/Test/aProject/Sources/TargetHeader2.h")
                                headermap.checkEntry("TargetHeader3.h", "/tmp/Test/aProject/Sources/TargetHeader3.h")
                                headermap.checkEntry("LibHeader.h", "Lib/LibHeader.h")
                                headermap.checkEntry("APIHeader1.h", "Lib/APIHeader1.h")
                                headermap.checkEntry("APIHeader2.h", "Lib/APIHeader2.h")
                                headermap.checkEntry("SPIHeader1.h", "Lib/SPIHeader1.h")
                                headermap.checkEntry("SPIHeader2.h", "Lib/SPIHeader2.h")
                                break
                            case "own-target-headers":
                                headermap.checkEntry("Tool/TargetHeader1.h", "/tmp/Test/aProject/Sources/TargetHeader1.h")
                                headermap.checkEntry("Tool/TargetHeader2.h", "/tmp/Test/aProject/Sources/TargetHeader2.h")
                                headermap.checkEntry("Tool/TargetHeader3.h", "/tmp/Test/aProject/Sources/TargetHeader3.h")
                                headermap.checkEntry("TargetHeader1.h", "/tmp/Test/aProject/Sources/TargetHeader1.h")
                                headermap.checkEntry("TargetHeader2.h", "/tmp/Test/aProject/Sources/TargetHeader2.h")
                                headermap.checkEntry("TargetHeader3.h", "/tmp/Test/aProject/Sources/TargetHeader3.h")
                                break
                            case "all-target-headers", "all-non-framework-target-headers":
                                headermap.checkEntry("Lib/LibHeader.h", "/tmp/Test/aProject/Sources/LibHeader.h")
                                headermap.checkEntry("Lib/APIHeader1.h", "/tmp/Test/aProject/Sources/APIHeader1.h")
                                headermap.checkEntry("Lib/APIHeader2.h", "/tmp/Test/aProject/Sources/APIHeader2.h")
                                headermap.checkEntry("Lib/SPIHeader1.h", "/tmp/Test/aProject/Sources/SPIHeader1.h")
                                headermap.checkEntry("Lib/SPIHeader2.h", "/tmp/Test/aProject/Sources/SPIHeader2.h")
                                break
                            case "generated-files":
                                headermap.checkEntry("Custom1", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Custom1")
                                headermap.checkEntry("Custom2", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Custom2")
                                headermap.checkEntry("Custom3", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Custom3")
                                headermap.checkEntry("Tool/Custom1", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Custom1")
                                headermap.checkEntry("Tool/Custom2", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Custom2")
                                headermap.checkEntry("Tool/Custom3", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/Custom3")
                                headermap.checkEntry("Tool/regular1.h", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/regular1.h")
                                headermap.checkEntry("Tool/regular1User.c", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/regular1User.c")
                                headermap.checkEntry("Tool/some1", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/some1")
                                headermap.checkEntry("Tool/some2", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/some2")
                                headermap.checkEntry("regular1.h", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/regular1.h")
                                headermap.checkEntry("regular1User.c", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/regular1User.c")
                                headermap.checkEntry("some1", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/some1")
                                headermap.checkEntry("some2", "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/DerivedSources/some2")
                                break
                            default:
                                Issue.record("Unhandled headermap")
                                break
                            }

                            headermap.checkNoEntries()
                        //}
                    }
                }
            }
        }
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                #expect(headermapBasenames.count == hmapContents.count)
                for (basename, hmapContents) in zip(headermapBasenames, hmapContents) {
                    #expect(!hmapContents.isEmpty)
                    results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("Tool-\(basename).hmap")) { headermap in
                        #expect(headermap.rawBytes == hmapContents)
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func allHeadersHeadermapUse() async throws {

        func buildConfiguration(withName name: String, extraSettings: [String: String]) async throws -> TestBuildConfiguration {
            let clangCompilerPath = try await self.clangCompilerPath
            let libClangPath = try await self.libClangPath
            return try await TestBuildConfiguration(name, buildSettings: [
                "CC": clangCompilerPath.str,
                "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                "CLANG_USE_RESPONSE_FILE": "NO",
                "GENERATE_INFOPLIST_FILE": "YES",
                "PRODUCT_NAME": "$(TARGET_NAME)",
                "SWIFT_EXEC": swiftCompilerPath.str,
                "SWIFT_VERSION": swiftVersion,
            ].merging(extraSettings, uniquingKeysWith: { a, b in a }))
        }

        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("main.c"),
                    TestFile("source.swift"),
                    TestFile("Framework.h"),
                ]),
            targets: [
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [
                        buildConfiguration(withName: "ModulesOffVFSOffDefineModuleOff", extraSettings: [:]),
                        buildConfiguration(withName: "ModulesOnVFSOffDefineModuleOff", extraSettings: ["CLANG_ENABLE_MODULES": "YES"]),
                        buildConfiguration(withName: "ModulesOffVFSOnDefineModuleOff", extraSettings: ["HEADERMAP_USES_VFS": "YES"]),
                        buildConfiguration(withName: "ModulesOnVFSOnDefineModuleOff", extraSettings: ["CLANG_ENABLE_MODULES": "YES", "HEADERMAP_USES_VFS": "YES"]),
                        buildConfiguration(withName: "ModulesOffVFSOffDefineModuleOn", extraSettings: [:]),
                        buildConfiguration(withName: "ModulesOnVFSOffDefineModuleOn", extraSettings: ["CLANG_ENABLE_MODULES": "YES"]),
                        buildConfiguration(withName: "ModulesOffVFSOnDefineModuleOn", extraSettings: ["HEADERMAP_USES_VFS": "YES"]),
                        buildConfiguration(withName: "ModulesOnVFSOnDefineModuleOn", extraSettings: ["CLANG_ENABLE_MODULES": "YES", "HEADERMAP_USES_VFS": "YES"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.c",
                            "source.swift",
                        ]),
                    ]),
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildConfigurations: [
                        buildConfiguration(withName: "ModulesOffVFSOffDefineModuleOff", extraSettings: [:]),
                        buildConfiguration(withName: "ModulesOnVFSOffDefineModuleOff", extraSettings: [:]),
                        buildConfiguration(withName: "ModulesOffVFSOnDefineModuleOff", extraSettings: [:]),
                        buildConfiguration(withName: "ModulesOnVFSOnDefineModuleOff", extraSettings: [:]),
                        buildConfiguration(withName: "ModulesOffVFSOffDefineModuleOn", extraSettings: ["DEFINES_MODULE": "YES"]),
                        buildConfiguration(withName: "ModulesOnVFSOffDefineModuleOn", extraSettings: ["DEFINES_MODULE": "YES"]),
                        buildConfiguration(withName: "ModulesOffVFSOnDefineModuleOn", extraSettings: ["DEFINES_MODULE": "YES"]),
                        buildConfiguration(withName: "ModulesOnVFSOnDefineModuleOn", extraSettings: ["DEFINES_MODULE": "YES"]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Framework.h", headerVisibility: .public),
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        func checkBuild(configurationName: String, clangUsesAllTargetHeaders: Bool, swiftUsesAllTargetHeaders: Bool, buildRequest: BuildRequest? = nil, sourceLocation: SourceLocation = #_sourceLocation) async {
            let targetName = (buildRequest == nil) ? "Application" : nil
            await tester.checkBuild(BuildParameters(configuration: configurationName), runDestination: .macOS, targetName: targetName, buildRequest: buildRequest) { results in
                results.checkTarget("Application") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        if clangUsesAllTargetHeaders {
                            task.checkCommandLineMatches([.contains("Application-all-target-headers.hmap")], sourceLocation: sourceLocation)
                        } else {
                            task.checkCommandLineNoMatch([.contains("Application-all-target-headers.hmap")], sourceLocation: sourceLocation)
                        }
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        if swiftUsesAllTargetHeaders {
                            task.checkCommandLineMatches([.contains("Application-all-target-headers.hmap")], sourceLocation: sourceLocation)
                        } else {
                            task.checkCommandLineNoMatch([.contains("Application-all-target-headers.hmap")], sourceLocation: sourceLocation)
                        }
                    }
                }
            }
        }

        // When the application builds by itself, all-target-headers.hmap is used unless the VFS is specifically requested.
        for configurationName in ["ModulesOffVFSOffDefineModuleOff", "ModulesOnVFSOffDefineModuleOff"] {
            await checkBuild(configurationName: configurationName, clangUsesAllTargetHeaders: true, swiftUsesAllTargetHeaders: true)
        }

        // If the VFS is requested, all-target-headers.hmap is not used if modules are not used
        await checkBuild(configurationName: "ModulesOffVFSOnDefineModuleOff", clangUsesAllTargetHeaders: true, swiftUsesAllTargetHeaders: false)
        await checkBuild(configurationName: "ModulesOnVFSOnDefineModuleOff", clangUsesAllTargetHeaders: false, swiftUsesAllTargetHeaders: false)

        let emptyParameters = BuildParameters(configuration: "")
        let buildTargets = tester.workspace.projects[0].targets.map { BuildRequest.BuildTargetInfo(parameters: emptyParameters, target: $0) }
        let buildRequest = BuildRequest(parameters: emptyParameters, buildTargets: buildTargets, dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        // When the application builds with the framework, the behavior is the same if the framework doesn't define a module.
        for configurationName in ["ModulesOffVFSOffDefineModuleOff", "ModulesOnVFSOffDefineModuleOff"] {
            await checkBuild(configurationName: configurationName, clangUsesAllTargetHeaders: true, swiftUsesAllTargetHeaders: true, buildRequest: buildRequest)
        }
        await checkBuild(configurationName: "ModulesOffVFSOnDefineModuleOff", clangUsesAllTargetHeaders: true, swiftUsesAllTargetHeaders: false, buildRequest: buildRequest)
        await checkBuild(configurationName: "ModulesOnVFSOnDefineModuleOff", clangUsesAllTargetHeaders: false, swiftUsesAllTargetHeaders: false, buildRequest: buildRequest)

        // When the framework does define a module, it will block all-target-headers.hmap if modules are used.
        for configurationName in ["ModulesOffVFSOffDefineModuleOn", "ModulesOffVFSOnDefineModuleOn"] {
            await checkBuild(configurationName: configurationName, clangUsesAllTargetHeaders: true, swiftUsesAllTargetHeaders: false, buildRequest: buildRequest)
        }
        for configurationName in ["ModulesOnVFSOffDefineModuleOn", "ModulesOnVFSOnDefineModuleOn"] {
            await checkBuild(configurationName: configurationName, clangUsesAllTargetHeaders: false, swiftUsesAllTargetHeaders: false, buildRequest: buildRequest)
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkEntriesForTargetsNotBeingBuilt() async throws {
        let testProject = TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("main.c"),
                    TestFile("Header.h"),
                ]),
            targets: [
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Default", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                        TestBuildConfiguration("Off", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "HEADERMAP_INCLUDES_FRAMEWORK_ENTRIES_FOR_TARGETS_NOT_BEING_BUILT": "NO",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                        TestBuildConfiguration("On", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "HEADERMAP_INCLUDES_FRAMEWORK_ENTRIES_FOR_TARGETS_NOT_BEING_BUILT": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.c",
                        ]),
                    ]),
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Header.h", headerVisibility: .public),
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        for configurationName in ["Default", "Off", "On"] {
            await tester.checkBuild(BuildParameters(configuration: configurationName), runDestination: .macOS, targetName: "Application") { results in
                results.checkTarget("Application") { target in
                    results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("Application-all-non-framework-target-headers.hmap")) { headermap in
                        if configurationName != "Off" {
                            headermap.checkEntry("Framework/Header.h", "/tmp/Test/Project/Header.h")
                        }
                        headermap.checkNoEntries()
                    }
                }
            }
        }
    }
}
