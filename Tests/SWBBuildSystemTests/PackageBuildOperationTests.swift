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

import struct Foundation.OperatingSystemVersion
import class Foundation.ProcessInfo

import Testing

import SwiftBuild
import SwiftBuildTestSupport
import func SWBBuildService.commandLineDisplayString
import SWBBuildSystem
import SWBCore
import struct SWBProtocol.RunDestinationInfo
import struct SWBProtocol.TargetDescription
import struct SWBProtocol.TargetDependencyRelationship
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SWBTestSupport

@Suite
fileprivate struct PackageBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func packageResourcesSwift() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestPackageProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "CODE_SIGNING_ALLOWED": "NO",
                        "GENERATE_RESOURCE_ACCESSORS": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": "5"]),
                ],
                targets: [
                    TestStandardTarget(
                        "swifttool", type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "PACKAGE_RESOURCE_BUNDLE_NAME": "best_resources",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                        ],
                        dependencies: ["mallory"]
                    ),
                    TestStandardTarget(
                        "mallory", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "PACKAGE_RESOURCE_BUNDLE_NAME": "best_resources",
                            ]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false, fileSystem: localFS)

            let projectDir = tester.workspace.projects[0].sourceRoot
            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<<
                    """
                    import Foundation

                    let bundle = Bundle.module
                    guard let foo = bundle.path(forResource: "foo", ofType: "txt") else {
                        fatalError("couldn't find foo")
                    }
                    print(foo)
                    """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageResourcesObjCPP() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestPackageProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.mm"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "CODE_SIGNING_ALLOWED": "NO",
                        "GENERATE_RESOURCE_ACCESSORS": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "USE_HEADERMAP": "NO"]),
                ],
                targets: [
                    TestStandardTarget(
                        "objcpptool", type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                "DEFINES_MODULE": "YES",
                                "PACKAGE_RESOURCE_BUNDLE_NAME": "best_resources",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.mm"]),
                        ],
                        dependencies: ["mallory"]
                    ),
                    TestStandardTarget(
                        "mallory", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_HEADERMAP": "NO",
                                "DEFINES_MODULE": "YES",
                                "PACKAGE_RESOURCE_BUNDLE_NAME": "best_resources",
                            ]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false, fileSystem: localFS)

            let projectDir = tester.workspace.projects[0].sourceRoot
            try await tester.fs.writeFileContents(projectDir.join("main.mm")) { stream in
                stream <<<
                    """
                    #import <Foundation/Foundation.h>

                    int main(int argc, const char * argv[]) {
                        @autoreleasepool {
                            NSBundle *bundle = SWIFTPM_MODULE_BUNDLE;
                            NSString *foo = [bundle pathForResource:@"foo" ofType:@"txt"];
                            printf("%s", foo.UTF8String);
                        }
                        return 0;
                    }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    /// Check that an .rkassets bundle gets an incremental build.
    @Test(.requireSDKs(.xrOS), .disabled(if: !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)), "rdar://129991610"), .disabled(if: getEnvironmentVariable("CI")?.isEmpty == false))
    func RKAssetsIncrementalRebuild() async throws {
        // FIXME: We should be able to test this in simulation. For that, we need BuildDescription support for knowing which tasks are safe to run in simulation.
        let core = try await getCore()
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            // Test that an incremental rebuild of a .rkassets bundle occurs when a swift file in its package is changed.
            // Targets need to opt-in to specialization.
            let packageResourceTarget = try await TestStandardTarget(
                "PackageResourceBundle",
                type: .bundle,
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "PackageLib",
                            "SDKROOT": "xros",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SWIFT_VERSION": swiftVersion,
                            "PACKAGE_RESOURCE_TARGET_KIND": "resource"
                        ]
                    )
                ],
                buildPhases: [TestResourcesBuildPhase(["test.rkassets"])]
            )
            let packageTarget = try await TestStandardTarget(
                "PackageLib",
                type: .objectFile,
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "PackageLib",
                            "SDKROOT": "xros",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SWIFT_VERSION": swiftVersion,
                            "PACKAGE_RESOURCE_TARGET_KIND": "regular"
                        ]
                    )
                ],
                buildPhases: [TestSourcesBuildPhase(["main.swift", "test.swift"])],
                dependencies: ["PackageResourceBundle"]
            )
            let packageProject = TestPackageProject(
                "aProject",
                groupTree: TestGroup("Package", children: [TestFile("main.swift"), TestFile("test.swift"), TestFile("test.rkassets")]),
                targets: [packageTarget, packageResourceTarget]
            )
            let workspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [packageProject]
            )
            let tester = try await BuildOperationTester(getCore(), workspace, simulated: false)
            let projectRoot = workspace.sourceRoot.join("aProject")
            let packageSwiftFileMain = projectRoot.join("main.swift")
            let packageSwiftFileTest = projectRoot.join("test.swift")
            let packageRKAssetsFile = projectRoot.join("test.rkassets")

            // Create the input files.
            try tester.fs.createDirectory(projectRoot, recursive: true)
            try tester.fs.write(packageSwiftFileMain, contents: "")
            try tester.fs.write(packageSwiftFileTest, contents: "")
            try tester.fs.createDirectory(packageRKAssetsFile)

            // Check initial build did swift compile, preprocess, and built .rkassets
            try await tester.checkBuild(runDestination: .xrOS, persistent: true) { results in
                results.checkNoErrors()

                results.checkTask(.matchRuleType("SwiftCompile"), .matchRuleItemPattern(.contains("main.swift"))) { _ in }
                results.checkTask(.matchRuleType("SwiftCompile"), .matchRuleItemPattern(.contains("test.swift"))) { _ in }

                try results.checkTask(.matchRuleType("RealityAssetsCompile")) { task in
                    task.checkCommandLineContainsUninterrupted([
                        core.developerPath.path.join("usr/bin/realitytool").str, "compile", "--platform", "xros", "--deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                        "-o", "\(workspace.sourceRoot.str)/aProject/build/Debug-xros/PackageLib.bundle/test.reality",
                        "\(packageRKAssetsFile.str)",
                        "--schema-file",
                        "\(workspace.sourceRoot.str)/aProject/build/aProject.build/Debug-xros/PackageResourceBundle.build/DerivedSources/RealityAssetsGenerated/CustomComponentUSDInitializers.usda"
                    ])
                    try results.checkTaskFollows(task, .matchRuleType("RealityAssetsSchemaGen"))
                }

                results.checkNoDiagnostics()
            }

            // modify the test.swift file in the package with the .rkassets so the schema file changes
            try tester.fs.write(packageSwiftFileTest, contents: """
            import RealityKit
            public struct MyComponent: Component, Codable {
                public init() {}
            }
            """)

            // Check that the next build is NOT null after touching the .swift file.
            try await tester.checkBuild(runDestination: .xrOS, persistent: true) { results in
                results.checkNoErrors()

                results.checkTask(.matchRuleType("SwiftCompile"), .matchRuleItemPattern(.contains("test.swift"))) { _ in }

                try results.checkTask(.matchRuleType("RealityAssetsCompile")) { task in
                    task.checkCommandLineContainsUninterrupted([
                        core.developerPath.path.join("usr/bin/realitytool").str, "compile", "--platform", "xros", "--deployment-target", results.runDestinationSDK.defaultDeploymentTarget,
                        "-o", "\(workspace.sourceRoot.str)/aProject/build/Debug-xros/PackageLib.bundle/test.reality",
                        "\(packageRKAssetsFile.str)",
                        "--schema-file",
                        "\(workspace.sourceRoot.str)/aProject/build/aProject.build/Debug-xros/PackageResourceBundle.build/DerivedSources/RealityAssetsGenerated/CustomComponentUSDInitializers.usda"
                    ])
                    try results.checkTaskFollows(task, .matchRuleType("RealityAssetsSchemaGen"))
                }

                results.checkNoDiagnostics()
            }
        }
    }

    /// Check that an .rkassets bundle produces a reasonable error when building for an unsupported platform.
    @Test(.requireSDKs(.watchOS), .requireXcode16())
    func RKAssetsWrongPlatform() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let packageResourceTarget = try await TestStandardTarget(
                "PackageResourceBundle",
                type: .bundle,
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "PackageLib",
                            "SDKROOT": "watchos",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SWIFT_VERSION": swiftVersion,
                            "PACKAGE_RESOURCE_TARGET_KIND": "resource"
                        ]
                    )
                ],
                buildPhases: [TestResourcesBuildPhase(["test.rkassets"])]
            )
            let packageTarget = try await TestStandardTarget(
                "PackageLib",
                type: .objectFile,
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "PackageLib",
                            "SDKROOT": "watchos",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SWIFT_VERSION": swiftVersion,
                            "PACKAGE_RESOURCE_TARGET_KIND": "regular"
                        ]
                    )
                ],
                buildPhases: [TestSourcesBuildPhase(["main.swift", "test.swift"])],
                dependencies: ["PackageResourceBundle"]
            )
            let packageProject = TestPackageProject(
                "aProject",
                groupTree: TestGroup("Package", children: [TestFile("main.swift"), TestFile("test.swift"), TestFile("test.rkassets")]),
                targets: [packageTarget, packageResourceTarget]
            )
            let workspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [packageProject]
            )
            let tester = try await BuildOperationTester(getCore(), workspace, simulated: false)
            let projectRoot = workspace.sourceRoot.join("aProject")
            let packageSwiftFileMain = projectRoot.join("main.swift")
            let packageSwiftFileTest = projectRoot.join("test.swift")
            let packageRKAssetsFile = projectRoot.join("test.rkassets")

            // Create the input files.
            try tester.fs.createDirectory(projectRoot, recursive: true)
            try tester.fs.write(packageSwiftFileMain, contents: "")
            try tester.fs.write(packageSwiftFileTest, contents: "")
            try tester.fs.createDirectory(packageRKAssetsFile)

            try await tester.checkBuild(runDestination: .watchOS, persistent: true) { results in
                _ = results.checkTask(.matchRuleType("RealityAssetsCompile")) { task in
                    results.checkError(.regex(#/^Building for 'watchos', but realitytool only supports \[.*\]/#))
                    results.checkError(.prefix("Command RealityAssetsCompile failed."))
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageNameFlag() async throws {
        let swiftFeatures = try await self.swiftFeatures
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let configurationToBuild = "TestConfig"
            let prodTarget = try await TestPackageProductTarget(
                "AppProduct",
                frameworksBuildPhase: TestFrameworksBuildPhase([
                    TestBuildFile(.target("App"))]),
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
                ],
                dependencies: ["App"]
            )
            let appTarget =
            try await TestStandardTarget("App", type: .objectFile,
                                         buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: [
                                            "PRODUCT_NAME": "App",
                                            "SDKROOT": "auto",
                                            "SWIFT_PACKAGE_NAME": "appPkg",
                                            "SDK_VARIANT": "auto",
                                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                            "SWIFT_VERSION": swiftVersion,
                                         ]) ],
                                         buildPhases: [TestSourcesBuildPhase(["app.swift"]),
                                                       TestFrameworksBuildPhase([
                                                        TestBuildFile(.target("LibA")),
                                                        TestBuildFile(.target("LibB"))
                                                       ])],
                                         dependencies: ["LibA", "LibB"])
            let childTargetA =
            try await TestStandardTarget("LibA", type: .objectFile,
                                         buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: [
                                            "PRODUCT_NAME": "LibA",
                                            "SWIFT_PACKAGE_NAME": "libPkg",
                                            "SDKROOT": "auto",
                                            "SDK_VARIANT": "auto",
                                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                            "SWIFT_VERSION": swiftVersion,
                                         ]) ],
                                         buildPhases: [TestSourcesBuildPhase(["libA.swift"])])
            let childTargetB =
            try await TestStandardTarget("LibB", type: .objectFile,
                                         buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: [
                                            "PRODUCT_NAME": "LibB",
                                            "SDKROOT": "auto",
                                            "SDK_VARIANT": "auto",
                                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                            "SWIFT_VERSION": swiftVersion,
                                         ]) ],
                                         buildPhases: [TestSourcesBuildPhase(["libB.swift"])])

            let package = TestPackageProject("rootPkg", groupTree: TestGroup("Package", children: [TestFile("app.swift"), TestFile("libA.swift"), TestFile("libB.swift")]), targets: [prodTarget, appTarget, childTargetA, childTargetB])
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [package])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("rootPkg/app.swift")) { stream in
                stream.write("import LibA\nimport LibB")
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("rootPkg/libA.swift")) { stream in
                stream.write("public func p1() {}")
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("rootPkg/libB.swift")) { stream in
                stream.write("public func p2() {}")
            }

            let buildParams = BuildParameters(configuration: configurationToBuild)
            try await tester.checkBuild(parameters: buildParams, runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("SwiftCompile")) { tasks in
                    for task in tasks {
                        let targetName = task.forTarget?.target.name ?? ""
                        if targetName == "LibA" {
                            task.checkCommandLineContains(["-module-name", "LibA"])
                            if !swiftFeatures.has(.packageName) {
                                task.checkCommandLineDoesNotContain("-package-name")
                            } else {
                                task.checkCommandLineContains(["-package-name", "libPkg"])
                            }
                        }
                        if targetName == "LibB" {
                            task.checkCommandLineContains(["-module-name", "LibB"])
                            // This target is not built with package-name
                            task.checkCommandLineDoesNotContain("-package-name")
                        }
                        if targetName == "App" {
                            task.checkCommandLineContains(["-module-name", "App"])
                            if !swiftFeatures.has(.packageName) {
                                task.checkCommandLineDoesNotContain("-package-name")
                            } else {
                                task.checkCommandLineContains(["-package-name", "appPkg"])
                            }
                        }
                    }
                }
                results.checkNoErrors()
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageModuleAliasing() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let configurationToBuild = "TestConfig"
            let prodTarget = try await TestPackageProductTarget(
                "PackageLibProduct",
                frameworksBuildPhase: TestFrameworksBuildPhase([
                    TestBuildFile(.target("PackageLib"))]),
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
                ],
                dependencies: ["PackageLib"]
            )
            let stdTarget =
            try await TestStandardTarget("PackageLib", type: .objectFile,
                                         buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: [
                                            "PRODUCT_NAME": "PackageLib",
                                            "SDKROOT": "auto",
                                            "SWIFT_MODULE_ALIASES": "ChildLib=MyLib",
                                            "SDK_VARIANT": "auto",
                                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                            "SWIFT_VERSION": swiftVersion,
                                         ]) ],
                                         buildPhases: [TestSourcesBuildPhase(["test.swift"]),
                                                       TestFrameworksBuildPhase([TestBuildFile(.target("MyLib"))])],
                                         dependencies: ["MyLib"])
            let childTarget =
            try await TestStandardTarget("MyLib", type: .objectFile,
                                         buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: [
                                            "PRODUCT_NAME": "MyLib",
                                            "SWIFT_MODULE_ALIASES": "ChildLib=MyLib",
                                            "SDKROOT": "auto",
                                            "SDK_VARIANT": "auto",
                                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                            "SWIFT_VERSION": swiftVersion,
                                         ]) ],
                                         buildPhases: [TestSourcesBuildPhase(["childtest.swift"])])

            let package = TestPackageProject("aPackage", groupTree: TestGroup("Package", children: [TestFile("test.swift"), TestFile("childtest.swift")]), targets: [prodTarget, stdTarget, childTarget])
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [package])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aPackage/test.swift")) { stream in
                stream.write("import ChildLib")
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aPackage/childtest.swift")) { stream in
                stream.write("public func somefunc() {}")
            }

            let buildParams = BuildParameters(configuration: configurationToBuild)
            try await tester.checkBuild(parameters: buildParams, runDestination: .macOS, persistent: true) { results in
                results.checkTasks(.matchRuleType("SwiftCompile")) { tasks in
                    for task in tasks {
                        let targetName = task.forTarget?.target.name ?? ""
                        #expect(targetName != "ChildLib")
                        if targetName == "MyLib" {
                            #expect(["-module-name", "MyLib"].allSatisfy(task.commandLine.contains))
                            #expect(["-module-alias",  "ChildLib=MyLib"].allSatisfy(task.commandLine.contains))
                        }
                        if targetName == "PackageLib" {
                            #expect(["-module-name",  "PackageLib"].allSatisfy(task.commandLine.contains))
                            #expect(["-module-alias",  "ChildLib=MyLib"].allSatisfy(task.commandLine.contains))
                        }
                    }
                }
                results.checkTasks(.matchRuleType("SwiftEmitModule")) { tasks in
                    for task in tasks {
                        let targetName = task.forTarget?.target.name ?? ""
                        if targetName == "MyLib" {
                            #expect(["-module-name",  "MyLib"].allSatisfy(task.commandLine.contains))
                            #expect(["-module-alias",  "ChildLib=MyLib"].allSatisfy(task.commandLine.contains))
                            #expect(!task.commandLine.filter {$0.asString.contains("MyLib.swiftmodule")}.isEmpty)
                            #expect(task.commandLine.filter {$0.asString.contains("ChildLib.swiftmodule")}.isEmpty)
                        }
                        if targetName == "PackageLib" {
                            #expect(["-module-name",  "PackageLib"].allSatisfy(task.commandLine.contains))
                            #expect(["-module-alias",  "ChildLib=MyLib"].allSatisfy(task.commandLine.contains))
                            #expect(!task.commandLine.filter {$0.asString.contains("PackageLib.swiftmodule")}.isEmpty)
                        }
                    }
                }
                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }

                results.checkNoErrors()
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func overridingConfigurationNameForSwiftPackages() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let configurationToBuild = "BestDevelopment"
            let tester = try await testerForBasicPackageProject(tmpDirPath: tmpDirPath, configurationToBuild: configurationToBuild)
            let good = BuildParameters(configuration: configurationToBuild)
            try await tester.checkBuild(parameters: good, runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func workspacesWithPackagesCreatePackageFrameworksDirectoryEagerly() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let configurationToBuild = "BestDevelopment"
            let packageBuildDirectory = tmpDirPath.join("Test/aPackage/build")
            let projectBuildDirectory = tmpDirPath.join("Test/aProject/build")

            let expectedBuildDirectories = [
                packageBuildDirectory.str,
                packageBuildDirectory.join(configurationToBuild).str,
                packageBuildDirectory.join(configurationToBuild).join("PackageFrameworks").str,
                packageBuildDirectory.join("EagerLinkingTBDs").join(configurationToBuild).str,

                projectBuildDirectory.str,
                projectBuildDirectory.join(configurationToBuild).str,
                projectBuildDirectory.join(configurationToBuild).join("PackageFrameworks").str,
                projectBuildDirectory.join("EagerLinkingTBDs").join(configurationToBuild).str,
            ].sorted()

            let tester = try await testerForBasicPackageProject(tmpDirPath: tmpDirPath, configurationToBuild: configurationToBuild)
            let good = BuildParameters(configuration: configurationToBuild)
            try await tester.checkBuild(parameters: good, runDestination: .macOS, persistent: true) { results in
                results.checkNoErrors()

                // Check that there is a `CreateBuildDirectory` for each expected build directory.
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { tasks in
                    let createdBuildDirectoriesFromRuleInfo = tasks.compactMap { $0.ruleInfo.last }.sorted()
                    #expect(createdBuildDirectoriesFromRuleInfo == expectedBuildDirectories)
                }

                // Check that all expected build directories exist on disk.
                for dir in expectedBuildDirectories {
                    #expect(tester.fs.exists(Path(dir)))
                }
            }
        }
    }

    func testerForBasicPackageProject(tmpDirPath: Path, configurationToBuild: String) async throws -> BuildOperationTester {
        let package = try await TestPackageProject("aPackage", groupTree: TestGroup("Package", children: [TestFile("test.swift")]), targets: [
            TestPackageProductTarget(
                "PackageLibProduct",
                frameworksBuildPhase: TestFrameworksBuildPhase([
                    TestBuildFile(.target("PackageLib"))]),
                buildConfigurations: [
                    // Targets need to opt-in to specialization.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "auto",
                        "SDK_VARIANT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
                ],
                dependencies: ["PackageLib"]
            ),
            TestStandardTarget("PackageLib", type: .objectFile,
                               buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "PackageLib",
                                "SDKROOT": "auto",
                                "SDK_VARIANT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                "SWIFT_VERSION": swiftVersion,
                               ]) ],
                               buildPhases: [TestSourcesBuildPhase(["test.swift"])])
        ])

        let buildSettings = try await [
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SWIFT_VERSION": swiftVersion,
            // FIXME: This is very hacky, but unfortunately, `BuildOperationTester` doesn't set up a shared `BUILT_PRODUCTS_DIR` for the whole workspace.
            "SWIFT_INCLUDE_PATHS": "$(TARGET_BUILD_DIR)/../../../aPackage/build/\(configurationToBuild)",
        ]

        let testWorkspace = TestWorkspace(
            "Test",
            sourceRoot: tmpDirPath.join("Test"),
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup("Sources", children: [
                        TestFile("Source.swift"),
                    ]),
                    buildConfigurations: [
                        TestBuildConfiguration("BestDevelopment", buildSettings: buildSettings),
                        TestBuildConfiguration("BestDeployment", buildSettings: buildSettings),
                    ],
                    targets: [
                        TestStandardTarget(
                            "Foo", type: .framework,
                            buildConfigurations: [TestBuildConfiguration("Debug"), TestBuildConfiguration("Release")],
                            buildPhases: [
                                TestSourcesBuildPhase(["Source.swift"]),
                                TestFrameworksBuildPhase([
                                    TestBuildFile(.target("PackageLibProduct"))])
                            ],
                            dependencies: ["PackageLibProduct"])]), package])
        let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
        try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Source.swift")) { stream in
            stream.write("import PackageLib")
        }
        try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aPackage/test.swift")) { stream in }
        return tester
    }

}
