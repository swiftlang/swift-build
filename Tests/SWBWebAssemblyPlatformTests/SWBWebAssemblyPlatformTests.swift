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
import SWBTaskExecution
import SWBUtil

@Suite
fileprivate struct SWBWebAssemblyPlatformTests: CoreBasedTests {
    @Test(
        .requireSDKs(.wasi),
        .requireThreadSafeWorkingDirectory,
        .skipXcodeToolchain,
        arguments: ["wasm32"], [true, false]
    )
    func wasiCommandWithSwift(arch: String, enableTestability: Bool) async throws {
        let sdkroot = try await #require(getCore().loadSDK(llvmTargetTripleSys: "wasi")).path.str

        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                        TestFile("static.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": arch,
                        "CODE_SIGNING_ALLOWED": "NO",
                        "DEFINES_MODULE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": sdkroot,
                        "SWIFT_VERSION": "6.0",
                        "SUPPORTED_PLATFORMS": "webassembly",
                        "ENABLE_TESTABILITY": enableTestability ? "YES" : "NO"
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                            TestFrameworksBuildPhase([
                                TestBuildFile(.target("staticlib")),
                            ])
                        ],
                        dependencies: [
                            "staticlib",
                        ]
                    ),
                    TestStandardTarget(
                        "staticlib",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["static.swift"]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<< "import staticlib\n"
                stream <<< "print(fromStaticLib())\n"
            }

            try await tester.fs.writeFileContents(projectDir.join("static.swift")) { stream in
                stream <<< "public func fromStaticLib() -> Int { return 42 }"
            }

            try await tester.checkBuild(runDestination: nil) { results in
                results.checkNoErrors()

                let clang = Path("bin").join(core.hostOperatingSystem.imageFormat.executableName(basename: "clang"))
                let llvmAr = Path("bin").join(core.hostOperatingSystem.imageFormat.executableName(basename: "llvm-ar"))

                results.checkTask(.matchRuleType("Libtool"), .matchRuleItemPattern(.suffix(Path("build/Debug-webassembly/libstaticlib.a").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(llvmAr.str),
                        "rcs",
                        .path(tmpDir.join("build/Debug-webassembly/libstaticlib.a")),
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-webassembly/staticlib.build/Objects-normal/\(arch)/staticlib.LinkFileList")),
                    ])
                }

                results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-webassembly/tool").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(clang.str),
                        "-target", "\(arch)-unknown-wasi",
                        "--sysroot", .suffix("/WASI.sdk"),
                        "-Os",
                        .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-webassembly")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/Debug-webassembly")),
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-webassembly/tool.build/Objects-normal/\(arch)/tool.LinkFileList")),
                        "-lswiftCore",
                        .anySequence,
                        "-lc++", "-lc++abi",
                        "-resource-dir", .suffix("usr/lib/swift_static/clang"),
                        .suffix("usr/lib/swift_static/wasi/static-executable-args.lnk"),
                        "-lstaticlib",
                        "-o", .path(tmpDir.join("build/Debug-webassembly/tool"))
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.wasi), .requireThreadSafeWorkingDirectory, .skipXcodeToolchain, arguments: ["wasm32"])
    func wasiCommandWithCAndCxx(arch: String) async throws {
        let sdkroot = try await #require(getCore().loadSDK(llvmTargetTripleSys: "wasi")).path.str

        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.c"),
                        TestFile("static1.c"),
                        TestFile("static2.cpp"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": arch,
                        "CODE_SIGNING_ALLOWED": "NO",
                        "DEFINES_MODULE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": sdkroot,
                        "SWIFT_VERSION": "6.0",
                        "SUPPORTED_PLATFORMS": "webassembly",
                    ])
                ],
                targets: [
                    // FIXME: C-based executable targets are not yet supported due to
                    // https://github.com/swiftlang/swift-build/issues/3, which forces
                    // us to add some Swift-specific linker flags to OTHER_LD_FLAGS and
                    // it makes the linker fail when linking non-Swift targets.
                    //
                    // TestStandardTarget(
                    //     "Ctool",
                    //     type: .commandLineTool,
                    //     buildConfigurations: [
                    //         TestBuildConfiguration("Debug", buildSettings: [:])
                    //     ],
                    //     buildPhases: [
                    //         TestSourcesBuildPhase(["main.c"]),
                    //         TestFrameworksBuildPhase([
                    //             TestBuildFile(.target("Cstaticlib")),
                    //         ])
                    //     ],
                    //     dependencies: [
                    //         "Cstaticlib",
                    //     ]
                    // ),
                    TestStandardTarget(
                        "Cstaticlib",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["static1.c", "static2.cpp"]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.c")) { stream in
                stream <<< "#include <stdio.h>\n"
                stream <<< "int fromStaticLib1(void);\n"
                stream <<< "int fromStaticLib2(void);\n"
                stream <<< "int main() { printf(\"%d\\n\", fromStaticLib2() + fromStaticLib1()); return 0; }\n"
            }

            try await tester.fs.writeFileContents(projectDir.join("static1.c")) { stream in
                stream <<< "int fromStaticLib1(void) { return 42; }\n"
            }
            try await tester.fs.writeFileContents(projectDir.join("static2.cpp")) { stream in
                stream <<< "extern \"C\" int fromStaticLib1(void);\n"
                stream <<< "extern \"C\" int fromStaticLib2(void) { return fromStaticLib1() * 2; }\n"
            }

            try await tester.checkBuild(runDestination: nil) { results in
                results.checkNoErrors()

                let llvmAr = Path("bin").join(core.hostOperatingSystem.imageFormat.executableName(basename: "llvm-ar"))

                results.checkTask(.matchRuleType("Libtool"), .matchRuleItemPattern(.suffix(Path("build/Debug-webassembly/libCstaticlib.a").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(llvmAr.str),
                        "rcs",
                        .path(tmpDir.join("build/Debug-webassembly/libCstaticlib.a")),
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-webassembly/Cstaticlib.build/Objects-normal/\(arch)/Cstaticlib.LinkFileList")),
                    ])
                }

                // FIXME: See above comment about C-based executable targets.
                //
                // results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-webassembly/Ctool").str))) { task in
                //     task.checkCommandLineMatches([
                //         .suffix(clang.str),
                //         "-target", "\(arch)-unknown-wasi",
                //         "--sysroot", .suffix("/WASI.sdk"),
                //         "-Os",
                //         .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-webassembly")),
                //         .pathEqual(prefix: "-L", tmpDir.join("build/Debug-webassembly")),
                //         .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-webassembly/Ctool.build/Objects-normal/\(arch)/Ctool.LinkFileList")),
                //         .anySequence,
                //         "-resource-dir", .suffix("usr/lib/swift_static/clang"),
                //         .anySequence,
                //         "-lCstaticlib",
                //         "-o", .path(tmpDir.join("build/Debug-webassembly/Ctool"))
                //     ])
                // }
            }
        }
    }
}

fileprivate extension Core {
    func loadSDK(llvmTargetTripleSys: String) -> SDK? {
        sdkRegistry.allSDKs.filter { $0.defaultVariant?.llvmTargetTripleSys == llvmTargetTripleSys }.only
    }
}
