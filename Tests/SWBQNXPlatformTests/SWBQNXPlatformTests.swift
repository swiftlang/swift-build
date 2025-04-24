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
import SWBProtocol
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SWBCore

@Suite
fileprivate struct QNXBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.qnx), .skipHostOS(.macOS), .requireThreadSafeWorkingDirectory, arguments: ["aarch64", "x86_64"])
    func qnxCommandLineTool(arch: String) async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.c"),
                        TestFile("dynamic.c"),
                        TestFile("static.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": arch,
                        "CODE_SIGNING_ALLOWED": "NO",
                        "DEFINES_MODULE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "qnx",
                        "SUPPORTED_PLATFORMS": "qnx",
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
                            TestSourcesBuildPhase(["main.c"]),
                            TestFrameworksBuildPhase([
                                TestBuildFile(.target("dynamiclib")),
                                TestBuildFile(.target("staticlib")),
                            ])
                        ],
                        dependencies: [
                            "dynamiclib",
                            "staticlib",
                        ]
                    ),
                    TestStandardTarget(
                        "dynamiclib",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "DYLIB_INSTALL_NAME_BASE": "$ORIGIN",

                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["dynamic.c"]),
                        ],
                        productReferenceName: "libdynamiclib.so"
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
                            TestSourcesBuildPhase(["static.c"]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.c")) { stream in
                stream <<< "int main() { }\n"
            }

            try await tester.fs.writeFileContents(projectDir.join("dynamic.c")) { stream in
                stream <<< "void dynamicLib() { }"
            }

            try await tester.fs.writeFileContents(projectDir.join("static.c")) { stream in
                stream <<< "void staticLib() { }"
            }

            let archName = arch == "aarch64" ? "aarch64le" : arch

            let destination: RunDestinationInfo = .qnx
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()

                let compiler = Path("bin").join(core.hostOperatingSystem.imageFormat.executableName(basename: "qcc"))

                results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-qnx/libdynamiclib.so").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(compiler.str),
                        "-V", "gcc_nto\(archName)",
                        "-shared",
                        "-Os",
                        .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-qnx")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/Debug-qnx")),
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-qnx/dynamiclib.build/Objects-normal/\(arch)/dynamiclib.LinkFileList")),
                        "-Wl,-h$ORIGIN/libdynamiclib.so",
                        "-o", .path(tmpDir.join("build/Debug-qnx/libdynamiclib.so"))
                    ])
                }

                results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-qnx/tool").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(compiler.str),
                        "-V", "gcc_nto\(archName)",
                        "-Os",
                        .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-qnx")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/Debug-qnx")),
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-qnx/tool.build/Objects-normal/\(arch)/tool.LinkFileList")),
                        "-ldynamiclib",
                        "-lstaticlib",
                        "-o", .path(tmpDir.join("build/Debug-qnx/tool"))
                    ])
                }

                #expect(tester.fs.exists(projectDir.join("build").join("Debug\(destination.builtProductsDirSuffix)").join("tool")))
            }
        }
    }
}
