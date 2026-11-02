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
import SWBMockCASPluginSupport
import SwiftBuildTestSupport

import SWBTaskExecution
import SWBProtocol

import Foundation

@Suite(.requireSwiftCASSandbox)
fileprivate struct SwiftDepScanCachingTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func basic() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                results.checkDepscanCacheMiss(planTask)
                // On a miss the planned build gets stored in the CAS.
                results.checkTaskExists(.matchRuleType("SwiftCachingCacheDepscanPlan"))
                results.checkTasks(.matchRuleType("SwiftCompile")) { tasks in
                    #expect(!tasks.isEmpty)
                    for task in tasks {
                        results.checkKeyQueryCacheMiss(task)
                    }
                }
                results.checkNoErrors()
            }

            // Clean the build to trigger a cached build.
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                results.checkDepscanCacheHit(planTask)
                // A replayed planned build doesn't need to get stored again.
                results.checkNoTask(.matchRuleType("SwiftCachingCacheDepscanPlan"))
                // The jobs of the replayed planned build still run and get cache hits.
                results.checkTasks(.matchRuleType("SwiftCompile")) { tasks in
                    #expect(!tasks.isEmpty)
                    for task in tasks {
                        results.checkKeyQueryCacheHit(task)
                    }
                }
                results.checkTaskExists(.matchRuleType("SwiftEmitModule"))
                results.checkNoErrors()
            }
            #expect(tester.fs.exists(tmpDirPath.join("Test/aProject/build/Debug/MyFrame.framework/Versions/A/MyFrame")))
            #expect(tester.fs.exists(tmpDirPath.join("Test/aProject/build/Debug/MyFrame.framework/Modules/MyFrame.swiftmodule")))
        }
    }

    @Test(.requireSDKs(.macOS))
    func withManyFileInputs() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let numOfFileInputs = 200
            var filenames: [String] = []
            for i in 0..<numOfFileInputs {
                filenames.append("\(i).swift")
            }

            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath, sourceFiles: filenames)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let sourcesDir = SRCROOT.join("Sources")

            for (i, filename) in filenames.enumerated() {
                try await tester.fs.writeFileContents(sourcesDir.join(filename)) {
                    $0 <<< "public func foo\(i)() {}\n"
                }
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                results.checkDepscanCacheMiss(planTask)
                results.checkNoErrors()
            }

            // Clean the build to trigger a cached build.
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                results.checkDepscanCacheHit(planTask)
                results.checkNoErrors()
            }
        }
    }

    /// Without `SWIFT_ENABLE_PRESCAN_CACHING` the planning task doesn't query or populate the prescan cache.
    @Test(.requireSDKs(.macOS))
    func disabled() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            var buildSettings = try await prescanBuildSettings(tmpDirPath)
            buildSettings.removeValue(forKey: "SWIFT_ENABLE_PRESCAN_CACHING")
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath, buildSettings: buildSettings)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            for _ in 0..<2 {
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                    results.checkDepscanNotCached(planTask)
                    results.checkNoTask(.matchRuleType("SwiftCachingCacheDepscanPlan"))
                    results.checkNoTask(.matchRuleType("CASCachingMaterializeKey"))
                    results.checkNoErrors()
                }
                try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            }
        }
    }

    /// `SWIFT_ENABLE_PRESCAN_CACHING` enables the CAS sandbox by default.
    @Test(.requireSDKs(.macOS))
    func enablesCASSandboxByDefault() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            var buildSettings = try await prescanBuildSettings(tmpDirPath)
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath, buildSettings: buildSettings)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTaskExists(.matchRuleType("IngestCASFSRoot"))
                let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                planTask.checkCommandLineContains(["-scanner-cas-fs"])
                // Headermaps are disabled when using the CAS sandbox.
                #expect(!planTask.commandLine.contains { $0.asString.hasSuffix(".hmap") })
                results.checkDepscanCacheMiss(planTask)
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheHit(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkNoErrors()
            }
        }
    }

    /// `SWIFT_ENABLE_PRESCAN_CACHING` can't be used if the CAS sandbox is explicitly disabled.
    @Test(.requireSDKs(.macOS))
    func errorWithoutCASSandbox() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            var buildSettings = try await prescanBuildSettings(tmpDirPath)
            buildSettings["SWIFT_ENABLE_CAS_SANDBOX"] = "NO"
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath, buildSettings: buildSettings)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkError(.prefix("Enabling SWIFT_ENABLE_PRESCAN_CACHING also requires: SWIFT_ENABLE_CAS_SANDBOX"))
                results.checkNoErrors()
            }
        }
    }

    /// `SWIFT_ENABLE_PRESCAN_CACHING` doesn't support rebuilds yet, the build folder needs to be cleaned first.
    @Test(.requireSDKs(.macOS))
    func errorOnRebuild() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }

            // A null build doesn't re-plan.
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoTask(.matchRuleType("SwiftDriver"))
                results.checkNoErrors()
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\npublic func bar() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkError(.prefix("SWIFT_ENABLE_PRESCAN_CACHING does not support rebuilds yet"))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func diagnosticRemarks() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            var buildSettings = try await prescanBuildSettings(tmpDirPath)
            buildSettings["COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS"] = "YES"
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath, buildSettings: buildSettings)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            var signatureKey: String = ""
            var planID: String = ""
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                results.checkDepscanCacheMiss(planTask)
                let missKey = try #require(results.checkDepscanRemark(planTask, prefix: "cache miss: "))

                let cachePlanTask: Task = try results.checkTask(.matchRuleType("SwiftCachingCacheDepscanPlan")) { $0 }
                (planID, signatureKey) = try #require(results.checkSerializedPlanRemark(cachePlanTask))
                // The key used for storing the plan is the same as the one used for the lookup.
                #expect(signatureKey == missKey)
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                results.checkDepscanCacheHit(planTask)
                #expect(results.getDiagnosticMessageForTask(.prefix("replayed from CAS object \(planID)"), kind: .note, task: planTask) != nil)
                #expect(results.checkDepscanRemark(planTask, prefix: "cache hit: ") == signatureKey)
                results.checkNoErrors()
            }
        }
    }

    /// Changing the contents of a source file changes the CAS sandbox inputs and so the prescan cache key.
    @Test(.requireSDKs(.macOS))
    func sourceChange() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let libPath = SRCROOT.join("Sources/lib.swift")

            try await tester.fs.writeFileContents(libPath) {
                $0 <<< "public func foo() {}\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheMiss(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkNoErrors()
            }

            // Modify the source file.
            try await tester.fs.writeFileContents(libPath) {
                $0 <<< "public func bar() {}\n"
            }
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheMiss(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkTaskExists(.matchRuleType("SwiftCachingCacheDepscanPlan"))
                results.checkNoErrors()
            }

            // Reverting to the original contents gets a hit for the first build's planned build.
            try await tester.fs.writeFileContents(libPath) {
                $0 <<< "public func foo() {}\n"
            }
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheHit(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkNoTask(.matchRuleType("SwiftCachingCacheDepscanPlan"))
                results.checkNoErrors()
            }
        }
    }

    /// Adding a new source file changes both the command line and the CAS sandbox inputs.
    @Test(.requireSDKs(.macOS))
    func addedSourceFile() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath, sourceFiles: ["lib.swift", "other.swift"])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/other.swift")) {
                $0 <<< "public func other() {}\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheMiss(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkNoErrors()
            }

            // Building a workspace variant with a single source file must not reuse the planned build.
            let singleFileWorkspace = try await singleFrameworkWorkspace(tmpDirPath, sourceFiles: ["lib.swift"])
            let singleFileTester = try await BuildOperationTester(getCore(), singleFileWorkspace, simulated: false)
            try await singleFileTester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await singleFileTester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheMiss(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkTaskExists(.matchRuleType("SwiftCompile"), .matchRuleItemBasename("lib.swift"))
                results.checkNoTask(.matchRuleType("SwiftCompile"), .matchRuleItemBasename("other.swift"))
                results.checkNoErrors()
            }
        }
    }

    /// Updating the timestamp of a source file re-runs planning, but the key remains the same.
    @Test(.requireSDKs(.macOS), .disabled("SWIFT_ENABLE_PRESCAN_CACHING doesn't support rebuilds yet"))
    func touchedSource() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let libPath = SRCROOT.join("Sources/lib.swift")

            try await tester.fs.writeFileContents(libPath) {
                $0 <<< "public func foo() {}\n"
            }
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheMiss(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkNoErrors()
            }

            try await tester.fs.updateTimestamp(libPath)
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheHit(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkNoTask(.matchRuleType("SwiftCachingCacheDepscanPlan"))
                results.checkNoErrors()
            }
        }
    }

    /// Compiler arguments are part of the prescan cache key.
    @Test(.requireSDKs(.macOS))
    func commandLineChange() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< """
                #if FOO
                public func foo() {}
                #else
                public func bar() {}
                #endif

                """
            }

            let defaultParameters = BuildParameters(configuration: "Debug")
            let fooParameters = BuildParameters(configuration: "Debug", overrides: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "FOO"])

            try await tester.checkBuild(parameters: defaultParameters, runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheMiss(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await tester.checkBuild(parameters: fooParameters, runDestination: .macOS, persistent: true) { results in
                let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                planTask.checkCommandLineContains(["-DFOO"])
                results.checkDepscanCacheMiss(planTask)
                results.checkNoErrors()
            }

            // Both configurations are now cached.
            for parameters in [defaultParameters, fooParameters] {
                try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
                try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                    try results.checkDepscanCacheHit(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                    results.checkNoErrors()
                }
            }
        }
    }

    /// After replaying a cached planned build, a subsequent build is a null build.
    @Test(.requireSDKs(.macOS))
    func nullBuildAfterReplay() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheHit(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkNoErrors()
            }

            try await tester.checkNullBuild(runDestination: .macOS, persistent: true)
        }
    }

    /// The prescan cache key of a target includes the modules of its dependencies, via the CAS sandbox.
    @Test(.requireSDKs(.macOS))
    func withDependency() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources",
                            children: [
                                TestFile("main.swift"),
                                TestFile("lib.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: prescanBuildSettings(tmpDirPath)),
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
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/main.swift")) {
                $0 <<< "import MyFrame\nfoo()\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            func checkBuild(frameworkHit: Bool, toolHit: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    for (target, hit) in [("MyFrame", frameworkHit), ("tool", toolHit)] {
                        let planTask: Task = try results.checkTask(.matchTargetName(target), .matchRuleType("SwiftDriver"), sourceLocation: sourceLocation) { $0 }
                        if hit {
                            results.checkDepscanCacheHit(planTask, sourceLocation: sourceLocation)
                        } else {
                            results.checkDepscanCacheMiss(planTask, sourceLocation: sourceLocation)
                        }
                    }
                    results.checkNoErrors(sourceLocation: sourceLocation)
                }
            }

            try await checkBuild(frameworkHit: false, toolHit: false)

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await checkBuild(frameworkHit: true, toolHit: true)

            // Changing the public interface of the framework invalidates the dependent's key as well.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\npublic func bar() {}\n"
            }
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await checkBuild(frameworkHit: false, toolHit: false)

            // Changing only the dependent invalidates only its own key.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/main.swift")) {
                $0 <<< "import MyFrame\nfoo()\nbar()\n"
            }
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await checkBuild(frameworkHit: true, toolHit: false)

            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await checkBuild(frameworkHit: true, toolHit: true)
        }
    }

    /// Prescan caching with a remote cache: the planned build gets uploaded by one "machine" and
    /// downloaded by another one with a fresh local CAS, at a different path.
    @Test(.requireSDKs(.macOS))
    func remote() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            var buildSettings = try await remotePrescanBuildSettings(tmpDirPath)
            buildSettings["COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS"] = "YES"
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath, buildSettings: buildSettings)
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/lib.swift")) {
                $0 <<< "public func foo() {}\n"
            }

            // "Machine" 1: builds from scratch, populating the remote cache on upload.
            var signatureKey: String = ""
            var planID: String = ""
            try await tester.checkBuild(parameters: machineParameters(tmpDirPath, machine: 1), runDestination: .macOS, persistent: true) { results in
                let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver")) { $0 }
                results.checkDepscanCacheMiss(planTask)

                // The remote key query happens as a dependency of the planning task.
                results.checkTaskExists(.matchRuleType("CASCachingMaterializeKey"))
                let keyQueryTask: Task = try results.checkTask(.matchRuleType("CASCachingKeyQuery")) { $0 }
                #expect(results.getDiagnosticMessageForTask(.prefix("cache miss"), kind: .note, task: keyQueryTask) != nil)
                results.checkNoTask(.matchRuleType("CASCachingObjectMaterializer"))

                let cachePlanTask: Task = try results.checkTask(.matchRuleType("SwiftCachingCacheDepscanPlan")) { $0 }
                (planID, signatureKey) = try #require(results.checkSerializedPlanRemark(cachePlanTask))
                #expect(keyQueryTask.ruleInfo == ["CASCachingKeyQuery", signatureKey])

                results.checkNoErrors()
            }

            do {
                let entries = try readCallLog(at: localPluginCASPath(tmpDirPath, machine: 1))
                // The planned build was associated with its key in the remote cache.
                #expect(entries.contains { $0.function.hasPrefix("llcas_actioncache_put_for_digest") && $0.globally == true && $0.keyDigest == signatureKey && $0.valueDigest == planID && $0.outcome == "success" })
                // The remote key query was a miss.
                #expect(entries.contains { $0.function.hasPrefix("llcas_actioncache_get_for_digest") && $0.globally == true && $0.keyDigest == signatureKey && $0.outcome == "notfound" })
            }

            // Remove the local CAS of machine 1, to make sure machine 2 doesn't depend on it.
            try tester.fs.removeDirectory(localCASPath(tmpDirPath, machine: 1))

            // "Machine" 2: fresh local CAS, but the same remote service path -> should hit remotely.
            let localPluginCASPath2 = localPluginCASPath(tmpDirPath, machine: 2)
            func checkRemoteHitBuild(sourceLocation: SourceLocation = #_sourceLocation) async throws {
                try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
                try await tester.checkBuild(parameters: machineParameters(tmpDirPath, machine: 2), runDestination: .macOS, persistent: true) { results in
                    let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver"), sourceLocation: sourceLocation) { $0 }
                    results.checkDepscanCacheHit(planTask, sourceLocation: sourceLocation)
                    #expect(results.getDiagnosticMessageForTask(.prefix("replayed from CAS object \(planID)"), kind: .note, task: planTask) != nil, sourceLocation: sourceLocation)

                    let keyQueryTask: Task = try results.checkTask(.matchRuleType("CASCachingKeyQuery"), sourceLocation: sourceLocation) { $0 }
                    #expect(results.getDiagnosticMessageForTask(.prefix("cache hit"), kind: .note, task: keyQueryTask) != nil, sourceLocation: sourceLocation)
                    // The planned build object is not available locally and needs to be downloaded.
                    let materializerTask: Task = try results.checkTask(.matchRuleType("CASCachingObjectMaterializer"), sourceLocation: sourceLocation) { $0 }
                    #expect(materializerTask.ruleInfo == ["CASCachingObjectMaterializer", planID], sourceLocation: sourceLocation)

                    results.checkNoTask(.matchRuleType("SwiftCachingCacheDepscanPlan"), sourceLocation: sourceLocation)
                    results.checkTasks(.matchRuleType("SwiftCompile")) { tasks in
                        #expect(!tasks.isEmpty, sourceLocation: sourceLocation)
                        for task in tasks {
                            // The jobs of the replayed planned build get the local CAS of machine 2 appended,
                            // overriding the `-cas-path` of machine 1.
                            #expect(Array(task.commandLineAsStrings.suffix(2)) == ["-cas-path", localPluginCASPath2.str], sourceLocation: sourceLocation)
                            // The jobs get remote cache hits too.
                            results.checkKeyQueryCacheHit(task, sourceLocation: sourceLocation)
                        }
                    }
                    results.checkNoErrors(sourceLocation: sourceLocation)
                }
                #expect(tester.fs.exists(tmpDirPath.join("Test/aProject/build/Debug/MyFrame.framework/Versions/A/MyFrame")), sourceLocation: sourceLocation)
                #expect(!tester.fs.exists(localCASPath(tmpDirPath, machine: 1)), sourceLocation: sourceLocation)

                let entries = try readCallLog(at: localPluginCASPath2)
                guard let remoteHitIndex = entries.firstIndex(where: { $0.function.hasPrefix("llcas_actioncache_get_for_digest") && $0.globally == true && $0.keyDigest == signatureKey && $0.outcome == "success" && $0.source == "remote" }) else {
                    Issue.record("no successful remote action-cache hit found for the prescan key", sourceLocation: sourceLocation)
                    return
                }
                // Rule out a false positive: no successful local-only lookup of the key should have
                // preceded the remote one, since the local CAS started out empty.
                let precedingLocalOnlyHits = entries[..<remoteHitIndex].filter { $0.function.hasPrefix("llcas_actioncache_get_for_digest") && $0.globally != true && $0.keyDigest == signatureKey && $0.outcome == "success" }
                #expect(precedingLocalOnlyHits.isEmpty, sourceLocation: sourceLocation)
                // The planned build object was downloaded from the remote CAS.
                #expect(entries[remoteHitIndex...].contains { $0.function.hasPrefix("llcas_cas_load_object") && $0.objectDigest == planID && $0.outcome == "success" && $0.source == "remote" }, sourceLocation: sourceLocation)
            }

            try await checkRemoteHitBuild()

            // Simulate losing the local CAS; the planned build should be downloaded again.
            #expect(tester.fs.exists(localCASPath(tmpDirPath, machine: 2)))
            try tester.fs.removeDirectory(localCASPath(tmpDirPath, machine: 2))
            try await checkRemoteHitBuild()

            // With the planned build available in the local CAS no remote query or download is needed.
            try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
            try await tester.checkBuild(parameters: machineParameters(tmpDirPath, machine: 2), runDestination: .macOS, persistent: true) { results in
                try results.checkDepscanCacheHit(results.checkTask(.matchRuleType("SwiftDriver")) { $0 })
                results.checkTaskExists(.matchRuleType("CASCachingMaterializeKey"))
                results.checkNoTask(.matchRuleType("CASCachingKeyQuery"))
                results.checkNoTask(.matchRuleType("CASCachingObjectMaterializer"))
                results.checkNoErrors()
            }
        }
    }

    /// A remote cache miss for a modified source file uploads a new planned build that another "machine" can use.
    @Test(.requireSDKs(.macOS))
    func remoteSourceChange() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = try await singleFrameworkWorkspace(tmpDirPath, buildSettings: remotePrescanBuildSettings(tmpDirPath))
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let libPath = SRCROOT.join("Sources/lib.swift")

            func checkBuild(machine: Int, hit: Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
                try await tester.checkBuild(runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })
                try await tester.checkBuild(parameters: machineParameters(tmpDirPath, machine: machine), runDestination: .macOS, persistent: true) { results in
                    let planTask: Task = try results.checkTask(.matchRuleType("SwiftDriver"), sourceLocation: sourceLocation) { $0 }
                    if hit {
                        results.checkDepscanCacheHit(planTask, sourceLocation: sourceLocation)
                    } else {
                        results.checkDepscanCacheMiss(planTask, sourceLocation: sourceLocation)
                    }
                    results.checkNoErrors(sourceLocation: sourceLocation)
                }
            }

            try await tester.fs.writeFileContents(libPath) {
                $0 <<< "public func foo() {}\n"
            }
            try await checkBuild(machine: 1, hit: false)
            try await checkBuild(machine: 2, hit: true)

            // Machine 2 changes the source and uploads a new planned build.
            try await tester.fs.writeFileContents(libPath) {
                $0 <<< "public func bar() {}\n"
            }
            try await checkBuild(machine: 2, hit: false)
            try await checkBuild(machine: 3, hit: true)

            // Machine 1 only has the original planned build locally, but gets the new one remotely.
            try await checkBuild(machine: 1, hit: true)
        }
    }
}

extension SwiftDepScanCachingTests {
    /// The common build settings for enabling prescan caching.
    fileprivate func prescanBuildSettings(_ tmpDirPath: Path) async throws -> [String: String] {
        return try await [
            "CODE_SIGNING_ALLOWED": "NO",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SDKROOT": "macosx",
            "SWIFT_VERSION": swiftVersion,
            "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
            "SWIFT_ENABLE_COMPILE_CACHE": "YES",
            "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
            "SWIFT_ENABLE_PRESCAN_CACHING": "YES",
            "COMPILATION_CACHE_CAS_PATH": tmpDirPath.join("CompilationCache").str,
            "COMPILATION_CACHE_ENABLE_PLUGIN": "YES",
            "DSTROOT": tmpDirPath.join("dstroot").str,
        ]
    }

    /// The build settings for prescan caching using the mock CAS plugin with a remote cache.
    fileprivate func remotePrescanBuildSettings(_ tmpDirPath: Path) async throws -> [String: String] {
        var buildSettings = try await prescanBuildSettings(tmpDirPath)
        buildSettings["COMPILATION_CACHE_PLUGIN_PATH"] = try MockCASPluginLocator.locate().str
        buildSettings["COMPILATION_CACHE_REMOTE_SERVICE_PATH"] = tmpDirPath.join("RemoteCache").str
        return buildSettings
    }

    /// The local CAS path (`COMPILATION_CACHE_CAS_PATH`) of a simulated "machine" sharing the remote cache.
    fileprivate func localCASPath(_ tmpDirPath: Path, machine: Int) -> Path {
        return tmpDirPath.join("CompilationCache\(machine)")
    }

    /// The local CAS path of the mock CAS plugin of a simulated "machine", which contains its call log.
    fileprivate func localPluginCASPath(_ tmpDirPath: Path, machine: Int) -> Path {
        return localCASPath(tmpDirPath, machine: machine).join("plugin")
    }

    /// The build parameters for building as a simulated "machine" sharing the remote cache.
    fileprivate func machineParameters(_ tmpDirPath: Path, machine: Int) -> BuildParameters {
        return BuildParameters(configuration: "Debug", overrides: ["COMPILATION_CACHE_CAS_PATH": localCASPath(tmpDirPath, machine: machine).str])
    }

    /// A workspace with a single framework target, `MyFrame`, compiling the given sources from the `Sources` directory.
    fileprivate func singleFrameworkWorkspace(_ tmpDirPath: Path, sourceFiles: [String] = ["lib.swift"], buildSettings settings: [String: String]? = nil) async throws -> TestWorkspace {
        let buildSettings: [String: String]
        if let settings {
            buildSettings = settings
        } else {
            buildSettings = try await prescanBuildSettings(tmpDirPath)
        }
        return TestWorkspace(
            "Test",
            sourceRoot: tmpDirPath.join("Test"),
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources", path: "Sources",
                        children: sourceFiles.map { TestFile($0) }
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: buildSettings),
                    ],
                    targets: [
                        TestStandardTarget(
                            "MyFrame",
                            type: .framework,
                            buildPhases: [
                                TestSourcesBuildPhase(sourceFiles.map { TestBuildFile($0) }),
                            ],
                        ),
                    ])
            ])
    }
}

extension BuildOperationTester.BuildResults {
    fileprivate func checkDepscanCacheMiss(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        check(contains: .taskHadEvent(task, event: .hadOutput(contents: "Cache miss\n")), sourceLocation: sourceLocation)
    }

    fileprivate func checkDepscanCacheHit(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        check(contains: .taskHadEvent(task, event: .hadOutput(contents: "Cache hit\n")), sourceLocation: sourceLocation)
    }

    fileprivate func checkDepscanNotCached(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        check(notContains: .taskHadEvent(task, event: .hadOutput(contents: "Cache miss\n")), sourceLocation: sourceLocation)
        check(notContains: .taskHadEvent(task, event: .hadOutput(contents: "Cache hit\n")), sourceLocation: sourceLocation)
    }

    /// Returns the key of a `cache hit: <key>` or `cache miss: <key>` remark of the planning task.
    fileprivate func checkDepscanRemark(_ task: Task, prefix: String, sourceLocation: SourceLocation = #_sourceLocation) -> String? {
        guard let message = getDiagnosticMessageForTask(.prefix(prefix), kind: .note, task: task) else {
            Issue.record("Unable to find '\(prefix)' remark for task \(task)", sourceLocation: sourceLocation)
            return nil
        }
        // The message is suffixed with the task description.
        return message.dropFirst(prefix.count).split(separator: " ").first.map(String.init)
    }

    /// Returns the `(planID, key)` of the `serialized <planID> for key: <key>` remark of the task caching the planned build.
    fileprivate func checkSerializedPlanRemark(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) -> (planID: String, key: String)? {
        guard let message = getDiagnosticMessageForTask(.prefix("serialized "), kind: .note, task: task),
              let match = message.firstMatch(of: #/^serialized (\S+) for key: (\S+)/#) else {
            Issue.record("Unable to find 'serialized' remark for task \(task)", sourceLocation: sourceLocation)
            return nil
        }
        return (String(match.1), String(match.2))
    }

    fileprivate func checkKeyQueryCacheMiss(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        check(contains: .taskHadEvent(task, event: .hadOutput(contents: "Cache miss\n")), sourceLocation: sourceLocation)
    }

    fileprivate func checkKeyQueryCacheHit(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) {
        check(contains: .taskHadEvent(task, event: .hadOutput(contents: "Cache hit\n")), sourceLocation: sourceLocation)
    }
}
