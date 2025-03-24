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

import SwiftBuildTestSupport
import SWBTestSupport

import SWBBuildSystem
import SWBCore
import SWBProtocol
import class SWBTaskConstruction.ProductPlan
import SWBUtil

@Suite
fileprivate struct HostBuildToolBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func buildingHostTools() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup("Foo", children: [
                    TestFile("dep.swift"),
                    TestFile("tool.swift"),
                    TestFile("frame.swift"),
                ]), buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "DSTROOT": tmpDirPath.join("dstroot").str,
                            "SWIFT_VERSION": swiftVersion,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget("HostToolDependency", type: .staticLibrary, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                                "MACOSX_DEPLOYMENT_TARGET": "$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)"
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["dep.swift"])
                    ]),
                    TestStandardTarget("HostTool", type: .hostBuildTool, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "MACOSX_DEPLOYMENT_TARGET": "$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)"
                            ])], buildPhases: [
                                TestSourcesBuildPhase(["tool.swift"]),
                                TestFrameworksBuildPhase(["libHostToolDependency.a"])
                            ], dependencies: [
                                "HostToolDependency"
                            ]),
                    TestStandardTarget("Framework", type: .framework, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                                "SUPPORTS_MACCATALYST": "YES",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["frame.swift"]),
                        TestShellScriptBuildPhase(name: "Script", shellPath: "/bin/bash", originalObjectID: "Script", contents: "${SCRIPT_INPUT_FILE_0} > ${SCRIPT_OUTPUT_FILE_0}",
                                                  inputs: ["$(BUILD_DIR)/$(CONFIGURATION)/HostTool"], outputs: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/HostToolGeneratedResource.txt"], alwaysOutOfDate: false),
                    ], dependencies: [
                        "HostTool"
                    ]),
                ]
            )
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath.join("Test"), projects: [testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/dep.swift")) { stream in
                stream <<<
                """
                public let frameworkMessage = "Hello from host lib!"
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.swift")) { stream in
                stream <<<
                """
                import HostToolDependency

                @main struct Foo {
                    static func main() {
                        print("Hello from host tool!")
                        print(frameworkMessage)
                    }
                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/frame.swift")) { stream in
                stream <<<
                """
                public class MyClass {

                }
                """
            }

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.targets(named: "Framework")[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            try await tester.checkBuild(runDestination: .anyMac, buildRequest: request) { results throws in
                results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkNoDiagnostics()

                // Test we successfully used the host tool to produce resources for the framework.
                #expect(try tester.fs.read(tmpDirPath.join("Test/aProject/build/Debug/Framework.framework/Resources/HostToolGeneratedResource.txt")).unsafeStringValue == "Hello from host tool!\nHello from host lib!\n")
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }

            // Run the same test with an iOS destination.
            try await tester.checkBuild(runDestination: .anyiOSDevice, buildRequest: request) { results throws in
                results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkNoDiagnostics()

                // Test we successfully used the host tool to produce resources for the framework.
                #expect(try tester.fs.read(tmpDirPath.join("Test/aProject/build/Debug-iphoneos/Framework.framework/HostToolGeneratedResource.txt")).unsafeStringValue == "Hello from host tool!\nHello from host lib!\n")
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }

            // Run the same test with a Catalyst destination.
            try await tester.checkBuild(runDestination: .anyMacCatalyst, buildRequest: request) { results throws in
                results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkNoDiagnostics()

                // Test we successfully used the host tool to produce resources for the framework.
                #expect(try tester.fs.read(tmpDirPath.join("Test/aProject/build/Debug-maccatalyst/Framework.framework/Resources/HostToolGeneratedResource.txt")).unsafeStringValue == "Hello from host tool!\nHello from host lib!\n")
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func hostToolsAndDependenciesAreBuiltDuringIndexingPreparation_Mac() async throws {
        try await testHostToolsAndDependenciesAreBuiltDuringIndexingPreparation(destination: .anyMac)
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func hostToolsAndDependenciesAreBuiltDuringIndexingPreparation_MacCatalyst() async throws {
        try await testHostToolsAndDependenciesAreBuiltDuringIndexingPreparation(destination: .anyMacCatalyst)
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func hostToolsAndDependenciesAreBuiltDuringIndexingPreparation_iOS() async throws {
        try await testHostToolsAndDependenciesAreBuiltDuringIndexingPreparation(destination: .anyiOSDevice)
    }

    func testHostToolsAndDependenciesAreBuiltDuringIndexingPreparation(destination: RunDestinationInfo) async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let depPackage = try await TestPackageProject(
                "DepPackage",
                groupTree: TestGroup("Foo", children: [
                    TestFile("transitivedep.swift"),
                    TestFile("dep.swift"),
                ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SWIFT_VERSION": swiftVersion,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget("TransitivePackageDep", type: .objectFile, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ],
                            impartedBuildProperties:
                                TestImpartedBuildProperties(
                                    buildSettings: [
                                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "IMPARTED_SETTINGS"
                                    ])
                        ),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["transitivedep.swift"])
                    ]),
                    TestStandardTarget("PackageDep", type: .staticLibrary, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["dep.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("TransitivePackageDep"))
                        ])
                    ], dependencies: [
                        "TransitivePackageDep"
                    ]),
                    TestPackageProductTarget("PackageDepProduct", frameworksBuildPhase:
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("PackageDep")),
                        ]
                    ), buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], dependencies: [
                        "PackageDep"
                    ]),
            ])

            let hostToolsPackage = try await TestPackageProject(
                "HostToolsPackage",
                groupTree: TestGroup("Foo", children: [
                    TestFile("tool.swift"),
                    TestFile("lib.swift"),
                ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SWIFT_VERSION": swiftVersion,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget("HostTool", type: .hostBuildTool, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                            ])
                    ], buildPhases: [
                        TestSourcesBuildPhase(["tool.swift"]),
                        TestFrameworksBuildPhase([TestBuildFile(.target("PackageDepProduct"))])
                    ], dependencies: [
                        "PackageDepProduct"
                    ]),
                    TestStandardTarget("HostToolClientLib", type: .objectFile, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["lib.swift"]),
                    ], dependencies: [
                        "HostTool"
                    ]),
                    TestPackageProductTarget("HostToolClientLibProduct", frameworksBuildPhase:
                        TestFrameworksBuildPhase([TestBuildFile(.target("HostToolClientLib"))]
                    ), buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], dependencies: [
                        "HostToolClientLib"
                    ]),
            ])

            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup("Foo", children: [
                    TestFile("frame.swift"),
                    TestFile("app.swift")
                ]), buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SWIFT_VERSION": swiftVersion,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget("Framework", type: .framework, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["frame.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("HostToolClientLibProduct"))
                        ]),
                    ], dependencies: [
                        "HostToolClientLibProduct"
                    ]),
                    TestStandardTarget("App", type: .application, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["app.swift"]),
                    ], dependencies: [
                        "Framework"
                    ]),
                ]
            )
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath.join("Test"), projects: [depPackage, hostToolsPackage, testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, systemInfo: .init(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: Architecture.host.stringValue ?? "undefined_arch"))

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("DepPackage/transitivedep.swift")) { stream in
                stream <<<
                """
                public let transitiveDependencyMessage = "Hello from host tool transitive dependency!"
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("DepPackage/dep.swift")) { stream in
                stream <<<
                """
                import TransitivePackageDep

                public let dependencyMessage = "Hello from host tool dependency! " + transitiveDependencyMessage
                #if !IMPARTED_SETTINGS
                #error("settings not imparted")
                #endif
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("HostToolsPackage/tool.swift")) { stream in
                stream <<<
                """
                import PackageDep

                @main struct Foo {
                    static func main() {
                        print("Hello from host tool! " + dependencyMessage)
                    }
                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("HostToolsPackage/lib.swift")) { stream in
                stream <<<
                """
                public class MyClass {}
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/frame.swift")) { stream in
                stream <<<
                """
                import HostToolClientLib

                public class MyClass2 {}
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/app.swift")) { stream in
                stream <<<
                """
                print("Hello, world!")
                """
            }

            try await tester.checkIndexBuild(prepareTargets: testProject.targets.map(\.guid), runDestination: destination, persistent: true) { results in
                results.checkWarning(.contains("annotation implies no releases, but consumes self"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkNoDiagnostics()
                // The host tool's transitive dependency should compile.
                results.checkTask(.matchTargetName("TransitivePackageDep"), .matchRuleItem("SwiftDriver Compilation")) { task in
                    // Check the host tool transitive dependency builds for macOS
                    task.checkCommandLineMatches(["-target", .contains("-apple-macos")])
                }
                results.checkTaskExists(.matchTargetName("TransitivePackageDep"), .matchRuleType("Ld"))
                // The host tool's dependency should compile.
                results.checkTask(.matchTargetName("PackageDep"), .matchRuleType("SwiftDriver Compilation")) { task in
                    // Check the host tool dependency builds for macOS
                    task.checkCommandLineMatches(["-target", .contains("-apple-macos")])
                }
                results.checkTaskExists(.matchTargetName("PackageDep"), .matchRuleType("Libtool"))
                // The host tool itself should also compile and link. It's prepared-for-index-precompilation node should depend on the have a dependency on the linker output of the dependency.
                results.checkTask(.matchTargetName("HostTool"), .matchRuleType("SwiftDriver Compilation")) { task in
                    // Check the host tool builds for macOS
                    task.checkCommandLineMatches(["-target", .contains("-apple-macos")])
                }
                results.checkTaskExists(.matchTargetName("HostTool"), .matchRuleType("Ld"))
                try results.checkTask(.matchTargetName("HostTool"), .matchRuleType(ProductPlan.preparedForIndexPreCompilationRuleName)) { task in
                    try results.checkTaskFollows(task, .matchTargetName("PackageDep"), .matchRuleType("Libtool"))
                }
                // The lib + framework should generate a module, and should not link. Prepared-for-index-precompilation of the lib which uses a host tool should follow linking the host tool.
                results.checkTaskExists(.matchTargetName("HostToolClientLib"), .matchRuleType("SwiftDriver GenerateModule"))
                results.checkNoTask(.matchTargetName("HostToolClientLib"), .matchRuleType("Ld"))
                try results.checkTask(.matchTargetName("HostToolClientLib"), .matchRuleType(ProductPlan.preparedForIndexPreCompilationRuleName)) { task in
                    try results.checkTaskFollows(task, .matchTargetName("HostTool"), .matchRuleType("Ld"))
                }
                results.checkTaskExists(.matchTargetName("Framework"), .matchRuleType("SwiftDriver GenerateModule"))
                results.checkNoTask(.matchTargetName("Framework"), .matchRuleType("Ld"))
                // The app should not compile, generate a module, or link.
                results.checkNoTask(.matchTargetName("App"), .matchRuleType("SwiftDriver Compilation"))
                results.checkNoTask(.matchTargetName("App"), .matchRuleType("SwiftDriver GenerateModule"))
                results.checkNoTask(.matchTargetName("App"), .matchRuleType("Ld"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func hostToolsAreSkippedDuringIndexingPreparationWhenUnapproved() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup("Foo", children: [
                    TestFile("tool.swift"),
                    TestFile("frame.swift"),
                    TestFile("otherframe.swift"),
                    TestFile("app.swift")
                ]), buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SWIFT_VERSION": swiftVersion,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget("HostTool", type: .hostBuildTool, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                            ])], buildPhases: [
                                TestSourcesBuildPhase(["tool.swift"]),
                            ], approvedByUser: false),
                    TestStandardTarget("Framework", type: .framework, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["frame.swift"]),
                    ], dependencies: [
                        "HostTool"
                    ]),
                    TestStandardTarget("OtherFramework", type: .framework, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["otherframe.swift"]),
                    ], dependencies: []),
                    TestStandardTarget("App", type: .application, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["app.swift"]),
                    ], dependencies: [
                        "Framework", "OtherFramework"
                    ]),
                ]
            )
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath.join("Test"), projects: [testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, systemInfo: .init(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: Architecture.host.stringValue ?? "undefined_arch"))

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.swift")) { stream in
                stream <<<
                """
                @main struct Foo {
                    static func main() {
                        print("Hello from host tool!")
                    }
                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/frame.swift")) { stream in
                stream <<<
                """
                public class MyClass {

                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/otherframe.swift")) { stream in
                stream <<<
                """
                public class MyClass2 {

                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/app.swift")) { stream in
                stream <<<
                """
                print("Hello, world!")
                """
            }

            try await tester.checkIndexBuildGraph(targets: testProject.targets) { results in
                results.delegate.checkDiagnostics(format: .debug, ["\(testWorkspace.sourceRoot.str)/aProject/aProject.xcodeproj:\(try testWorkspace.findTarget(name: "HostTool", project: nil).guid): warning: [targetMissingUserApproval] Target \'HostTool\' must be enabled before it can be used."])
            }

            try await tester.checkIndexBuild(prepareTargets: testProject.targets.map(\.guid), runDestination: .anyMac, persistent: true) { results in
                results.checkWarning(.and(.prefix("unable to get timestamp"), .contains("HostTool-preparedForIndex-target")))
                results.checkNoDiagnostics()
                // The host tool is unapproved, so none of it's tasks should run.
                results.checkNoTask(.matchTargetName("HostTool"))
                // The two frameworks should generate a module, and should not link. Prepared-for-index-precompilation of the framework which uses a host tool should follow linking the host tool.
                results.checkTaskExists(.matchTargetName("Framework"), .matchRuleType("SwiftDriver GenerateModule"))
                results.checkNoTask(.matchTargetName("Framework"), .matchRuleType("Ld"))
                try results.checkTask(.matchTargetName("Framework"), .matchRuleType(ProductPlan.preparedForIndexPreCompilationRuleName)) { task in
                    try results.checkTaskFollows(task, .matchTargetName("HostTool"), .matchRuleType("Ld"))
                }
                results.checkTaskExists(.matchTargetName("OtherFramework"), .matchRuleType("SwiftDriver GenerateModule"))
                results.checkNoTask(.matchTargetName("OtherFramework"), .matchRuleType("Ld"))
                // The app should not compile, generate a module, or link.
                results.checkNoTask(.matchTargetName("App"), .matchRuleType("SwiftDriver Compilation"))
                results.checkNoTask(.matchTargetName("App"), .matchRuleType("SwiftDriver GenerateModule"))
                results.checkNoTask(.matchTargetName("App"), .matchRuleType("Ld"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func hostToolsAreNotFullyBuiltWhenNotPreparingDependents() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup("Foo", children: [
                    TestFile("tool.swift"),
                    TestFile("frame.swift"),
                ]), buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SWIFT_VERSION": swiftVersion,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget("HostTool", type: .hostBuildTool, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                            ])], buildPhases: [
                                TestSourcesBuildPhase(["tool.swift"]),
                            ], dependencies: []),
                    TestStandardTarget("Framework", type: .framework, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["frame.swift"]),
                    ], dependencies: [
                        "HostTool"
                    ]),
                ]
            )
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath.join("Test"), projects: [testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, systemInfo: BuildOperationTester.defaultSystemInfo)

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.swift")) { stream in
                stream <<<
                """
                @main struct Foo {
                    static func main() {
                        print("Hello from host tool!")
                    }
                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/frame.swift")) { stream in
                stream <<<
                """
                public class MyClass {

                }
                """
            }

            try await tester.checkIndexBuild(prepareTargets: tester.workspace.targets(named: "HostTool").map(\.guid), runDestination: .anyMac, persistent: true) { results in
                results.checkNoDiagnostics()
                // None of the dependents of the host tool are being prepared, so only the prepared-for-index-precompilation tasks should run.
                results.checkNoTask(.matchTargetName("HostTool"), .matchRuleType("SwiftDriver Compilation"))
                results.checkNoTask(.matchTargetName("HostTool"), .matchRuleType("Ld"))
                results.checkTaskExists(.matchTargetName("HostTool"), .matchRulePattern(["WriteAuxiliaryFile", .suffix("HostTool-OutputFileMap.json")]))
                results.checkTaskExists(.matchTargetName("HostTool"), .matchRuleType(ProductPlan.preparedForIndexPreCompilationRuleName))

                // No tasks for 'Framework' should run, we're only preparing the host tool.
                results.checkNoTask(.matchTargetName("Framework"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func hostToolBuildFailuresDoNotBlockDownstreamModuleGenerationDuringIndexPreparation() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup("Foo", children: [
                    TestFile("tool.swift"),
                    TestFile("toolinterface.swift"),
                    TestFile("client.swift"),
                ]), buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SWIFT_VERSION": swiftVersion,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget("HostTool", type: .hostBuildTool, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES": "HostToolInterface",
                            ])], buildPhases: [
                                TestSourcesBuildPhase(["tool.swift"]),
                            ]),
                    TestStandardTarget("HostToolInterface", type: .framework, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["toolinterface.swift"]),
                    ], dependencies: [
                        "HostTool"
                    ]),
                    TestStandardTarget("Client", type: .framework, buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            ]),
                    ], buildPhases: [
                        TestSourcesBuildPhase(["client.swift"]),
                        TestFrameworksBuildPhase(["HostToolInterface.framework"])
                    ], dependencies: [
                        "HostToolInterface"
                    ]),
                ]
            )
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath.join("Test"), projects: [testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, systemInfo: .init(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: Architecture.host.stringValue ?? "undefined_arch"))

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.swift")) { stream in
                stream <<<
                """
                not a valid program!
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/toolinterface.swift")) { stream in
                stream <<<
                """
                public let x = 42
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/client.swift")) { stream in
                stream <<<
                """
                import HostToolInterface
                func f() {
                    print(x)
                }
                """
            }

            try await tester.checkIndexBuild(prepareTargets: tester.workspace.targets(named: "Client").map(\.guid), runDestination: .macOS, persistent: true) { results in
                // Even though building the host tool failed, we should still have a task to generate the interface's module, which may still succeed.
                results.checkTaskExists(.matchTargetName("HostToolInterface"), .matchRuleType("SwiftDriver GenerateModule"))
                // The build will emit diagnostics, but as long as we generated the host tool interface module we'll have some semantic editor functionality.
                results.checkedErrors = true
                results.checkedWarnings = true
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func toolsConsumedByScriptPhasesAreBuiltDuringIndexingPreparation() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup("Foo", children: [
                    TestFile("tool.swift"),
                    TestFile("frame.swift"),
                ]), buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SWIFT_VERSION": swiftVersion,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget("Tool", type: .commandLineTool, buildConfigurations: [
                        TestBuildConfiguration("Debug")
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["tool.swift"]),
                    ]),
                    TestStandardTarget("Framework", type: .framework, buildConfigurations: [
                        TestBuildConfiguration("Debug")
                    ], buildPhases: [
                        TestShellScriptBuildPhase(name: "UsesTool",
                                                  shellPath: "/bin/zsh",
                                                  originalObjectID: "UsesTool",
                                                  contents: "${SCRIPT_INPUT_FILE_0} > ${SCRIPT_INPUT_FILE_0}",
                                                  inputs: [tmpDirPath.join("Test/Index.noindex/Build/Products/Debug/Tool").str],
                                                  outputs: [tmpDirPath.join("scriptoutput").str]),
                        TestSourcesBuildPhase(["frame.swift"]),
                    ], dependencies: [
                        "Tool"
                    ]),
                ]
            )
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath.join("Test"), projects: [testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, systemInfo: .init(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: Architecture.host.stringValue ?? "undefined_arch"))

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.swift")) { stream in
                stream <<<
                """
                @main struct Foo {
                    static func main() {
                        print("Hello from tool!")
                    }
                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/frame.swift")) { stream in
                stream <<<
                """
                public class MyClass {

                }
                """
            }

            try await tester.checkIndexBuild(prepareTargets: tester.workspace.targets(named: "Framework").map(\.guid), runDestination: .host, persistent: true) { results in
                results.checkNoDiagnostics()

                // The tool itself should compile and link.
                results.checkTaskExists(.matchTargetName("Tool"), .matchRuleType("SwiftDriver Compilation"))
                results.checkTask(.matchTargetName("Tool"), .matchRuleType("Ld")) { task in
                    task.checkCommandLineMatches(["-target", .contains("-apple-macos")])
                }

                try results.checkTask(.matchTargetName("Framework"), .matchRuleType(ProductPlan.preparedForIndexPreCompilationRuleName)) { task in
                    try results.checkTaskFollows(task, .matchTargetName("Tool"), .matchRuleType("Ld"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func toolsConsumedByCustomTasksPreparingForIndexingAreBuiltDuringIndexingPreparation() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup("Foo", children: [
                    TestFile("tool.swift"),
                    TestFile("frame.swift"),
                ]), buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SWIFT_VERSION": swiftVersion,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget("Tool", type: .commandLineTool, buildConfigurations: [
                        TestBuildConfiguration("Debug")
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["tool.swift"]),
                    ]),
                    TestStandardTarget("Framework", type: .framework, buildConfigurations: [
                        TestBuildConfiguration("Debug")
                    ], buildPhases: [
                        TestSourcesBuildPhase(["frame.swift"]),
                    ], customTasks: [
                        TestCustomTask(commandLine: [tmpDirPath.join("Test/Index.noindex/Build/Products/Debug/Tool").str, tmpDirPath.join("scriptoutput").str],
                                       environment: [:],
                                       workingDirectory: tmpDirPath.str,
                                       executionDescription: "Running Tool",
                                       inputs: [tmpDirPath.join("Test/Index.noindex/Build/Products/Debug/Tool").str],
                                       outputs: [tmpDirPath.join("output").str],
                                       enableSandboxing: false,
                                       preparesForIndexing: true)
                    ],
                    dependencies: [
                        "Tool"
                    ]),
                ]
            )

            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath.join("Test"), projects: [testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, systemInfo: .init(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: Architecture.host.stringValue ?? "undefined_arch"))

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/tool.swift")) { stream in
                stream <<<
                """
                import Foundation
                @main struct Foo {
                    static func main() throws {
                        try "hello, world!".write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
                    }
                }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/frame.swift")) { stream in
                stream <<<
                """
                public class MyClass {

                }
                """
            }

            try await tester.checkIndexBuild(prepareTargets: tester.workspace.targets(named: "Framework").map(\.guid), runDestination: .host, persistent: true) { results in
                results.checkNoDiagnostics()

                // The tool itself should compile and link.
                results.checkTaskExists(.matchTargetName("Tool"), .matchRuleType("SwiftDriver Compilation"))
                results.checkTask(.matchTargetName("Tool"), .matchRuleType("Ld")) { task in
                    task.checkCommandLineMatches(["-target", .contains("-apple-macos")])
                }

                try results.checkTask(.matchTargetName("Framework"), .matchRuleType(ProductPlan.preparedForIndexPreCompilationRuleName)) { task in
                    try results.checkTaskFollows(task, .matchTargetName("Tool"), .matchRuleType("Ld"))
                }
            }
        }
    }
}
