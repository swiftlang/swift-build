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
import SWBTestSupport
import SwiftBuildTestSupport
@_spi(Testing) import SWBUtil
import SWBProtocol
import SWBTaskExecution

@Suite
fileprivate struct ObjectLibraryBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func objectLibraryBasics() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("a.c"),
                                TestFile("b.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Library",
                                type: .objectLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "a.c",
                                        "b.c",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/a.c")) {
                $0 <<< "void foo(void) {}\n"
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/b.c")) {
                $0 <<< "void bar(void) {}\n"
            }

            try await tester.checkBuild(runDestination: .host) { results in
                results.checkNoDiagnostics()
                let libPath = tmpDirPath.join("Test/aProject/build/Debug\(RunDestinationInfo.host.builtProductsDirSuffix)/Library.objlib")
                #expect(tester.fs.exists(libPath))
                try #expect(tester.fs.listdir(libPath).sorted() == ["a.o", "args.resp", "b.o"])
            }
        }
    }

    @Test(.requireSDKs(.host))
    func consumingObjectLibrary_ld() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("a.swift"),
                                TestFile("b.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": try await swiftVersion,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "b.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "Library.objlib"
                                    ])
                                ],
                                dependencies: [
                                    "Library",
                                ]
                            ),
                            TestStandardTarget(
                                "Library",
                                type: .objectLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "a.swift",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/a.swift")) {
                $0 <<< """
                    public struct Foo {
                        public var x: Int

                        public init(x: Int) {
                            self.x = x
                        }
                    }
                """
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/b.swift")) {
                $0 <<< """
                    import Library

                    @main
                    struct Entry {
                        static func main() {
                            let f = Foo(x: 42)
                            print(f)
                        }
                    }

                """
            }

            try await tester.checkBuild(runDestination: .host) { results in
                results.checkNoDiagnostics()
                results.checkTaskExists(.matchRuleType("Ld"))
            }
        }
    }

    @Test(.requireSDKs(.host))
    func consumingObjectLibrary_libtool() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("a.swift"),
                                TestFile("b.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": try await swiftVersion,
                                    "LIBTOOL_USE_RESPONSE_FILE": "NO",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "StaticLibrary",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "b.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "Library.objlib"
                                    ])
                                ],
                                dependencies: [
                                    "Library",
                                ]
                            ),
                            TestStandardTarget(
                                "Library",
                                type: .objectLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "a.swift",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/a.swift")) {
                $0 <<< """
                    public struct Foo {
                        public var x: Int

                        public init(x: Int) {
                            self.x = x
                        }
                    }
                """
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/b.swift")) {
                $0 <<< """
                    import Library

                    @main
                    struct Entry {
                        static func main() {
                            let f = Foo(x: 42)
                            print(f)
                        }
                    }

                """
            }

            try await tester.checkBuild(runDestination: .host) { results in
                results.checkNoDiagnostics()
                results.checkTaskExists(.matchRuleType("Libtool"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func consumingObjectLibraryIncrementalBuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("a.swift"),
                                TestFile("b.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": try await swiftVersion,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "b.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "Library.objlib"
                                    ])
                                ],
                                dependencies: [
                                    "Library",
                                ]
                            ),
                            TestStandardTarget(
                                "Library",
                                type: .objectLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "a.swift",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/a.swift")) {
                $0 <<< """
                    public struct Foo {
                        public var x: Int

                        public init(x: Int) {
                            self.x = x
                        }
                    }
                """
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/b.swift")) {
                $0 <<< """
                    import Library

                    @main
                    struct Entry {
                        static func main() {
                            let f = Foo(x: 42)
                            print(f)
                        }
                    }

                """
            }

            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try await tester.checkNullBuild(runDestination: .host, persistent: true)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/a.swift")) {
                $0 <<< """
                    public struct Foo {
                        public var x: Int

                        public init(x: Int) {
                            print("hello, world!")
                            self.x = x
                        }
                    }
                """
            }

            try await tester.checkBuild(runDestination: .host, persistent: true) { results in
                results.checkNoDiagnostics()
                // We should both reassemble the object library and relink the executable after updating an object file.
                results.checkTaskExists(.matchRuleType("AssembleObjectLibrary"))
                results.checkTaskExists(.matchRuleType("Ld"))
            }

            try await tester.checkNullBuild(runDestination: .host, persistent: true)
        }
    }
}
