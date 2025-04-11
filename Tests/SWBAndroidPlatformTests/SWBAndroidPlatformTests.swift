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
fileprivate struct AndroidBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.android), .requireThreadSafeWorkingDirectory, arguments: ["armv7", "aarch64", "riscv64", "i686", "x86_64"])
    func androidCommandLineTool(arch: String) async throws {
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
                        "SDKROOT": "android",
                        "SUPPORTED_PLATFORMS": "android",
                        "ANDROID_DEPLOYMENT_TARGET": "22.0",
                        "ANDROID_DEPLOYMENT_TARGET[arch=riscv64]": "35.0",
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

            let minOS = arch == "riscv64" ? "35.0" : "22.0"

            let destination: RunDestinationInfo = .android
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()

                let clang = Path("bin").join(core.hostOperatingSystem.imageFormat.executableName(basename: "clang"))

                results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-android/libdynamiclib.so").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(clang.str),
                        "-target", "\(arch)-none-linux-android\(minOS)",
                        "-shared",
                        "--sysroot",
                        .contains(Path("/toolchains/llvm/prebuilt/").str),
                        "-Os",
                        .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-android")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/Debug-android")),
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-android/dynamiclib.build/Objects-normal/\(arch)/dynamiclib.LinkFileList")),
                        "-Xlinker", "-soname", "-Xlinker", "$ORIGIN/libdynamiclib.so",
                        "-o", .path(tmpDir.join("build/Debug-android/libdynamiclib.so"))
                    ])
                }

                results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-android/tool").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(clang.str),
                        "-target", "\(arch)-none-linux-android\(minOS)",
                        "--sysroot", .contains(Path("/toolchains/llvm/prebuilt/").str),
                        "-Os",
                        .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-android")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/Debug-android")),
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-android/tool.build/Objects-normal/\(arch)/tool.LinkFileList")),
                        "-ldynamiclib",
                        "-lstaticlib",
                        "-o", .path(tmpDir.join("build/Debug-android/tool"))
                    ])
                }

                #expect(tester.fs.exists(projectDir.join("build").join("Debug\(destination.builtProductsDirSuffix)").join("tool")))
            }
        }
    }
}
