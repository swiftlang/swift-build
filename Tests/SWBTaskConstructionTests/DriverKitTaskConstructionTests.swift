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

import class Foundation.ProcessInfo

import Testing
import SWBCore
import SWBTaskConstruction
import SWBTestSupport
@_spi(Testing) import SWBUtil
import SWBProtocol

@Suite
fileprivate struct DriverKitTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.driverKit), arguments: [true, false])
    func driverAndFramework(runUnifdef: Bool) async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("interface.iig"),
                    TestFile("project.iig"),
                    TestFile("private.iig"),
                    TestFile("public.iig"),
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "DEBUG_INFORMATION_FORMAT": "",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "IIG_EXEC": iigPath.str,
                        "OTHER_IIG_FLAGS": "--log \(Path.null.str)",
                        "OTHER_IIG_CFLAGS": "-Werror=deprecated-declarations",
                        "SDKROOT": "driverkit",
                        "IIG_CXX_LANGUAGE_STANDARD": "c++17",
                        "COPY_HEADERS_RUN_UNIFDEF": runUnifdef ? "YES" : "NO",
                        "COPY_HEADERS_UNIFDEF_FLAGS": runUnifdef ? "-DHIDE_FOO" : "",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "DextTarget",
                    type: .driverExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "interface.iig",
                            "main.c",
                        ]),
                    ],
                    dependencies: ["LibraryTarget"]
                ),
                TestStandardTarget(
                    "LibraryTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.c",
                            "project.iig",
                            TestBuildFile("private.iig", headerVisibility: .private),
                            TestBuildFile("public.iig", headerVisibility: .public),
                        ]),
                    ]
                )
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let srcRoot = tester.workspace.projects[0].sourceRoot

        let driverkitSDK = core.loadSDK(.driverKit)
        let hasDriverKitPlatform = driverkitSDK.path.str.contains("DriverKit.platform")

        let fs = PseudoFS()
        try fs.writeSimulatedProvisioningProfile(uuid: "8db0e92c-592c-4f06-bfed-9d945841b78d")

        let iigPath = try await self.iigPath

        await tester.checkBuild(runDestination: hasDriverKitPlatform ? .driverKit : .macOS, fs: fs) { results in
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "CodeSign", "Gate", "Ld", "GenerateTAPI", "MkDir", "RegisterExecutionPolicyException", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "SymLink", "Touch", "WriteAuxiliaryFile"])

            results.checkTarget("DextTarget") { target in
                results.checkTask(.matchRule(["CompileC", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/DextTarget.build/Objects-normal/x86_64/main.o", "\(srcRoot.str)/Sources/main.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in
                    // Ensure that installation of iig-produced headers is treated as a requirement to begin downstream compilation.
                    results.checkTaskFollows(task, .matchTargetName("LibraryTarget"), .matchRuleType("Iig"), .matchRulePattern([.suffix("public.iig")]))
                }

                results.checkTask(.matchRule(["Iig", "\(srcRoot.str)/Sources/interface.iig"])) { task in
                    task.checkCommandLine([iigPath.str, "--def", "\(srcRoot.str)/Sources/interface.iig", "--header", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/DextTarget.build/DerivedSources/DextTarget/interface.h", "--impl", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/DextTarget.build/DerivedSources/DextTarget/interface.iig.cpp", "--deployment-target", driverkitSDK.version, "--log", Path.null.str, "--", "-isysroot", driverkitSDK.path.str, "-x", "c++", "-std=c++17", "-D__IIG=1", "-Werror=deprecated-declarations", "-I/tmp/Test/aProject/build/Debug-driverkit/include", "-F/tmp/Test/aProject/build/Debug-driverkit"])
                }

                results.checkTask(.matchRule(["CompileC", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/DextTarget.build/Objects-normal/x86_64/interface.iig.o", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/DextTarget.build/DerivedSources/DextTarget/interface.iig.cpp", "normal", "x86_64", "c++", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in }

                results.checkNoTask(.matchTarget(target))
            }

            results.checkTarget("LibraryTarget") { target in
                results.checkTask(.matchRule(["CompileC", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/Objects-normal/x86_64/main.o", "\(srcRoot.str)/Sources/main.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in }

                results.checkTask(.matchRule(["Iig", "\(srcRoot.str)/Sources/project.iig"])) { task in
                    task.checkCommandLine([iigPath.str, "--def", "\(srcRoot.str)/Sources/project.iig", "--header", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/project.h", "--impl", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/project.iig.cpp", "--deployment-target", driverkitSDK.version, "--framework-name", "LibraryTarget", "--log", Path.null.str, "--", "-isysroot", driverkitSDK.path.str, "-x", "c++", "-std=c++17", "-D__IIG=1", "-Werror=deprecated-declarations", "-I/tmp/Test/aProject/build/Debug-driverkit/include", "-F/tmp/Test/aProject/build/Debug-driverkit"])
                }

                results.checkTask(.matchRule(["CompileC", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/Objects-normal/x86_64/project.iig.o", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/project.iig.cpp", "normal", "x86_64", "c++", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in }

                results.checkTask(.matchRule(["Iig", "\(srcRoot.str)/Sources/public.iig"])) { task in
                    task.checkCommandLine([iigPath.str, "--def", "\(srcRoot.str)/Sources/public.iig", "--header", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/public.h", "--impl", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/public.iig.cpp", "--deployment-target", driverkitSDK.version, "--framework-name", "LibraryTarget", "--log", Path.null.str, "--", "-isysroot", driverkitSDK.path.str, "-x", "c++", "-std=c++17", "-D__IIG=1", "-Werror=deprecated-declarations", "-I/tmp/Test/aProject/build/Debug-driverkit/include", "-F/tmp/Test/aProject/build/Debug-driverkit"])
                }

                if runUnifdef {
                    results.checkTask(.matchRule(["Unifdef", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/Headers/public.iig", "\(srcRoot.str)/Sources/public.iig"])) { task in
                        task.checkCommandLine(["unifdef", "-x", "2", "-DHIDE_FOO", "-o", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/Headers/public.iig", "\(srcRoot.str)/Sources/public.iig"])
                    }

                    results.checkTask(.matchRule(["Unifdef", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/Headers/public.h", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/public.h"])) { task in
                        task.checkCommandLine(["unifdef", "-x", "2", "-DHIDE_FOO", "-o", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/Headers/public.h", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/public.h"])
                    }
                } else {
                    results.checkTask(.matchRule(["Copy", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/Headers/public.iig", "\(srcRoot.str)/Sources/public.iig"])) { task in }

                    results.checkTask(.matchRule(["CpHeader", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/Headers/public.h", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/public.h"])) { task in }
                }

                results.checkTask(.matchRule(["CompileC", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/Objects-normal/x86_64/public.iig.o", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/public.iig.cpp", "normal", "x86_64", "c++", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in }

                results.checkTask(.matchRule(["Iig", "\(srcRoot.str)/Sources/private.iig"])) { task in
                    task.checkCommandLine([iigPath.str, "--def", "\(srcRoot.str)/Sources/private.iig", "--header", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/private.h", "--impl", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/private.iig.cpp", "--deployment-target", driverkitSDK.version, "--framework-name", "LibraryTarget", "--log", Path.null.str, "--", "-isysroot", driverkitSDK.path.str, "-x", "c++", "-std=c++17", "-D__IIG=1", "-Werror=deprecated-declarations", "-I/tmp/Test/aProject/build/Debug-driverkit/include", "-F/tmp/Test/aProject/build/Debug-driverkit"])
                }

                if runUnifdef {
                    results.checkTask(.matchRule(["Unifdef", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/PrivateHeaders/private.iig", "\(srcRoot.str)/Sources/private.iig"])) { task in
                        task.checkCommandLine(["unifdef", "-x", "2", "-DHIDE_FOO", "-o", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/PrivateHeaders/private.iig", "\(srcRoot.str)/Sources/private.iig"])
                    }

                    results.checkTask(.matchRule(["Unifdef", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/PrivateHeaders/private.h", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/private.h"])) { task in
                        task.checkCommandLine(["unifdef", "-x", "2", "-DHIDE_FOO", "-o", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/PrivateHeaders/private.h", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/private.h"])
                    }
                } else {
                    results.checkTask(.matchRule(["Copy", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/PrivateHeaders/private.iig", "\(srcRoot.str)/Sources/private.iig"])) { task in }

                    results.checkTask(.matchRule(["CpHeader", "\(srcRoot.str)/build/Debug-driverkit/LibraryTarget.framework/PrivateHeaders/private.h", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/private.h"])) { task in }
                }

                results.checkTask(.matchRule(["CompileC", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/Objects-normal/x86_64/private.iig.o", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/private.iig.cpp", "normal", "x86_64", "c++", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in }

                results.checkNoTask(.matchTarget(target))
            }

            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.driverKit), arguments: [true, false])
    func driverKitFrameworkInstallHeaders(trace: Bool) async throws {
        var env = Environment.current.filter { $0.key != EnvironmentKey("IIG_TRACE_HEADERS") }
        if trace {
            env["IIG_TRACE_HEADERS"] = "1"
        }

        try await withEnvironment(env, clean: true) {
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("interface.iig"),
                        TestFile("project.iig"),
                        TestFile("private.iig"),
                        TestFile("public.iig"),
                        TestFile("main.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "OTHER_IIG_FLAGS": "--log \(Path.null.str)",
                            "OTHER_IIG_CFLAGS": "-Werror=deprecated-declarations",
                            "SDKROOT": "driverkit",
                            "SUPPORTS_TEXT_BASED_API": "YES",
                            "TAPI_EXEC": tapiToolPath.str,
                            "IIG_EXEC": iigPath.str,
                            "IIG_CXX_LANGUAGE_STANDARD": "c++17",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "LibraryTarget",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "main.c",
                                "project.iig",
                                TestBuildFile("private.iig", headerVisibility: .private),
                                TestBuildFile("public.iig", headerVisibility: .public),
                            ]),
                        ]
                    )
                ])
            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            let srcRoot = tester.workspace.projects[0].sourceRoot
            let driverkitSDK = core.loadSDK(.driverKit)

            let iigPath = try await self.iigPath

            if trace {
                await tester.checkBuild(BuildParameters(action: .installHeaders, configuration: "Debug", overrides: ["EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING": "YES"]), runDestination: .macOS) { results in
                    results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "CodeSign", "Gate", "Ld", "MkDir", "RegisterExecutionPolicyException", "ProcessInfoPlistFile", "ProcessProductPackaging", "SymLink", "Touch", "WriteAuxiliaryFile"])

                    results.checkTarget("LibraryTarget") { target in
                        results.checkTask(.matchRule(["Iig", "\(srcRoot.str)/Sources/project.iig"])) { task in
                            task.checkCommandLine([iigPath.str, "--def", "\(srcRoot.str)/Sources/project.iig", "--header", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/project.h", "--impl", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/project.iig.cpp", "--deployment-target", driverkitSDK.version, "--framework-name", "LibraryTarget", "--log", Path.null.str, "--", "-isysroot", driverkitSDK.path.str, "-x", "c++", "-std=c++17", "-D__IIG=1", "-Werror=deprecated-declarations", "-I/tmp/Test/aProject/build/Debug-driverkit/include", "-F/tmp/Test/aProject/build/Debug-driverkit"])
                        }

                        results.checkTask(.matchRule(["Iig", "\(srcRoot.str)/Sources/public.iig"])) { task in
                            task.checkCommandLine([iigPath.str, "--def", "\(srcRoot.str)/Sources/public.iig", "--header", "/tmp/Test/aProject/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/public.h", "--impl", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/public.iig.cpp", "--deployment-target", driverkitSDK.version, "--framework-name", "LibraryTarget", "--log", Path.null.str, "--", "-isysroot", driverkitSDK.path.str, "-x", "c++", "-std=c++17", "-D__IIG=1", "-Werror=deprecated-declarations", "-I/tmp/Test/aProject/build/Debug-driverkit/include", "-F/tmp/Test/aProject/build/Debug-driverkit"])
                        }

                        results.checkTask(.matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/LibraryTarget.framework/Headers/public.iig", "\(srcRoot.str)/Sources/public.iig"])) { task in }

                        results.checkTask(.matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/LibraryTarget.framework/Headers/public.h", "/tmp/Test/aProject/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/public.h"])) { task in }

                        results.checkTask(.matchRule(["Iig", "\(srcRoot.str)/Sources/private.iig"])) { task in
                            task.checkCommandLine([iigPath.str, "--def", "\(srcRoot.str)/Sources/private.iig", "--header", "/tmp/Test/aProject/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/private.h", "--impl", "\(srcRoot.str)/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/private.iig.cpp", "--deployment-target", driverkitSDK.version, "--framework-name", "LibraryTarget", "--log", Path.null.str, "--", "-isysroot", driverkitSDK.path.str, "-x", "c++", "-std=c++17", "-D__IIG=1", "-Werror=deprecated-declarations", "-I/tmp/Test/aProject/build/Debug-driverkit/include", "-F/tmp/Test/aProject/build/Debug-driverkit"])
                        }

                        results.checkTask(.matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/LibraryTarget.framework/PrivateHeaders/private.iig", "\(srcRoot.str)/Sources/private.iig"])) { task in }

                        results.checkTask(.matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/LibraryTarget.framework/PrivateHeaders/private.h", "/tmp/Test/aProject/build/aProject.build/Debug-driverkit/LibraryTarget.build/DerivedSources/LibraryTarget/private.h"])) { task in }

                        results.checkNoTask(.matchTarget(target))
                    }

                    results.checkNoTask()

                    results.checkNoDiagnostics()
                }
            } else {
                // installhdrs and installapi should only install the iig files.
                await tester.checkBuild(BuildParameters(action: .installHeaders, configuration: "Debug", overrides: ["EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING": "YES"]), runDestination: .macOS) { results in
                    results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "CodeSign", "Gate", "Ld", "MkDir", "RegisterExecutionPolicyException", "ProcessInfoPlistFile", "ProcessProductPackaging", "SymLink", "Touch", "WriteAuxiliaryFile"])

                    results.checkTarget("LibraryTarget") { target in
                        results.checkTask(.matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/LibraryTarget.framework/Headers/public.iig", "\(srcRoot.str)/Sources/public.iig"])) { task in }
                        results.checkTask(.matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/LibraryTarget.framework/PrivateHeaders/private.iig", "\(srcRoot.str)/Sources/private.iig"])) { task in }

                        results.checkNoTask(.matchTarget(target))
                    }

                    results.checkNoTask()

                    // Check there are no diagnostics.
                    results.checkNoDiagnostics()
                }
                await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS) { results in
                    results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "CodeSign", "Gate", "GenerateTAPI", "Ld", "MkDir", "RegisterExecutionPolicyException", "ProcessInfoPlistFile", "ProcessProductPackaging", "SymLink", "Touch", "WriteAuxiliaryFile"])

                    results.checkTarget("LibraryTarget") { target in
                        results.checkTask(.matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/LibraryTarget.framework/Headers/public.iig", "\(srcRoot.str)/Sources/public.iig"])) { task in }
                        results.checkTask(.matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/LibraryTarget.framework/PrivateHeaders/private.iig", "\(srcRoot.str)/Sources/private.iig"])) { task in }

                        results.checkNoTask(.matchTarget(target))
                    }

                    results.checkNoTask()

                    results.checkNoDiagnostics()
                }
            }
        }
    }

    @Test(.requireSDKs(.driverKit))
    func driverKitAnalyze() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("main.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "driverkit",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "DextTarget",
                        type: .driverExtension,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "main.c",
                            ]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            let fs = PseudoFS()
            try fs.writeSimulatedProvisioningProfile(uuid: "8db0e92c-592c-4f06-bfed-9d945841b78d")

            // Analyze for a generic destination should analyze arm64 + x86_64
            await tester.checkBuild(BuildParameters(action: .analyze, configuration: "Debug", overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), runDestination: .anyDriverKit, fs: fs) { results in
                results.checkTask(.matchRule(["AnalyzeShallow", "\(tmpDir.str)/Sources/main.c", "normal", "arm64"])) { _ in }
                results.checkTask(.matchRule(["AnalyzeShallow", "\(tmpDir.str)/Sources/main.c", "normal", "x86_64"])) { _ in }
                results.checkNoTask(.matchRuleItem("AnalyzeShallow"))
                results.checkNoDiagnostics()
            }

            // Analyze for concrete destinations should only analyze those architectures
            await tester.checkBuild(BuildParameters(action: .analyze, configuration: "Debug", overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), runDestination: .driverKitAppleSilicon, fs: fs) { results in
                results.checkTask(.matchRule(["AnalyzeShallow", "\(tmpDir.str)/Sources/main.c", "normal", "arm64"])) { _ in }
                results.checkNoTask(.matchRuleItem("AnalyzeShallow"))
                results.checkNoDiagnostics()
            }

            await tester.checkBuild(BuildParameters(action: .analyze, configuration: "Debug", overrides: ["RUN_CLANG_STATIC_ANALYZER": "YES"]), runDestination: .driverKitIntel, fs: fs) { results in
                results.checkTask(.matchRule(["AnalyzeShallow", "\(tmpDir.str)/Sources/main.c", "normal", "x86_64"])) { _ in }
                results.checkNoTask(.matchRuleItem("AnalyzeShallow"))
                results.checkNoDiagnostics()
            }
        }
    }
}
