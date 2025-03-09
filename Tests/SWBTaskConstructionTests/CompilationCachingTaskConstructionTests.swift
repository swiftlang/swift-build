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
import SWBTestSupport
import SWBCore
@_spi(Testing) import SWBUtil

@Suite
fileprivate struct CompilationCachingTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, comment: "Caching requires explicit modules, which requires libclang and is only available on macOS"), .requireCompilationCaching)
    func settingRemoteCacheSupportedLanguages() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("Another.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CC": clangCompilerPath.str,
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "CLANG_ENABLE_MODULES": "YES",
                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                    "CLANG_ENABLE_COMPILE_CACHE": "YES",
                    "SWIFT_ENABLE_COMPILE_CACHE": "YES",
                    "COMPILATION_CACHE_ENABLE_PLUGIN": "YES",
                    "COMPILATION_CACHE_REMOTE_SERVICE_PATH": "/tmp/cc",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m", "Another.swift"])],
                    dependencies: [
                        "ToolRemoteObjC",
                        "ToolRemoteSwift",
                        "ToolRemoteBoth",
                    ]
                ),
                TestStandardTarget(
                    "ToolRemoteObjC",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "COMPILATION_CACHE_REMOTE_SUPPORTED_LANGUAGES": "objective-c",
                        ])
                    ],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m", "Another.swift"])]
                ),
                TestStandardTarget(
                    "ToolRemoteSwift",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "COMPILATION_CACHE_REMOTE_SUPPORTED_LANGUAGES": "swift",
                        ])
                    ],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m", "Another.swift"])]
                ),
                TestStandardTarget(
                    "ToolRemoteBoth",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "COMPILATION_CACHE_REMOTE_SUPPORTED_LANGUAGES": "swift objective-c",
                        ])
                    ],
                    buildPhases: [TestSourcesBuildPhase(["SourceFile.m", "Another.swift"])]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        try await tester.checkBuild(runDestination: .macOS) { results in
            try results.checkTarget("Tool") { target in
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    let casOpts = try #require((task.execTask.payload as? ClangTaskPayload)?.explicitModulesPayload?.casOptions)
                    #expect(casOpts.remoteServicePath == Path("/tmp/cc"))
                }
                try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    let casOpts = try #require((task.execTask.payload as? SwiftTaskPayload)?.driverPayload?.casOptions)
                    #expect(casOpts.remoteServicePath == Path("/tmp/cc"))
                }
            }

            try results.checkTarget("ToolRemoteObjC") { target in
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    let casOpts = try #require((task.execTask.payload as? ClangTaskPayload)?.explicitModulesPayload?.casOptions)
                    #expect(casOpts.remoteServicePath == Path("/tmp/cc"))
                }
                try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    let casOpts = try #require((task.execTask.payload as? SwiftTaskPayload)?.driverPayload?.casOptions)
                    #expect(casOpts.remoteServicePath == nil)
                }
            }

            try results.checkTarget("ToolRemoteSwift") { target in
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    let casOpts = try #require((task.execTask.payload as? ClangTaskPayload)?.explicitModulesPayload?.casOptions)
                    #expect(casOpts.remoteServicePath == nil)
                }
                try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    let casOpts = try #require((task.execTask.payload as? SwiftTaskPayload)?.driverPayload?.casOptions)
                    #expect(casOpts.remoteServicePath == Path("/tmp/cc"))
                }
            }

            try results.checkTarget("ToolRemoteBoth") { target in
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    let casOpts = try #require((task.execTask.payload as? ClangTaskPayload)?.explicitModulesPayload?.casOptions)
                    #expect(casOpts.remoteServicePath == Path("/tmp/cc"))
                }
                try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    let casOpts = try #require((task.execTask.payload as? SwiftTaskPayload)?.driverPayload?.casOptions)
                    #expect(casOpts.remoteServicePath == Path("/tmp/cc"))
                }
            }
        }
    }
}
