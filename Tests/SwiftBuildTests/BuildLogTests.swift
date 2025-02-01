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

import Foundation
import Testing

@_spi(Testing) import SwiftBuild
import SwiftBuildTestSupport

import SWBUtil
import SWBCore
import SWBTestSupport

@Suite(.requireHostOS(.macOS))
struct BuildLogTests {
    /// Check the basic behaviors of the build log.
    @Test(.requireSDKs(.macOS))
    func buildLog() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let srcroot = tmpDirPath.join("Test")
                let testTarget = TestStandardTarget(
                    "Tool", type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                // FIXME: There should be a way to automatically populate the version here, but since these tests are not CoreBasedTests, there isn't a good way to do so right now.
                                "SWIFT_VERSION": "4.2",
                                "SWIFT_OBJC_BRIDGING_HEADER": "Bridging Header.h",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File With Space.c"),
                            TestBuildFile("File 1.swift"),
                            TestBuildFile("File 2.swift")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [
                        TestFile("File With Space.c"),
                        TestFile("File 1.swift"),
                        TestFile("File 2.swift"),
                        TestFile("Bridging Header.h")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                let fs = localFS
                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test sources.
                try await fs.writeFileContents(SRCROOT.join("File With Space.c")) { contents in
                    contents <<< "int main() { return 0; }\n"
                }
                try await fs.writeFileContents(SRCROOT.join("File 1.swift")) { contents in
                    contents <<< "struct S { let x: Int32 }\n"
                }
                try await fs.writeFileContents(SRCROOT.join("File 2.swift")) { contents in
                    contents <<< "let s = S(x: cFunc())\n"
                }
                try await fs.writeFileContents(SRCROOT.join("Bridging Header.h")) { contents in
                    contents <<< "static inline int cFunc() { return 0; }\n"
                }

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                try await tester.checkResults(events: events) { results in
                    // Check the file with spaces is quoted.
                    try results.checkTasks(.matchRuleType("CompileC")) { tasks in
                        #expect(!tasks.isEmpty)
                        for task in tasks {
                            let commandLineDisplayString = try #require(task.commandLineDisplayString)
                            XCTAssertMatch(commandLineDisplayString, .contains("File\\ With\\ Space.c"))
                        }
                    }

                    // We should have a task for all source files.
                    for name in ["File 1.swift", "File 2.swift"] {
                        results.checkTasks(.matchRuleItem(SRCROOT.join(name).str)) { tasks in
                            #expect(!tasks.isEmpty, "missing task(s) for source file: '\(name)'")

                            // Check that files with spaces are not doubly-quoted.
                            for task in tasks {
                                if let cli = task.commandLineDisplayString, cli.contains("-primary-file") && cli.contains("File\\ 1.swift") {
                                    XCTAssertMatch(cli, .contains("File\\ 1.swift "))
                                    XCTAssertMatch(cli, .not(.contains("File\\ 1.swift\"")))
                                    XCTAssertMatch(cli, .not(.contains("File\\ 1.swift\\\"")))
                                }
                            }
                        }
                    }

                    results.checkNote(.equal("Building targets in dependency order"))
                    results.checkNoDiagnostics()

                    results.checkNoFailedTasks()

                    results.checkUniqueTaskSignatures()
                }

                let allOutput = events.allOutput().bytes
                if !allOutput.isEmpty {
                    let reportedBuildDescriptionID = try #require(events.reportBuildDescriptionMessage?.buildDescriptionID)
                    #expect(allOutput.unsafeStringValue.hasPrefix(
                    """
                    Build description signature: \(reportedBuildDescriptionID)
                    Build description path: \(tmpDirPath.str)/Test/aProject/build/XCBuildData/\(reportedBuildDescriptionID).xcbuilddata
                    """))
                }
            }
        }
    }

    // Regression test for rdar://95168084 (invocation spits out json as part of log output)
    @Test(.requireSDKs(.macOS))
    func swiftParseableOutputDoesNotAppearInBuildLogWithWMO() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let srcroot = tmpDirPath.join("Test")
                let testTarget = TestStandardTarget(
                    "Tool", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                // FIXME: There should be a way to automatically populate the version here, but since these tests are not CoreBasedTests, there isn't a good way to do so right now.
                                "SWIFT_VERSION": "5.0",
                                "SWIFT_WHOLE_MODULE_OPTIMIZATION": "YES",
                                "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "USE_HEADERMAP": "NO",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                            ])],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.swift"),
                            TestBuildFile("File2.swift")]),
                    ])
                let testProject = TestProject(
                    "aProject",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Foo", children: [
                        TestFile("File1.swift"),
                        TestFile("File2.swift")]),
                    targets: [testTarget])
                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                let fs = localFS

                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await tester.invalidate()
                    }
                }

                // Write the test sources.
                try await fs.writeFileContents(SRCROOT.join("File1.swift")) { contents in
                    contents <<< "struct A {}\n"
                }
                try await fs.writeFileContents(SRCROOT.join("File2.swift")) { contents in
                    contents <<< "struct B {}\n"
                }

                // Run a test build.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))

                let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                // Check that nothing which looks like Swift parseable output appears in the build log.
                #expect(!events.allOutput().bytes.description.contains(
                """
                {
                  "kind":
                """))
            }
        }
    }

    /// Test functionality that's only present when `EnableDebugActivityLogs` is on.
    @Test(.requireSDKs(.macOS))
    func enableDebugActivityLogs() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let srcroot = tmpDirPath.join("Test")
                let appTarget = TestStandardTarget(
                    "App", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [:]
                        )],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("main.swift"),
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("Fwk1.framework"),
                            TestBuildFile("Fwk2.framework"),
                        ]),
                    ],
                    dependencies: [
                        TestTargetDependency("Fwk1"),
                    ]
                )
                let fwk1Target = TestStandardTarget(
                    "Fwk1", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [:])],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("ClassOne.swift"),
                        ]),
                    ])
                let fwk2Target = TestStandardTarget(
                    "Fwk2", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [:])],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("ClassTwo.swift"),
                        ]),
                    ])
                let testProject = TestProject(
                    "Project",
                    defaultConfigurationName: "Release",
                    groupTree: TestGroup("Project", children: [
                        TestGroup("Sources", children: [
                            TestFile("main.swift"),
                            TestFile("ClassOne.swift"),
                            TestFile("ClassTwo.swift"),
                        ]),
                        TestGroup("Frameworks", children: [
                            TestFile("Fwk1.framework"),
                            TestFile("Fwk2.framework"),
                        ]),
                    ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                // FIXME: There should be a way to automatically populate the version here, but since these tests are not CoreBasedTests, there isn't a good way to do so right now.
                                "SWIFT_VERSION": "5.2",
                                "MACOSX_DEPLOYMENT_TARGET": "10.15",
                                "SWIFT_STDLIB_TOOL_STRIP_BITCODE": "NO",
                            ])],
                    targets: [
                        appTarget,
                        fwk1Target,
                        fwk2Target,
                    ])
                let testWorkspace = TestWorkspace("Workspace",
                                                  sourceRoot: srcroot,
                                                  projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("Project")

                let fs = localFS

                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)

                // Write the test sources.
                let sourcesDir = SRCROOT.join("Sources")
                try await fs.writeFileContents(sourcesDir.join("main.swift")) { contents in
                    contents <<< "print(\"Hello, World!\")\n"
                }
                try await fs.writeFileContents(sourcesDir.join("ClassOne.swift")) { contents in
                    contents <<< "class ClassOne {}"
                }
                try await fs.writeFileContents(sourcesDir.join("ClassTwo.swift")) { contents in
                    contents <<< "class ClassTwo {}"
                }

                // Create a build request.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.useImplicitDependencies = true
                request.add(target: SWBConfiguredTarget(guid: appTarget.guid, parameters: nil))

                // Perform a build with EnableDebugActivityLogs turned on.
                do {
                    // Configure the session to turn on debug activity logs
                    try await testSession.session.setUserPreferences(UserPreferences.defaultForTesting.with(enableDebugActivityLogs: true))

                    // Run the build.
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    // Check expected diagnostics.
                    try await tester.checkResults(events: events) { results in
                        // We should have a task for all source files, just to make sure the build didn't fall over.
                        for name in ["main.swift", "ClassOne.swift", "ClassTwo.swift"] {
                            results.checkTasks(.matchRuleItem(sourcesDir.join(name).str)) { tasks in
                                #expect(!tasks.isEmpty, "missing task(s) for source file: '\(name)'")
                            }
                        }

                        results.checkNote(.contains("Target dependency graph (3 targets)"))
                        results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                        results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                        results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                        results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                        results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                        results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                        results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                        results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }

                    let reportedBuildDescriptionID = try #require(events.reportBuildDescriptionMessage?.buildDescriptionID)
                    // TODO: Revert to .equal once appintentsmetadataprocessor output is removed
                    XCTAssertMatch(events.allOutput().bytes.unsafeStringValue, .contains(
                    """
                    Build description signature: \(reportedBuildDescriptionID)
                    Build description path: \(tmpDirPath.str)/Test/Project/build/XCBuildData/\(reportedBuildDescriptionID).xcbuilddata

                    """)
                    )
                }

                // Remove the build directory to do another clean build.
                try await testSession.session.waitForQuiescence()
                try fs.removeDirectory(SRCROOT.join("build"))

                // Perform a build with EnableDebugActivityLogs turned off to make sure unexpected items don't end up in the log.
                do {
                    // HACK: <rdar://67845004> Work around false race in TSan; this second call to sendPIF() should not be needed but for some reason it makes the TSan issue go away.
                    try await testSession.sendPIF(testWorkspace)

                    // Configure the session to turn off debug activity logs
                    try await testSession.session.setUserPreferences(UserPreferences.defaultForTesting.with(enableDebugActivityLogs: false))

                    // Run the build.
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    // Check expected diagnostics.
                    try await tester.checkResults(events: events) { results in
                        // We should have a task for all source files, just to make sure the build didn't fall over.
                        for name in ["main.swift", "ClassOne.swift", "ClassTwo.swift"] {
                            results.checkTasks(.matchRuleItem(sourcesDir.join(name).str)) { tasks in
                                #expect(!tasks.isEmpty, "missing task(s) for source file: '\(name)'")
                            }
                        }

                        results.checkNote(.contains("Building targets in dependency order"))
                        results.checkNote(.prefix("Target dependency graph"))
                        results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                        results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                        results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                        results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }

                    let reportedBuildDescriptionID = try #require(events.reportBuildDescriptionMessage?.buildDescriptionID)
                    // TODO: Revert to .equals once appintentsmetadataprocessor output is removed
                    XCTAssertMatch(events.allOutput().bytes.unsafeStringValue, .prefix(
                    """
                    Build description signature: \(reportedBuildDescriptionID)
                    Build description path: \(tmpDirPath.str)/Test/Project/build/XCBuildData/\(reportedBuildDescriptionID).xcbuilddata

                    """)
                    )
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildOrderDiagnosticMultipleTargets() async throws {
        try await withTemporaryDirectory { (tmpDir: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(temporaryDirectory: tmpDir)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testProject = TestProject(
                    "aProject",
                    sourceRoot: tmpDir.path,
                    groupTree: TestGroup(
                        "Sources", children: []),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]
                        )],
                    targets: [
                        TestStandardTarget(
                            "FwkTarget",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [:]),
                            ],
                            buildPhases: [
                            ], dependencies: [
                                "FwkTarget2"
                            ]
                        ),
                        TestStandardTarget(
                            "FwkTarget2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [:]),
                            ],
                            buildPhases: [
                            ]
                        ),
                    ])
                let fs = localFS
                let tester = try await CoreQualificationTester(testProject, testSession, fs: fs)

                // Regular parallel builds
                do {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = true
                    request.schemeCommand = .launch
                    try await tester.checkBuild(SWBBuildParameters(action: "build", configuration: "Debug", activeRunDestination: .macOS), request) { results in
                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()
                    }
                }

                // Scheme-style builds with parallelism disabled
                do {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = false
                    request.schemeCommand = .launch
                    try await tester.checkBuild(SWBBuildParameters(action: "build", configuration: "Debug", activeRunDestination: .macOS), request) { results in
                        results.checkWarning(.equal("Building targets in manual order is deprecated - choose Dependency Order in scheme settings instead, or set DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING in any of the targets in the current scheme to suppress this warning"))
                        results.checkNoDiagnostics()
                    }
                }

                // Scheme-style builds with parallelism disabled, warning disabled
                do {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = false
                    request.schemeCommand = .launch
                    try await tester.checkBuild(SWBBuildParameters(action: "build", configuration: "Debug", activeRunDestination: .macOS, overrides: ["DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES"]), request) { results in
                        results.checkNote(.equal("Building targets in manual order is deprecated - choose Dependency Order in scheme settings instead, or set DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING in any of the targets in the current scheme to suppress this warning"))
                        results.checkNoDiagnostics()
                    }
                }

                // Target-style builds with parallelism disabled
                do {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = false
                    request.schemeCommand = nil
                    try await tester.checkBuild(SWBBuildParameters(action: "build", configuration: "Debug", activeRunDestination: nil), request) { results in
                        results.checkWarning(.equal("Building targets in manual order is deprecated - check \"Parallelize build for command-line builds\" in the project editor, or set DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING in any of the targets in the current build to suppress this warning"))
                        results.checkNoDiagnostics()
                    }
                }

                // Target-style builds with parallelism disabled, warning disabled
                do {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = false
                    request.schemeCommand = nil
                    try await tester.checkBuild(SWBBuildParameters(action: "build", configuration: "Debug", activeRunDestination: nil, overrides: ["DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES"]), request) { results in
                        results.checkNote(.equal("Building targets in manual order is deprecated - check \"Parallelize build for command-line builds\" in the project editor, or set DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING in any of the targets in the current build to suppress this warning"))
                        results.checkNoDiagnostics()
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildOrderDiagnosticOneTarget() async throws {
        try await withTemporaryDirectory { (tmpDir: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(temporaryDirectory: tmpDir)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let testProject = TestProject(
                    "aProject",
                    sourceRoot: tmpDir.path,
                    groupTree: TestGroup(
                        "Sources", children: []),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]
                        )],
                    targets: [
                        TestStandardTarget(
                            "FwkTarget",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [:]),
                            ],
                            buildPhases: [
                            ]
                        ),
                    ])
                let fs = localFS
                let tester = try await CoreQualificationTester(testProject, testSession, fs: fs)

                // Regular parallel builds
                do {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = true
                    request.schemeCommand = .launch
                    try await tester.checkBuild(SWBBuildParameters(action: "build", configuration: "Debug", activeRunDestination: .macOS), request) { results in
                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()
                    }
                }

                // Scheme-style builds with parallelism disabled
                do {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = false
                    request.schemeCommand = .launch
                    try await tester.checkBuild(SWBBuildParameters(action: "build", configuration: "Debug", activeRunDestination: .macOS), request) { results in
                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()
                    }
                }

                // Target-style builds with parallelism disabled
                do {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = false
                    request.schemeCommand = nil
                    try await tester.checkBuild(SWBBuildParameters(action: "build", configuration: "Debug", activeRunDestination: nil), request) { results in
                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()
                    }
                }
            }
        }
    }
}
