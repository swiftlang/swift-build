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

import Testing

import SWBCore
import SWBTestSupport
import SWBUtil

import SWBTaskExecution
import SWBProtocol

import Foundation

@Suite(.requireSwiftCASSandbox)
fileprivate struct CompilationCASSandboxTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func swiftSimpleDependency() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("lib.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath)),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.swift",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "MyFrame.framework",
                                    ]),
                                ],
                                dependencies: ["MyFrame"]
                            ),
                            TestStandardTarget(
                                "MyFrame",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "lib.swift",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let toolTempDir = targetTempDir(tmpDirPath, "tool")
            let frameTempDir = targetTempDir(tmpDirPath, "MyFrame")
            let developerDir = try await getCore().developerPath.path

            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import MyFrame\nfoo()\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // The JSON descriptions of the CASFS of the framework.
                try results.checkTask(.matchTargetName("MyFrame"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-deps.json")) { task in
                    #expect(task.outputPaths == [frameTempDir.join("casfs-deps.json")])
                    let casFSDesc = try readCASFSDescription(tester, task)
                    // No dependencies.
                    #expect(casFSDesc.paths.isEmpty)
                    #expect(casFSDesc.roots.isEmpty)
                    #expect(casFSDesc.searchPaths.isEmpty)
                }
                try results.checkTask(.matchTargetName("MyFrame"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-compilation-inputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.paths.contains(SRCROOT.join("lib.swift")))
                    // Headermaps are disabled when using CAS sandbox for now.
                    #expect(!casFSDesc.paths.contains { $0.fileExtension == "hmap" })
                    // Not importing underlying module.
                    #expect(casFSDesc.roots == [frameTempDir.join("casfs-deps.json")])
                    #expect(casFSDesc.searchPaths.isEmpty)
                }
                try results.checkTask(.matchTargetName("MyFrame"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-objc-outputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.roots.isEmpty)
                    // The generated ObjC header of a Swift module is not an ObjC output of the module.
                    #expect(!casFSDesc.paths.contains { $0.basename == "MyFrame-Swift.h" })
                }
                try results.checkTask(.matchTargetName("MyFrame"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-outputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    // The binary is not needed for compiling the dependents.
                    #expect(!casFSDesc.paths.contains { $0.str.hasSuffix("/MyFrame.framework/MyFrame") })
                    #expect(!casFSDesc.paths.contains { $0.str.hasSuffix("/MyFrame.framework/Versions/A/MyFrame") })
                    // The Swift module and the framework structure symlinks are needed.
                    #expect(casFSDesc.paths.contains { $0.fileExtension == "swiftmodule" })
                    #expect(casFSDesc.paths.contains { $0.str.hasSuffix("/MyFrame.framework/Modules") })
                    #expect(casFSDesc.paths.contains { $0.str.hasSuffix("/MyFrame.framework/Versions/Current") })
                    #expect(casFSDesc.paths.contains { $0.basename == "MyFrame-Swift.h" })
                    #expect(Set(casFSDesc.roots) == [frameTempDir.join("casfs-objc-outputs.json"), frameTempDir.join("casfs-deps.json")])
                }

                // The JSON descriptions of the CASFS of the tool.
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-deps.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.paths.isEmpty)
                    #expect(casFSDesc.roots == [frameTempDir.join("casfs-outputs.json")])
                }
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-compilation-inputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.paths.contains(SRCROOT.join("main.swift")))
                    #expect(!casFSDesc.paths.contains(SRCROOT.join("lib.swift")))
                    #expect(casFSDesc.roots == [toolTempDir.join("casfs-deps.json")])
                }

                // The CASFS ingestion tasks.
                for (target, tempDir) in [("MyFrame", frameTempDir), ("tool", toolTempDir)] {
                    try results.checkTask(.matchTargetName(target), .matchRuleType("IngestCASFSRoot")) { task in
                        let casFSIDPath = try #require(task.outputPaths.only)
                        // The CASFS ID is an input of the Swift compilation tasks.
                        let consumers = results.getTasks(.matchTargetName(target)).filter { $0.inputPaths.contains(casFSIDPath) }
                        #expect(Set(consumers.map { $0.ruleInfo[0] }) == ["SwiftDriver Compilation Requirements", "SwiftDriver Compilation"])
                        #expect(casFSIDPath.basename == "casfs-compilation-inputs.casfsid")
                        #expect(casFSIDPath.str.hasPrefix(tempDir.str))
                        #expect(task.inputPaths.contains { $0.basename == "casfs-compilation-inputs.json" })
                        let casFSID = try tester.fs.read(casFSIDPath).asString
                        #expect(!casFSID.isEmpty)
                        results.checkTaskOutput(task) { output in
                            #expect(output.asString == casFSID)
                        }

                        // The Swift compilation uses the CASFS for scanning and is allowed to escape it for the developer dir.
                        results.checkTask(.matchTargetName(target), .matchRuleType("SwiftDriver")) { driverTask in
                            driverTask.checkCommandLineContainsUninterrupted(["-scanner-cas-fs", "@\(casFSIDPath.str)"])
                            driverTask.checkCommandLineContainsUninterrupted(["-cas-fs-escape", developerDir.str])
                            // Headermaps are disabled when using CAS sandbox for now.
                            #expect(!driverTask.commandLine.contains { $0.asString.hasSuffix(".hmap") })
                        }
                    }
                }

                results.checkNoErrors()
            }
        }
    }

    /// A module that exists on disk but is not a declared dependency in the build graph must not be visible to the compiler.
    @Test(.requireSDKs(.macOS))
    func undeclaredDependencyIsNotVisible() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("lib.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath)),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.swift",
                                    ]),
                                ]
                                // No dependency on 'MyFrame'.
                            ),
                            TestStandardTarget(
                                "MyFrame",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "lib.swift",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import MyFrame\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            // Build the framework first so that it exists in the build directory.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest(tester, targets: ["MyFrame"]), persistent: true) { results in
                results.checkNoErrors()
            }
            #expect(tester.fs.exists(tmpDirPath.join("Test/aProject/build/Debug/MyFrame.framework/Modules/MyFrame.swiftmodule")))

            // The framework is not visible to the tool because it is not a declared dependency.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest(tester, targets: ["tool"]), persistent: true) { results in
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-deps.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.roots.isEmpty)
                }
                results.checkError(.contains("unable to resolve module dependency: 'MyFrame'"))
            }

            // Without the CAS sandbox the compiler picks up the framework from the build directory.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest(tester, targets: ["tool"], overrides: ["SWIFT_ENABLE_CAS_SANDBOX": "NO"]), persistent: true) { results in
                results.checkNoTask(.matchRuleType("IngestCASFSRoot"))
                results.checkNoErrors()
            }
        }
    }

    /// Modules of transitive dependencies are visible via the CASFS of the direct dependencies.
    @Test(.requireSDKs(.macOS))
    func swiftTransitiveDependency() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("A.swift"),
                                TestFile("B.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath)),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                    TestFrameworksBuildPhase(["A.framework"]),
                                ],
                                dependencies: ["A"]
                            ),
                            TestStandardTarget(
                                "A",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["A.swift"]),
                                    TestFrameworksBuildPhase(["B.framework"]),
                                ],
                                dependencies: ["B"]
                            ),
                            TestStandardTarget(
                                "B",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["B.swift"]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import A\nlet b = makeB()\nprint(b.value)\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("A.swift")) {
                $0 <<< "@_exported import B\npublic func makeB() -> BType { BType() }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("B.swift")) {
                $0 <<< "public struct BType { public init() {}; public var value: Int { 42 } }\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-deps.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.roots == [targetTempDir(tmpDirPath, "A").join("casfs-outputs.json")])
                }
                try results.checkTask(.matchTargetName("A"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-deps.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.roots == [targetTempDir(tmpDirPath, "B").join("casfs-outputs.json")])
                }
                try results.checkTask(.matchTargetName("A"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-outputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    // The outputs of 'A' include, transitively, the outputs of 'B'.
                    #expect(casFSDesc.roots.contains(targetTempDir(tmpDirPath, "A").join("casfs-deps.json")))
                }
                results.checkTasks(.matchRuleType("IngestCASFSRoot")) { tasks in
                    #expect(Set(tasks.compactMap { $0.forTarget?.target.name }) == ["tool", "A", "B"])
                }
                results.checkNoErrors()
            }
        }
    }

    /// A framework that mixes ObjC and Swift exposes its ObjC outputs to its own Swift compilation and to its dependents.
    @Test(.requireSDKs(.macOS))
    func mixedObjCSwiftFramework() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("MyFrame.h"),
                                TestFile("ObjCThing.h"),
                                TestFile("ObjCThing.m"),
                                TestFile("SwiftThing.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath).addingContents(of: [
                                    "DEFINES_MODULE": "YES",
                                ])),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                    TestFrameworksBuildPhase(["MyFrame.framework"]),
                                ],
                                dependencies: ["MyFrame"]
                            ),
                            TestStandardTarget(
                                "MyFrame",
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("MyFrame.h", headerVisibility: .public),
                                        TestBuildFile("ObjCThing.h", headerVisibility: .public),
                                    ]),
                                    TestSourcesBuildPhase([
                                        "ObjCThing.m",
                                        "SwiftThing.swift",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let frameTempDir = targetTempDir(tmpDirPath, "MyFrame")

            try await tester.fs.writeFileContents(SRCROOT.join("MyFrame.h")) {
                $0 <<< "#import <MyFrame/ObjCThing.h>\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("ObjCThing.h")) {
                $0 <<< "int objc_thing(void);\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("ObjCThing.m")) {
                $0 <<< "#import \"ObjCThing.h\"\nint objc_thing(void) { return 1; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("SwiftThing.swift")) {
                $0 <<< "public func swiftThing() -> Int32 { objc_thing() }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import MyFrame\nprint(objc_thing() + swiftThing())\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkTask(.matchTargetName("MyFrame"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-objc-outputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.roots.isEmpty)
                    let products = tmpDirPath.join("Test/aProject/build/Debug/MyFrame.framework")
                    #expect(casFSDesc.paths.contains(products.join("Versions/A/Headers/MyFrame.h")))
                    #expect(casFSDesc.paths.contains(products.join("Versions/A/Headers/ObjCThing.h")))
                    #expect(casFSDesc.paths.contains(products.join("Versions/A/Modules/module.modulemap")))
                    #expect(casFSDesc.paths.contains(products.join("Headers")))
                    #expect(casFSDesc.paths.contains(products.join("Modules")))
                    #expect(casFSDesc.paths.contains(products.join("Versions/Current")))
                    // Implementation files are not ObjC outputs.
                    #expect(!casFSDesc.paths.contains { $0.fileExtension == "o" || $0.fileExtension == "m" })
                }
                try results.checkTask(.matchTargetName("MyFrame"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-compilation-inputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.paths.contains(SRCROOT.join("SwiftThing.swift")))
                    #expect(!casFSDesc.paths.contains(SRCROOT.join("ObjCThing.m")))
                    // Importing the underlying module requires the ObjC outputs of the module.
                    #expect(Set(casFSDesc.roots) == [frameTempDir.join("casfs-deps.json"), frameTempDir.join("casfs-objc-outputs.json")])
                }
                try results.checkTask(.matchTargetName("MyFrame"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-outputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(Set(casFSDesc.roots) == [frameTempDir.join("casfs-objc-outputs.json"), frameTempDir.join("casfs-deps.json")])
                }
                results.checkTask(.matchTargetName("MyFrame"), .matchRuleType("SwiftDriver")) { task in
                    task.checkCommandLineContains(["-import-underlying-module"])
                }
                results.checkNoErrors()
            }
        }
    }

    /// An ObjC-only framework dependency is visible to a Swift client.
    @Test(.requireSDKs(.macOS))
    func objCOnlyFrameworkDependency() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("ObjCFrame.h"),
                                TestFile("ObjCFrame.m"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath).addingContents(of: [
                                    "DEFINES_MODULE": "YES",
                                ])),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                    TestFrameworksBuildPhase(["ObjCFrame.framework"]),
                                ],
                                dependencies: ["ObjCFrame"]
                            ),
                            TestStandardTarget(
                                "ObjCFrame",
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("ObjCFrame.h", headerVisibility: .public),
                                    ]),
                                    TestSourcesBuildPhase(["ObjCFrame.m"]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let frameTempDir = targetTempDir(tmpDirPath, "ObjCFrame")

            try await tester.fs.writeFileContents(SRCROOT.join("ObjCFrame.h")) {
                $0 <<< "int objc_frame(void);\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("ObjCFrame.m")) {
                $0 <<< "#import \"ObjCFrame.h\"\nint objc_frame(void) { return 1; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import ObjCFrame\nprint(objc_frame())\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // There is no Swift compilation in the framework.
                results.checkNoTask(.matchTargetName("ObjCFrame"), .matchRuleType("IngestCASFSRoot"))
                results.checkNoTask(.matchTargetName("ObjCFrame"), .matchRuleItemBasename("casfs-compilation-inputs.json"))

                try results.checkTask(.matchTargetName("ObjCFrame"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-objc-outputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.paths.contains { $0.basename == "ObjCFrame.h" })
                    #expect(casFSDesc.paths.contains { $0.basename == "module.modulemap" })
                }
                try results.checkTask(.matchTargetName("ObjCFrame"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-outputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.roots.contains(frameTempDir.join("casfs-objc-outputs.json")))
                }
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-deps.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.roots == [frameTempDir.join("casfs-outputs.json")])
                }
                results.checkTaskExists(.matchTargetName("tool"), .matchRuleType("IngestCASFSRoot"))
                results.checkNoErrors()
            }
        }
    }

    /// The Swift module of a static library dependency is visible to its client.
    @Test(.requireSDKs(.macOS))
    func swiftStaticLibraryDependency() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("lib.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath)),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                    TestFrameworksBuildPhase(["libMyLib.a"]),
                                ],
                                dependencies: ["MyLib"]
                            ),
                            TestStandardTarget(
                                "MyLib",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["lib.swift"]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import MyLib\nfoo()\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkTask(.matchTargetName("MyLib"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-outputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    let swiftModuleDir = tmpDirPath.join("Test/aProject/build/Debug/MyLib.swiftmodule")
                    #expect(casFSDesc.paths.contains { $0.fileExtension == "swiftmodule" && $0.str.hasPrefix(swiftModuleDir.str) })
                    // The library binary is not needed for compiling the dependents.
                    #expect(!casFSDesc.paths.contains { $0.basename == "libMyLib.a" })
                }
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-deps.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.roots == [targetTempDir(tmpDirPath, "MyLib").join("casfs-outputs.json")])
                }
                results.checkNoErrors()
            }
        }
    }

    /// User header search paths are included in the CASFS only if they point inside the source directories.
    @Test(.requireSDKs(.macOS))
    func userHeaderSearchPaths() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let externalDir = tmpDirPath.join("external")
            let externalIncludeDir = externalDir.join("include")
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("Bridge.h"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath).addingContents(of: [
                                    "SWIFT_OBJC_BRIDGING_HEADER": "Bridge.h",
                                    "USER_HEADER_SEARCH_PATHS": "$(SRCROOT)/include \(externalIncludeDir.str)",
                                ])),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Bridge.h")) {
                $0 <<< "#include \"internal.h\"\n#include \"external.h\"\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("include/internal.h")) {
                $0 <<< "static inline int internal_func(void) { return 1; }\n"
            }
            try await tester.fs.writeFileContents(externalIncludeDir.join("external.h")) {
                $0 <<< "static inline int external_func(void) { return 2; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "print(internal_func() + external_func())\n"
            }

            // The search path outside of the source directory is not included in the sandbox.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-compilation-inputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.searchPaths == [SRCROOT.join("include")])
                    #expect(casFSDesc.paths.contains(SRCROOT.join("Bridge.h")))
                }
                // Ignore the follow-up errors.
                #expect(results.getErrors().contains { $0.contains("'external.h' file not found") })
            }

            // `CAS_SANDBOX_OTHER_SOURCE_DIRS` allows including additional source directories in the sandbox.
            let parameters = BuildParameters(configuration: "Debug", overrides: ["CAS_SANDBOX_OTHER_SOURCE_DIRS": externalDir.str])
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-compilation-inputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.searchPaths == [SRCROOT.join("include"), externalIncludeDir])
                }
                results.checkNoErrors()
            }
        }
    }

    /// User header search paths that are the same as a source directory are included in the CASFS.
    @Test(.requireSDKs(.macOS))
    func userHeaderSearchPathsEqualToSourceDirs() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let externalDir = tmpDirPath.join("external")
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("bridge/Bridge.h"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath).addingContents(of: [
                                    "SWIFT_OBJC_BRIDGING_HEADER": "bridge/Bridge.h",
                                    "USER_HEADER_SEARCH_PATHS": "$(SRCROOT) \(externalDir.str)",
                                    "CAS_SANDBOX_OTHER_SOURCE_DIRS": externalDir.str,
                                ])),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // The bridging header is in a subdirectory so the headers can only be found via the search paths.
            try await tester.fs.writeFileContents(SRCROOT.join("bridge/Bridge.h")) {
                $0 <<< "#include \"root.h\"\n#include \"external.h\"\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("root.h")) {
                $0 <<< "static inline int root_func(void) { return 1; }\n"
            }
            try await tester.fs.writeFileContents(externalDir.join("external.h")) {
                $0 <<< "static inline int external_func(void) { return 2; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "print(root_func() + external_func())\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-compilation-inputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.searchPaths == [SRCROOT, externalDir])
                }
                results.checkNoErrors()
            }
        }
    }

    /// Only headers up to one subdirectory deep (by default) inside a user header search path are included in the CASFS.
    @Test(.requireSDKs(.macOS))
    func userHeaderSearchPathIngestionDepth() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("Bridge.h"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath).addingContents(of: [
                                    "SWIFT_OBJC_BRIDGING_HEADER": "Bridge.h",
                                    "USER_HEADER_SEARCH_PATHS": "$(SRCROOT)/include",
                                ])),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Bridge.h")) {
                $0 <<< "#include \"mymodule/myheader.h\"\n#include \"SomethingElse/whatever/header.h\"\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("include/mymodule/myheader.h")) {
                $0 <<< "static inline int my_func(void) { return 1; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("include/SomethingElse/whatever/header.h")) {
                $0 <<< "static inline int whatever_func(void) { return 2; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "print(my_func() + whatever_func())\n"
            }

            // Without the CAS sandbox both headers are found via the search path.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["SWIFT_ENABLE_CAS_SANDBOX": "NO"]), runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            // With the CAS sandbox the header nested more than one directory deep in the search path is not ingested.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-compilation-inputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.searchPaths == [SRCROOT.join("include")])
                    #expect(casFSDesc.searchPathIngestionDepth == 1)
                }
                let errors = results.getErrors()
                #expect(errors.contains { $0.contains("'SomethingElse/whatever/header.h' file not found") })
                #expect(!errors.contains { $0.contains("'mymodule/myheader.h' file not found") })
            }

            // Increasing the ingestion depth makes the header nested two directories deep visible.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CAS_SANDBOX_SEARCH_PATH_INGESTION_DEPTH": "2"]), runDestination: .macOS, persistent: true) { results in
                try results.checkTask(.matchTargetName("tool"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("casfs-compilation-inputs.json")) { task in
                    let casFSDesc = try readCASFSDescription(tester, task)
                    #expect(casFSDesc.searchPathIngestionDepth == 2)
                }
                results.checkNoErrors()
            }

            // The header one directory deep in the search path is ingested.
            try await tester.fs.writeFileContents(SRCROOT.join("Bridge.h")) {
                $0 <<< "#include \"mymodule/myheader.h\"\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "print(my_func())\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            // An invalid ingestion depth is diagnosed.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CAS_SANDBOX_SEARCH_PATH_INGESTION_DEPTH": "-1"]), runDestination: .macOS, persistent: true) { results in
                results.checkError(.contains("CAS_SANDBOX_SEARCH_PATH_INGESTION_DEPTH must be a non-negative integer, found '-1'"))
                results.checkNoErrors()
            }
        }
    }

    /// Only header and module map files inside a user header search path are included in the CASFS.
    @Test(.requireSDKs(.macOS))
    func userHeaderSearchPathIngestionFileFilter() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("Bridge.h"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath).addingContents(of: [
                                    "SWIFT_OBJC_BRIDGING_HEADER": "Bridge.h",
                                    "USER_HEADER_SEARCH_PATHS": "$(SRCROOT)/include",
                                ])),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("include/plain.h")) {
                $0 <<< "static inline int plain_func(void) { return 1; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("include/plain.hpp")) {
                $0 <<< "static inline int plain_hpp_func(void) { return 3; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("include/MyCMod/nested.hpp")) {
                $0 <<< "static inline int nested_hpp_func(void) { return 4; }\n"
            }
            // A C module that is found via the search path by its name.
            try await tester.fs.writeFileContents(SRCROOT.join("include/MyCMod/module.modulemap")) {
                $0 <<< "module MyCMod {\n  header \"mycmod.h\"\n  export *\n}\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("include/MyCMod/mycmod.h")) {
                $0 <<< "static inline int mycmod_func(void) { return 2; }\n"
            }
            let excludedFiles = ["other.def", "other.inc", "MyCMod/other.def"]
            for excludedFile in excludedFiles {
                try await tester.fs.writeFileContents(SRCROOT.join("include").join(excludedFile)) {
                    $0 <<< "\n"
                }
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import MyCMod\nprint(plain_func() + plain_hpp_func() + nested_hpp_func() + mycmod_func())\n"
            }

            func writeBridgingHeader(including extraInclude: String?) async throws {
                try await tester.fs.writeFileContents(SRCROOT.join("Bridge.h")) {
                    $0 <<< "#include \"plain.h\"\n#include \"plain.hpp\"\n#include \"MyCMod/nested.hpp\"\n"
                    if let extraInclude {
                        $0 <<< "#include \"\(extraInclude)\"\n"
                    }
                }
            }

            // With the CAS sandbox header (`.h` and `.hpp`) and module map files are ingested.
            try await writeBridgingHeader(including: nil)
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("SwiftExplicitDependencyGeneratePcm"), .matchRuleItemPattern(.contains("/MyCMod-")))
                results.checkNoErrors()
            }

            // Without the CAS sandbox the other files are found via the search path.
            for excludedFile in excludedFiles {
                try await writeBridgingHeader(including: excludedFile)
                try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["SWIFT_ENABLE_CAS_SANDBOX": "NO"]), runDestination: .macOS, persistent: true) { results in
                    results.checkNoErrors()
                }
            }

            // With the CAS sandbox files that are not headers or module maps are not ingested.
            for excludedFile in excludedFiles {
                try await writeBridgingHeader(including: excludedFile)
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    let errors = results.getErrors()
                    #expect(errors.contains { $0.contains("'\(excludedFile)' file not found") }, "expected '\(excludedFile)' to not be ingested")
                    #expect(!errors.contains { $0.contains("'plain.h' file not found") })
                    #expect(!errors.contains { $0.contains("'plain.hpp' file not found") })
                    #expect(!errors.contains { $0.contains("'MyCMod/nested.hpp' file not found") })
                    #expect(!errors.contains { $0.contains("unable to resolve module dependency: 'MyCMod'") })
                }
            }
        }
    }

    /// The CAS sandbox requires compilation caching.
    @Test(.requireSDKs(.macOS))
    func errorForCASSandboxWithoutCompilationCaching() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath).addingContents(of: [
                                    "SWIFT_ENABLE_COMPILE_CACHE": "NO",
                                ])),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.swift")) {
                $0 <<< "print(1)\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkError(.equal("SWIFT_ENABLE_CAS_SANDBOX requires enabling compilation caching (SWIFT_ENABLE_COMPILE_CACHE=YES) (in target 'tool' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }
    }

    /// The CAS sandbox is not enabled by default.
    @Test(.requireSDKs(.macOS))
    func noCASSandboxByDefault() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            var buildSettings = try await casSandboxBuildSettings(tmpDirPath)
            buildSettings.removeValue(forKey: "SWIFT_ENABLE_CAS_SANDBOX")
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("lib.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: buildSettings),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                    TestFrameworksBuildPhase(["MyFrame.framework"]),
                                ],
                                dependencies: ["MyFrame"]
                            ),
                            TestStandardTarget(
                                "MyFrame",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["lib.swift"]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import MyFrame\nfoo()\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoTask(.matchRuleType("IngestCASFSRoot"))
                for jsonFile in ["casfs-compilation-inputs.json", "casfs-deps.json", "casfs-outputs.json", "casfs-objc-outputs.json"] {
                    results.checkNoTask(.matchRuleItemBasename(jsonFile))
                }
                results.checkTasks(.matchRuleType("SwiftDriver")) { tasks in
                    #expect(tasks.count == 2)
                    for task in tasks {
                        task.checkCommandLineDoesNotContain("-scanner-cas-fs")
                        task.checkCommandLineDoesNotContain("-cas-fs-escape")
                        // Headermaps are used by default.
                        #expect(task.commandLine.contains { $0.asString.hasSuffix(".hmap") })
                    }
                }
                results.checkNoErrors()
            }
        }
    }

    /// Rebuilds pick up changes in the module sources, in the dependencies, and in the headers of the search paths.
    @Test(.requireSDKs(.macOS))
    func incrementalBuild() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("lib.swift"),
                                TestFile("Bridge.h"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: try await casSandboxBuildSettings(tmpDirPath)),
                        ],
                        targets: [
                            TestStandardTarget(
                                "tool",
                                type: .commandLineTool,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "SWIFT_OBJC_BRIDGING_HEADER": "Bridge.h",
                                        "USER_HEADER_SEARCH_PATHS": "$(SRCROOT)/include",
                                    ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase(["main.swift"]),
                                    TestFrameworksBuildPhase(["MyFrame.framework"]),
                                ],
                                dependencies: ["MyFrame"]
                            ),
                            TestStandardTarget(
                                "MyFrame",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["lib.swift"]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Bridge.h")) {
                $0 <<< "#include \"inc.h\"\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("include/inc.h")) {
                $0 <<< "static inline int inc_func(void) { return 1; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import MyFrame\nfoo()\nprint(inc_func())\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            let toolCASFSIDPath = try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
                return try results.checkTask(.matchTargetName("tool"), .matchRuleType("IngestCASFSRoot")) { task in
                    try #require(task.outputPaths.only)
                }
            }
            let casFSID1 = try tester.fs.read(toolCASFSIDPath).asString

            // Null build.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoTask(.matchRuleType("IngestCASFSRoot"))
                results.checkNoTask(.matchRuleType("SwiftDriver"))
                results.checkNoErrors()
            }

            // Change the API of the dependency.
            try await tester.fs.writeFileContents(SRCROOT.join("lib.swift")) {
                $0 <<< "public func foo() {}\npublic func bar() {}\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import MyFrame\nfoo()\nbar()\nprint(inc_func())\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchTargetName("MyFrame"), .matchRuleType("IngestCASFSRoot"))
                results.checkTaskExists(.matchTargetName("tool"), .matchRuleType("IngestCASFSRoot"))
                results.checkNoErrors()
            }
            let casFSID2 = try tester.fs.read(toolCASFSIDPath).asString
            #expect(casFSID1 != casFSID2)

            // Change a header in a user header search path.
            try await tester.fs.writeFileContents(SRCROOT.join("include/inc.h")) {
                $0 <<< "static inline int inc_func(void) { return 1; }\nstatic inline int inc_func2(void) { return 2; }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("main.swift")) {
                $0 <<< "import MyFrame\nfoo()\nbar()\nprint(inc_func() + inc_func2())\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchTargetName("tool"), .matchRuleType("IngestCASFSRoot"))
                results.checkNoErrors()
            }
            let casFSID3 = try tester.fs.read(toolCASFSIDPath).asString
            #expect(casFSID2 != casFSID3)
        }
    }
}

extension CompilationCASSandboxTests {
    /// The common build settings for enabling the CAS sandbox.
    fileprivate func casSandboxBuildSettings(_ tmpDirPath: Path) async throws -> [String: String] {
        return try await [
            "CODE_SIGNING_ALLOWED": "NO",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SDKROOT": "macosx",
            "SWIFT_VERSION": swiftVersion,
            "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
            "SWIFT_ENABLE_COMPILE_CACHE": "YES",
            "SWIFT_ENABLE_CAS_SANDBOX": "YES",
            "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
            "DSTROOT": tmpDirPath.join("dstroot").str,
        ]
    }
}

private func targetTempDir(_ tmpDirPath: Path, _ targetName: String) -> Path {
    return tmpDirPath.join("Test/aProject/build/aProject.build/Debug/\(targetName).build")
}

private func readCASFSDescription(_ tester: BuildOperationTester, _ task: any ExecutableTask) throws -> CASFSDescription {
    return try JSONDecoder().decode(CASFSDescription.self, from: Data(tester.fs.read(task.outputPaths[0])))
}

private func buildRequest(_ tester: BuildOperationTester, targets: [String], overrides: [String: String] = [:]) -> BuildRequest {
    let parameters = BuildParameters(configuration: "Debug", overrides: overrides)
    let buildTargets = tester.workspace.projects[0].targets.filter { targets.contains($0.name) }.map {
        BuildRequest.BuildTargetInfo(parameters: parameters, target: $0)
    }
    return BuildRequest(parameters: parameters, buildTargets: buildTargets, dependencyScope: .workspace, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
}
