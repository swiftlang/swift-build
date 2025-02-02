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

@Suite
fileprivate struct SWBWebAssemblyPlatformTests: CoreBasedTests {
    @Test(.requireThreadSafeWorkingDirectory, .enabled(if: getEnvironmentVariable("WASM_SDKROOT") != nil), arguments: ["wasm32"])
    func wasiCommand(arch: String) async throws {
        guard let sdkroot = getEnvironmentVariable("WASM_SDKROOT") else { return }
        guard let toolchain = getEnvironmentVariable("WASM_TOOLCHAINS") else { return }

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
                        "TOOLCHAINS": toolchain,
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
                stream <<< ""
            }

            try await tester.fs.writeFileContents(projectDir.join("static.swift")) { stream in
                stream <<< ""
            }

            try await tester.checkBuild(runDestination: nil) { results in
                results.checkNoErrors()

                let clang = Path("bin").join(core.hostOperatingSystem.imageFormat.executableName(basename: "clang"))


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
}
