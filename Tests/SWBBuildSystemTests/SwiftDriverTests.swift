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

@_spi(Testing) import SWBCore
import SWBProtocol
import SWBUtil
import SWBTestSupport
import SWBLLBuild

import SWBCore
import SWBTaskExecution

@Suite(.requireLLBuild(apiVersion: 12), .requireXcode16())
fileprivate struct SwiftDriverTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func swiftDriverPlanning() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),

                                TestFile("file3.swift"),
                                TestFile("file4.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                        "file2.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file3.swift",
                                        "file4.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    struct B {
                        let a = A()
                    }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) { file in
                file <<<
                    """
                    struct C {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file4.swift")) { file in
                file <<<
                    """
                    import TargetA

                    struct D {
                        let a = A()
                    }
                    """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in

                results.checkNoErrors()

                // Planning needs to follow upstream planning
                let planningTargetA = try #require(results.getTask(.matchTargetName("TargetA"), .matchRuleType("SwiftDriver")))
                planningTargetA.checkCommandLineMatches(["builtin-SwiftDriver", "--", .anySequence])
                #expect(planningTargetA.execDescription == "Planning Swift module TargetA (arm64e)")

                let planningTargetB = try #require(results.getTask(.matchTargetName("TargetB"), .matchRuleType("SwiftDriver")))
                planningTargetB.checkCommandLineMatches(["builtin-SwiftDriver", "--", .anySequence])
                #expect(planningTargetB.execDescription == "Planning Swift module TargetB (arm64e)")

                try results.checkTaskFollows(planningTargetB, planningTargetA)

                for targetName in ["TargetA", "TargetB"] {
                    results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTargetName(targetName)) { compilationRequirementTask in
                        compilationRequirementTask.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements"])
                        #expect(compilationRequirementTask.execDescription == "Unblock downstream dependents of \(targetName) (arm64e)")
                    }
                }

                for fileName in ["file1", "file2"] {
                    let linkTask = try #require(results.getTask(.matchTargetName("TargetA"), .matchRuleType("Ld")))
                    try results.checkTask(.matchTargetName("TargetA"), .matchRule(["SwiftCompile", "normal", "arm64e", "Compiling \(fileName).swift",SRCROOT.join("Sources/\(fileName).swift").str])) { compileTask in
                        compileTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/\(fileName).swift").str), .anySequence, "-o", .suffix("\(fileName).o")])
                        let env = compileTask.environment.bindingsDictionary
                        #expect(env["DEVELOPER_DIR"] != nil)
                        #expect(env["SDKROOT"] != nil)

                        try results.checkTaskFollows(linkTask, compileTask)
                    }
                }

                // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module, both are valid here.
                results.checkTask(.matchTargetName("TargetA"), .matchRulePattern([.or("SwiftMergeModule", "SwiftEmitModule"), "normal", "arm64e", .or("Merging module TargetA", "Emitting module for TargetA")])) { task in
                    if task.ruleIdentifier == "SwiftMergeModule" {
                        task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-merge-modules", .anySequence, .suffix("file1~partial.swiftmodule"), .suffix("file2~partial.swiftmodule"), .anySequence, "-o", .suffix("TargetA.swiftmodule")])
                    } else {
                        task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("TargetA.swiftmodule")])
                    }
                    let env = task.environment.bindingsDictionary
                    #expect(env["DEVELOPER_DIR"] != nil)
                    #expect(env["SDKROOT"] != nil)
                }

                for fileName in ["file3", "file4"] {
                    let linkTask = try #require(results.getTask(.matchTargetName("TargetB"), .matchRuleType("Ld")))
                    try results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", "arm64e", "Compiling \(fileName).swift", SRCROOT.join("Sources/\(fileName).swift").str])) { compileTask in
                        compileTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/\(fileName).swift").str), .anySequence, "-o", .suffix("\(fileName).o")])

                        try results.checkTaskFollows(linkTask, compileTask)
                    }
                }

                // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module, both are valid here.
                results.checkTask(.matchTargetName("TargetB"), .matchRulePattern([.or("SwiftMergeModule", "SwiftEmitModule"), "normal", "arm64e", .or("Merging module TargetB", "Emitting module for TargetB")])) { task in
                    if task.ruleIdentifier == "SwiftMergeModule" {
                        task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-merge-modules", .anySequence, .suffix("file3~partial.swiftmodule"), .suffix("file4~partial.swiftmodule"), .anySequence, "-o", .suffix("TargetB.swiftmodule")])
                    } else {
                        task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("TargetB.swiftmodule")])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func multipleArchs() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),

                                TestFile("file3.swift"),
                                TestFile("file4.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "$(VALID_ARCHS)",
                                    "VALID_ARCHS": "arm64e x86_64",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                        "file2.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file3.swift",
                                        "file4.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    struct B {
                        let a = A()
                    }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) { file in
                file <<<
                    """
                    struct C {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file4.swift")) { file in
                file <<<
                    """
                    import TargetA

                    struct D {
                        let a = A()
                    }
                    """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .anyMac, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()

                for arch in ["arm64e", "x86_64"] {
                    for targetName in ["TargetA", "TargetB"] {
                        results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName(targetName), .matchRuleItem(arch)) { driverTask in
                            driverTask.checkCommandLineMatches(["builtin-SwiftDriver", "--", .anySequence])
                            #expect(driverTask.execDescription == "Planning Swift module \(targetName) (\(arch))")
                        }
                    }

                    results.checkTask(.matchTargetName("TargetA"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file1.swift", SRCROOT.join("Sources/file1.swift").str])) { compileFile1Task in
                        compileFile1Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file1.swift").str), .anySequence, "-o", .suffix("file1.o")])
                        let env = compileFile1Task.environment.bindingsDictionary
                        #expect(env["DEVELOPER_DIR"] != nil)
                        #expect(env["SDKROOT"] != nil)
                    }

                    results.checkTask(.matchTargetName("TargetA"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file2.swift", SRCROOT.join("Sources/file2.swift").str])) { compileFile2Task in
                        compileFile2Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file2.swift").str), .anySequence, "-o", .suffix("file2.o")])
                        let env = compileFile2Task.environment.bindingsDictionary
                        #expect(env["DEVELOPER_DIR"] != nil)
                        #expect(env["SDKROOT"] != nil)
                    }

                    // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module, both are valid here.
                    results.checkTask(.matchTargetName("TargetA"), .matchRulePattern([.or("SwiftMergeModule", "SwiftEmitModule"), "normal", .equal(arch), .or("Merging module TargetA", "Emitting module for TargetA")])) { task in
                        if task.ruleIdentifier == "SwiftMergeModule" {
                            task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-merge-modules", .anySequence, .suffix("file1~partial.swiftmodule"), .suffix("file2~partial.swiftmodule"), .anySequence, "-o", .suffix("TargetA.swiftmodule")])
                        } else {
                            task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("TargetA.swiftmodule")])
                        }
                        let env = task.environment.bindingsDictionary
                        #expect(env["DEVELOPER_DIR"] != nil)
                        #expect(env["SDKROOT"] != nil)
                    }

                    results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file3.swift", SRCROOT.join("Sources/file3.swift").str])) { compileFile1Task in
                        compileFile1Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file3.swift").str), .anySequence, "-o", .suffix("file3.o")])
                    }

                    results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file4.swift", SRCROOT.join("Sources/file4.swift").str])) { compileFile2Task in
                        compileFile2Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file4.swift").str), .anySequence, "-o", .suffix("file4.o")])
                    }

                    // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module, both are valid here.
                    results.checkTask(.matchTargetName("TargetB"), .matchRulePattern([.or("SwiftMergeModule", "SwiftEmitModule"), "normal", .equal(arch), .or("Merging module TargetB", "Emitting module for TargetB")])) { task in
                        if task.ruleIdentifier == "SwiftMergeModule" {
                            task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-merge-modules", .anySequence, .suffix("file3~partial.swiftmodule"), .suffix("file4~partial.swiftmodule"), .anySequence, "-o", .suffix("TargetB.swiftmodule")])
                        } else {
                            task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("TargetB.swiftmodule")])
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func precompiledHeader() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("Bridging-Header.h"),
                                TestFile("file1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64",
                                    "SWIFT_OBJC_BRIDGING_HEADER": "Sources/Bridging-Header.h",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                    TestHeadersBuildPhase([
                                        "Bridging-Header.h"
                                    ])
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                        """
                        public struct A {
                            public init() {}
                        }
                        """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Bridging-Header.h")) { file in
                file <<<
                        """
                        @import Foundation;
                        """
            }

            try await tester.checkBuild(runDestination: .anyMac, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitBuildWithAPrecompiledHeader() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let sourceRootPath = tmpDirPath.join("Test")
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: sourceRootPath,
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("Bridging-Header.h"),
                                TestFile("file1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64",
                                    "SWIFT_OBJC_BRIDGING_HEADER": "Sources/Bridging-Header.h",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                    TestHeadersBuildPhase([
                                        "Bridging-Header.h"
                                    ])
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                        """
                        public struct A {
                            public init() {}
                        }
                        """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Bridging-Header.h")) { file in
                file <<<
                        """
                        @import Foundation;
                        """
            }

            try await tester.checkBuild(runDestination: .anyMac, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()

                let checkPayload: (BuildOperationTester.BuildResults.Task) -> Void = { task in
                    guard let swiftPayload = task.payload as? SwiftTaskPayload, let driverPayload = swiftPayload.driverPayload else {
                        Issue.record("Unexpected payload for Swift driver: \(task.payload as Any)")
                        return
                    }
                    #expect(driverPayload.moduleName == "TargetA")
                    #expect(driverPayload.variant == "normal")
                    #expect(driverPayload.architecture == "arm64")
                    #expect(driverPayload.eagerCompilationEnabled)
                    #expect(driverPayload.explicitModulesEnabled)
                }

                results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName("TargetA")) { driverTask -> Void in
                    driverTask.checkCommandLineMatches(["builtin-SwiftDriver", .anySequence, "-module-cache-path", .suffix("aProject/build/SwiftExplicitPrecompiledModules")])
                    #expect(driverTask.execDescription == "Planning Swift module TargetA (arm64)")
                    checkPayload(driverTask)
                }

                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTargetName("TargetA")) { driverTask in
                    driverTask.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements"])
                    #expect(driverTask.execDescription == "Unblock downstream dependents of TargetA (arm64)")
                    checkPayload(driverTask)
                }

                results.checkTask(.matchTargetName("TargetA"), .matchRule(["SwiftCompile", "normal", "arm64", "Compiling file1.swift", SRCROOT.join("Sources/file1.swift").str])) { compileFile1Task in
                    compileFile1Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .equal(SRCROOT.join("Sources/file1.swift").str), .anySequence, "-disable-implicit-swift-modules", .anySequence, "-import-objc-header", .regex(#/.*aProject/build/aProject.build/Debug/TargetA.build/Objects-normal/arm64/.*.pch/#), .anySequence, "-o", .suffix("file1.o")])
                }

            }
        }
    }

    @Test(.requireSDKs(.macOS), arguments: [true, false])
    func verifyModule(enableWMO: Bool) async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64",
                                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                                    "OTHER_SWIFT_FLAGS": "$(inherited) -verify-emitted-module-interface",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "SWIFT_WHOLE_MODULE_OPTIMIZATION": enableWMO ? "YES" : "NO",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .dynamicLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                            """
                            public struct A {
                                public init() {}
                            }
                            """
            }

            try await tester.checkBuild(runDestination: .anyMac, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()

                results.checkTask(.matchTargetName("TargetA"), .matchRuleType("SwiftDriver Compilation")) { compileBucket in
                    results.checkTaskRequested(compileBucket, .matchTargetName("TargetA"), .matchRuleType("SwiftVerifyEmittedModuleInterface"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func compatibleArchs() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "$(ARCHS_STANDARD)",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .dynamicLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "TargetAConfig",
                                        buildSettings: [
                                            "ARCHS": "arm64e"
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .dynamicLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "TargetBConfig",
                                        buildSettings: [
                                            "ARCHS": "arm64"
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file2.swift",
                                    ]),
                                ],
                                dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                        """
                        public struct A {
                            public init() {}
                        }
                        """
            }

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                        """
                        public struct B {
                            public init() {}
                        }
                        """
            }

            try await tester.checkBuild(runDestination: .anyMac, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func skipInstall() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64",
                                    "SUPPORTS_TEXT_BASED_API": "YES",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",

                                    "DSTROOT": tmpDirPath.join("dstroot").str,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .dynamicLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "TargetAConfig",
                                        buildSettings: [
                                            "SKIP_INSTALL": "YES"
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .dynamicLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file2.swift",
                                    ]),
                                ],
                                dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(action: .installAPI, configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                        """
                        public struct A {
                            public init() {}
                        }
                        """
            }

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                        """
                        public struct B {
                            public init() {}
                        }
                        """
            }

            try await tester.checkBuild(runDestination: .anyMac, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitBuildDefaultFromBlocklist() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let moduleCacheDir = tmpDirPath.join("ModuleCache")
            let blockListFilePath = tmpDirPath.join("swift-explicit-modules.json")
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file.swift")
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "BLOCKLISTS_PATH": tmpDirPath.str,
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file.swift"
                                    ]),
                                ])
                        ])
                ])
            var tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            try tester.fs.createDirectory(moduleCacheDir)
            let cleanParameters = BuildParameters(action: .clean, configuration: "Debug")
            let cleanRequest = BuildRequest(parameters: cleanParameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: cleanParameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            // Create the source file.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file.swift")) { file in
                file <<<
                            """
                            public struct A {
                                public init() {}
                            }
                            """
            }

            let checkExplicitBuildOn = { (results: BuildOperationTester.BuildResults) in
                results.checkNoErrors()
                // Remove in rdar://83104047
                results.checkWarnings([.contains("input unused"), .contains("input unused")], failIfNotFound: false)
                let checkPayload: (BuildOperationTester.BuildResults.Task) -> Void = { task in
                    guard let swiftPayload = task.payload as? SwiftTaskPayload, let driverPayload = swiftPayload.driverPayload else {
                        Issue.record("Unexpected payload for Swift driver: \(task.payload as Any)")
                        return
                    }
                    #expect(driverPayload.explicitModulesEnabled)
                }
                results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName("TargetA")) { driverTask -> Void in
                    driverTask.checkCommandLineMatches(["builtin-SwiftDriver", .anySequence, "-module-cache-path", .suffix("aProject/build/SwiftExplicitPrecompiledModules")])
                    #expect(driverTask.execDescription == "Planning Swift module TargetA (arm64)")
                    checkPayload(driverTask)
                }
            }

            let checkExplicitBuildOff = { (results: BuildOperationTester.BuildResults) in
                results.checkNoErrors()
                // Remove in rdar://83104047
                results.checkWarnings([.contains("input unused"), .contains("input unused")], failIfNotFound: false)
                let checkPayload: (BuildOperationTester.BuildResults.Task) -> Void = { task in
                    guard let swiftPayload = task.payload as? SwiftTaskPayload, let driverPayload = swiftPayload.driverPayload else {
                        Issue.record("Unexpected payload for Swift driver: \(task.payload as Any)")
                        return
                    }
                    #expect(!driverPayload.explicitModulesEnabled)
                }
                results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName("TargetA")) { driverTask -> Void in
                    driverTask.checkCommandLineMatches(["builtin-SwiftDriver", .anySequence])
                    #expect(driverTask.execDescription == "Planning Swift module TargetA (arm64)")
                    checkPayload(driverTask)
                }
            }

            let parameterizedBuildRequest = { (_ parameters: BuildParameters) in
                return BuildRequest(parameters: parameters,
                                    buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }),
                                    continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            }

            do {
                let buildParameters = BuildParameters(configuration: "Debug",
                                                      commandLineOverrides: ["SWIFT_ENABLE_EXPLICIT_MODULES":"YES"])
                // Ensure explicit modules are enabled as per the default
                try await tester.fs.writeFileContents(blockListFilePath) { file in
                    file <<<
                            """
                            {
                                "KnownFailures": []
                            }
                            """
                }
                try await tester.checkBuild(runDestination: .macOS, buildRequest: parameterizedBuildRequest(buildParameters)) { results in checkExplicitBuildOn(results) }
                try await tester.checkBuild(runDestination: .macOS, buildRequest: cleanRequest) { results in results.checkNoErrors() }
            }

            tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            do {
                // Add project name to the `KnownFailures` and ensure explicit modules are disabled despite the build setting enable
                let buildParameters = BuildParameters(configuration: "Debug",
                                                      commandLineOverrides: ["SWIFT_ENABLE_EXPLICIT_MODULES":"YES"])
                try await tester.fs.writeFileContents(blockListFilePath) { file in
                    file <<<
                            """
                            {
                                "KnownFailures": ["aProject"]
                            }
                            """
                }
                try await tester.checkBuild(runDestination: .macOS, buildRequest: parameterizedBuildRequest(buildParameters)) { results in checkExplicitBuildOff(results) }
                try await tester.checkBuild(runDestination: .macOS, buildRequest: cleanRequest) { results in results.checkNoErrors() }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitBuild() async throws {
        for setting in ["SWIFT_ENABLE_EXPLICIT_MODULES", "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES"] {
            for arch in ["x86_64", "arm64"] {
                try await withTemporaryDirectory { tmpDirPath async throws -> Void in
                    let moduleCacheDir = tmpDirPath.join("ModuleCache")
                    let testWorkspace = try await TestWorkspace(
                        "Test",
                        sourceRoot: tmpDirPath.join("Test"),
                        projects: [
                            TestProject(
                                "aProject",
                                groupTree: TestGroup(
                                    "Sources",
                                    path: "Sources",
                                    children: [
                                        TestFile("fileC.c"),
                                        TestFile("fileC.h"),

                                        TestFile("file1.swift"),
                                        TestFile("file2.swift"),

                                        TestFile("file3.swift"),
                                        TestFile("file4.swift"),

                                        TestFile("file5.swift"),
                                        TestFile("file6.swift"),
                                    ]),
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "SWIFT_VERSION": swiftVersion,
                                            "BUILD_VARIANTS": "normal",
                                            "ARCHS": arch,
                                            "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                            setting: "YES",
                                        ])
                                ],
                                targets: [
                                    TestStandardTarget(
                                        "Target0",
                                        type: .framework,
                                        buildPhases: [
                                            TestSourcesBuildPhase([
                                                "fileC.c",
                                                "fileC.h"
                                            ]),
                                        ]),
                                    TestStandardTarget(
                                        "TargetA",
                                        type: .framework,
                                        buildPhases: [
                                            TestSourcesBuildPhase([
                                                "file1.swift",
                                                "file2.swift",
                                            ]),
                                        ]),
                                    TestStandardTarget(
                                        "TargetB",
                                        type: .framework,
                                        buildPhases: [
                                            TestSourcesBuildPhase([
                                                "file3.swift",
                                                "file4.swift",
                                            ]),
                                            // Explicit module builds do not currently behave the same way
                                            // as implicit, which auto-link all dependencies by-default.
                                            // Explicitly linking dependencies is required. This may cause
                                            // a lot of projects to break though so we may need to make explicit modules
                                            // behave the same way and re-introduce auto-linking.
                                            TestFrameworksBuildPhase([TestBuildFile(.target("TargetA"))])
                                        ], dependencies: ["TargetA"]),
                                    TestStandardTarget(
                                        "TargetC",
                                        type: .framework,
                                        buildPhases: [
                                            TestSourcesBuildPhase([
                                                "file5.swift",
                                                "file6.swift",
                                            ]),
                                            TestFrameworksBuildPhase([TestBuildFile(.target("TargetA")), TestBuildFile(.target("TargetB"))])
                                        ], dependencies: ["TargetB", "Target0"])
                                ])
                        ])

                    let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                    try tester.fs.createDirectory(moduleCacheDir)
                    let parameters = BuildParameters(configuration: "Debug")
                    let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
                    let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                    // Create the source files.
                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileC.c")) { file in
                        file <<<
                        """
                        int foo() { return 11; }
                        """
                    }
                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileC.h")) { file in
                        file <<<
                        """
                        int foo();
                        """
                    }
                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                        file <<<
                        """
                        public struct A {
                            public init() {}
                        }
                        """
                    }
                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                        file <<<
                        """
                        struct B {
                            let a = A()
                        }
                        """
                    }

                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) { file in
                        file <<<
                        """
                        public struct C {
                            public init() {}
                        }
                        """
                    }
                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/file4.swift")) { file in
                        file <<<
                        """
                        import TargetA

                        struct D {
                            let a = A()
                        }
                        """
                    }

                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/file5.swift")) { file in
                        file <<<
                        """
                        struct E {}
                        """
                    }
                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/file6.swift")) { file in
                        file <<<
                        """
                        import TargetB

                        struct F {
                            let c = C()
                        }
                        """
                    }

                    // Check that subtasks progress events are reported as expected.
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                        results.checkNoErrors()
                        // Remove in rdar://83104047
                        results.checkWarnings([.contains("input unused"), .contains("input unused")], failIfNotFound: false)

                        for targetName in ["TargetA", "TargetB"] {
                            let checkPayload: (BuildOperationTester.BuildResults.Task) -> Void = { task in
                                guard let swiftPayload = task.payload as? SwiftTaskPayload, let driverPayload = swiftPayload.driverPayload else {
                                    Issue.record("Unexpected payload for Swift driver: \(task.payload as Any)")
                                    return
                                }
                                #expect(driverPayload.moduleName == targetName)
                                #expect(driverPayload.variant == "normal")
                                #expect(driverPayload.architecture == arch)
                                #expect(driverPayload.eagerCompilationEnabled)
                                #expect(driverPayload.explicitModulesEnabled)
                            }

                            results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName(targetName)) { driverTask -> Void in
                                driverTask.checkCommandLineMatches(["builtin-SwiftDriver", .anySequence, "-module-cache-path", .suffix("aProject/build/SwiftExplicitPrecompiledModules")])
                                #expect(driverTask.execDescription == "Planning Swift module \(targetName) (\(arch))")
                                checkPayload(driverTask)
                            }

                            results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTargetName(targetName)) { driverTask in
                                driverTask.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements"])
                                #expect(driverTask.execDescription == "Unblock downstream dependents of \(targetName) (\(arch))")
                                checkPayload(driverTask)
                            }
                        }

                        results.checkTask(.matchTargetName("TargetA"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file1.swift", SRCROOT.join("Sources/file1.swift").str])) { compileFile1Task in
                            compileFile1Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .equal(SRCROOT.join("Sources/file1.swift").str), .anySequence, "-disable-implicit-swift-modules", .anySequence, "-o", .suffix("file1.o")])
                        }

                        results.checkTask(.matchTargetName("TargetA"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file2.swift", SRCROOT.join("Sources/file2.swift").str])) { compileFile2Task in
                            compileFile2Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .equal(SRCROOT.join("Sources/file2.swift").str), .anySequence, "-disable-implicit-swift-modules",  .anySequence, "-o", .suffix("file2.o")])
                        }

                        // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module, both are valid here.
                        results.checkTask(.matchTargetName("TargetA"), .matchRulePattern([.or("SwiftMergeModule", "SwiftEmitModule"), "normal", "\(arch)", .or("Merging module TargetA", "Emitting module for TargetA")])) { task in
                            if task.ruleIdentifier == "SwiftMergeModule" {
                                task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-merge-modules", .anySequence, .suffix("file1~partial.swiftmodule"), .suffix("file2~partial.swiftmodule"), .anySequence, "-o", .suffix("TargetA.swiftmodule")])
                            } else {
                                task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("TargetA.swiftmodule")])
                            }
                        }

                        results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file3.swift", SRCROOT.join("Sources/file3.swift").str])) { compileFile3Task in
                            compileFile3Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file3.swift").str), .anySequence, "-disable-implicit-swift-modules",  .anySequence, "-o", .suffix("file3.o")])
                        }

                        results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file4.swift", SRCROOT.join("Sources/file4.swift").str])) { compileFile4Task in
                            compileFile4Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file4.swift").str), .anySequence, "-disable-implicit-swift-modules",  .anySequence, "-o", .suffix("file4.o")])
                        }

                        // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module, both are valid here.
                        results.checkTask(.matchTargetName("TargetB"), .matchRulePattern([.or("SwiftMergeModule", "SwiftEmitModule"), "normal", "\(arch)", .or("Merging module TargetB", "Emitting module for TargetB")])) { task in
                            if task.ruleIdentifier == "SwiftMergeModule" {
                                task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-merge-modules", .anySequence, .suffix("file3~partial.swiftmodule"), .suffix("file4~partial.swiftmodule"), .anySequence, "-o", .suffix("TargetB.swiftmodule")])
                            } else {
                                task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("TargetB.swiftmodule")])
                            }
                        }
                        results.checkTask(.matchTargetName("TargetC"), .matchRule(["SwiftCompile", "normal", "\(arch)", "Compiling file5.swift", SRCROOT.join("Sources/file5.swift").str])) { compileFile3Task in
                            compileFile3Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file5.swift").str), .anySequence, "-disable-implicit-swift-modules",  .anySequence, "-o", .suffix("file5.o")])
                        }

                        results.checkTask(.matchTargetName("TargetC"), .matchRule(["SwiftCompile", "normal", "\(arch)", "Compiling file6.swift", SRCROOT.join("Sources/file6.swift").str])) { compileFile4Task in
                            compileFile4Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file6.swift").str), .anySequence, "-disable-implicit-swift-modules",  .anySequence, "-o", .suffix("file6.o")])
                        }

                        // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module, both are valid here.
                        results.checkTask(.matchTargetName("TargetC"), .matchRulePattern([.or("SwiftMergeModule", "SwiftEmitModule"), "normal", "\(arch)", .or("Merging module TargetC", "Emitting module for TargetC")])) { task in
                            if task.ruleIdentifier == "SwiftMergeModule" {
                                task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-merge-modules", .anySequence, .suffix("file5~partial.swiftmodule"), .suffix("file6~partial.swiftmodule"), .anySequence, "-o", .suffix("TargetC.swiftmodule")])
                            } else {
                                task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("TargetC.swiftmodule")])
                            }
                        }

                        // The below checks also ensure uniqueness of these tasks in this build
                        results.checkTasks(.matchRule(["SwiftExplicitDependencyGeneratePcm", "normal", arch, "Compiling Clang module SwiftShims"]), .matchCommandLineArgument("SwiftShims")) { pcmBuildTasks in
                            for pcmBuildTask in pcmBuildTasks {
                                pcmBuildTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-pcm", .anySequence, "-module-name", "SwiftShims"])
                            }
                        }

                        results.checkTasks(.matchRule(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", arch, "Compiling Swift module _Concurrency"]), .matchCommandLineArgument("_Concurrency")) { emitModuleTasks in
                            for emitModuleTask in emitModuleTasks {
                                emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-compile-module-from-interface", .anySequence, "-module-name", "_Concurrency"])
                            }
                        }

                        results.checkTasks(.matchRule(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", arch, "Compiling Swift module Swift"]), .matchCommandLineArgument("Swift")) { emitModuleTasks in
                            for emitModuleTask in emitModuleTasks {
                                emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-compile-module-from-interface", .anySequence, "-module-name", "Swift"])
                            }
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitModuleDeduplicationBasics() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileC.c"),
                                TestFile("Target0.h"),
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                    "DEFINES_MODULE": "YES",
                                    "CLANG_ENABLE_MODULES": "YES"
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Target0",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileC.c",
                                    ]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Target0.h", headerVisibility: .public)
                                    ])
                                ]),
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ], dependencies: [
                                    "Target0"
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file2.swift",
                                    ]),
                                ], dependencies: [
                                    "Target0"
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileC.c")) { file in
                file <<<
                            """
                            int foo() { return 11; }
                            """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Target0.h")) { file in
                file <<<
                            """
                            int foo();
                            """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                            """
                            import Target0
                            public struct A {
                                public init() { foo() }
                            }
                            """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                            """
                            import Target0
                            public struct B {
                                public init() { foo() }
                            }
                            """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()

                // Identical build variants should be able to share PCMs. We should only have one task to precompile Target0's module.
                try results.checkTask(.matchRulePattern(["SwiftExplicitDependencyGeneratePcm", .anySequence, .contains("Target0")])) { precompileTarget0Task in
                    try results.checkTask(.matchRulePattern(["SwiftCompile", "normal", .any, "Compiling file1.swift", .any])) { task in
                        try results.checkTaskFollows(task, precompileTarget0Task)
                    }
                    try results.checkTask(.matchRulePattern(["SwiftCompile", "normal", .any, "Compiling file2.swift", .any])) { task in
                        try results.checkTaskFollows(task, precompileTarget0Task)
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .flaky("Occasionally fails in CI due to SwiftExplicitDependencyCompileModuleFromInterface missing from the dependency graph"), .bug("rdar://138085722"), arguments: ["x86_64", "arm64"])
    func explicitBuildWithMultipleProjects(arch: String) async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let moduleCacheDir = tmpDirPath.join("ModuleCache")
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": arch,
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget("TargetA",
                                               type: .framework,
                                               buildConfigurations: [
                                                TestBuildConfiguration("Debug"),
                                               ],
                                               buildPhases: [
                                                TestSourcesBuildPhase([
                                                    "file1.swift",
                                                    "file2.swift"
                                                ]),
                                               ])
                        ]),
                    TestProject(
                        "bProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file3.swift"),
                                TestFile("file4.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": arch,
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                    // FIXME: Unfortunately, `BuildOperationTester` doesn't set up a shared `BUILT_PRODUCTS_DIR` for the whole workspace.
                                    "SWIFT_INCLUDE_PATHS": "$(TARGET_BUILD_DIR)/../../../aProject/build/Debug",
                                    "FRAMEWORK_SEARCH_PATHS": "$(TARGET_BUILD_DIR)/../../../aProject/build/Debug",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug"),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file3.swift",
                                        "file4.swift",
                                    ]),
                                    TestFrameworksBuildPhase([TestBuildFile(.target("TargetA"))])
                                ], dependencies: ["TargetA"])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            tester.userInfo = tester.userInfo.withAdditionalEnvironment(environment: ["SWIFT_FORCE_MODULE_LOADING": "only-interface"])
            try tester.fs.createDirectory(moduleCacheDir)
            let parameters = BuildParameters(configuration: "Debug", overrides: [
                // Redirect the prebuilt cache so we always build modules from source
                "SWIFT_OVERLOAD_PREBUILT_MODULE_CACHE_PATH": tmpDirPath.str
            ])
            let targetsToBuild = tester.workspace.projects.flatMap { project in project.targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }) }
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: targetsToBuild, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOTA = testWorkspace.sourceRoot.join("aProject")
            let SRCROOTB = testWorkspace.sourceRoot.join("bProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOTA.join("Sources/file1.swift")) { file in
                file <<<
                        """
                        public struct A {\n\tpublic init() {}\n}
                        """
            }
            try await tester.fs.writeFileContents(SRCROOTA.join("Sources/file2.swift")) { file in
                file <<<
                        """
                        struct B {\n\tlet a = A()\n}
                        """
            }

            try await tester.fs.writeFileContents(SRCROOTB.join("Sources/file3.swift")) { file in
                file <<<
                        """
                        public struct C {\n\tpublic init() {}\n}
                        """
            }
            try await tester.fs.writeFileContents(SRCROOTB.join("Sources/file4.swift")) { file in
                file <<<
                        """
                        import TargetA\n\nstruct D {\n\tlet a = A()\n}
                        """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
                // Remove in rdar://83104047
                results.checkWarnings([.contains("input unused"), .contains("input unused")], failIfNotFound: false)

                // Explicit dependency jobs are de-duplicated per-project (for now).
                results.checkTask(.matchRulePattern(["SwiftExplicitDependencyGeneratePcm", "normal", .equal(arch), .contains("SwiftShims")]), .matchCommandLineArgument("SwiftShims"), .matchCommandLineArgumentPattern(.contains("aProject/build/SwiftExplicitPrecompiledModules/SwiftShims"))) { emitModuleTask in
                    emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-pcm", .anySequence, "-module-name", "SwiftShims"])
                }
                results.checkTask(.matchRulePattern(["SwiftExplicitDependencyGeneratePcm", "normal", .equal(arch), .contains("SwiftShims")]), .matchCommandLineArgument("SwiftShims"), .matchCommandLineArgumentPattern(.contains("bProject/build/SwiftExplicitPrecompiledModules/SwiftShims"))) { emitModuleTask in
                    emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-pcm", .anySequence, "-module-name", "SwiftShims"])
                }

                results.checkTask(.matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("Swift")]), .matchCommandLineArgument("Swift"), .matchCommandLineArgumentPattern(.contains("aProject/build/SwiftExplicitPrecompiledModules/Swift"))) { emitModuleTask in
                    emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-compile-module-from-interface", .anySequence, "-module-name", "Swift", .anySequence, "-o", .contains("aProject/build/SwiftExplicitPrecompiledModules/Swift")])
                }
                results.checkTask(.matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("Swift")]), .matchCommandLineArgument("Swift"), .matchCommandLineArgumentPattern(.contains("bProject/build/SwiftExplicitPrecompiledModules/Swift"))) { emitModuleTask in
                    emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-compile-module-from-interface", .anySequence, "-module-name", "Swift", .anySequence, "-o", .contains("bProject/build/SwiftExplicitPrecompiledModules/Swift")])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .flaky("Occasionally fails in CI due to SwiftExplicitDependencyCompileModuleFromInterface missing from the dependency graph"), .bug("rdar://138160283"))
    func explicitBuildModuleSharingWithResponseFiles() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let moduleCacheDir = tmpDirPath.join("ModuleCache")
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                    // Force use of a response file
                                    "GCC_PREPROCESSOR_DEFINITIONS": Array(repeating: "ABCD=1", count: 10000).joined(separator: " ")
                                ])
                        ],
                        targets: [
                            TestStandardTarget("TargetA",
                                               type: .framework,
                                               buildConfigurations: [
                                                TestBuildConfiguration("Debug"),
                                               ],
                                               buildPhases: [
                                                TestSourcesBuildPhase([
                                                    "file1.swift",
                                                ]),
                                               ], dependencies: ["TargetB"]),
                            TestStandardTarget("TargetB",
                                               type: .framework,
                                               buildConfigurations: [
                                                TestBuildConfiguration("Debug"),
                                               ],
                                               buildPhases: [
                                                TestSourcesBuildPhase([
                                                    "file2.swift"
                                                ]),
                                               ])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            tester.userInfo = tester.userInfo.withAdditionalEnvironment(environment: ["SWIFT_FORCE_MODULE_LOADING": "only-interface"])
            try tester.fs.createDirectory(moduleCacheDir)
            let parameters = BuildParameters(configuration: "Debug")
            let targetsToBuild = tester.workspace.projects.flatMap { project in project.targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }) }
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: targetsToBuild, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOTA = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOTA.join("Sources/file1.swift")) { file in
                file <<<
                        """
                        import Foundation
                        """
            }
            try await tester.fs.writeFileContents(SRCROOTA.join("Sources/file2.swift")) { file in
                file <<<
                        """
                        import Foundation
                        """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
                results.checkTasks(.matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .any, .contains("SwiftExplicitPrecompiledModules/Foundation-")])) { compileFoundationTasks in
                    // We only expect to need one variant of Foundation
                    #expect(compileFoundationTasks.count == 1)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitBuildWithMixedSourceTarget() async throws {
        for arch in ["x86_64", "arm64"] {
            try await withTemporaryDirectory { tmpDirPath async throws -> Void in
                let moduleCacheDir = tmpDirPath.join("ModuleCache")
                let testWorkspace = try await TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources",
                                path: "Sources",
                                children: [
                                    TestFile("fileC.c"),
                                    TestFile("fileC.h"),
                                    TestFile("file1.swift"),
                                    TestFile("file2.swift"),

                                    TestFile("file3.swift"),
                                    TestFile("file4.swift"),
                                ]),
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "SWIFT_VERSION": swiftVersion,
                                        "BUILD_VARIANTS": "normal",
                                        "ARCHS": arch,
                                        "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                    ])
                            ],
                            targets: [
                                // Ensure that a target containing both Swift and C sources
                                // can be used as dependency.
                                TestStandardTarget(
                                    "TargetA",
                                    type: .framework,
                                    buildConfigurations: [
                                        // Modify PRODUCT_NAME to ensure we use it downstream
                                        // for target dependency info, instead of target name.
                                        TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "TargetA_X"]),
                                    ],
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "fileC.c",
                                            "fileC.h",
                                            "file1.swift",
                                            "file2.swift"
                                        ]),
                                    ]),
                                TestStandardTarget(
                                    "TargetB",
                                    type: .framework,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "TargetB_X"]),
                                    ],
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "file3.swift",
                                            "file4.swift",
                                        ]),
                                        TestFrameworksBuildPhase([TestBuildFile(.auto("TargetA_X.framework"))])
                                    ], dependencies: ["TargetA"])
                            ])
                    ])

                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                try tester.fs.createDirectory(moduleCacheDir)
                let parameters = BuildParameters(configuration: "Debug")
                let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                // Create the source files.
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileC.c")) { file in
                    file <<<
                        """
                        int foo() { return 11; }
                        """
                }
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileC.h")) { file in
                    file <<<
                        """
                        int foo();
                        """
                }
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                    file <<<
                        """
                        public struct A {
                            public init() {}
                        }
                        """
                }
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                    file <<<
                        """
                        struct B {
                            let a = A()
                        }
                        """
                }

                try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) { file in
                    file <<<
                        """
                        public struct C {
                            public init() {}
                        }
                        """
                }
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/file4.swift")) { file in
                    file <<<
                        """
                        import TargetA_X

                        struct D {
                            let a = A()
                        }
                        """
                }

                // Check that subtasks progress events are reported as expected.
                try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                    results.checkNoErrors()
                    // Remove in rdar://83104047
                    results.checkWarnings([.contains("input unused"), .contains("input unused")], failIfNotFound: false)

                    for targetName in ["TargetA", "TargetB"] {
                        results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName(targetName)) { driverTask in
                            driverTask.checkCommandLineMatches(["builtin-SwiftDriver", "--", .anySequence, "-module-cache-path", .suffix("aProject/build/SwiftExplicitPrecompiledModules")])
                            #expect(driverTask.execDescription == "Planning Swift module \(targetName)_X (\(arch))")
                        }

                        results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTargetName(targetName)) { driverTask in
                            driverTask.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements"])
                            #expect(driverTask.execDescription == "Unblock downstream dependents of \(targetName)_X (\(arch))")
                        }
                    }

                    results.checkTask(.matchTargetName("TargetA"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file1.swift", SRCROOT.join("Sources/file1.swift").str])) { compileFile1Task in
                        compileFile1Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .equal(SRCROOT.join("Sources/file1.swift").str), .anySequence, "-disable-implicit-swift-modules", .anySequence, "-o", .suffix("file1.o")])
                    }

                    results.checkTask(.matchTargetName("TargetA"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file2.swift", SRCROOT.join("Sources/file2.swift").str])) { compileFile2Task in
                        compileFile2Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .equal(SRCROOT.join("Sources/file2.swift").str), .anySequence, "-disable-implicit-swift-modules",  .anySequence, "-o", .suffix("file2.o")])
                    }

                    // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module, both are valid here.
                    results.checkTask(.matchTargetName("TargetA"), .matchRulePattern([.or("SwiftMergeModule", "SwiftEmitModule"), "normal", "\(arch)", .or("Merging module TargetA_X", "Emitting module for TargetA_X")])) { task in
                        if task.ruleIdentifier == "SwiftMergeModule" {
                            task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-merge-modules", .anySequence, .suffix("file1~partial.swiftmodule"), .suffix("file2~partial.swiftmodule"), .anySequence, "-o", .suffix("TargetA_X.swiftmodule")])
                        } else {
                            task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("TargetA_X.swiftmodule")])
                        }
                    }

                    results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file3.swift", SRCROOT.join("Sources/file3.swift").str])) { compileFile3Task in
                        compileFile3Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .equal(SRCROOT.join("Sources/file3.swift").str), .anySequence, "-disable-implicit-swift-modules",  .anySequence, "-o", .suffix("file3.o")])
                    }

                    results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", arch, "Compiling file4.swift", SRCROOT.join("Sources/file4.swift").str])) { compileFile4Task in
                        compileFile4Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file4.swift").str), .anySequence, "-disable-implicit-swift-modules",  .anySequence, "-o", .suffix("file4.o")])
                    }

                    // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module, both are valid here.
                    results.checkTask(.matchTargetName("TargetB"), .matchRulePattern([.or("SwiftMergeModule", "SwiftEmitModule"), "normal", "\(arch)", .or("Merging module TargetB_X", "Emitting module for TargetB_X")])) { task in
                        if task.ruleIdentifier == "SwiftMergeModule" {
                            task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-merge-modules", .anySequence, .suffix("file3~partial.swiftmodule"), .suffix("file4~partial.swiftmodule"), .anySequence, "-o", .suffix("TargetB_X.swiftmodule")])
                        } else {
                            task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("TargetB_X.swiftmodule")])
                        }
                    }

                    // The below checks also ensure uniqueness of these tasks in this build
                    results.checkTasks(.matchRule(["SwiftExplicitDependencyGeneratePcm", "normal", arch, "Compiling Clang module SwiftShims"]), .matchCommandLineArgument("SwiftShims")) { pcmBuildTasks in
                        for pcmBuildTask in pcmBuildTasks {
                            pcmBuildTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-pcm", .anySequence, "-module-name", "SwiftShims"])
                        }
                    }

                    results.checkTasks(.matchRule(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", arch, "Compiling Swift module _Concurrency"]), .matchCommandLineArgument("_Concurrency")) { emitModuleTasks in
                        for emitModuleTask in emitModuleTasks {
                            emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-compile-module-from-interface", .anySequence, "-module-name", "_Concurrency"])
                        }
                    }

                    results.checkTasks(.matchRule(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", arch, "Compiling Swift module Swift"]), .matchCommandLineArgument("Swift")) { emitModuleTasks in
                        for emitModuleTask in emitModuleTasks {
                            emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-compile-module-from-interface", .anySequence, "-module-name", "Swift"])
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuild_invalidateDownstreamPlanning() async throws {

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file2.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    open class A1 {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    import TargetA

                    final class A2: A1 {}
                    """
            }

            // Initial build
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
            }

            // null build
            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            // Add method to A1 in TargetA to invalidate TargetA and TargetB planning
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    open class A1 {
                        open func foo() { }
                    }
                    """
            }

            // null build
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()

                results.checkTaskExists(.matchTargetName("TargetA"), .matchRuleType("SwiftDriver"))
                results.checkTaskExists(.matchTargetName("TargetB"), .matchRuleType("SwiftDriver"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuild_changeSameFile() async throws {

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source file.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift"), waitForNewTimestamp: true) { file in
                file <<<
                    """
                    public struct A1 {}
                    """
            }

            // Initial build
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
            }

            // null build
            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            // Change the source file.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift"), waitForNewTimestamp: true) { file in
                file <<<
                    """
                    public class A1 { }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
                results.checkTaskExists(.matchRuleType("SwiftCompile"))
                results.checkTaskExists(.matchRuleType("Ld"))
            }

            // Change the source file again.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift"), waitForNewTimestamp: true) { file in
                file <<<
                    """
                    public class A2 { }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
                results.checkTaskExists(.matchRuleType("SwiftCompile"))
                results.checkTaskExists(.matchRuleType("Ld"))
            }
        }
    }

    // Regression test for rdar://105302287 (Build A.swift and B.swift, change A.swift to break B.swift, revert A.swift such that B.swift doesn't need to rebuild => build log still reports error from B.swift). Note that this must be tested at the Swift Build layer rather than SwiftDriver because Swift Build is responsible for using the SwiftDriver API to correctly emit an incremental build record.
    @Test(.requireSDKs(.macOS))
    func incrementalBuildRecordCorrectlyPersistsCompileFailures() async throws {

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                        "file2.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the sources.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift"), waitForNewTimestamp: true) { file in
                file <<<
                    """
                    func f() {
                        // We place this code inside a function body so that when we introduce an error, it is emitted by only the compile task, and not the emit-module task as well.
                        let x = y
                        print(x)
                    }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift"), waitForNewTimestamp: true) { file in
                file <<<
                    """
                    let y = 42
                    """
            }

            // Initial build should succeed. We should have two compile tasks and one module emission task.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkNoDiagnostics()
                results.checkTaskExists(.matchRulePattern(["SwiftEmitModule", "normal", .any, "Emitting module for TargetA"]))
                results.checkTaskExists(.matchRulePattern(["SwiftCompile", "normal", .any, "Compiling file1.swift"]))
                results.checkTaskExists(.matchRulePattern(["SwiftCompile", "normal", .any, "Compiling file2.swift"]))
            }

            // Update file2 such that the compilation of file1 will emit an error and fail.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift"), waitForNewTimestamp: true) { file in
                file <<<
                    """
                    let z = 42
                    """
            }
            // In this build, only file2 was directly modified, so it will be in the first wave and file1 will be in the second wave. As a result, we should see both tasks even though compilation of file 1 fails. We may or may not see the emit-module task depending on timing, so don't check for it.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkError(.contains("cannot find 'y' in scope"))
                results.checkError(.prefix("Command SwiftCompile failed."))
                results.checkTaskExists(.matchRulePattern(["SwiftCompile", "normal", .any, "Compiling file1.swift"]))
                results.checkTaskExists(.matchRulePattern(["SwiftCompile", "normal", .any, "Compiling file2.swift"]))
            }

            // Revert the changes to file2. The new build should succeed, and both files should recompile, file2 because it was modified and file1 because it failed in the previous build.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift"), waitForNewTimestamp: true) { file in
                file <<<
                    """
                    let y = 42
                    """
            }
            // Previously, only the emit module task and compilation of file2 would run, because the stale build record indicated that file1 succeeded in the previous build. With the fix, we should once again see the emit-module task and both compile tasks.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkNoDiagnostics()
                results.checkTaskExists(.matchRulePattern(["SwiftEmitModule", "normal", .any, "Emitting module for TargetA"]))
                results.checkTaskExists(.matchRulePattern(["SwiftCompile", "normal", .any, "Compiling file1.swift"]))
                results.checkTaskExists(.matchRulePattern(["SwiftCompile", "normal", .any, "Compiling file2.swift"]))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuild_eagerCompilation() async throws {

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),

                                TestFile("file3.swift"),
                                TestFile("file4.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                        "file2.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file3.swift",
                                        "file4.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A1 {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    open class A2 {
                        let a = A1()
                    }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) { file in
                file <<<
                    """
                    import TargetA

                    class B1: A2 {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file4.swift")) { file in
                file <<<
                    """
                    class B2: B1 {}
                    """
            }

            // Initial build
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
            }

            // null build
            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            // Change B -> Incremental build
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file4.swift")) { file in
                file <<<
                    """
                    class B2 { }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
                results.consumeTasksMatchingRuleTypes(["Gate", "SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation"], targetName: "TargetA")

                for ruleInfoType in ["SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation", "SwiftCompile", "SwiftEmitModule"] {
                    results.checkTasks(.matchTargetName("TargetB"), .matchRuleType(ruleInfoType)) { tasks in
                        #expect(!tasks.isEmpty, "Did not find tasks for ruleInfoType \(ruleInfoType).")
                    }
                }

                for ruleInfoType in ["SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation"] {
                    results.checkNoTask(.matchTargetName("TargetA"), .matchRuleType(ruleInfoType))
                }

                let batchedSubtaskUpToDateCount = results.events.filter {
                    if case .previouslyBatchedSubtaskUpToDate = $0 {
                        return true
                    } else {
                        return false
                    }
                }.count
                #expect(batchedSubtaskUpToDateCount == 1)
            }

            // Another null build
            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            // Change public API in A
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A1 {}
                    public struct Foo {}
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()

                // We expect TargetB to rebuild it's files when changing API in a dependency
                results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", "arm64e", "Compiling file3.swift", SRCROOT.join("Sources/file3.swift").str])) { compileFile3Task in
                    compileFile3Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .equal(SRCROOT.join("Sources/file3.swift").str), .anySequence, "-o", .suffix("file3.o")])
                }
                results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", "arm64e", "Compiling file4.swift", SRCROOT.join("Sources/file4.swift").str])) { compileFile4Task in
                    compileFile4Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .equal(SRCROOT.join("Sources/file4.swift").str), .anySequence, "-o", .suffix("file4.o")])
                }

                for ruleInfoType in ["SwiftCompile", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation", "SwiftEmitModule", "SwiftDriver", "Ld"] {
                    results.checkTasks(.matchTargetName("TargetA"), .matchRuleItemPattern(.prefix(ruleInfoType))) { tasks in
                        #expect(!tasks.isEmpty, "Did not find tasks for ruleInfoType \(ruleInfoType).")
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalBuild_nullBuildPlanning() async throws {

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),

                                TestFile("file3.swift"),
                                TestFile("file4.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                        "file2.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file3.swift",
                                        "file4.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A1 {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    open class A2 {
                        let a = A1()
                    }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) { file in
                file <<<
                    """
                    import TargetA

                    class B1: A2 {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file4.swift")) { file in
                file <<<
                    """
                    class B2: B1 {}
                    """
            }

            // Initial build
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
            }

            // null build

            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            // another null build
            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)
        }
    }

    @Test(.requireSDKs(.macOS))
    func threadSafety() async throws {
        let numberOfTargets = 5
        let numberOfFilesPerTarget = 300

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: (0..<numberOfTargets).flatMap { targetNumber in
                                (0..<numberOfFilesPerTarget).map { fileNumber in
                                    TestFile("Target\(targetNumber)File\(fileNumber).swift")
                                }
                            }),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets:
                            (0..<numberOfTargets).map { targetNumber in
                                TestStandardTarget(
                                    "Target\(targetNumber)",
                                    type: .framework,
                                    buildPhases: [
                                        TestSourcesBuildPhase((0..<numberOfFilesPerTarget).map { fileNumber in
                                            TestBuildFile("Target\(targetNumber)File\(fileNumber).swift")
                                        })
                                    ])
                            }
                    )
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            for targetNumber in 0..<numberOfTargets {
                for fileNumber in 0..<numberOfFilesPerTarget {
                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/Target\(targetNumber)File\(fileNumber).swift")) { file in
                        file <<<
                                """
                                public struct Target\(targetNumber)File\(fileNumber) { }
                                """
                    }
                }
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func manySwiftFlags() async throws {
        let numberOfSwiftFlags = 1_000

        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [ TestFile("file.swift") ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",

                                    "OTHER_SWIFT_FLAGS": "$(inherited) " + (0..<numberOfSwiftFlags).map({ "-FLAG\($0)" }).joined(separator: " "),
                                ])
                        ],
                        targets:
                            [
                                TestStandardTarget(
                                    "TargetA",
                                    type: .framework,
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            TestBuildFile("file.swift")
                                        ])
                                    ])
                            ]
                    )
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file.swift")) { file in
                file <<< "class A {}"
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func diagnostics() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in

            let arch = "arm64e"
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                                TestFile("file3.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": arch,

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "OTHER_SWIFT_FLAGS": "$(inherited) -driver-batch-count 1",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                        "file2.swift",
                                        "file3.swift",
                                    ]),
                                ])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public class A1: DoesNotExist { }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    public class A2: DoesAlsoNotExist { }
                    """
            }

            // file3.swift has no source error, so the diagnostics path should be an empty file
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) { file in
                file <<<
                    """
                    public class A3 { }
                    """
            }

            // Initial build
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkError(.and(.prefix("\(SRCROOT.join("Sources/file1.swift").str):1:18:"), .contains("DoesNotExist")))
                results.checkError(.and(.prefix("\(SRCROOT.join("Sources/file2.swift").str):1:18:"), .contains("DoesAlsoNotExist")))
                results.checkError(.prefix("Command SwiftCompile failed."))

                // Swift Driver changed default behavior from merging modules after compilation to eagerly emitting the module which might create the same error too (rdar://84254570)
                results.checkError(.and(.prefix("\(SRCROOT.join("Sources/file1.swift").str):1:18:"), .contains("DoesNotExist")), failIfNotFound: false)
                results.checkError(.and(.prefix("\(SRCROOT.join("Sources/file2.swift").str):1:18:"), .contains("DoesAlsoNotExist")), failIfNotFound: false)
                results.checkError(.prefix("Command SwiftEmitModule failed."), failIfNotFound: false)

                if !SWBFeatureFlag.performOwnershipAnalysis.value {
                    results.checkErrors([
                        .contains("No such file or directory"),
                        .contains("No such file or directory"),
                        .contains("No such file or directory"),
                        .contains("No such file or directory"),
                    ])
                }

                results.checkTask(.matchTargetName("TargetA"), .matchRuleType("SwiftCompile")) { compileTask in
                    let serializedDiagnosticPaths = compileTask.type.serializedDiagnosticsPaths(compileTask, tester.fs)
                    #expect(serializedDiagnosticPaths == [])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func diagnostics_WMO() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in

            let arch = "arm64e"
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),
                                TestFile("file3.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": arch,
                                    "SWIFT_WHOLE_MODULE_OPTIMIZATION": "YES",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                        "file2.swift",
                                        "file3.swift",
                                    ]),
                                ])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public class A1: DoesNotExist { }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    public class A2: DoesAlsoNotExist { }
                    """
            }

            // file3.swift has no source error, so the diagnostics path should be an empty file
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) { file in
                file <<<
                    """
                    public class A3 { }
                    """
            }

            // Initial build
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkError(.and(.prefix("\(SRCROOT.join("Sources/file1.swift").str):1:18:"), .contains("DoesNotExist")))
                results.checkError(.and(.prefix("\(SRCROOT.join("Sources/file2.swift").str):1:18:"), .contains("DoesAlsoNotExist")))
                results.checkError(.prefix("Command SwiftCompile failed."))

                if !SWBFeatureFlag.performOwnershipAnalysis.value {
                    results.checkErrors([
                        .contains("No such file or directory"),
                        .contains("No such file or directory"),
                        .contains("No such file or directory"),
                        .contains("No such file or directory"),
                    ])
                }

                results.checkTaskExists(.matchTargetName("TargetA"), .matchRuleType("SwiftCompile"))
            }
        }
    }

    @Test(.requireSDKs(.macOS), .flaky("Occasionally fails in CI due to SwiftExplicitDependencyCompileModuleFromInterface missing from the dependency graph"), .bug("rdar://137888063"))
    func driverInitDiagnostics() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestGroup("A",
                                          path: "A",
                                          children: [
                                            TestFile("file.swift", guid: "Afile.swift")
                                          ]),
                                TestGroup("B",
                                          path: "B",
                                          children: [
                                            TestFile("file.swift", guid: "Bfile.swift")
                                          ])
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "x86_64",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "SUPPORTS_TEXT_BASED_API": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "Afile.swift",
                                        "Bfile.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/A/file.swift")) { $0 <<< "" }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/B/file.swift")) { $0 <<< "" }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkError(.equal("[Swift Compiler Error] filename \"file.swift\" used twice: '\(SRCROOT.join("Sources/A/file.swift").str)' and '\(SRCROOT.join("Sources/B/file.swift").str)' (for task: [\"SwiftDriver\", \"TargetA\", \"normal\", \"x86_64\", \"com.apple.xcode.tools.swift.compiler\"])"))

                results.checkNoErrors()
            }

        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftDriverJobExecutionEnvironment() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in

            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e x86_64",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "SUPPORTS_TEXT_BASED_API": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }


            // Check that subtasks progress events are reported as expected.
            tester.userInfo = UserInfo(user: "user", group: "group", uid: 1337, gid: 42, home: tmpDirPath.join("home"), processEnvironment: ["LD_APPLICATION_EXTENSION_SAFE": "1"], buildSystemEnvironment: [:])

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftEagerCompilation() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileA1.swift"),
                                TestFile("fileA2.swift"),

                                TestFile("fileB1.swift"),
                                TestFile("fileB2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileA1.swift",
                                        "fileA2.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileB1.swift",
                                        "fileB2.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA2.swift")) { file in
                file <<<
                    """
                    struct B {
                        let a = A()
                    }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB1.swift")) { file in
                file <<<
                    """
                    struct C {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB2.swift")) { file in
                file <<<
                    """
                    import TargetA\n\nstruct D {\n\tlet a = A()\n}
                    """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in

                results.checkNoErrors()

                for targetNameSuffix in ["A", "B"] {
                    let targetName = "Target\(targetNameSuffix)"
                    results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName(targetName)) { driverTask in
                        driverTask.checkCommandLineMatches(["builtin-SwiftDriver", "--", .anySequence])
                        #expect(driverTask.execDescription == "Planning Swift module \(targetName) (arm64e)")
                        results.checkNoUncheckedTasksRequested(driverTask)
                    }

                    results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTargetName(targetName)) { compilationBlockingTask in
                        compilationBlockingTask.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements"])
                        #expect(compilationBlockingTask.execDescription == "Unblock downstream dependents of \(targetName) (arm64e)")

                        results.checkTaskRequested(compilationBlockingTask, .matchTargetName(targetName), .matchRule(["SwiftEmitModule", "normal", "arm64e", "Emitting module for \(targetName)"]))
                        results.checkTaskRequested(compilationBlockingTask, .matchRuleType("SwiftDriver"), .matchTargetName(targetName))
                        results.checkNoUncheckedTasksRequested(compilationBlockingTask)
                    }

                    results.checkTask(.matchRuleType("SwiftDriver Compilation"), .matchTargetName(targetName)) { compilationTask in
                        compilationTask.checkCommandLineMatches(["builtin-Swift-Compilation"])
                        #expect(compilationTask.execDescription == "Compile \(targetName) (arm64e)")

                        results.checkTaskRequested(compilationTask, .matchTargetName(targetName), .matchRuleType("SwiftCompile"), .matchRuleItem(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str))
                        results.checkTaskRequested(compilationTask, .matchTargetName(targetName), .matchRuleType("SwiftCompile"), .matchRuleItem(SRCROOT.join("Sources/file\(targetNameSuffix)2.swift").str))
                        results.checkTaskRequested(compilationTask , .matchRuleType("SwiftDriver"), .matchTargetName(targetName))
                        results.checkTaskRequested(compilationTask, .matchTargetName(targetName), .matchRule(["SwiftEmitModule", "normal", "arm64e", "Emitting module for \(targetName)"]))
                        results.checkNoUncheckedTasksRequested(compilationTask)
                    }

                    results.checkTask(.matchTargetName(targetName), .matchRule(["SwiftCompile", "normal", "arm64e", "Compiling file\(targetNameSuffix)1.swift", SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str])) { compileFile1Task in
                        compileFile1Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str), .anySequence, "-o", .suffix("file\(targetNameSuffix)1.o")])
                    }

                    results.checkTask(.matchTargetName(targetName), .matchRule(["SwiftCompile", "normal", "arm64e", "Compiling file\(targetNameSuffix)2.swift", SRCROOT.join("Sources/file\(targetNameSuffix)2.swift").str])) { compileFile2Task in
                        compileFile2Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file\(targetNameSuffix)2.swift").str), .anySequence, "-o", .suffix("file\(targetNameSuffix)2.o")])
                    }

                    results.checkTask(.matchTargetName(targetName), .matchRule(["SwiftEmitModule", "normal", "arm64e", "Emitting module for \(targetName)"])) { emitModuleTask in
                        emitModuleTask.checkCommandLineMatches(["builtin-swiftTaskExecution", "--", .suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("\(targetName).swiftmodule")])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftEagerLinking() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileA1.swift"),
                                TestFile("fileA2.swift"),

                                TestFile("fileB1.swift"),
                                TestFile("fileB2.swift"),

                                TestFile("fileC1.swift"),
                                TestFile("fileC2.swift"),

                                TestFile("libDylib.dylib")
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "EAGER_LINKING": "YES",
                                    "EAGER_LINKING_REQUIRE": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileA1.swift",
                                        "fileA2.swift",
                                    ]),
                                    TestFrameworksBuildPhase([TestBuildFile(.target("Fwk")), TestBuildFile("libDylib.dylib")])
                                ], dependencies: ["Fwk", "DynamicLibrary"]),
                            TestStandardTarget(
                                "Fwk",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileB1.swift",
                                        "fileB2.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "DynamicLibrary",
                                type: .dynamicLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "libDylib"]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileC1.swift",
                                        "fileC2.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                file <<<
                    """
                    import Fwk
                    import libDylib
                    @main public struct Tool {
                        static func main() {
                            _ = InternalStruct()
                            _ = FwkStruct()
                            _ = DylibStruct()
                        }
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA2.swift")) { file in
                file <<<
                    """
                    struct InternalStruct {}
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB1.swift")) { file in
                file <<<
                    """
                    public struct FwkStruct {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB2.swift")) { file in
                file <<<
                    """
                    extension FwkStruct {}
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileC1.swift")) { file in
                file <<<
                    """
                    public struct DylibStruct {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileC2.swift")) { file in
                file <<<
                    """
                    extension DylibStruct {}
                    """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                // The build should succeed
                results.checkNoDiagnostics()

                results.checkTaskExists(.matchRule(["CreateBuildDirectory", SRCROOT.join("build/EagerLinkingTBDs/Debug").str]))

                // Linking the tool should follow emitting the framework's module, but not linking the framework.
                try results.checkTask(.matchTargetName("Tool"), .matchRuleType("Ld")) { linkToolTask in
                    try results.checkTaskFollows(linkToolTask, .matchTargetName("Fwk"), .matchRule(["SwiftEmitModule", "normal", "arm64e", "Emitting module for Fwk"]))
                    try results.checkTaskFollows(linkToolTask, .matchTargetName("Fwk"), .matchRuleType("GenerateTAPI"))
                    try results.checkTaskDoesNotFollow(linkToolTask, .matchTargetName("Fwk"), .matchRuleType("Ld"))
                    try results.checkTaskFollows(linkToolTask, .matchTargetName("DynamicLibrary"), .matchRule(["SwiftEmitModule", "normal", "arm64e", "Emitting module for libDylib"]))
                    try results.checkTaskFollows(linkToolTask, .matchTargetName("DynamicLibrary"), .matchRuleType("GenerateTAPI"))
                    try results.checkTaskDoesNotFollow(linkToolTask, .matchTargetName("DynamicLibrary"), .matchRuleType("Ld"))
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftEagerLinkingFrameworkWithShallowBundle() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileA1.swift"),
                                TestFile("fileA2.swift"),

                                TestFile("fileB1.swift"),
                                TestFile("fileB2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",
                                    "SDKROOT": "iphoneos",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "EAGER_LINKING": "YES",
                                    "EAGER_LINKING_REQUIRE": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileA1.swift",
                                        "fileA2.swift",
                                    ]),
                                    TestFrameworksBuildPhase([TestBuildFile(.target("Fwk"))])
                                ], dependencies: ["Fwk"]),
                            TestStandardTarget(
                                "Fwk",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileB1.swift",
                                        "fileB2.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                file <<<
                    """
                    import Fwk
                    @main public struct Tool {
                        static func main() {
                            _ = InternalStruct()
                            _ = FwkStruct()
                        }
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA2.swift")) { file in
                file <<<
                    """
                    struct InternalStruct {}
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB1.swift")) { file in
                file <<<
                    """
                    public struct FwkStruct {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB2.swift")) { file in
                file <<<
                    """
                    extension FwkStruct {}
                    """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .anyiOSDevice, buildRequest: buildRequest, persistent: true) { results in
                // The build should succeed
                results.checkNoDiagnostics()

                results.checkTaskExists(.matchRule(["CreateBuildDirectory", SRCROOT.join("build/EagerLinkingTBDs/Debug-iphoneos").str]))

                // Linking the tool should follow emitting the framework's module, but not linking the framework.
                try results.checkTask(.matchTargetName("Tool"), .matchRuleType("Ld")) { linkToolTask in
                    try results.checkTaskFollows(linkToolTask, .matchTargetName("Fwk"), .matchRule(["SwiftEmitModule", "normal", "arm64e", "Emitting module for Fwk"]))
                    try results.checkTaskFollows(linkToolTask, .matchTargetName("Fwk"), .matchRuleType("GenerateTAPI"))
                    try results.checkTaskDoesNotFollow(linkToolTask, .matchTargetName("Fwk"), .matchRuleType("Ld"))
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS), .requireLLBuild(apiVersion: 12))
    func swiftEagerCompilation_WMO() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileA1.swift"),
                                TestFile("fileA2.swift"),

                                TestFile("fileB1.swift"),
                                TestFile("fileB2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",
                                    "SWIFT_WHOLE_MODULE_OPTIMIZATION": "YES",
                                    "SWIFT_ENABLE_LIBRARY_EVOLUTION": "YES",
                                    "SDKROOT": "iphoneos",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileA1.swift",
                                        "fileA2.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileB1.swift",
                                        "fileB2.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA2.swift")) { file in
                file <<<
                    """
                    struct B {
                        let a = A()
                    }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB1.swift")) { file in
                file <<<
                    """
                    struct C {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB2.swift")) { file in
                file <<<
                    """
                    import TargetA\n\nstruct D {\n\tlet a = A()\n}
                    """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .anyiOSDevice, buildRequest: buildRequest, persistent: true) { results in

                results.checkNoErrors()

                let compilationRequirementA = try #require(results.getTask(.matchTargetName("TargetA"), .matchRuleType("SwiftDriver Compilation Requirements")))
                let compilationRequirementB = try #require(results.getTask(.matchTargetName("TargetB"), .matchRuleType("SwiftDriver Compilation Requirements")))
                let compilationA = try #require(results.getTask(.matchTargetName("TargetA"), .matchRuleType("SwiftDriver Compilation")))
                let compilationB = try #require(results.getTask(.matchTargetName("TargetB"), .matchRuleType("SwiftDriver Compilation")))

                try results.checkTaskFollows(compilationRequirementB, compilationRequirementA)
                try results.checkTaskDoesNotFollow(compilationB, compilationA)

                // The flags should enable EMS and disable CMO.
                compilationA.checkCommandLineMatches(["-emit-module-separately-wmo"]);
                compilationA.checkCommandLineNoMatch(["-no-emit-module-separately-wmo"]);
                compilationA.checkCommandLineMatches(["-disable-cmo"]);

                for targetNameSuffix in ["A", "B"] {
                    let targetName = "Target\(targetNameSuffix)"
                    results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName(targetName)) { driverTask in
                        driverTask.checkCommandLineMatches(["builtin-SwiftDriver", "--", .anySequence])
                        #expect(driverTask.execDescription == "Planning Swift module \(targetName) (arm64e)")
                        results.checkNoUncheckedTasksRequested(driverTask)
                    }

                    results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTargetName(targetName)) { compilationBlockingTask in
                        compilationBlockingTask.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements"])
                        #expect(compilationBlockingTask.execDescription == "Unblock downstream dependents of \(targetName) (arm64e)")

                        results.checkTaskRequested(compilationBlockingTask, .matchTargetName(targetName), .matchRule(["SwiftEmitModule", "normal", "arm64e", "Emitting module for \(targetName)"]))
                    }

                    results.checkTask(.matchRuleType("SwiftDriver Compilation"), .matchTargetName(targetName)) { compilationTask in
                        compilationTask.checkCommandLineMatches(["builtin-Swift-Compilation"])
                        #expect(compilationTask.execDescription == "Compile \(targetName) (arm64e)")

                        results.checkTaskRequested(compilationTask, .matchTargetName(targetName), .matchRuleType("SwiftCompile"), .matchRuleItem(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str), .matchRuleItem(SRCROOT.join("Sources/file\(targetNameSuffix)2.swift").str))
                    }

                    results.checkTask(.matchTargetName(targetName), .matchRulePattern(["SwiftCompile", "normal", "arm64e", "Compiling file\(targetNameSuffix)1.swift, file\(targetNameSuffix)2.swift", .equal(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str), .equal(SRCROOT.join("Sources/file\(targetNameSuffix)2.swift").str)])) { compileFileTask in
                        compileFileTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, .equal(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str), .anySequence, "-o", .suffix("file\(targetNameSuffix)1.o"), "-o", .suffix("file\(targetNameSuffix)2.o")])
                    }
                }
            }
        }
    }

    // Test that SWIFT_EAGER_MODULE_EMISSION_IN_WMO is ignored when SWIFT_ENABLE_LIBRARY_EVOLUTION is set to NO.
    @Test(.requireSDKs(.iOS), .requireLLBuild(apiVersion: 12))
    func swiftEagerCompilation_WMObutNoLibraryEvolution() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileA1.swift"),
                                TestFile("fileA2.swift"),

                                TestFile("fileB1.swift"),
                                TestFile("fileB2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",
                                    "SWIFT_WHOLE_MODULE_OPTIMIZATION": "YES",
                                    "SWIFT_ENABLE_LIBRARY_EVOLUTION": "NO",
                                    "SDKROOT": "iphoneos",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileA1.swift",
                                        "fileA2.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileB1.swift",
                                        "fileB2.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA2.swift")) { file in
                file <<<
                    """
                    struct B {
                        let a = A()
                    }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB1.swift")) { file in
                file <<<
                    """
                    struct C {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB2.swift")) { file in
                file <<<
                    """
                    import TargetA\n\nstruct D {\n\tlet a = A()\n}
                    """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .anyiOSDevice, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()

                for targetNameSuffix in ["A", "B"] {
                    let targetName = "Target\(targetNameSuffix)"
                    let compilation = try #require(results.getTask(.matchTargetName(targetName), .matchRuleType("SwiftDriver Compilation")))

                    // Check that EMS is disabled, and CMO not disabled.
                    compilation.checkCommandLineMatches(["-no-emit-module-separately-wmo"]);
                    compilation.checkCommandLineNoMatch(["-emit-module-separately-wmo"]);
                    compilation.checkCommandLineNoMatch(["-disable-cmo"]);
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .flaky("Occasionally fails in CI due to SwiftExplicitDependencyCompileModuleFromInterface missing from the dependency graph"), .bug("rdar://138085791"))
    func swiftEagerCompilationWithExplicitModules() async throws {
        for arch in ["x86_64", "arm64"] {
            try await withTemporaryDirectory { tmpDirPath async throws -> Void in
                let testWorkspace = try await TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources",
                                path: "Sources",
                                children: [
                                    TestFile("fileA1.swift"),
                                    TestFile("fileA2.swift"),

                                    TestFile("fileB1.swift"),
                                    TestFile("fileB2.swift"),
                                ]),
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "SWIFT_VERSION": swiftVersion,
                                        "BUILD_VARIANTS": "normal",
                                        "ARCHS": arch,
                                        "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                    ])
                            ],
                            targets: [
                                TestStandardTarget(
                                    "TargetA",
                                    type: .framework,
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "fileA1.swift",
                                            "fileA2.swift",
                                        ]),
                                    ]),
                                TestStandardTarget(
                                    "TargetB",
                                    type: .framework,
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "fileB1.swift",
                                            "fileB2.swift",
                                        ]),
                                        // Explicit module builds do not currently behave the same way
                                        // as implicit, which auto-link all dependencies by-default.
                                        // Explicitly linking dependencies is required. This may cause
                                        // a lot of projects to break though so we may need to make explicit modules
                                        // behave the same way and re-introduce auto-linking.
                                        TestFrameworksBuildPhase([TestBuildFile(.target("TargetA"))])
                                    ], dependencies: ["TargetA"]),
                            ])
                    ])

                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                tester.userInfo = tester.userInfo.withAdditionalEnvironment(environment: ["SWIFT_FORCE_MODULE_LOADING": "only-interface"])
                let parameters = BuildParameters(configuration: "Debug", overrides: [
                    // Redirect the prebuilt cache so we always build modules from source
                    "SWIFT_OVERLOAD_PREBUILT_MODULE_CACHE_PATH": tmpDirPath.str
                ])
                let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                // Create the source files.
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                    file <<<
                        """
                        public struct A {
                            public init() { }
                        }
                        """
                }
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA2.swift")) { file in
                    file <<<
                        """
                        struct B {
                            let a = A()
                        }
                        """
                }
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB1.swift")) { file in
                    file <<<
                        """
                        struct C { }
                        """
                }
                try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileB2.swift")) { file in
                    file <<<
                        """
                        import TargetA

                        struct D {
                            let a = TargetA.A()
                        }
                        """
                }

                // Check that subtasks progress events are reported as expected.
                try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                    results.checkNoErrors()
                    // Remove in rdar://83104047
                    results.checkWarnings([.contains("input unused"), .contains("input unused")], failIfNotFound: false)

                    for targetNameSuffix in ["A", "B"] {
                        let targetName = "Target\(targetNameSuffix)"
                        results.checkTask(.matchRuleType("SwiftDriver"), .matchTargetName(targetName)) { driverTask in
                            driverTask.checkCommandLineMatches(["builtin-SwiftDriver", "--", .anySequence])
                            #expect(driverTask.execDescription == "Planning Swift module \(targetName) (\(arch))")
                            results.checkNoUncheckedTasksRequested(driverTask)
                        }

                        results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTargetName(targetName)) { compilationBlockingTask in
                            compilationBlockingTask.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements"])
                            #expect(compilationBlockingTask.execDescription == "Unblock downstream dependents of \(targetName) (\(arch))")

                            results.checkTaskRequested(compilationBlockingTask, .matchTargetName(targetName), .matchRule(["SwiftEmitModule", "normal", arch, "Emitting module for \(targetName)"]))
                            results.checkTaskRequested(compilationBlockingTask, .matchRule(["SwiftDriver", targetName, "normal", arch, "com.apple.xcode.tools.swift.compiler"]))
                            results.checkNoUncheckedTasksRequested(compilationBlockingTask)
                        }

                        results.checkTask(.matchRuleType("SwiftDriver Compilation"), .matchTargetName(targetName)) { compilationTask in
                            compilationTask.checkCommandLineMatches(["builtin-Swift-Compilation"])
                            #expect(compilationTask.execDescription == "Compile \(targetName) (\(arch))")

                            results.checkTaskRequested(compilationTask, .matchTargetName(targetName), .matchRuleType("SwiftCompile"), .matchRuleItem(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str))
                            results.checkTaskRequested(compilationTask, .matchTargetName(targetName), .matchRuleType("SwiftCompile"), .matchRuleItem(SRCROOT.join("Sources/file\(targetNameSuffix)2.swift").str))
                            results.checkTaskRequested(compilationTask, .matchTargetName(targetName), .matchRule(["SwiftEmitModule", "normal", arch, "Emitting module for \(targetName)"]))
                            results.checkTaskRequested(compilationTask, .matchRule(["SwiftDriver", targetName, "normal", arch, "com.apple.xcode.tools.swift.compiler"]))
                            results.checkNoUncheckedTasksRequested(compilationTask)
                        }

                        results.checkTask(.matchTargetName(targetName), .matchRule(["SwiftCompile", "normal", arch, "Compiling file\(targetNameSuffix)1.swift", SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str])) { compileFile1Task in
                            compileFile1Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file\(targetNameSuffix)1.swift").str), .anySequence, "-o", .suffix("file\(targetNameSuffix)1.o")])

                            results.checkTaskRequested(compileFile1Task, .matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("Swift-")]))
                            results.checkTaskRequested(compileFile1Task, .matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("_Concurrency-")]))
                            results.checkTaskRequested(compileFile1Task, .matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("_StringProcessing-")]))
                            results.checkTaskRequested(compileFile1Task, .matchRulePattern(["SwiftExplicitDependencyGeneratePcm", "normal", .equal(arch), .contains("_SwiftConcurrencyShims-")]))
                            results.checkTaskRequested(compileFile1Task, .matchRulePattern(["SwiftExplicitDependencyGeneratePcm", "normal", .equal(arch), .contains("SwiftShims-")]))
                            results.checkNoUncheckedTasksRequested(compileFile1Task)
                        }

                        results.checkTask(.matchTargetName(targetName), .matchRule(["SwiftCompile", "normal", arch, "Compiling file\(targetNameSuffix)2.swift", SRCROOT.join("Sources/file\(targetNameSuffix)2.swift").str])) { compileFile2Task in
                            compileFile2Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .anySequence, .equal(SRCROOT.join("Sources/file\(targetNameSuffix)2.swift").str), .anySequence, "-o", .suffix("file\(targetNameSuffix)2.o")])

                            results.checkTaskRequested(compileFile2Task, .matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("Swift-")]))
                            results.checkTaskRequested(compileFile2Task, .matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("_Concurrency-")]))
                            results.checkTaskRequested(compileFile2Task, .matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("_StringProcessing-")]))
                            results.checkTaskRequested(compileFile2Task, .matchRulePattern(["SwiftExplicitDependencyGeneratePcm", "normal", .equal(arch), .contains("_SwiftConcurrencyShims-")]))
                            results.checkTaskRequested(compileFile2Task, .matchRulePattern(["SwiftExplicitDependencyGeneratePcm", "normal", .equal(arch), .contains("SwiftShims-")]))
                            results.checkNoUncheckedTasksRequested(compileFile2Task)
                        }

                        results.checkTask(.matchTargetName(targetName), .matchRule(["SwiftEmitModule", "normal", arch, "Emitting module for \(targetName)"])) { emitModuleTask in
                            emitModuleTask.checkCommandLineMatches(["builtin-swiftTaskExecution", "--", .suffix("swift-frontend"), .anySequence, "-emit-module", .anySequence, "-o", .suffix("\(targetName).swiftmodule")])

                            results.checkTaskRequested(emitModuleTask, .matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("Swift-")]))
                            results.checkTaskRequested(emitModuleTask, .matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("_Concurrency-")]))
                            results.checkTaskRequested(emitModuleTask, .matchRulePattern(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", .equal(arch), .contains("_StringProcessing-")]))
                            results.checkTaskRequested(emitModuleTask, .matchRulePattern(["SwiftExplicitDependencyGeneratePcm", "normal", .equal(arch), .contains("_SwiftConcurrencyShims-")]))
                            results.checkTaskRequested(emitModuleTask, .matchRulePattern(["SwiftExplicitDependencyGeneratePcm", "normal", .equal(arch), .contains("SwiftShims-")]))
                            results.checkNoUncheckedTasksRequested(emitModuleTask)
                        }
                    }

                    // The below checks also ensure uniqueness of these tasks in this build
                    results.checkTasks(.matchRule(["SwiftExplicitDependencyGeneratePcm", "normal", arch, "Compiling Clang module SwiftShims"]), .matchCommandLineArgument("SwiftShims")) { pcmBuildTasks in
                        for pcmBuildTask in pcmBuildTasks {
                            pcmBuildTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-emit-pcm", .anySequence, "-module-name", "SwiftShims"])
                        }
                    }

                    results.checkTasks(.matchRule(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", arch, "Compiling Swift module _Concurrency"]), .matchCommandLineArgument("_Concurrency")) { emitModuleTasks in
                        for emitModuleTask in emitModuleTasks {
                            emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-compile-module-from-interface", .anySequence, "-module-name", "_Concurrency"])
                        }
                    }

                    results.checkTasks(.matchRule(["SwiftExplicitDependencyCompileModuleFromInterface", "normal", arch, "Compiling Swift module Swift"]), .matchCommandLineArgument("Swift")) { emitModuleTasks in
                        for emitModuleTask in emitModuleTasks {
                            emitModuleTask.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-compile-module-from-interface", .anySequence, "-module-name", "Swift"])
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func indexingAndPreviewInfo() async throws {
        for arch in ["x86_64", "arm64"] {
            try await withTemporaryDirectory { tmpDirPath async throws -> Void in
                func createInfos(useIntegratedDriver: Bool) async throws -> (index: SwiftSourceFileIndexingInfo, preview: TaskGeneratePreviewInfoOutput) {
                    var result: (index: SwiftSourceFileIndexingInfo?, preview: TaskGeneratePreviewInfoOutput?)?

                    let targetA = TestStandardTarget(
                        "TargetA",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "file1.swift",
                            ]),
                        ])

                    let testWorkspace = try await TestWorkspace(
                        "Test",
                        sourceRoot: tmpDirPath.join("Test"),
                        projects: [
                            TestProject(
                                "aProject",
                                groupTree: TestGroup(
                                    "Sources",
                                    path: "Sources",
                                    children: [
                                        TestFile("file1.swift"),
                                    ]),
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "SWIFT_VERSION": swiftVersion,
                                            "BUILD_VARIANTS": "normal",
                                            "ARCHS": arch,
                                            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                            "ENABLE_PREVIEWS": "YES",
                                            "SWIFT_USE_INTEGRATED_DRIVER": useIntegratedDriver ? "YES" : "NO",
                                            "SWIFT_ENABLE_EXPLICIT_MODULES": useIntegratedDriver ? "YES" : "NO",
                                            "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": useIntegratedDriver ? "YES" : "NO",
                                            // Eager linking is not supported when using the driver binary.
                                            "EAGER_LINKING": "NO",
                                            "SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION": "NO",
                                        ])
                                ],
                                targets: [ targetA ])
                        ])

                    let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                    let parameters = BuildParameters(configuration: "Debug")
                    let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
                    let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                    // Create the source files.
                    try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                        file <<<
                            """
                            public struct A {
                                public init() { }
                            }
                            """
                    }

                    let core = try await self.getCore()
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                        results.checkNoErrors()
                        // Remove in rdar://83104047
                        results.checkWarnings([.contains("input unused"), .contains("input unused")], failIfNotFound: false)

                        func indexAndPreviewInfo(for task: any ExecutableTask) throws -> (index: SwiftSourceFileIndexingInfo?, preview: TaskGeneratePreviewInfoOutput?) {
                            let swiftSpec = try core.specRegistry.getSpec() as SwiftCompilerSpec
                            let sourceFile = SRCROOT.join("Sources/file1.swift")

                            return (
                                swiftSpec.generateIndexingInfo(for: task, input: TaskGenerateIndexingInfoInput(requestedSourceFile: sourceFile, outputPathOnly: false, enableIndexBuildArena: true)).only?.indexingInfo as? SwiftSourceFileIndexingInfo,
                                swiftSpec.generatePreviewInfo(for: task, input: TaskGeneratePreviewInfoInput.thunkInfo(sourceFile: sourceFile, thunkVariantSuffix: ""), fs: tester.fs).only
                            )
                        }

                        try results.checkTask(.matchTargetName("TargetA"), .matchRuleType(useIntegratedDriver ? "SwiftDriver Compilation Requirements" : "CompileSwiftSources")) { task in
                            result = try indexAndPreviewInfo(for: task)
                        }

                        if useIntegratedDriver {
                            // Only the compilation requirements task should generate index and preview info
                            for ruleInfoType in ["SwiftDriver Compilation", "SwiftDriver"] {
                                try results.checkTask(.matchTargetName("TargetA"), .matchRuleType(ruleInfoType)) { task in
                                    let infos = try indexAndPreviewInfo(for: task)
                                    #expect(infos.index == nil)
                                    #expect(infos.preview == nil)
                                }
                            }
                        }

                    }
                    return (try #require(result?.index), try #require(result?.preview))
                }

                let integratedInfos = try await createInfos(useIntegratedDriver: true)
                let binaryInfos = try await createInfos(useIntegratedDriver: false)

                // Explicit modules will add a module cache path that we expect for index and preview but remove for comparing
                func checkAndRemoveModuleCachePath(_ commandLine: [String]) -> [String] {
                    guard let index = commandLine.firstIndex(of: "-module-cache-path") else {
                        Issue.record("Command line is missing -module-cache-path argument.")
                        return []
                    }
                    #expect(commandLine[index + 1].hasSuffix("SwiftExplicitPrecompiledModules"))
                    var commandLine = commandLine
                    commandLine.replaceSubrange(index...(index + 1), with: [])
                    return commandLine
                }

                XCTAssertEqualSequences(
                    checkAndRemoveModuleCachePath(integratedInfos.index.commandLine.map(\.asString)),
                    binaryInfos.index.commandLine.map(\.asString)
                )

                XCTAssertEqualSequences(
                    integratedInfos.preview.commandLine.filter { $0 != "-disable-cmo" &&
                                                                                                $0 != "-no-color-diagnostics" &&
                                                                                                $0 != "-experimental-emit-module-separately" },
                    binaryInfos.preview.commandLine
                )
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func prepareForIndexing() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: false))
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file.swift")) { file in
                file <<< "func foo() {}"
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkTaskExists(.matchRuleType("SwiftDriver"))
                results.checkTaskExists(.matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTaskExists(.matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchRuleType("SwiftCompile"))
                results.checkTaskExists(.matchRuleType("SwiftEmitModule"))

                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireLLBuild(apiVersion: 13))
    func progressStatistics() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("file2.swift"),

                                TestFile("file3.swift"),
                                TestFile("file4.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                        "file2.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file3.swift",
                                        "file4.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    struct B {
                        let a = A()
                    }
                    """
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file3.swift")) { file in
                file <<<
                    """
                    struct C {}
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file4.swift")) { file in
                file <<<
                    """
                    import TargetA

                    struct D {
                        let a = A()
                    }
                    """
            }

            // Check that subtasks progress events are reported as expected.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()

                // Check that progress statistics are consistent
                for case let .totalProgressChanged(_, started, max) in results.events {
                    #expect(started <= max)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func documentationBuild() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .dynamicLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(action: .docBuild, configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }

            try await tester.checkBuild(runDestination: .anyMac, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
                try results.checkTask(.matchTargetName("TargetA"), .matchRule(["SwiftEmitModule", "normal", "arm64", "Emitting module for TargetA"])) { task in
                    task.checkCommandLineContains([
                        "-emit-symbol-graph",
                        "-emit-symbol-graph-dir",
                    ])

                    let docCompileTask = try #require(results.getTask(.matchTargetName("TargetA"), .matchRule(["CompileDocumentation"])))
                    try results.checkTaskFollows(docCompileTask, task)

                    // Check that compiling follows the creation of the directory
                    let symbolGraphCreationTask = try #require(results.getTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItemPattern(.contains("symbol-graph"))))
                    try results.checkTaskFollows(task, symbolGraphCreationTask)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func discoveredDependencies() async throws {

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in

            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),

                                TestFile("file2.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",

                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetB",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file2.swift",
                                    ]),
                                ], dependencies: ["TargetA"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let targetA = tester.workspace.projects[0].targets[0]
            let targetB = tester.workspace.projects[0].targets[1]

            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public static func foo() -> Int { 5 }
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    import TargetA
                    open class B {
                        let a = A.foo()
                    }
                    """
            }

            // Initial build
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()

                let configuredTargetA = ConfiguredTarget(parameters: results.buildRequest.parameters, target: targetA)
                let configuredTargetB = ConfiguredTarget(parameters: results.buildRequest.parameters, target: targetB)
                results.check(event: .targetHadEvent(configuredTargetA, event: .started), precedes: .targetHadEvent(configuredTargetA, event: .completed))
                results.check(event: .targetHadEvent(configuredTargetB, event: .started), precedes: .targetHadEvent(configuredTargetB, event: .completed))
            }

            // null build
            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            // Change B -> Incremental build
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    import TargetA
                    final class B {
                        let a = A.foo()
                    }
                    """
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
                results.consumeTasksMatchingRuleTypes(["Gate", "SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation"], targetName: "TargetA")

                // No actual compilation, just planning
                results.checkNoTask(.matchTargetName("TargetA"))

                for ruleInfoType in ["SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation", "SwiftCompile", "SwiftEmitModule"] {
                    results.checkTasks(.matchTargetName("TargetB"), .matchRuleType(ruleInfoType)) { tasks in
                        #expect(!tasks.isEmpty, "Did not find tasks for ruleInfoType \(ruleInfoType).")
                    }
                }

                let configuredTargetB = ConfiguredTarget(parameters: results.buildRequest.parameters, target: targetB)
                results.check(event: .targetHadEvent(configuredTargetB, event: .started), precedes: .targetHadEvent(configuredTargetB, event: .completed))
            }

            // Another null build
            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            // Remove public API in A
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                // B is still using that API, so it should recompile and fail given the discovered dependencies
                results.checkError(.contains("file2.swift:3"))
                // We get the error for emit-module and compile jobs
                results.checkError(.contains("file2.swift:3"))
                results.checkedErrors = true

                // We expect TargetB to rebuild it's files when changing API in a dependency
                results.checkTask(.matchTargetName("TargetB"), .matchRule(["SwiftCompile", "normal", "arm64e", "Compiling file2.swift", SRCROOT.join("Sources/file2.swift").str])) { compileFile3Task in
                    compileFile3Task.checkCommandLineMatches([.suffix("swift-frontend"), .anySequence, "-primary-file", .equal(SRCROOT.join("Sources/file2.swift").str), .anySequence, "-o", .suffix("file2.o")])
                }

                for ruleInfoType in ["SwiftCompile", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation", "SwiftEmitModule", "SwiftDriver", "Ld"] {
                    results.checkTasks(.matchTargetName("TargetA"), .matchRuleItemPattern(.prefix(ruleInfoType))) { tasks in
                        #expect(!tasks.isEmpty, "Did not find tasks for ruleInfoType \(ruleInfoType).")
                    }
                }

                let configuredTargetA = ConfiguredTarget(parameters: results.buildRequest.parameters, target: targetA)
                let configuredTargetB = ConfiguredTarget(parameters: results.buildRequest.parameters, target: targetB)
                results.check(event: .targetHadEvent(configuredTargetA, event: .started), precedes: .targetHadEvent(configuredTargetA, event: .completed))
                results.check(event: .targetHadEvent(configuredTargetB, event: .started), precedes: .targetHadEvent(configuredTargetB, event: .completed))
            }

            // Fix call in B -> Incremental build
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file2.swift")) { file in
                file <<<
                    """
                    import TargetA
                    final class B {
                        let a = A()
                    }
                    """
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoErrors()
                results.consumeTasksMatchingRuleTypes(["Gate", "SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation"], targetName: "TargetA")

                // No actual compilation, just planning
                results.checkNoTask(.matchTargetName("TargetA"))

                for ruleInfoType in ["SwiftDriver", "SwiftDriver Compilation Requirements", "SwiftDriver Compilation", "SwiftCompile", "SwiftEmitModule"] {
                    results.checkTasks(.matchTargetName("TargetB"), .matchRuleType(ruleInfoType)) { tasks in
                        #expect(!tasks.isEmpty, "Did not find tasks for ruleInfoType \(ruleInfoType).")
                    }
                }

                let configuredTargetB = ConfiguredTarget(parameters: results.buildRequest.parameters, target: targetB)
                results.check(event: .targetHadEvent(configuredTargetB, event: .started), precedes: .targetHadEvent(configuredTargetB, event: .completed))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func jobDiscoveryActivityLog() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("Source.swift"),
                        TestFile("Source2.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": swiftVersion
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "Foo",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase(["Source.swift", "Source2.swift"]),
                        ])
                ])


            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            try await tester.fs.writeFileContents(tmpDirPath.join("Source.swift")) {
                $0 <<< "struct Foo {}"
            }
            try await tester.fs.writeFileContents(tmpDirPath.join("Source2.swift")) {
                $0 <<< "struct Bar {}"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.check(contains: .activityStarted(ruleInfo: "SwiftDriverJobDiscovery normal \(results.runDestinationTargetArchitecture) Emitting module for Foo"))
                results.check(contains: .activityEnded(ruleInfo: "SwiftDriverJobDiscovery normal \(results.runDestinationTargetArchitecture) Emitting module for Foo", status: .succeeded))
                results.check(contains: .activityStarted(ruleInfo: "SwiftDriverJobDiscovery normal \(results.runDestinationTargetArchitecture) Compiling Source.swift"))
                results.check(contains: .activityEnded(ruleInfo: "SwiftDriverJobDiscovery normal \(results.runDestinationTargetArchitecture) Compiling Source.swift", status: .succeeded))
                results.check(contains: .activityStarted(ruleInfo: "SwiftDriverJobDiscovery normal \(results.runDestinationTargetArchitecture) Compiling Source2.swift"))
                results.check(contains: .activityEnded(ruleInfo: "SwiftDriverJobDiscovery normal \(results.runDestinationTargetArchitecture) Compiling Source2.swift", status: .succeeded))
            }

        }
    }

    @Test(.requireSDKs(.macOS))
    func planningErrorsFailTask() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                                TestFile("TargetA.h"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",
                                    "SWIFT_OBJC_BRIDGING_HEADER": tmpDirPath.join("Test/aProject/Sources/bridge.h").str,
                                    "DEFINES_MODULE": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([
                                        TestBuildFile("TargetA.h", headerVisibility: .public)
                                    ]),
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/TargetA.h")) { file in
                file <<<
                    """
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/bridge.h")) { file in
                file <<<
                    """
                    @import Foundation;
                    """
            }

            // Ensure that if the driver finishes planning but emitted errors, we fail the plan task instead of trying to continue.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkError(.prefix("[Swift Compiler Error] using bridging headers with framework targets is unsupported"))
                // We don't care about other errors which may pop up here.
                results.checkedErrors = true
                results.checkTask(.matchTargetName("TargetA"), .matchRuleType("SwiftDriver")) { task in
                    results.checkTaskResult(task, expected: .exit(exitStatus: .exit(1), metrics: nil))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func jobDiscoveryDoesNotFailAfterNonFatalError() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64e",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "A", originalObjectID: "A", contents: "echo 'error: something bad happened'", alwaysOutOfDate: true),
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                    """
                    public struct A {
                        public init() {}
                    }
                    """
            }

            // Ensure that if the driver finishes planning but emitted errors, we fail the plan task instead of trying to continue.
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkError(.prefix("something bad happened"))
                results.checkNoErrors()
                // The earlier failure should not fail this activity.
                results.check(contains: .activityEnded(ruleInfo: "SwiftDriverJobDiscovery normal arm64e Emitting module for TargetA", status: .succeeded))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func userModuleHeaderChangeInvalidatesPlanning() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Framework1.h"),
                                TestFile("file_1.c"),
                                TestFile("file_2.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                "SWIFT_VERSION": swiftVersion,
                                "DEFINES_MODULE": "YES",
                                "VALID_ARCHS": "arm64",
                                "DSTROOT": tmpDir.join("dstroot").str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Framework1",
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("Framework1.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase(["file_1.c"]),
                                ]),
                            TestStandardTarget(
                                "Framework2",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_2.swift"]),
                                ],
                            dependencies: [
                                "Framework1"
                            ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework1.h")) { stream in
                stream <<<
            """
            void foo(void);
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_1.c")) { stream in
                stream <<<
            """
            #include <Framework1/Framework1.h>
            void foo(void) {}
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_2.swift")) { stream in
                stream <<<
            """
            import Framework1
            public func bar() {
                foo()
            }
            """
            }

            let parameters = BuildParameters(configuration: "Debug", overrides: [:])
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            try tester.fs.touch(testWorkspace.sourceRoot.join("aProject/Framework1.h"))

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("SwiftDriver"))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func systemModuleOutsideSysrootHeaderChangeInvalidatesPlanning() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Framework1.h"),
                                TestFile("file_1.c"),
                                TestFile("file_2.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                "SWIFT_VERSION": swiftVersion,
                                "DEFINES_MODULE": "YES",
                                "VALID_ARCHS": "arm64",
                                "DSTROOT": tmpDir.join("dstroot").str,
                                "MODULEMAP_FILE_CONTENTS": "framework module Framework1 [system] { header \"Framework1.h\" }"
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Framework1",
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("Framework1.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase(["file_1.c"]),
                                ]),
                            TestStandardTarget(
                                "Framework2",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_2.swift"]),
                                ],
                            dependencies: [
                                "Framework1"
                            ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework1.h")) { stream in
                stream <<<
            """
            void foo(void);
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_1.c")) { stream in
                stream <<<
            """
            #include <Framework1/Framework1.h>
            void foo(void) {}
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_2.swift")) { stream in
                stream <<<
            """
            import Framework1
            public func bar() {
                foo()
            }
            """
            }

            let parameters = BuildParameters(configuration: "Debug", overrides: [:])
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            try tester.fs.touch(testWorkspace.sourceRoot.join("aProject/Framework1.h"))

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("SwiftDriver"))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func diagnosingMissingTargetDependencies() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Framework1.h"),
                                TestFile("file_1.c"),
                                TestFile("file_2.swift"),
                                TestFile("file_3.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                "SWIFT_VERSION": swiftVersion,
                                "DEFINES_MODULE": "YES",
                                "VALID_ARCHS": "arm64",
                                "DSTROOT": tmpDir.join("dstroot").str,
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Framework1",
                                type: .framework,
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("Framework1.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase(["file_1.c"]),
                                ]),
                            TestStandardTarget(
                                "Framework2",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_2.swift"]),
                                ]),
                            TestStandardTarget(
                                "Framework3",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_3.swift"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework1.h")) { stream in
                stream <<<
            """
            void foo(void);
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_1.c")) { stream in
                stream <<<
            """
            #include <Framework1/Framework1.h>
            void foo(void) {}
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_2.swift")) { stream in
                stream <<<
            """
            public func bar() {}
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_3.swift")) { stream in
                stream <<<
            """
            import Framework1
            import Framework2

            public func baz() {
                foo()
                bar()
            }
            """
            }

            for warningLevel in [BooleanWarningLevel.yes, .yesError] {
                let parameters = BuildParameters(configuration: "Debug", overrides: ["DIAGNOSE_MISSING_TARGET_DEPENDENCIES": warningLevel.rawValue])
                let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)

                try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                    switch warningLevel {
                    case .yes:
                        results.checkWarning("'Framework3' is missing a dependency on 'Framework1' because dependency scan of Swift module 'Framework3' discovered a dependency on 'Framework1' (in target 'Framework3' from project 'aProject')")
                        results.checkWarning("'Framework3' is missing a dependency on 'Framework2' because dependency scan of Swift module 'Framework3' discovered a dependency on 'Framework2' (in target 'Framework3' from project 'aProject')")
                    case .yesError:
                        results.checkError("'Framework3' is missing a dependency on 'Framework1' because dependency scan of Swift module 'Framework3' discovered a dependency on 'Framework1' (in target 'Framework3' from project 'aProject')")
                        results.checkError("'Framework3' is missing a dependency on 'Framework2' because dependency scan of Swift module 'Framework3' discovered a dependency on 'Framework2' (in target 'Framework3' from project 'aProject')")
                    default:
                        break
                    }
                    results.checkNoDiagnostics()
                }

                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func diagnosingMissingTargetDependenciesWithDependencyDomains() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Framework1.h"),
                                TestFile("file_1.c"),
                                TestFile("file_2.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CLANG_ENABLE_MODULES": "YES",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                                "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                "SWIFT_VERSION": swiftVersion,
                                "DEFINES_MODULE": "YES",
                                "VALID_ARCHS": "arm64",
                                "DSTROOT": tmpDir.join("dstroot").str,
                                "DIAGNOSE_MISSING_TARGET_DEPENDENCIES": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Framework1",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "IMPLICIT_DEPENDENCY_DOMAIN": "One"
                                    ])],
                                buildPhases: [
                                    TestHeadersBuildPhase([TestBuildFile("Framework1.h", headerVisibility: .public)]),
                                    TestSourcesBuildPhase(["file_1.c"]),
                                ]),
                            TestStandardTarget(
                                "Framework2",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "IMPLICIT_DEPENDENCY_DOMAIN": "Two"
                                    ])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["file_2.swift"]),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Framework1.h")) { stream in
                stream <<<
            """
            void foo(void);
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_1.c")) { stream in
                stream <<<
            """
            #include <Framework1/Framework1.h>
            void foo(void) {}
            """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/file_2.swift")) { stream in
                stream <<<
            """
            import Framework1
            public func baz() {
                foo()
            }
            """
            }

            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                // Normally, we would report "'Framework2' is missing a dependency on 'Framework1' because dependency scan of Swift module 'Framework2' discovered a dependency on 'Framework1'"
                // However, because the targets are in different domains, we shouldn't report any diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func explicitPCMDeduplicationWithBuildVariant() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileC.c"),
                                TestFile("Target0.h"),
                                TestFile("file1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal other",
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                    "DEFINES_MODULE": "YES",
                                    "CLANG_ENABLE_MODULES": "YES"
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Target0",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileC.c",
                                    ]),
                                    TestHeadersBuildPhase([
                                        TestBuildFile("Target0.h", headerVisibility: .public)
                                    ])
                                ]),
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file1.swift",
                                    ]),
                                ], dependencies: [
                                    "Target0"
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileC.c")) { file in
                file <<<
                        """
                        int foo() { return 11; }
                        """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/Target0.h")) { file in
                file <<<
                        """
                        int foo();
                        """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file1.swift")) { file in
                file <<<
                        """
                        import Target0
                        public struct A {
                            public init() { foo() }
                        }
                        """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()

                // Identical build variants should be able to share PCMs
                results.checkTasks(.matchRulePattern(["SwiftExplicitDependencyGeneratePcm", .anySequence, .contains("Target0")])) { tasks in
                    #expect(tasks.count == 1)
                }
            }
        }
    }


    @Test(.requireSDKs(.macOS))
    func diagnosingLanguageFeatureEnablement() async throws {

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let blockListFilePath = tmpDirPath.join("swift-language-feature-enablement.json")
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("file.swift")
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": "5",
                                    "BUILD_VARIANTS": "normal",
                                    "ARCHS": "arm64",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "BLOCKLISTS_PATH": tmpDirPath.str,
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "file.swift"
                                    ]),
                                ])
                        ])
                ])

            var tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let cleanParameters = BuildParameters(action: .clean, configuration: "Debug")
            let cleanRequest = BuildRequest(parameters: cleanParameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: cleanParameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            // Create the source file.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/file.swift")) { file in
                file <<< "import Swift"
            }

            let parameterizedBuildRequest = { (_ parameters: BuildParameters) in
                return BuildRequest(parameters: parameters,
                                    buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }),
                                    continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            }

            // Test with a diagnostic level of "warn".
            do {
                try await tester.fs.writeFileContents(blockListFilePath) { file in
                    file <<<
                            """
                            {
                                "features": {
                                    "DeprecateApplicationMain": {
                                        "level": "warn",
                                        "buildSettings": ["SWIFT_UPCOMING_FEATURE_DEPRECATE_APPLICATION_MAIN"],
                                        "learnMoreURL": "https://www.swift.org/swift-evolution/",
                                        "moduleExceptions": [""]
                                    }
                                }
                            }
                            """
                }

                // Build without DeprecateApplicationMain enabled.
                do {
                    let params = BuildParameters(configuration: "Debug")
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: parameterizedBuildRequest(params)) { results in
                        results.checkWarnings([.contains("Enabling the Swift language feature 'DeprecateApplicationMain' will become a requirement in the future; set 'SWIFT_UPCOMING_FEATURE_DEPRECATE_APPLICATION_MAIN = YES'")], failIfNotFound: true)
                        results.checkNotes([.contains("Learn more about 'DeprecateApplicationMain' by visiting https://www.swift.org/swift-evolution/")])
                        results.checkNoErrors()
                    }
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: cleanRequest) { results in results.checkNoErrors() }
                }

                // Build with 'SWIFT_UPCOMING_FEATURE_DEPRECATE_APPLICATION_MAIN = YES'.
                do {
                    let params = BuildParameters(configuration: "Debug",
                                                 commandLineOverrides: ["SWIFT_UPCOMING_FEATURE_DEPRECATE_APPLICATION_MAIN": "YES"])
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: parameterizedBuildRequest(params)) { results in results.checkNoDiagnostics() }
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: cleanRequest) { results in results.checkNoErrors() }
                }

                // Build with '-enable-upcoming-feature DeprecateApplicationMain'.
                do {
                    let params = BuildParameters(configuration: "Debug",
                                                 commandLineOverrides: ["OTHER_SWIFT_FLAGS": "-enable-upcoming-feature DeprecateApplicationMain"])
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: parameterizedBuildRequest(params)) { results in results.checkNoDiagnostics() }
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: cleanRequest) { results in results.checkNoErrors() }
                }

                // Build with '-enable-experimental-feature DeprecateApplicationMain'.
                do {
                    let params = BuildParameters(configuration: "Debug",
                                                 commandLineOverrides: ["OTHER_SWIFT_FLAGS": "-enable-experimental-feature DeprecateApplicationMain"])
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: parameterizedBuildRequest(params)) { results in results.checkNoDiagnostics() }
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: cleanRequest) { results in results.checkNoErrors() }
                }
            }

            //Reinit the core to invalidate all caching
            tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            // Test with a diagnostic level of "error".
            do {
                try await tester.fs.writeFileContents(blockListFilePath) { file in
                    file <<<
                            """
                            {
                                "features": {
                                    "RegionBasedIsolation": {
                                        "level": "error",
                                        "learnMoreURL": "https://www.swift.org/swift-evolution/",
                                        "moduleExceptions": [""]
                                    }
                                }
                            }
                            """
                }

                // Build without RegionBasedIsolation enabled.
                do {
                    let params = BuildParameters(configuration: "Debug")
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: parameterizedBuildRequest(params)) { results in
                        results.checkErrors([.contains("Enabling the Swift language feature 'RegionBasedIsolation' is required; add '-enable-upcoming-feature RegionBasedIsolation' to 'OTHER_SWIFT_FLAGS'")], failIfNotFound: true)
                        results.checkNotes([.contains("Learn more about 'RegionBasedIsolation' by visiting https://www.swift.org/swift-evolution/")])
                        results.checkNoWarnings()
                    }
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: cleanRequest) { results in results.checkNoErrors() }
                }
            }

            // Test with module exceptions specified in the block list.
            //Reinit the core to invalidate all caching
            tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            do {
                try await tester.fs.writeFileContents(blockListFilePath) { file in
                    file <<<
                            """
                            {
                                "features": {
                                    "InternalImportsByDefault": {
                                        "level": "warn",
                                        "learnMoreURL": "https://www.swift.org/swift-evolution/",
                                        "moduleExceptions": ["TargetA"]
                                    }
                                }
                            }
                            """
                }

                // Build without InternalImportsByDefault enabled.
                do {
                    let params = BuildParameters(configuration: "Debug")
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: parameterizedBuildRequest(params)) { results in results.checkNoDiagnostics() }
                    try await tester.checkBuild(runDestination: .macOS, buildRequest: cleanRequest) { results in results.checkNoErrors() }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .flaky("Occasionally fails in CI due to the response file being empty"), .bug("rdar://138227317"))
    func explicitModulesLinkerSwiftmoduleRegistration() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileA1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileA1.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            tester.userInfo = tester.userInfo.withAdditionalEnvironment(environment: ["SWIFT_FORCE_MODULE_LOADING": "only-interface"])
            let parameters = BuildParameters(configuration: "Debug", overrides: [
                // Redirect the prebuilt cache so we always build modules from source
                "SWIFT_OVERLOAD_PREBUILT_MODULE_CACHE_PATH": tmpDirPath.str
            ])
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                file <<<
                        """
                        public struct A {
                            public init() { }
                        }
                        """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                var responseFile: Path? = nil
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements")) { driverTask in
                    responseFile = driverTask.outputPaths.filter { $0.str.hasSuffix("-linker-args.resp") }.only
                }
                try results.checkTask(.matchRuleType("Ld")) { linkTask in
                    linkTask.checkCommandLineContains("@\(try #require(responseFile).str)")
                }
                let responseFileContents = try tester.fs.read(try #require(responseFile))
                #expect(!responseFileContents.isEmpty)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func incrementalExplicitModulesLinkerSwiftmoduleRegistration() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("fileA1.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "BUILD_VARIANTS": "normal",
                                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetA",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fileA1.swift",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            tester.userInfo = tester.userInfo.withAdditionalEnvironment(environment: ["SWIFT_FORCE_MODULE_LOADING": "only-interface"])
            let parameters = BuildParameters(configuration: "Debug", overrides: [
                // Redirect the prebuilt cache so we always build modules from source
                "SWIFT_OVERLOAD_PREBUILT_MODULE_CACHE_PATH": tmpDirPath.str
            ])
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                file <<<
                        """
                        public struct A {
                            public init() { }
                        }
                        """
            }

            var cleanResponseFileContents: ByteString? = nil
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                var responseFile: Path? = nil
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements")) { driverTask in
                    responseFile = driverTask.outputPaths.filter { $0.str.hasSuffix("-linker-args.resp") }.only
                }
                try results.checkTask(.matchRuleType("Ld")) { linkTask in
                    linkTask.checkCommandLineContains("@\(try #require(responseFile).str)")
                }
                let responseFileContents = try tester.fs.read(try #require(responseFile))
                #expect(!responseFileContents.isEmpty)
                cleanResponseFileContents = responseFileContents
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/fileA1.swift")) { file in
                file <<<
                        """
                        public struct A {
                            public init() { }
                        }
                        
                        public func foo() { }
                        """
            }

            var incrementalResponseFileContents: ByteString? = nil
            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                var responseFile: Path? = nil
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements")) { driverTask in
                    responseFile = driverTask.outputPaths.filter { $0.str.hasSuffix("-linker-args.resp") }.only
                }
                try results.checkTask(.matchRuleType("Ld")) { linkTask in
                    linkTask.checkCommandLineContains("@\(try #require(responseFile).str)")
                }
                let responseFileContents = try tester.fs.read(try #require(responseFile))
                #expect(!responseFileContents.isEmpty)
                incrementalResponseFileContents = responseFileContents
            }

            let cleanContents = try #require(cleanResponseFileContents)
            let incrementalContents = try #require(incrementalResponseFileContents)
            #expect(cleanContents == incrementalContents)
        }
    }
}
