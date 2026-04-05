//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing

import SWBCore
import SWBProtocol
import SWBTaskConstruction
import SWBTestSupport
@_spi(Testing) import SWBUtil

@Suite
fileprivate struct ToolsetTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func staticResourceDirectorySelection_toolsetImposesStaticStdlib() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sdkManifestDir = tmpDir.join("TestSDK.artifactbundle")

            let dynamicSwiftResourcesPath = "swift.xctoolchain/usr/lib/swift"
            let staticSwiftResourcesPath = "swift.xctoolchain/usr/lib/swift_static"
            let dynamicSwiftResourceDir = sdkManifestDir.join(dynamicSwiftResourcesPath)
            let dynamicClangResourceDir = dynamicSwiftResourceDir.join("clang")

            try localFS.createDirectory(sdkManifestDir)
            let sdkManifestPath = sdkManifestDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestPath) { $0 <<< """
                {
                    "schemaVersion" : "4.0",
                    "targetTriples" : {
                        "x86_64-unknown-linux-gnu" : {
                            "sdkRootPath" : "sysroot",
                            "swiftResourcesPath" : "\(dynamicSwiftResourcesPath)",
                            "swiftStaticResourcesPath" : "\(staticSwiftResourcesPath)",
                            "toolsetPaths" : [
                                "static-toolset.json"
                            ]
                        }
                    }
                }
                """
            }

            try await localFS.writeFileContents(sdkManifestDir.join("static-toolset.json")) { stream in
                stream.write("""
                {
                    "schemaVersion" : "1.0",
                    "swiftCompiler" : {
                        "extraCLIOptions" : [
                            "-static-stdlib"
                        ]
                    }
                }
                """)
            }

            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("a.c"),
                        TestFile("b.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "SwiftTool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "SWIFT_VERSION": try await swiftVersion,
                                                    "LINKER_DRIVER": "swiftc",
                                                    "SWIFT_EXEC": try await swiftCompilerPath.strWithPosixSlashes,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("b.swift"),
                            ]),
                        ], dependencies: ["ClangTool"]),
                    TestStandardTarget(
                        "ClangTool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                    "LINKER_DRIVER": "clang",
                                                    "CC": try await clangCompilerPath.strWithPosixSlashes,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("a.c"),
                            ]),
                        ]),
                ])

            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "x86_64-unknown-linux-gnu", targetArchitecture: "x86_64", supportedArchitectures: ["x86_64"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

            await tester.checkBuild(parameters, runDestination: nil, fs: localFS) { results in

                results.checkTarget("SwiftTool") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-resource-dir", dynamicSwiftResourceDir.str])
                        task.checkCommandLineContains(["-static-stdlib"])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-resource-dir", dynamicSwiftResourceDir.str])
                        task.checkCommandLineContains(["-Xclang-linker", "-resource-dir", "-Xclang-linker", dynamicClangResourceDir.str])
                    }
                }

                results.checkTarget("ClangTool") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-resource-dir", dynamicClangResourceDir.str])
                    }
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.host))
    func staticResourceDirectorySelection_requestImposesStaticStdlib() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sdkManifestDir = tmpDir.join("TestSDK.artifactbundle")

            let dynamicSwiftResourcesPath = "swift.xctoolchain/usr/lib/swift"
            let staticSwiftResourcesPath = "swift.xctoolchain/usr/lib/swift_static"
            let staticSwiftResourceDir = sdkManifestDir.join(staticSwiftResourcesPath)
            let staticClangResourceDir = staticSwiftResourceDir.join("clang")

            try localFS.createDirectory(sdkManifestDir)
            let sdkManifestPath = sdkManifestDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestPath) { $0 <<< """
                {
                    "schemaVersion" : "4.0",
                    "targetTriples" : {
                        "x86_64-unknown-linux-gnu" : {
                            "sdkRootPath" : "sysroot",
                            "swiftResourcesPath" : "\(dynamicSwiftResourcesPath)",
                            "swiftStaticResourcesPath" : "\(staticSwiftResourcesPath)",
                            "toolsetPaths" : [
                                "static-toolset.json"
                            ]
                        }
                    }
                }
                """
            }

            try await localFS.writeFileContents(sdkManifestDir.join("static-toolset.json")) { stream in
                stream.write("""
                {
                    "schemaVersion" : "1.0",
                    "swiftCompiler" : {
                        "extraCLIOptions" : [
                            "-static-stdlib"
                        ]
                    }
                }
                """)
            }

            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("a.c"),
                        TestFile("b.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "SwiftTool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "SWIFT_VERSION": try await swiftVersion,
                                                    "LINKER_DRIVER": "swiftc",
                                                    "SWIFT_EXEC": try await swiftCompilerPath.strWithPosixSlashes,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("b.swift"),
                            ]),
                        ], dependencies: ["ClangTool"]),
                    TestStandardTarget(
                        "ClangTool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                    "LINKER_DRIVER": "clang",
                                                    "CC": try await clangCompilerPath.strWithPosixSlashes,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("a.c"),
                            ]),
                        ]),
                ])

            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "x86_64-unknown-linux-gnu", targetArchitecture: "x86_64", supportedArchitectures: ["x86_64"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination, overrides: ["SWIFT_FORCE_STATIC_LINK_STDLIB": "YES"])

            await tester.checkBuild(parameters, runDestination: nil, fs: localFS) { results in

                results.checkTarget("SwiftTool") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-resource-dir", staticSwiftResourceDir.str])
                        task.checkCommandLineContains(["-static-stdlib"])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-resource-dir", staticSwiftResourceDir.str])
                        task.checkCommandLineContains(["-Xclang-linker", "-resource-dir", "-Xclang-linker", staticClangResourceDir.str])
                    }
                }

                results.checkTarget("ClangTool") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-resource-dir", staticClangResourceDir.str])
                    }
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.host))
    func dynamicResourceDirectorySelection() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sdkManifestDir = tmpDir.join("TestSDK.artifactbundle")

            let dynamicSwiftResourcesPath = "swift.xctoolchain/usr/lib/swift"
            let staticSwiftResourcesPath = "swift.xctoolchain/usr/lib/swift_static"
            let dynamicSwiftResourceDir = sdkManifestDir.join(dynamicSwiftResourcesPath)
            let dynamicClangResourceDir = dynamicSwiftResourceDir.join("clang")

            try localFS.createDirectory(sdkManifestDir)
            let sdkManifestPath = sdkManifestDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestPath) { $0 <<< """
                {
                    "schemaVersion" : "4.0",
                    "targetTriples" : {
                        "x86_64-unknown-linux-gnu" : {
                            "sdkRootPath" : "sysroot",
                            "swiftResourcesPath" : "\(dynamicSwiftResourcesPath)",
                            "swiftStaticResourcesPath" : "\(staticSwiftResourcesPath)",
                            "toolsetPaths" : [
                                "toolset.json"
                            ]
                        }
                    }
                }
                """
            }

            try await localFS.writeFileContents(sdkManifestDir.join("toolset.json")) { stream in
                stream.write("""
                {
                    "schemaVersion" : "1.0",
                    "swiftCompiler" : {
                        "extraCLIOptions" : [
                            "-DWhatever"
                        ]
                    }
                }
                """)
            }

            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("a.c"),
                        TestFile("b.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "SwiftTool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "SWIFT_VERSION": try await swiftVersion,
                                                    "LINKER_DRIVER": "swiftc",
                                                    "SWIFT_EXEC": try await swiftCompilerPath.strWithPosixSlashes,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("b.swift"),
                            ]),
                        ], dependencies: ["ClangTool"]),
                    TestStandardTarget(
                        "ClangTool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                    "LINKER_DRIVER": "clang",
                                                    "CC": try await clangCompilerPath.strWithPosixSlashes,
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("a.c"),
                            ]),
                        ]),
                ])

            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "x86_64-unknown-linux-gnu", targetArchitecture: "x86_64", supportedArchitectures: ["x86_64"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

            await tester.checkBuild(parameters, runDestination: nil, fs: localFS) { results in

                results.checkTarget("SwiftTool") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-resource-dir", dynamicSwiftResourceDir.str])
                        task.checkCommandLineDoesNotContain("-static-stdlib")
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-resource-dir", dynamicSwiftResourceDir.str])
                        task.checkCommandLineContains(["-Xclang-linker", "-resource-dir", "-Xclang-linker", dynamicClangResourceDir.str])
                    }
                }

                results.checkTarget("ClangTool") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-resource-dir", dynamicClangResourceDir.str])
                    }
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.host))
    func toolsetCustomization() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()
            let toolchainBinDir = tmpDir.join("custom-toolchain").join("bin")
            try localFS.createDirectory(toolchainBinDir, recursive: true)
            let customClang = toolchainBinDir.join(core.hostOperatingSystem.imageFormat.executableName(basename: "clang"))
            let customClangxx = toolchainBinDir.join(core.hostOperatingSystem.imageFormat.executableName(basename: "clang++"))
            let customSwiftc = toolchainBinDir.join(core.hostOperatingSystem.imageFormat.executableName(basename: "swiftc"))
            try localFS.symlink(customClang, target: try await clangCompilerPath)
            try localFS.symlink(customClangxx, target: try await clangPlusPlusCompilerPath)
            try localFS.symlink(customSwiftc, target: try await swiftCompilerPath)

            let toolsetPath = tmpDir.join("toolset.json")
            let toolset = SwiftSDK.Toolset(
                cCompiler: .init(path: customClang.str, extraCLIOptions: ["-DTOOLSET_C"]),
                cxxCompiler: .init(path: customClangxx.str, extraCLIOptions: ["-DTOOLSET_CXX"]),
                swiftCompiler: .init(path: customSwiftc.str, extraCLIOptions: ["-DTOOLSET_SWIFT"]),
                linker: .init(path: Path.root.join("some").join("path").join("to").join(core.hostOperatingSystem.imageFormat.executableName(basename: "ld")).str, extraCLIOptions: ["-ltoolset-lib"]),
                librarian: .init(path: Path.root.join("some").join("path").join("to").join(core.hostOperatingSystem.imageFormat.executableName(basename: "ar")).str, extraCLIOptions: ["-ltoolset-archive"])
            )
            let toolsetData = try JSONEncoder().encode(toolset)
            try localFS.createDirectory(toolsetPath.dirname, recursive: true)
            try localFS.write(toolsetPath, contents: ByteString(toolsetData))

            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("file.c"),
                        TestFile("file.cpp"),
                        TestFile("file.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": try await swiftVersion,
                        "CLANG_USE_RESPONSE_FILE": "NO",
                        "SWIFT_SDK_TOOLSETS": toolsetPath.strWithPosixSlashes,
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "DynamicLib",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "LINKER_DRIVER": "swiftc",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.c", "file.cpp", "file.swift"]),
                        ],
                        dependencies: ["StaticLib"]
                    ),
                    TestStandardTarget(
                        "StaticLib",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "LINKER_DRIVER": "clang"
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.c", "file.cpp", "file.swift"]),
                        ]
                    ),
                ])

            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(BuildParameters(configuration: "Debug"), runDestination: .host, fs: localFS) { results in
                results.checkNoDiagnostics()

                results.checkTarget("DynamicLib") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("file.c"))) { task in
                        task.checkCommandLineContains([customClang.str])
                        task.checkCommandLineContains(["-DTOOLSET_C"])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("file.cpp"))) { task in
                        task.checkCommandLineContains([customClangxx.str])
                        task.checkCommandLineContains(["-DTOOLSET_CXX"])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains([customSwiftc.str])
                        task.checkCommandLineContains(["-DTOOLSET_SWIFT"])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-ld-path=\(Path.root.join("some").join("path").join("to").join(core.hostOperatingSystem.imageFormat.executableName(basename: "ld")).str)"])
                        task.checkCommandLineContains(["-ltoolset-lib"])
                        task.checkCommandLineContains(["-DTOOLSET_SWIFT"])
                    }
                }

                results.checkTarget("StaticLib") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("file.c"))) { task in
                        task.checkCommandLineContains([customClang.str])
                        task.checkCommandLineContains(["-DTOOLSET_C"])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("file.cpp"))) { task in
                        task.checkCommandLineContains([customClangxx.str])
                        task.checkCommandLineContains(["-DTOOLSET_CXX"])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains([customSwiftc.str])
                        task.checkCommandLineContains(["-DTOOLSET_SWIFT"])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                        task.checkCommandLineContains([Path.root.join("some").join("path").join("to").join(core.hostOperatingSystem.imageFormat.executableName(basename: "ar")).str])
                        task.checkCommandLineContains(["-ltoolset-archive"])
                        task.checkCommandLineDoesNotContain("-DTOOLSET_SWIFT")
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func toolsetEnablingWMO() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()

            let toolsetPath = tmpDir.join("toolset.json")
            let toolset = SwiftSDK.Toolset(
                swiftCompiler: .init(extraCLIOptions: ["-wmo"])
            )
            let toolsetData = try JSONEncoder().encode(toolset)
            try localFS.createDirectory(toolsetPath.dirname, recursive: true)
            try localFS.write(toolsetPath, contents: ByteString(toolsetData))

            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("file.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": try await swiftVersion,
                        "SWIFT_SDK_TOOLSETS": toolsetPath.strWithPosixSlashes,
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "target",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.swift"]),
                        ]
                    ),
                ])

            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(BuildParameters(configuration: "Debug"), runDestination: .host, fs: localFS) { results in
                results.checkNoDiagnostics()

                results.checkTarget("target") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-wmo"])
                        task.checkCommandLineDoesNotContain("-enable-batch-mode")
                        task.checkCommandLineDoesNotContain("-incremental")
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func toolsetInBuildRequestOverrides() async throws {
        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()

            let toolsetPath = tmpDir.join("toolset.json")
            let toolset = SwiftSDK.Toolset(
                swiftCompiler: .init(extraCLIOptions: ["-DFOO"])
            )
            let toolsetData = try JSONEncoder().encode(toolset)
            try localFS.createDirectory(toolsetPath.dirname, recursive: true)
            try localFS.write(toolsetPath, contents: ByteString(toolsetData))

            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("file.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": try await swiftVersion,
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "target",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.swift"]),
                        ]
                    ),
                ])

            let tester = try TaskConstructionTester(core, testProject)

            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_SDK_TOOLSETS": toolsetPath.strWithPosixSlashes]), runDestination: .host, fs: localFS) { results in
                results.checkNoDiagnostics()

                results.checkTarget("target") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-DFOO"])
                    }
                }
            }
        }
    }
}
