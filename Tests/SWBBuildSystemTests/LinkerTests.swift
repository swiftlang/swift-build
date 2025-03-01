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

import SWBTestSupport
import SWBUtil
import Testing
import SWBBuildSystem
import SWBCore
import SWBProtocol

@Suite
fileprivate struct LinkerTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func linkerDriverDiagnosticsParsing() async throws {

        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "testTarget", type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                                "OTHER_LDFLAGS": "-not-a-real-flag"
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("source.swift")) { stream in
                stream <<< "func foo() {}"
            }

            try await tester.checkBuild() { results in
                results.checkError(.prefix("Unknown argument: '-not-a-real-flag'"))
                results.checkError(.prefix("Command Ld failed."))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func objCxxTargetLinksWithSwiftStdlibIfDepUsesSwiftCxxInterop() async throws {

        let swiftVersion = try await self.swiftVersion
        func createProject(_ tmpDir: Path, enableInterop: Bool) -> TestProject {
            TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile("source.mm")
                    ]),
                targets: [
                    TestStandardTarget(
                        "testTarget", type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.mm"]),
                        ],
                        dependencies: [TestTargetDependency("testFramework")]
                    ),
                    TestStandardTarget(
                        "testFramework", type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                                "SWIFT_OBJC_INTEROP_MODE": enableInterop ? "objcxx" : "objc",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"])
                        ]
                    )
                ])
        }

        try await withTemporaryDirectory { tmpDir in
            let testProject = createProject(tmpDir, enableInterop: true)
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let projectDir = tester.workspace.projects[0].sourceRoot
            try await tester.fs.writeFileContents(projectDir.join("source.swift")) { stream in
                stream <<< "func foo() {}"
            }
            try await tester.fs.writeFileContents(projectDir.join("source.mm")) { stream in
                stream <<< "int main() { return 0; }"
            }
            try await tester.checkBuild() { results in
                try results.checkTasks(.matchRuleType("Ld")) { tasks in
                    let task = try #require(tasks.first(where: {  $0.outputPaths[0].ends(with: "testTarget") }))
                    task.checkCommandLineMatches([StringPattern.and(StringPattern.prefix("-L"), StringPattern.suffix("usr/lib/swift/macosx"))])
                    task.checkCommandLineContains(["-L/usr/lib/swift", "-lswiftCore"])
                    task.checkCommandLineMatches([StringPattern.suffix("testTarget.app/Contents/MacOS/testTarget")])
                }
                // Note: The framework build might fail if the Swift compiler in the toolchain
                // does not yet support the `-cxx-interoperability-mode=default` flag that's
                // passed by SWIFT_OBJC_INTEROP_MODE. In that case, ignore any additional errors
                // related to the Swift build itself.
                // FIXME: replace by `checkNoErrors` when Swift submissions catch up.
                results.checkedErrors = true
            }
        }

        // Validate that Swift isn't linked when interop isn't enabled.
        try await withTemporaryDirectory { tmpDir in
            let testProject = createProject(tmpDir, enableInterop: false)
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let projectDir = tester.workspace.projects[0].sourceRoot
            try await tester.fs.writeFileContents(projectDir.join("source.swift")) { stream in
                stream <<< "func foo() {}"
            }
            try await tester.fs.writeFileContents(projectDir.join("source.mm")) { stream in
                stream <<< "int main() { return 0; }"
            }
            try await tester.checkBuild() { results in
                results.checkTasks(.matchRuleType("Ld")) { tasks in
                    let task = tasks.first(where: {  $0.outputPaths[0].ends(with: "testTarget") })!
                    task.checkCommandLineNoMatch([StringPattern.and(StringPattern.prefix("-L"), StringPattern.suffix("usr/lib/swift/macosx"))])
                    task.checkCommandLineDoesNotContain("-L/usr/lib/swift")
                    task.checkCommandLineDoesNotContain("-lswiftCore")
                }
                results.checkNoErrors()
            }
        }
    }

    /// Test ALTERNATE_LINKER build settings
    ///
    /// This test checks that if an alternate linker is requested by setting the
    /// the ALTERNATE_LINKER build setting that the linker is infact used.
    ///
    /// There is no reliable way to determine from a final linked binary which
    /// linker was used, so the test enables some verbosity to see which linker
    /// clang invokes.
    /// Note: There is an output parser in the LinkerTool spec that does
    ///       error parsing and creates a new build error diagnostic with
    ///       a capaitalized error snippet, so this needs to be handled.
    @Test(.requireSDKs(.host))
    func alternateLinkerSelection() async throws {
        let runDestination: RunDestinationInfo = .host
        let swiftVersion = try await self.swiftVersion
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                        TestFile("library.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "CODE_SIGNING_ALLOWED": "NO",
                            "OTHER_LDFLAGS": "-v",  // This will add the -v to the clang linking invocation so we can see what linker will be called.
                        ])
                ],
                targets: [
                    TestStandardTarget(
                        "CommandLineTool",
                        type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                            TestFrameworksBuildPhase([TestBuildFile(.target("Library"))]),
                        ],
                        dependencies: ["Library"]
                    ),
                    TestStandardTarget(
                        "Library",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "library.swift"
                            ])
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let projectDir = tester.workspace.projects[0].sourceRoot
            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<< """
                    import Library

                    hello()
                    """
            }
            try await tester.fs.writeFileContents(projectDir.join("library.swift")) { stream in
                stream <<< """
                    public func hello() {
                        print(\"Hello World\")
                    }
                    """
            }

            // Try to find the installed linkers
            let ldLinkerPath = try await self.ldPath
            let lldLinkerPath = try await self.lldPath
            let goldLinkerPath = try await self.goldPath
            var linkLinkerPath = try await self.linkPath
            if runDestination == .windows {
                // Issue: Finding link.exe will fail until https://github.com/swiftlang/swift-build/pull/163 is merged. Clang will find it via PATH.
                linkLinkerPath = Path("link.exe")
            }
            let installedLinkerPaths = [lldLinkerPath, ldLinkerPath, goldLinkerPath, linkLinkerPath].compactMap { $0 }

            // Default Linker
            var parameters = BuildParameters(configuration: "Debug", overrides: ["ALTERNATE_LINKER": ""])
            try await tester.checkBuild(parameters: parameters, runDestination: .host) { results in
                results.checkTask(.matchRuleType("Ld")) { task in
                    results.checkTaskOutput(task) { taskOutput in
                        results.checkTaskOutput(task) { output in
                            // Expect that one of the installed linkers is used, we are not sure which one.
                            #expect(installedLinkerPaths.map { $0.str }.contains(where: output.asString.contains))
                        }
                    }
                }
                if runDestination == .windows {
                    // Issue: Linker cannot find dependent library
                    results.checkError(.contains("Linker command failed with exit code 1"))
                    results.checkError(.contains("LNK1181: cannot open input file 'Library.lib'"))
                }
                results.checkNoDiagnostics()
            }

            // Invalid Linker
            parameters = BuildParameters(configuration: "Debug", overrides: ["ALTERNATE_LINKER": "not-a-linker"])
            try await tester.checkBuild(parameters: parameters, runDestination: .host) { results in
                if runDestination != .windows {
                    results.checkError(.contains("Invalid linker name in argument '-fuse-ld=not-a-linker'"))
                    results.checkError(.contains("invalid linker name in argument '-fuse-ld=not-a-linker'"))
                } else {
                    // Windows 'clang' does not check the linker in passed in via -fuse-ld and simply tries to execute it verbatim.
                    results.checkError(.contains("Unable to execute command: program not executable"))
                    results.checkError(.contains("unable to execute command: program not executable"))
                    results.checkError(.contains("Linker command failed with exit code 1"))
                }
                results.checkNoDiagnostics()
            }

            // lld - llvm linker
            if let lldLinkerPath {
                parameters = BuildParameters(configuration: "Debug", overrides: ["ALTERNATE_LINKER": "lld"])
                try await tester.checkBuild(parameters: parameters, runDestination: .host) { results in
                    if runDestination == .windows {
                        // Issue: Linker cannot find dependent library
                        results.checkError(.contains("Linker command failed with exit code 1"))
                        results.checkError(.contains("lld-link: error: could not open 'Library.lib'"))
                    }

                    results.checkTask(.matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-fuse-ld=lld"])
                        results.checkTaskOutput(task) { output in
                            // Expect that the default linker is called by clang
                            if runDestination == .windows {
                                // clang will choose to run lld-link rather than ld.lld.exe.
                                // clang output will have escaped slashes in stdout.
                                #expect(output.asString.replacingOccurrences(of: "\\\\", with: "\\").contains(lldLinkerPath.dirname.join("lld-link").str))
                            } else {
                                #expect(output.asString.contains(lldLinkerPath.str))
                            }
                        }
                    }
                    results.checkNoDiagnostics()
                }
            }

            // gold
            if let goldLinkerPath {
                parameters = BuildParameters(configuration: "Debug", overrides: ["ALTERNATE_LINKER": "gold"])
                try await tester.checkBuild(parameters: parameters, runDestination: .host) { results in
                    results.checkTask(.matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-fuse-ld=gold"])
                        results.checkTaskOutput(task) { output in
                            // Expect that the default linker is called by clang
                            #expect(output.asString.contains(goldLinkerPath.str))
                        }
                    }
                    results.checkNoDiagnostics()
                }
            }

            // link.exe
            if let linkLinkerPath {
                parameters = BuildParameters(configuration: "Debug", overrides: ["ALTERNATE_LINKER": "link"])
                try await tester.checkBuild(parameters: parameters, runDestination: .host) { results in
                    results.checkTask(.matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(["-fuse-ld=link"])
                        results.checkTaskOutput(task) { output in
                            // Expect that the default linker is called by clang
                            #expect(output.asString.contains(linkLinkerPath.str))
                        }
                    }
                    //Issue: Linker cannot find dependent library
                    results.checkError(.contains("Linker command failed with exit code 1"))
                    results.checkError(.contains("LINK : fatal error LNK1181: cannot open input file 'Library.lib'"))
                    results.checkNoDiagnostics()
                }
            }
        }
    }
}
