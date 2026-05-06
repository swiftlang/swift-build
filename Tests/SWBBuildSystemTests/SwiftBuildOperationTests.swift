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
import SWBUtil

import Foundation

import SWBTaskExecution

@Suite
fileprivate struct SwiftBuildOperationTests: CoreBasedTests {
    /// Test that building a project with module-only architectures and generated Objective-C headers still generates the headers for the module-only architectures.
    @Test(.requireSDKs(.watchOS))
    func swiftModuleOnlyArchsWithGeneratedObjectiveCHeaders() async throws {
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
                                TestFile("App.m"),
                                TestFile("App.swift"),
                                TestFile("API.swift"),
                                TestFile("Bridging.h"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "ARCHS": "arm64_32",
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_MODULE_ONLY_ARCHS": "armv7k",
                                    "SWIFT_MODULE_ONLY_WATCHOS_DEPLOYMENT_TARGET": "$(WATCHOS_DEPLOYMENT_TARGET)",
                                    "SWIFT_PRECOMPILE_BRIDGING_HEADER[arch=armv7k]": "NO",
                                    "SDKROOT": "watchos",
                                    "SWIFT_VERSION": "5.0",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Application",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "SWIFT_OBJC_BRIDGING_HEADER": "Bridging.h",
                                    ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "App.m",
                                        "App.swift",
                                    ]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "API.swift",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Bridging.h")) {
                $0 <<< "#import <Framework/Framework-Swift.h>\n"

                // Reference some type exposed by the header. This will ensure we fail to build if the type is not visible to the current architecture when precompiling the bridging header.
                $0 <<< "@interface Baz\n"
                $0 <<< "@property (readonly) Foo *foo;\n"
                $0 <<< "@end\n"
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/API.swift")) {
                $0 <<< "import Foundation\n"
                $0 <<< "@objc public class Foo: NSObject { public func bar() { } }\n"
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/App.m")) {
                $0 <<< "#import <Framework/Framework-Swift.h>\n"
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/App.swift")) {
                $0 <<< "import Framework\n"
                $0 <<< "@main struct Main { static func main() { } }\n"
            }

            try await tester.checkBuild(runDestination: .anywatchOSDevice) { results in
                results.consumeTasksMatchingRuleTypes()
                results.consumeTasksMatchingRuleTypes(["CopySwiftLibs", "GenerateDSYMFile", "ProcessInfoPlistFile", "RegisterExecutionPolicyException", "Touch", "Validate", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports"])

                for (arch, isModuleOnly) in [("armv7k", true), ("arm64_32", false)] {
                    let moduleBaseNameSuffix = isModuleOnly ? "-watchos" : ""
                    let archRuleItem = isModuleOnly ? "\(arch)\(moduleBaseNameSuffix)" : arch

                    results.checkTask(.matchTargetName("Framework"), .matchRule(["SwiftDriver Compilation Requirements", "Framework", "normal", archRuleItem, "com.apple.xcode.tools.swift.compiler"])) { task in
                    }

                    results.checkTask(.matchTargetName("Framework"), .matchRule(["SwiftEmitModule", "normal", archRuleItem, "Emitting module for Framework"])) { _ in }

                    results.checkTask(.matchTargetName("Framework"), .matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug-watchos/Framework.framework/Modules/Framework.swiftmodule/\(arch)-apple-watchos.swiftdoc", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Framework.build/Objects-normal/\(arch)/Framework\(moduleBaseNameSuffix).swiftdoc"])) { _ in }

                    results.checkTask(.matchTargetName("Framework"), .matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug-watchos/Framework.framework/Modules/Framework.swiftmodule/\(arch)-apple-watchos.swiftmodule", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Framework.build/Objects-normal/\(arch)/Framework\(moduleBaseNameSuffix).swiftmodule"])) { _ in }

                    results.checkTask(.matchTargetName("Framework"), .matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug-watchos/Framework.framework/Modules/Framework.swiftmodule/Project/\(arch)-apple-watchos.swiftsourceinfo", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Framework.build/Objects-normal/\(arch)/Framework\(moduleBaseNameSuffix).swiftsourceinfo"])) { _ in }

                    results.checkTask(.matchTargetName("Framework"), .matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug-watchos/Framework.framework/Modules/Framework.swiftmodule/\(arch)-apple-watchos.abi.json", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Framework.build/Objects-normal/\(arch)/Framework\(moduleBaseNameSuffix).abi.json"])) { _ in }

                    if isModuleOnly {
                        results.checkTask(.matchTargetName("Framework"), .matchRule(["SwiftDriver GenerateModule", "Framework", "normal", archRuleItem, "com.apple.xcode.tools.swift.compiler"])) { _ in }
                    } else {
                        results.checkTask(.matchTargetName("Framework"), .matchRule(["SwiftDriver", "Framework", "normal", arch, "com.apple.xcode.tools.swift.compiler"])) { _ in }
                        results.checkTask(.matchTargetName("Framework"), .matchRule(["SwiftDriver Compilation", "Framework", "normal", archRuleItem, "com.apple.xcode.tools.swift.compiler"])) { task in
                        }
                        results.checkTask(.matchTargetName("Framework"), .matchRule(["SwiftCompile", "normal", archRuleItem, "Compiling API.swift", "\(tmpDirPath.str)/Test/aProject/API.swift"])) { _ in }
                    }
                }

                // The SwiftMergeGeneratedHeaders task should include normal AND module-only architectures.
                results.checkTask(.matchTargetName("Framework"), .matchRule(["SwiftMergeGeneratedHeaders", "\(tmpDirPath.str)/Test/aProject/build/Debug-watchos/Framework.framework/Headers/Framework-Swift.h", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Framework.build/Objects-normal/arm64_32/Framework-Swift.h", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Framework.build/Objects-normal/armv7k/Framework-Swift.h"])) { _ in }

                // There's only one "real" architecture, so should be only one linker task.
                results.checkTask(.matchTargetName("Framework"), .matchRuleType("Ld")) { _ in }
                results.checkTask(.matchTargetName("Framework"), .matchRuleType("GenerateTAPI")) { _ in }

                results.checkNoTask(.matchTargetName("Framework"))

                for (arch, isModuleOnly) in [("armv7k", true), ("arm64_32", false)] {
                    let moduleBaseNameSuffix = isModuleOnly ? "-watchos" : ""
                    let archRuleItem = isModuleOnly ? "\(arch)\(moduleBaseNameSuffix)" : arch

                    results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftDriver Compilation Requirements", "Application", "normal", archRuleItem, "com.apple.xcode.tools.swift.compiler"])) { task in
                    }

                    results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftEmitModule", "normal", archRuleItem, "Emitting module for Application"])) { _ in }

                    results.checkTask(.matchTargetName("Application"), .matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug-watchos/Application.swiftmodule/\(arch)-apple-watchos.swiftdoc", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Application.build/Objects-normal/\(arch)/Application\(moduleBaseNameSuffix).swiftdoc"])) { _ in }

                    results.checkTask(.matchTargetName("Application"), .matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug-watchos/Application.swiftmodule/\(arch)-apple-watchos.swiftmodule", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Application.build/Objects-normal/\(arch)/Application\(moduleBaseNameSuffix).swiftmodule"])) { _ in }

                    results.checkTask(.matchTargetName("Application"), .matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug-watchos/Application.swiftmodule/Project/\(arch)-apple-watchos.swiftsourceinfo", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Application.build/Objects-normal/\(arch)/Application\(moduleBaseNameSuffix).swiftsourceinfo"])) { _ in }

                    results.checkTask(.matchTargetName("Application"), .matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug-watchos/Application.swiftmodule/\(arch)-apple-watchos.abi.json", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Application.build/Objects-normal/\(arch)/Application\(moduleBaseNameSuffix).abi.json"])) { _ in }

                    if isModuleOnly {
                        results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftDriver GenerateModule", "Application", "normal", archRuleItem, "com.apple.xcode.tools.swift.compiler"])) { _ in }
                    } else {
                        results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftDriver", "Application", "normal", arch, "com.apple.xcode.tools.swift.compiler"])) { _ in }
                        results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftDriver Compilation", "Application", "normal", archRuleItem, "com.apple.xcode.tools.swift.compiler"])) { task in
                        }
                        results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftCompile", "normal", archRuleItem, "Compiling App.swift", "\(tmpDirPath.str)/Test/aProject/App.swift"])) { _ in }

                        results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftGeneratePch", "normal", archRuleItem, "Compiling bridging header"])) { task in }

                        results.checkTask(.matchTargetName("Application"), .matchRule(["CompileC", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Application.build/Objects-normal/\(arch)/App-\(BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: tmpDirPath.join("Test/aProject/App.m"))).o", "\(tmpDirPath.str)/Test/aProject/App.m", "normal", arch, "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                    }
                }

                // The SwiftMergeGeneratedHeaders task should include normal AND module-only architectures.
                results.checkTask(.matchTargetName("Application"), .matchRule(["SwiftMergeGeneratedHeaders", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Application.build/DerivedSources/Application-Swift.h", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Application.build/Objects-normal/arm64_32/Application-Swift.h", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-watchos/Application.build/Objects-normal/armv7k/Application-Swift.h"])) { _ in }

                // There's only one "real" architecture, so should be only one linker task.
                results.checkTask(.matchTargetName("Application"), .matchRuleType("Ld")) { _ in }

                results.checkNoTask(.matchTargetName("Application"))

                results.checkNoTask()
                results.checkWarning(.contains("'SWIFT_NORETURN' macro redefined"), failIfNotFound: false)
                results.checkWarning(.contains("'SWIFT_NORETURN' macro redefined"), failIfNotFound: false)
                results.checkWarning(.equal("SWIFT_MODULE_ONLY_ARCHS assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'Application' from project 'aProject')"))
                results.checkWarning(.equal("SWIFT_MODULE_ONLY_WATCHOS_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'Application' from project 'aProject')"))
                results.checkWarning(.equal("SWIFT_MODULE_ONLY_ARCHS assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'Framework' from project 'aProject')"))
                results.checkWarning(.equal("SWIFT_MODULE_ONLY_WATCHOS_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'Framework' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildLibraryForDistributionIgnoresExecutables() async throws {
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
                                TestFile("main.swift"),
                                TestFile("API.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                                    "SWIFT_VERSION": "5.0",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "Tool",
                                type: .commandLineTool,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.swift",
                                    ]),
                                ],
                                dependencies: ["Framework"]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "API.swift",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/API.swift")) {
                $0 <<< "public final class Foo { public func bar() { } }\n"
            }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/main.swift")) {
                $0 <<< "import Framework\n"
                $0 <<< "for _ in 0..<100 { }\nprint(\"hello\")\n"
            }

            try await tester.checkBuild(runDestination: .host) { results in
                results.checkNoTask(.matchTargetName("Tool"), .matchRuleType("SwiftVerifyEmittedModuleInterface"))

                // The build should not fail when BUILD_LIBRARY_FOR_DISTRIBUTION is applied to an executable.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test that stale Swift stdlib dylibs are removed on incremental builds (rdar://43151403).
    @Test(.requireSDKs(.macOS))
    func staleSwiftStdlibDylibRemovedOnIncrementalBuild() async throws {
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
                                TestFile("main.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": "5.0",
                                    "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "App",
                                type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.swift",
                                    ]),
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/main.swift")) {
                $0 <<< "import Foundation\nprint(\"hello\")\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("CopySwiftLibs"), .matchTargetName("App")) { _ in }
            }

            let frameworksDir = tmpDirPath.join("Test/aProject/build/Debug/App.app/Contents/Frameworks")
            let legitimateDylibs: [String]
            if tester.fs.exists(frameworksDir) {
                legitimateDylibs = try tester.fs.listdir(frameworksDir).filter {
                    $0.hasPrefix("libswift") && $0.hasSuffix(".dylib")
                }
            } else {
                legitimateDylibs = []
            }

            try tester.fs.createDirectory(frameworksDir, recursive: true)

            let staleDylibPath = frameworksDir.join("libswiftFakeModule.dylib")
            try await tester.fs.writeFileContents(staleDylibPath) { $0 <<< "fake" }
            #expect(tester.fs.exists(staleDylibPath), "Stale dylib should exist before incremental build")

            let userDylibPath = frameworksDir.join("libMyCustomLib.dylib")
            try await tester.fs.writeFileContents(userDylibPath) { $0 <<< "user" }

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/main.swift")) {
                $0 <<< "import Foundation\nprint(\"hello world\")\n"
            }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("CopySwiftLibs"), .matchTargetName("App")) { _ in }
            }

            #expect(!tester.fs.exists(staleDylibPath), "Stale libswiftFakeModule.dylib should have been removed on incremental build")
            #expect(tester.fs.exists(userDylibPath), "Non-Swift dylib libMyCustomLib.dylib should not have been removed")

            for dylib in legitimateDylibs {
                #expect(tester.fs.exists(frameworksDir.join(dylib)), "Legitimate stdlib dylib \(dylib) should not have been removed")
            }
        }
    }

    @Test(.requireSDKs(.host), .requireClangFeatures(.invokeSsaf))
    func invokeSsafCommandLineFlags() async throws {
        func makeTestWorkspace(_ tmpDirPath: Path, invokeSSAF: String, extractSummaries: String = "") -> TestWorkspace {
            TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("File1.cpp")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INVOKE_SSAF": invokeSSAF,
                                "EXTRACT_SUMMARIES": extractSummaries,
                                // Uncomment to test with a local build of clang
                                // "CC": "<LOCAL_CLANG_PATH>/bin/clang",
                                "CODE_SIGNING_ALLOWED": "NO",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Test",
                                type: .dynamicLibrary,
                                buildPhases: [TestSourcesBuildPhase(["File1.cpp"])])
                        ])
                ])
        }

        // INVOKE_SSAF=YES: both flags are present and the summary file path is co-located with
        // the object file, sharing the same basename but with a .json extension.
        try await withTemporaryDirectory { tmpDirPath in
            let tester = try await BuildOperationTester(getCore(), makeTestWorkspace(tmpDirPath, invokeSSAF: "YES", extractSummaries: "CallGraph"), simulated: false)
            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/File1.cpp")) {
                $0 <<< "void foo() {}\n"
                $0 <<< "\n"
                $0 <<< "void bar() {\n"
                $0 <<< "  foo();\n"
                $0 <<< "}\n"
                $0 <<< "\n"
                $0 <<< "void baz() {}\n"
                $0 <<< "\n"
                $0 <<< "void test_call() {\n"
                $0 <<< "  bar();\n"
                $0 <<< "  baz();\n"
                $0 <<< "}\n"
            }
            try await tester.checkBuild(runDestination: .host) { results in
                try results.checkTask(.matchRuleType("CompileC")) { task throws in
                    let objectPath = try #require(task.outputPaths.first { $0.str.hasSuffix(".o") })
                    let expectedJsonPath = objectPath.dirname.join(objectPath.basenameWithoutSuffix + ".json").str
                    task.checkCommandLineContains(["--ssaf-extract-summaries=CallGraph"])
                    task.checkCommandLineContains(["--ssaf-tu-summary-file=\(expectedJsonPath)"])

                    let jsonBytes = try tester.fs.read(Path(expectedJsonPath))
                    let jsonData = Data(jsonBytes.bytes)
                    let parsed = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]

                    // Build id -> USR lookup; entity IDs are assigned non-deterministically
                    let idTable = parsed["id_table"] as! [[String: Any]]
                    var idToUSR: [Int: String] = [:]
                    for entry in idTable {
                        let id = entry["id"] as! Int
                        let nameInfo = entry["name"] as! [String: Any]
                        idToUSR[id] = (nameInfo["usr"] as! String)
                    }

                    // Resolve call graph by USR so comparisons are ID-order-independent
                    let dataArr = parsed["data"] as! [[String: Any]]
                    let callGraph = try #require(dataArr.first { ($0["summary_name"] as? String) == "CallGraph" })
                    let summaryData = callGraph["summary_data"] as! [[String: Any]]

                    var prettyNameByUSR: [String: String] = [:]
                    var defLineByUSR: [String: Int] = [:]
                    var calleesByUSR: [String: [String]] = [:]
                    for entry in summaryData {
                        let entityId = entry["entity_id"] as! Int
                        let summary = entry["entity_summary"] as! [String: Any]
                        let def = summary["def"] as! [String: Any]
                        let callees = (summary["direct_callees"] as! [[String: Any]])
                            .compactMap { idToUSR[$0["@"] as! Int] }
                            .sorted()
                        guard let usr = idToUSR[entityId] else { continue }
                        prettyNameByUSR[usr] = (summary["pretty_name"] as! String)
                        defLineByUSR[usr] = (def["line"] as! Int)
                        calleesByUSR[usr] = callees
                    }

                    let tuNamespace = parsed["tu_namespace"] as! [String: Any]
                    #expect((tuNamespace["name"] as! String).hasSuffix("/Test/aProject/File1.cpp"))

                    #expect(prettyNameByUSR["c:@F@foo#"] == "foo()")
                    #expect(defLineByUSR["c:@F@foo#"] == 1)
                    #expect(calleesByUSR["c:@F@foo#"] == [])

                    #expect(prettyNameByUSR["c:@F@bar#"] == "bar()")
                    #expect(defLineByUSR["c:@F@bar#"] == 3)
                    #expect(calleesByUSR["c:@F@bar#"] == ["c:@F@foo#"])

                    #expect(prettyNameByUSR["c:@F@baz#"] == "baz()")
                    #expect(defLineByUSR["c:@F@baz#"] == 7)
                    #expect(calleesByUSR["c:@F@baz#"] == [])

                    #expect(prettyNameByUSR["c:@F@test_call#"] == "test_call()")
                    #expect(defLineByUSR["c:@F@test_call#"] == 9)
                    #expect(calleesByUSR["c:@F@test_call#"] == ["c:@F@bar#", "c:@F@baz#"])
                }
                results.checkNoDiagnostics()
            }
        }

        // INVOKE_SSAF=NO: neither SSAF flag is present.
        try await withTemporaryDirectory { tmpDirPath in
            let tester = try await BuildOperationTester(getCore(), makeTestWorkspace(tmpDirPath, invokeSSAF: "NO"), simulated: false)
            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/File1.cpp")) {
                $0 <<< "void foo() {}\n"
                $0 <<< "\n"
                $0 <<< "void bar() {\n"
                $0 <<< "  foo();\n"
                $0 <<< "}\n"
                $0 <<< "\n"
                $0 <<< "void baz() {}\n"
                $0 <<< "\n"
                $0 <<< "void test_call() {\n"
                $0 <<< "  bar();\n"
                $0 <<< "  baz();\n"
                $0 <<< "}\n"
            }
            try await tester.checkBuild(runDestination: .host) { results in
                results.checkTask(.matchRuleType("CompileC")) { task in
                    task.checkCommandLineNoMatch([.prefix("--ssaf-extract-summaries=")])
                    task.checkCommandLineNoMatch([.prefix("--ssaf-tu-summary-file=")])
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.host))
    func extractSummariesValuePassedThrough() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [TestFile("File1.c")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INVOKE_SSAF": "YES",
                                "EXTRACT_SUMMARIES": "codegen",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Test",
                                type: .dynamicLibrary,
                                buildPhases: [TestSourcesBuildPhase(["File1.c"])])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: true)
            try await tester.checkBuild(runDestination: .host) { results in
                results.checkTask(.matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains(["--ssaf-extract-summaries=codegen"])
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.host))
    func avoidEmitModuleSourceInfo() async throws {
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
                                TestFile("Foo.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGNING_ALLOWED": "NO",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "OTHER_SWIFT_FLAGS": "-avoid-emit-module-source-info",
                                    "SWIFT_VERSION": "5",
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "library",
                                type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase(["Foo.swift"]),
                                ])
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Foo.swift")) {
                $0 <<< "public struct Foo {}\n"
            }

            try await tester.checkBuild(runDestination: .host) { results in
                // The .swiftsourceinfo file should not be copied when -avoid-emit-module-source-info is set, and the build should succeed.
                results.checkNoTask(.matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".swiftsourceinfo")))
                results.checkNoDiagnostics()
            }
        }
    }
}
