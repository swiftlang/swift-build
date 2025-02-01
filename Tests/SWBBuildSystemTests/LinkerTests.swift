//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SWBTestSupport
import SWBUtil
import Testing

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
                results.checkTasks(.matchRuleType("Ld")) { tasks in
                    let task = tasks.first(where: {  $0.outputPaths[0].ends(with: "testTarget") })!
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
}
