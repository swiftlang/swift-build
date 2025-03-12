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

import SWBUtil
import SWBBuildSystem
import SWBCore
import SWBTestSupport

@Suite(.requireXcode16())
fileprivate struct HeadermapModuleCompatibilityTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func implicitDependency() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            // Set up a project with a framework and client. They need to be independently buildable
            // for environments where the client might have an external dependency that also
            // depends on the framework. Therefore the client doesn't have a declared dependency on
            // the framework so that the build order can go Framework, then External, then Client,
            // and building Client doesn't rebuild Framework.
            let testProject = TestProject(
                "Project",
                sourceRoot: temporaryDirectory.join("Project"),
                groupTree: TestGroup(
                    "Group",
                    children: [
                        TestGroup(
                            "Client",
                            path: "Client",
                            children: [
                                TestFile("main.m"),
                            ]),
                        TestGroup(
                            "Framework",
                            path: "Framework",
                            children: [
                                TestFile("Framework.modulemap"),
                                TestFile("Framework.h"),
                                TestFile("Object.h"),
                            ]),
                    ]),
                targets: [
                    TestStandardTarget(
                        "Client-Default",
                        type: .application,
                        buildConfigurations: [
                            // The default all-target-headers.hmap will make this setup fail.
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "main.m",
                            ]),
                        ]),
                    TestStandardTarget(
                        "Client-UseVFS",
                        type: .application,
                        buildConfigurations: [
                            // Forcing HEADERMAP_USES_VFS will turn off all-target-headers.hmap,
                            // but its replacement all-non-framework-target-headers.hmap will
                            // cause the same failure.
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                                "HEADERMAP_USES_VFS": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "main.m",
                            ]),
                        ]),
                    TestStandardTarget(
                        "Client-NoFrameworkEntries",
                        type: .application,
                        buildConfigurations: [
                            // HEADERMAP_INCLUDES_FRAMEWORK_ENTRIES_FOR_TARGETS_NOT_BEING_BUILT
                            // will neuter all-non-framework-target-headers.hmap enough that this
                            // setup will work.
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                                "HEADERMAP_INCLUDES_FRAMEWORK_ENTRIES_FOR_TARGETS_NOT_BEING_BUILT": "NO",
                                "HEADERMAP_USES_VFS": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "main.m",
                            ]),
                        ]),
                    TestStandardTarget(
                        "Framework",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "DEFINES_MODULE": "YES",
                                "MODULEMAP_FILE": "Framework/Framework.modulemap",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("Framework.h", headerVisibility: .public),
                                TestBuildFile("Object.h", headerVisibility: .public),
                            ]),
                        ]),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)

            // A common interoperability issue with header maps and clang modules is that the same
            // header is seen in both the source directory and the build or SDK directories. This
            // happens when header maps redirect #include's back to the source directory, and module
            // maps read headers relative to the module map.
            try await tester.fs.writeFileContents(temporaryDirectory.join("Project/Client/main.m")) {
                // Force building the Framework module. #import would be redirected by header maps
                // to Project/Framework.h which isn't in any kind of module structure on disk.
                // However, @import does a module lookup and build.
                // Also make sure that quoted includes still resolve via header maps.
                $0.write("""
                    @import Framework;
                    #import "Object.h"

                    int main(int argc, const char *argv[]) {
                        return 0;
                    }
                """)
            }
            try await tester.fs.writeFileContents(temporaryDirectory.join("Project/Framework/Framework.modulemap")) {
                // Force seeing Object.h outside of the influence of header maps by explicitly
                // accessing it in a `header` declaration, which is resolved relative to the
                // module map file. [system] is so -Wnon-modular-include-in-framework-module
                // doesn't hide the redeclaration error (and to better simulate real modules).
                $0.write("""
                    framework module Framework [system] {
                      umbrella header "Framework.h"

                      module Object {
                        header "Object.h"
                      }
                    }
                """)
            }
            try await tester.fs.writeFileContents(temporaryDirectory.join("Project/Framework/Framework.h")) {
                // Force seeing Object.h under the influence of header maps by including it
                // from another header in the module.
                $0.write("#import <Framework/Object.h>")
            }
            try await tester.fs.writeFileContents(temporaryDirectory.join("Project/Framework/Object.h")) {
                // Add a declaration to the header file that will cause a conflict when seen twice.
                $0.write("""
                    @interface Object
                    @end
                """)
            }

            let buildParameters = BuildParameters(configuration: "Debug")
            func buildRequest(_ targetIndex: Array.Index) -> BuildRequest {
                return BuildRequest(
                    parameters: buildParameters,
                    buildTargets: [
                        BuildRequest.BuildTargetInfo(parameters: buildParameters, target: tester.workspace.projects[0].targets[targetIndex]),
                    ],
                    continueBuildingAfterErrors: false,
                    useParallelTargets: false,
                    useImplicitDependencies: false,
                    useDryRun: false
                )
            }

            // Build the framework first so that its module can be found in the build directory.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest(3)) { results in
                results.checkNoDiagnostics()
            }

            for targetIndex in [0, 1, 2] {
                try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest(targetIndex)) { results in
                    if targetIndex != 2 {
                        // The client should fail to build by default, and forcing HEADERMAP_USES_VFS won't help.
                        results.checkError(.prefix("\(temporaryDirectory.str)/Project/build/Debug/Framework.framework/Headers/Object.h:1:5: [Semantic Issue] duplicate interface definition for class 'Object'"))
                        results.checkError(.prefix("Command PrecompileModule failed."))
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }
}
