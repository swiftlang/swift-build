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
}
