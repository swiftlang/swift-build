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

import SWBCore
import SWBTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct DiscoveredDependenciesBuildOperationTests: CoreBasedTests {
    /// Check that failing to read discovered dependencies still fails the task even if the process execution succeeded.
    @Test(.requireSDKs(.macOS))
    func discoveredDependenciesSetupFailure() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("proc.c"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CC": "/usr/bin/true", // use `true` so the process succeeds but won't write any dependency file
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Client", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["proc.c"]),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/proc.c")) { contents in
                contents <<< "int main() { return 0; }\n"
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("CompileC")) { task in
                    results.checkError(.prefix("unable to open dependencies file"))
                    results.checkWarning(.contains("Could not read serialized diagnostics file"))

                    // Even though the underlying `/usr/bin/true` will have succeeded, not being able to open discovered dependencies should be an overriding failure.
                    results.checkTaskResult(task, expected: .exit(exitStatus: .exit(1), metrics: nil))
                }

                results.checkNoDiagnostics()
            }
        }
    }

    /// Check the handling of Swift discovered dependencies.
    @Test(.requireSDKs(.macOS))
    func swiftDiscoveredDeps() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("Client.swift"),
                                TestFile("Dep.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Client", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["Client.swift"]),
                                    TestFrameworksBuildPhase(["Dep.framework"])
                                ],
                                dependencies: ["Dep"]),
                            TestStandardTarget(
                                "Dep", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["Dep.swift"]),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Dep.swift")) { contents in
                contents <<< "public func dep0() {}\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Client.swift")) { contents in
                contents <<< "import Dep\n"
                contents <<< "public func client1() {\n"
                contents <<< "  Dep.dep0()\n"
                contents <<< "}\n"
            }

            func checkDriverContainerTasks(_ results: BuildOperationTester.BuildResults) {
                results.checkTasks(.matchRuleType("SwiftDriver")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("SwiftDriver Compilation Requirements")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { tasks in
                    #expect(tasks.count == 2)
                }
            }

            // Check the initial build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true, serial: true) { results in
                results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "WriteAuxiliaryFile", "SymLink", "CreateBuildDirectory", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "ClangStatCache", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports"])

                checkDriverContainerTasks(results)

                results.checkTasks(.matchRuleType("SwiftCompile")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("SwiftEmitModule")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("SwiftMergeGeneratedHeaders")) { tasks in
                    #expect(tasks.count == 2)
                }

                if SWBFeatureFlag.enableEagerLinkingByDefault.value {
                    results.checkTasks(.matchRuleType("GenerateTAPI")) { tasks in
                        #expect(tasks.count == 2)
                    }
                }

                results.checkTasks(.matchRuleType("Ld")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("GenerateTAPI")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("Copy")) { tasks in
                    #expect(tasks.count == 8)
                }

                results.checkTasks(.matchRuleType("Touch")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }

                results.checkNoTask()
            }

            try await tester.checkNullBuild(runDestination: .macOS, persistent: true)

            // Modify the dep implementation, and rebuild. The swiftmodule of Dep won't change, so Client will not need to run SwiftDriver planning.
            //
            // FIXME: This removal is needed to work around <rdar://problem/29695274>, removal tracked by: <rdar://problem/31455149> [BLOCKED] Remove workarounds for <rdar://problem/29695274>
            try tester.fs.remove(SRCROOT.join("build/aProject.build/Debug/Dep.build/Objects-normal/x86_64/Dep.o"))
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Dep.swift")) { contents in
                contents <<< "public func dep0() { print() }\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // We need to rebuild Dep, relink its framework (since the impl changed), and relink Client (since we don't yet analyze API-based deps).
                results.consumeTasksMatchingRuleTypes(["Gate"])
                results.checkTaskExists(.matchTargetName("Dep"), .matchRuleType("SwiftCompile"))
                results.checkTaskExists(.matchTargetName("Dep"), .matchRuleType("SwiftEmitModule"))
                results.checkTaskExists(.matchTargetName("Dep"), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTargetName("Dep"), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTaskExists(.matchTargetName("Dep"), .matchRuleType("SwiftDriver"))

                if SWBFeatureFlag.enableEagerLinkingByDefault.value {
                    results.checkTasks(.matchRuleType("GenerateTAPI")) { tasks in
                        #expect(tasks.count == 1)
                    }
                }

                results.checkTaskExists(.matchRuleType("Ld"), .matchTargetName("Dep"))
                results.checkTaskExists(.matchRuleType("GenerateTAPI"), .matchTargetName("Dep"))
                results.checkTaskExists(.matchRuleType("Copy"), .matchRuleItemBasename("Dep.swiftsourceinfo"))

                if tester.fs.fileSystemMode != .checksumOnly {
                    if try await discoveredTAPIToolInfo(at: tapiToolPath).toolVersion < Version(1500, 0, 8, 4, 1) {
                        results.checkTaskExists(.matchRuleType("Ld"), .matchTargetName("Client"))
                        results.checkTaskExists(.matchRuleType("GenerateTAPI"), .matchTargetName("Client"))
                    }
                    results.checkTaskExists(.matchRuleType("Copy"), .matchRuleItemBasename("Dep.abi.json"))
                }

                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
                results.checkTasks(.matchRuleType("ClangStatCache")) { _ in }
                results.checkTasks(.matchRuleType("ProcessSDKImports")) { _ in }
                results.checkNoTask()
            }


            try await tester.checkNullBuild(runDestination: .macOS, persistent: true)

            // Change the public API of the dep, and rebuild.
            //
            // FIXME: This removal is needed to work around <rdar://problem/29695274>, removal tracked by: <rdar://problem/31455149> [BLOCKED] Remove workarounds for <rdar://problem/29695274>
            try tester.fs.remove(SRCROOT.join("build/aProject.build/Debug/Dep.build/Objects-normal/x86_64/Dep.o"))
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Dep.swift")) { contents in
                contents <<< "public func dep0() { }\n"
                contents <<< "public func dep1() { }\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true, serial: true) { results in
                // We should rebuild Dep, recopy its .swiftmodule, rebuild the client, and relink both.
                //
                // FIXME: Why doesn't this trigger the bug where we sometimes stat the module ahead of when it is needed? That was the purpose of this test so we need to get this to fail more before we fix it.
                results.consumeTasksMatchingRuleTypes(["Gate"])

                checkDriverContainerTasks(results)

                results.checkTasks(.matchRuleType("SwiftCompile")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTasks(.matchRuleType("SwiftEmitModule")) { tasks in
                    #expect(tasks.count == 2)
                }

                if SWBFeatureFlag.enableEagerLinkingByDefault.value {
                    results.checkTasks(.matchRuleType("GenerateTAPI")) { tasks in
                        #expect(tasks.count == 1)
                    }
                }

                results.checkTasks(.matchRuleType("Ld")) { tasks in
                    #expect(tasks.count == 2)
                }

                results.checkTaskExists(.matchRuleType("GenerateTAPI"), .matchTargetName("Dep"))
                results.checkTaskExists(.matchRuleType("Copy"), .matchRuleItemBasename("Dep.swiftsourceinfo"))
                results.checkTaskExists(.matchRuleType("Copy"), .matchRuleItemBasename("Dep.swiftmodule"))

                if tester.fs.fileSystemMode != .checksumOnly {
                    results.checkTaskExists(.matchRuleType("GenerateTAPI"), .matchTargetName("Client"))
                    results.checkTaskExists(.matchRuleType("Copy"), .matchRuleItemBasename("Dep.abi.json"))
                    results.checkTaskExists(.matchRuleType("Copy"), .matchRuleItemBasename("Client.abi.json"))
                }

                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
                results.checkTasks(.matchRuleType("ClangStatCache")) { _ in }
                results.checkTasks(.matchRuleType("ProcessSDKImports")) { _ in }

                results.checkNoTask()
            }

            // Check that we get a null build.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true)
        }
    }

    // This tests checks for a very particular sequence of actions that lead to a cyclical dependency error. The gist of
    // it is that <rdar://59011589> clang incorrectly adds the module it is building for as a dependency through an
    // LC_LINKER_OPTION. This leads to the linker linking a binary against itself, which is propagated to llbuild
    // through the discovered dependencies mechanism. This manifests as a warning from ld in some toolchains. Now, if we pair this with TAPI, llbuild will detect a cyclical dependency and
    // Swift Build will show an error as in <rdar://58963825>.
    @Test(.requireSDKs(.macOS))
    func complexSymlinkCaseWithDiscoveredDependencies() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let SRCROOT = tmpDirPath.join("Test")

            let testProject = TestProject(
                "aProject",
                sourceRoot: SRCROOT,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Fmwk.m"),
                        TestFile("Fmwk_something_public.h"),
                        TestFile("Fmwk_something_private.h"),
                        TestFile("Fmwk.h"),
                        TestFile("Fmwk_Private.h"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "DEFINES_MODULE": "YES",
                        "CLANG_ENABLE_MODULES": "YES",
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Fmwk",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "INFOPLIST_FILE": "Info.plist",
                                "MODULEMAP_PRIVATE_FILE": "module.private.modulemap",
                                "GENERATE_TEXT_BASED_STUBS": "YES",
                                "PRODUCT_MODULE_NAME": "$(PRODUCT_NAME)"
                            ])],
                        buildPhases: [
                            TestSourcesBuildPhase(["Fmwk.m"]),
                            TestHeadersBuildPhase([
                                TestBuildFile("Fmwk_something_public.h", headerVisibility: .public),
                                TestBuildFile("Fmwk_something_private.h", headerVisibility: .private),
                                TestBuildFile("Fmwk.h", headerVisibility: .public),
                                TestBuildFile("Fmwk_Private.h", headerVisibility: .private),
                            ])
                        ]
                    ),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fmwkSource = SRCROOT.join("Fmwk.m")
            let somethingPublicHeader = SRCROOT.join("Fmwk_something_public.h")
            let somethingPrivateHeader = SRCROOT.join("Fmwk_something_private.h")
            let publicFmwkHeader = SRCROOT.join("Fmwk.h")
            let privateFmwkHeader = SRCROOT.join("Fmwk_Private.h")
            let privateModuleMap = SRCROOT.join("module.private.modulemap")
            let infoPlist = SRCROOT.join("Info.plist")

            try tester.fs.createDirectory(SRCROOT)
            try tester.fs.write(fmwkSource, contents: """
    #import <Fmwk/Fmwk_something_private.h>
    int shared = 1;
    """)
            try tester.fs.write(somethingPublicHeader, contents: "// Empty")
            try tester.fs.write(somethingPrivateHeader, contents: "#import <Fmwk/Fmwk_something_public.h>")
            try tester.fs.write(publicFmwkHeader, contents: "#import <Fmwk/Fmwk_something_public.h>")
            try tester.fs.write(privateFmwkHeader, contents: "#import <Fmwk/Fmwk_something_private.h>")
            try tester.fs.write(privateModuleMap, contents: """
    framework module Fmwk_Private {
        umbrella header "Fmwk_Private.h"
        module * { export * }
        export *
    }
    """)
            try await tester.fs.writePlist(infoPlist, .plDict([:]))

            // Do a first build where everything should be ok.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // Modify the source to trigger compilation and linking.
            try tester.fs.write(fmwkSource, contents: """
    #import <Fmwk/Fmwk_something_private.h>
    int shared = 2;
    """)
            // We're not expecting this build to fail.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // Modify the plist to trigger bundling, but not re-linking.
            try await tester.fs.writePlist(infoPlist, .plDict([:]))

            // Before the fix for linker discovered dependencies, this would have caused a build error.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func linkerDiscoversIntermediateTBDDependencies() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let SRCROOT = tmpDirPath.join("Test")

            let testProject = TestProject(
                "aProject",
                sourceRoot: SRCROOT,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Fmwk.m"),
                        TestFile("Fmwk.h"),
                        TestFile("App.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["App.m"]),
                            TestFrameworksBuildPhase([TestBuildFile(.target("Fmwk"))]),
                        ],
                        dependencies: ["Fmwk"]
                    ),
                    TestStandardTarget(
                        "Fmwk",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase(["Fmwk.m"]),
                            TestHeadersBuildPhase([
                                TestBuildFile("Fmwk.h", headerVisibility: .public),
                            ])
                        ]
                    )
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let frameworkSource = SRCROOT.join("Fmwk.m")
            let frameworkHeader = SRCROOT.join("Fmwk.h")
            let appSource = SRCROOT.join("App.m")

            try tester.fs.createDirectory(SRCROOT)
            try tester.fs.write(frameworkSource, contents: """
                int foo(void) {
                    return 42;
                }
            """)
            try tester.fs.write(frameworkHeader, contents: "int foo(void);")
            try tester.fs.write(appSource, contents: """
                #import <Foundation/Foundation.h>
                #import <Fmwk/Fmwk.h>

                int main(int argc, const char * argv[]) {
                    @autoreleasepool {
                        printf("%d", foo());
                    }
                    return 0;
                }
            """)

            // Do a first build where everything should be ok.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            // The linker dependency info should contain the stub, not the binary.
            let ldDepsPath = SRCROOT.join("build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_dependency_info.dat")
            let dependencyInfo = try DependencyInfo(bytes: tester.fs.read(ldDepsPath).bytes)
            #expect(dependencyInfo.inputs.contains(SRCROOT.join("build/EagerLinkingTBDs/Debug/Fmwk.framework/Fmwk.tbd").str))
            #expect(dependencyInfo.inputs.contains(SRCROOT.join("build/EagerLinkingTBDs/Debug/Fmwk.framework/Versions/A/Fmwk.tbd").str))
            #expect(!dependencyInfo.inputs.contains(SRCROOT.join("build/Debug/Fmwk.framework/Fmwk").str))
            #expect(!dependencyInfo.inputs.contains(SRCROOT.join("build/Debug/Fmwk.framework/Versions/A/Fmwk").str))
        }
    }
}
