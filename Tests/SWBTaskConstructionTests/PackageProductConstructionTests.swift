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

import SWBCore
import SWBProtocol
import SWBTaskConstruction
import SWBUtil
import SWBTestSupport

/// Task construction tests related to the custom package product target.
@Suite
fileprivate struct PackageProductConstructionTests: CoreBasedTests {
    /// Check the basic behaviors of the package product target.
    @Test(.requireSDKs(.macOS))
    func basics() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.c"),
                    TestFile("d.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "CODE_SIGNING_ALLOWED": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO"]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool", type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"]),
                        TestFrameworksBuildPhase([
                            "libBEGIN.a",
                            // Duplicate references to the same product should be ignored.
                            TestBuildFile(.target("SomePackageProduct")),
                            TestBuildFile(.target("SomePackageProduct")),
                            // Duplicates *within* the product should also be ignored.
                            TestBuildFile(.target("OtherPackageProduct")),
                            // Add a package which has transitive references through a static library.
                            TestBuildFile(.target("PackageProductWithTransitiveRefs")),
                            "libEND.a"]),
                    ],
                    dependencies: [
                        "SomePackageProduct",
                        "SwiftyJSON",
                        "PackageProductWithTransitiveRefs",
                    ]),
                TestStandardTarget(
                    "D", type: .staticLibrary,
                    buildConfigurations: [],
                    buildPhases: [
                        TestSourcesBuildPhase(["d.c"])
                    ]),
            ])
        let testPackage = try await TestPackageProject(
            "Package",
            groupTree: TestGroup(
                "OtherFiles",
                children: [
                    TestFile("foo.c"),
                    TestFile("libBEGIN.a"),
                    TestFile("libEND.a"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO"]),
            ],
            targets: [
                TestPackageProductTarget(
                    "SomePackageProduct",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("A"))]),
                    dependencies: ["A"]),
                TestPackageProductTarget(
                    "OtherPackageProduct",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("A"))]),
                    dependencies: ["A"]),
                TestPackageProductTarget(
                    "NestedPackagedProduct",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("B"))]),
                    dependencies: ["B"]),
                TestPackageProductTarget(
                    "PackageProductWithTransitiveRefs",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        // This is redundant in the place it is used.
                        TestBuildFile(.target("SomePackageProduct")),
                        // This is a package product which should add more transitive refs.
                        TestBuildFile(.target("NestedPackagedProduct")),
                        // This is a static library which should also add more transitive refs.
                        TestBuildFile(.target("C")),
                        // This is an object file which should also add more transitive refs.
                        TestBuildFile(.target("E"))]),
                    dependencies: ["SomePackageProduct", "NestedPackageProduct", "C", "E"]),
                TestStandardTarget(
                    "A", type: .staticLibrary,
                    buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
                TestStandardTarget(
                    "B", type: .staticLibrary,
                    buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
                TestStandardTarget(
                    "C", type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("C_Impl"))])],
                    dependencies: ["C_Impl"]),
                TestStandardTarget(
                    "C_Impl", type: .staticLibrary,
                    buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
                TestPackageProductTarget(
                    "SwiftyJSON",
                    frameworksBuildPhase: TestFrameworksBuildPhase([]),
                    buildConfigurations: [],
                    dependencies: ["D"]),
                TestStandardTarget(
                    "E", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("F"))])
                    ], dependencies: ["F"]),
                TestStandardTarget(
                    "F", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"])
                    ]),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject, testPackage])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Release"), runDestination: .macOS, targetName: "Tool") { results in
            results.checkWarning(.contains("missing target configuration for 'D' (in target 'D' from project 'aProject')"))
            results.checkNoDiagnostics()
            results.checkTarget("Tool") { target in
                // Check that the product reference of a package product "sees through" it to the constituent libraries.
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    #expect(task.commandLine.contains(["-lBEGIN", "/tmp/aWorkspace/Package/build/Release/libA.a", "/tmp/aWorkspace/Package/build/Release/libB.a", "/tmp/aWorkspace/Package/build/Release/libC.a", "/tmp/aWorkspace/Package/build/Release/libC_Impl.a", "-lEND"]), "unexpected linker command line: \(task.commandLineAsStrings.quotedDescription)")
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Tool.LinkFileList")) { task, contents in
                    #expect(contents == "/tmp/aWorkspace/aProject/build/aProject.build/Release/Tool.build/Objects-normal/x86_64/main.o\n/tmp/aWorkspace/Package/build/Release/E.o\n/tmp/aWorkspace/Package/build/Release/F.o\n")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func canLinkUsingObjectOnlyFrameworkBuildPhase() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Utility.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                ]),
            ],
            targets: [
                TestAggregateTarget(
                    "ALL",
                    dependencies: ["DynamicUtility", "DynamicJSON"]),

                TestStandardTarget(
                    "DynamicUtility", type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Utility"))
                        ]),
                    ],
                    dependencies: ["Utility"]),

                TestStandardTarget(
                    "DynamicJSON", type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("PackageProduct::SwiftyJSON")),
                        ]),
                    ],
                    dependencies: [
                        "PackageProduct::SwiftyJSON",
                    ]),

                TestStandardTarget(
                    "Utility", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase(["Utility.swift"])
                    ]),
            ])
        let testPackage = try await TestPackageProject(
            "Package",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SwiftyJSON.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                ]),
            ],
            targets: [
                TestPackageProductTarget(
                    "PackageProduct::SwiftyJSON",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("SwiftyJSON"))]),
                    dependencies: ["SwiftyJSON"]),

                TestStandardTarget(
                    "SwiftyJSON", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift"])
                    ]),
            ]
        )
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject, testPackage])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("DynamicJSON") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkCommandLineContains(["-o", "/tmp/aWorkspace/aProject/build/Debug/DynamicJSON.dylib", "/tmp/aWorkspace/Package/build/Package.build/Debug/SwiftyJSON.build/Objects-normal/x86_64/SwiftyJSON.swiftmodule"])

                    task.checkCommandLineNoMatch([.any, "-Xlinker", "-add_ast_path", "-Xlinker", "/tmp/aWorkspace/aProject/build/aProject.build/Debug/DynamicJSON.build/Objects-normal/x86_64/DynamicJSON.swiftmodule", .any])
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("DynamicJSON.LinkFileList")) { task, contents in
                    #expect(contents == "/tmp/aWorkspace/Package/build/Debug/SwiftyJSON.o\n")
                }
            }
        }

        // Check deployment build.
        try await withTemporaryDirectory { tmpDir in
            let parameters = BuildParameters(configuration: "Debug", overrides: [
                "DSTROOT": tmpDir.join("dst").str,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
            ])

            await tester.checkBuild(parameters, runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                results.checkTarget("DynamicJSON") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SymLink")) { task in
                        task.checkCommandLineContains(["../UninstalledProducts/macosx/DynamicJSON.dylib", "/tmp/aWorkspace/aProject/build/Debug/DynamicJSON.dylib"])
                    }
                }

                results.checkTarget("DynamicUtility") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SymLink")) { task in
                        task.checkCommandLineContains(["../UninstalledProducts/macosx/DynamicUtility.dylib", "/tmp/aWorkspace/aProject/build/Debug/DynamicUtility.dylib"])
                    }
                }
            }

            // Check multi arch build.
            let overrides = [
                "ARCHS": "x86_64 x86_64h",
                "VALID_ARCHS": "$(inherited) x86_64h",
            ]
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: overrides), runDestination: .anyMac) { results in
                results.checkNoDiagnostics()
                results.checkTarget("SwiftyJSON") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkCommandLineContains(["/tmp/aWorkspace/Package/build/Package.build/Debug/SwiftyJSON.build/Objects-normal/x86_64/Binary/SwiftyJSON.o", "/tmp/aWorkspace/Package/build/Package.build/Debug/SwiftyJSON.build/Objects-normal/x86_64h/Binary/SwiftyJSON.o", "-output", "/tmp/aWorkspace/Package/build/Debug/SwiftyJSON.o"])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func moduleMapGeneration() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("clib.c"),
                    TestGroup(
                        "clib",
                        children: [
                            TestFile("clib.h"),
                        ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO"]),
            ],
            targets: [
                TestStandardTarget(
                    "tool", type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("clib")),
                        ]),
                    ],
                    dependencies: [
                        "clib",
                    ]),

                TestStandardTarget(
                    "clib", type: .objectFile,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "USE_HEADERMAP": "NO",
                            "DEFINES_MODULE": "YES",
                            "MODULEMAP_FILE_CONTENTS": "foo",
                            "MODULEMAP_PATH": "$(BUILT_PRODUCTS_DIR)/somewhere/test.modulemap",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["clib.c"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("clib") { target in
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("test.modulemap")) { task, contents in
                    #expect(contents == "foo")
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("test.modulemap")) { task in
                    #expect(task.outputs.map{$0.path.str} == ["/tmp/Test/aProject/build/Debug/somewhere/test.modulemap"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func unsafeFlags() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "tool", type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("SwiftyJSON")),
                        ]),
                    ],
                    dependencies: [
                        "SwiftyJSON",
                    ]),
            ])
        let testPackage = try await TestPackageProject(
            "Package",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SwiftyJSON.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                ]),
            ],
            targets: [
                TestPackageProductTarget(
                    "SwiftyJSON",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("PACKAGE::SwiftyJSON"))]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "USES_SWIFTPM_UNSAFE_FLAGS": "YES",
                        ]),
                    ],
                    dependencies: ["PACKAGE::SwiftyJSON"]),

                TestStandardTarget(
                    "PACKAGE::SwiftyJSON", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift"])
                    ]),
            ]
        )
        let testWorkspace = TestWorkspace("Test", projects: [testProject, testPackage])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkError("[targetIntegrity] The package product 'SwiftyJSON' cannot be used as a dependency of this target because it uses unsafe build flags. (in target 'tool' from project 'aProject')")
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func bundleLoader() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SwiftyJSON.swift"),
                    TestFile("SwiftyJSONTests.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "CODE_SIGN_IDENTITY": "",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                    "MACOSX_DEPLOYMENT_TARGET": "10.15",
                    "IPHONEOS_DEPLOYMENT_TARGET": "13.0",
                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    "SUPPORTS_MACCATALYST": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "SwiftJSONTests", type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "BUNDLE_LOADER[sdk=macosx*]": "$(BUILT_PRODUCTS_DIR)/SwiftyJSON.app/Contents/MacOS/SwiftyJSON",
                            "BUNDLE_LOADER": "$(BUILT_PRODUCTS_DIR)/SwiftyJSON.app/SwiftyJSON",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSONTests.swift"]),
                    ],
                    dependencies: [
                        "SwiftyJSON",
                    ]),

                TestStandardTarget(
                    "SwiftyJSON", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", impartedBuildProperties: TestImpartedBuildProperties(buildSettings: [
                            "OTHER_SWIFT_FLAGS": "-Isome/path",
                        ]))
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift"]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        for destination in [RunDestinationInfo.iOS, .macOS, .macCatalyst] {
            await tester.checkBuild(runDestination: destination) { results in
                results.checkNoDiagnostics()
                results.checkTarget("SwiftJSONTests") { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileSwiftSources")) { tasks in
                        for task in tasks {
                            task.checkCommandLineContains(["-Isome/path"])

                            // Also check that the destination is correctly applied.
                            switch destination {
                            case .iOS:
                                task.checkCommandLineMatches([.suffix("-apple-ios13.0")])
                            case .macOS:
                                task.checkCommandLineMatches([.suffix("-apple-macos10.15")])
                            case .macCatalyst:
                                task.checkCommandLineMatches([.suffix("-apple-ios13.1-macabi")])
                            default:
                                assertionFailure("Unhandled destination \(destination)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func invalidDeploymentTargets() async throws {
        let testProject = try await TestPackageProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SwiftyJSON.swift"),
                    TestFile("fmwk.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "ENTITLEMENTS_REQUIRED": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                    "SUPPORTS_MACCATALYST": "YES",
                    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "fmwk", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MACOSX_DEPLOYMENT_TARGET": "10.13",
                            "IPHONEOS_DEPLOYMENT_TARGET": "13.0", // NOTE: *effective* deployment target is clamped to 13.1 for Mac Catalyst
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["fmwk.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("SwiftyJSON")),
                        ]),
                    ],
                    dependencies: [
                        "SwiftyJSON",
                        "SwiftyJSONImpl"
                    ]),

                TestPackageProductTarget(
                    "SwiftyJSON",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("PACKAGE::SwiftyJSON"))]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MACOSX_DEPLOYMENT_TARGET": "10.14",
                            "IPHONEOS_DEPLOYMENT_TARGET": "13.2",
                            "SDKROOT": "auto",
                            "SDK_VARIANT": "auto",
                        ]),
                    ],
                    dependencies: ["PACKAGE::SwiftyJSON"]),

                TestStandardTarget(
                    "PACKAGE::SwiftyJSON", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift"])
                    ]),

                TestPackageProductTarget(
                    "SwiftyJSONImpl",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("PACKAGE::SwiftyJSONImpl"))]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MACOSX_DEPLOYMENT_TARGET": "11.0",
                            "IPHONEOS_DEPLOYMENT_TARGET": "13.2",
                            "SDKROOT": "auto",
                            "SDK_VARIANT": "auto",
                        ]),
                    ],
                    dependencies: ["PACKAGE::SwiftyJSONImpl"]),

                TestStandardTarget(
                    "PACKAGE::SwiftyJSONImpl", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkError("[targetIntegrity] The package product 'SwiftyJSONImpl' requires minimum platform version 11.0 for the macOS platform, but this target supports 10.13 (in target 'fmwk' from project 'aProject')")
            results.checkError("[targetIntegrity] The package product 'SwiftyJSON' requires minimum platform version 10.14 for the macOS platform, but this target supports 10.13 (in target 'fmwk' from project 'aProject')")
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(runDestination: .iOS) { results in
            results.checkError("[targetIntegrity] The package product 'SwiftyJSONImpl' requires minimum platform version 13.2 for the iOS platform, but this target supports 13.0 (in target 'fmwk' from project 'aProject')")
            results.checkError("[targetIntegrity] The package product 'SwiftyJSON' requires minimum platform version 13.2 for the iOS platform, but this target supports 13.0 (in target 'fmwk' from project 'aProject')")
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(runDestination: .iOSSimulator) { results in
            results.checkError("[targetIntegrity] The package product 'SwiftyJSONImpl' requires minimum platform version 13.2 for the iOS platform, but this target supports 13.0 (in target 'fmwk' from project 'aProject')")
            results.checkError("[targetIntegrity] The package product 'SwiftyJSON' requires minimum platform version 13.2 for the iOS platform, but this target supports 13.0 (in target 'fmwk' from project 'aProject')")
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(runDestination: .macCatalyst) { results in
            results.checkError("[targetIntegrity] The package product 'SwiftyJSONImpl' requires minimum platform version 13.2 for the Mac Catalyst platform, but this target supports 13.1 (in target 'fmwk' from project 'aProject')")
            results.checkError("[targetIntegrity] The package product 'SwiftyJSON' requires minimum platform version 13.2 for the Mac Catalyst platform, but this target supports 13.1 (in target 'fmwk' from project 'aProject')")
            results.checkNoDiagnostics()
        }
    }

    func commandLineDynamicLibraryTarget(name: String, buildSettings: [String:String]) -> TestStandardTarget {
        TestStandardTarget(
            name,
            type: .dynamicLibrary, // we need to choose a product type that is supported on all platforms; so tool, for example, doesn't work
            buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": name,
                                                                                   "ONLY_ACTIVE_ARCH": "YES",
                                                                                   "USE_HEADERMAP": "NO",
                                                                                   "CODE_SIGN_IDENTITY": "",
                                                                                   "ENTITLEMENTS_REQUIRED": "NO",
                                                                                  ].merging(buildSettings, uniquingKeysWith: { a, _ in
                                                                                      Issue.record("should not be reached")
                                                                                      return a
                                                                                  })) ],
            buildPhases: [ TestSourcesBuildPhase(["best.c"]),
                           TestFrameworksBuildPhase([TestBuildFile("PackageLib.o")]) ],
            dependencies: ["PackageLibProduct"]
        )
    }

    func findInput(for name: String, in tasks: GenericSequence<any PlannedTask>) -> (any PlannedNode)? {
        guard let task = tasks.filter({ $0.outputs.first?.path.basename == name }).first else {
            Issue.record("could not find linker tasks for \(name)")
            return nil
        }

        guard let input = task.inputs.filter({ $0.path.basename.hasSuffix("PackageLib.o") }).first else {
            Issue.record("could not find linked package lib in linker task for \(name)")
            return nil
        }

        return input
    }

    @Test(.requireSDKs(.macOS))
    func packageProductReferences() async throws {
        let core = try await getCore()
        let allPlatforms = core.platformRegistry.platforms.filter { !$0.isSimulator && core.sdkRegistry.lookup($0.name) != nil }
        #expect(allPlatforms.count > 0) // ensure we don't just pass this test because we somehow ended up with no platforms
        let targets = allPlatforms.map { $0.name }.map {
            commandLineDynamicLibraryTarget(name: "\($0)Lib", buildSettings: ["SDKROOT": $0])
        }
        let macCatalystTarget = try ProcessInfo.processInfo.hostOperatingSystem() == .macOS ? commandLineDynamicLibraryTarget(name: "MacCatalystLib", buildSettings: ["SDKROOT": "macosx", "SDK_VARIANT": MacCatalystInfo.sdkVariantName]) : nil
        let almostAllTargets = targets + (macCatalystTarget.map { [$0] } ?? [])
        let allTargets = [TestAggregateTarget("ALL", dependencies: almostAllTargets.map { $0.name })] + almostAllTargets.map { $0 as (any TestTarget) }

        let package = TestPackageProject("aPackage", groupTree: TestGroup("Package", children: [TestFile("test.c")]), targets: [
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
                               ]) ],
                               buildPhases: [TestSourcesBuildPhase(["test.c"])])
        ])

        let workspace = TestWorkspace("Workspace", projects: [TestProject("aProject", groupTree: TestGroup("SomeFiles", children: [TestFile("best.c")]), targets: allTargets), package])
        let tester = try await TaskConstructionTester(getCore(), workspace)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["EXCLUDED_ARCHS": "i386 i686 x86_64 armv7 armv7k arm64_32 arm64e riscv64"]), runDestination: .host) { results in
            results.checkNoDiagnostics()

            results.checkTasks(.matchRuleType("Ld")) { tasks in
                let frameworkLinkerTasks = tasks.filter { $0.outputs.first?.path.basename.hasSuffix("Lib.dylib") == true || $0.outputs.first?.path.basename.hasSuffix("Lib.so") == true }
                #expect(frameworkLinkerTasks.count == allPlatforms.count + (macCatalystTarget != nil ? 1 : 0))

                for platform in allPlatforms {
                    let dylibSuffix = core.sdkRegistry.lookup(platform.name)?.defaultVariant?.llvmTargetTripleVendor == "apple" ? "dylib" : "so"
                    guard let input = findInput(for: "\(platform.name)Lib.\(dylibSuffix)", in: tasks) else {
                        return
                    }

                    if platform.name == "macosx" {
                        #expect(input.path.str.hasSuffix("Debug/PackageLib.o"), "incorrect linker input path for \(platform.name): \(input.path.str)")
                    } else {
                        #expect(input.path.str.hasSuffix("Debug-\(platform.name)/PackageLib.o"), "incorrect linker input path for \(platform.name): \(input.path.str)")
                    }
                }

                if macCatalystTarget != nil {
                    // Check package got specialized correctly for MacCatalyst.
                    guard let input = findInput(for: "MacCatalystLib.dylib", in: tasks) else {
                        return // `findInput()` will already error if there's no matching task or input
                    }
                    #expect(input.path.str.hasSuffix("Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/PackageLib.o"), "incorrect linker input path for MacCatalyst: \(input.path.str)")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func linkageGraphHasAllLevelTargets() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SwiftyJSON.swift"),
                    TestFile("SwiftyJSONTests.swift"),
                    TestFile("Network.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "CODE_SIGN_IDENTITY": "",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "SwiftyJSONTests", type: .unitTest,
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSONTests.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Network")),
                        ]),
                    ],
                    dependencies: [
                        "SwiftyJSON",
                        "Network",
                    ]),

                TestStandardTarget(
                    "SwiftyJSON", type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Network")),
                        ]),
                    ],
                    dependencies: [
                        "Network",
                    ]),
                TestStandardTarget(
                    "Network", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", impartedBuildProperties: TestImpartedBuildProperties(buildSettings: [
                            "OTHER_SWIFT_FLAGS": "-Isome/path",
                        ])),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Network.swift"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("SwiftyJSONTests") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-Isome/path"])
                }
            }
            results.checkTarget("SwiftyJSON") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-Isome/path"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func objCHeaderGenerationWithModuleMapContents() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "DEFINES_MODULE": "YES",
                    "USE_HEADERMAP": "NO"]),
            ],
            targets: [
                TestStandardTarget(
                    "foo", type: .objectFile,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MODULEMAP_FILE_CONTENTS": "foo",
                            "SWIFT_OBJC_INTERFACE_HEADER_NAME": "Foo-Swift.h",
                            "MODULEMAP_PATH": "$(BUILT_PRODUCTS_DIR)/somewhere/test.modulemap",
                            "SWIFT_OBJC_INTERFACE_HEADER_DIR": "$(BUILT_PRODUCTS_DIR)/somewhere",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.swift"])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget("foo") { target in
                // Make sure Swift Build doesn't append anything to the explicitly provided module map contents.
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("test.modulemap")) { task, contents in
                    #expect(contents == "foo")
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("test.modulemap")) { task in
                    #expect(task.outputs.map{$0.path.str} == ["/tmp/Test/aProject/build/Debug/somewhere/test.modulemap"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("Foo-Swift.h")) { task in
                    #expect(task.outputs.map{$0.path.str} == ["/tmp/Test/aProject/build/Debug/somewhere/Foo-Swift.h"])
                }

                // Make sure we don't get the unextended module VFS overlay and import underlying module for pure Swift target which wants to emit a modulemap using MODULEMAP_FILE_CONTENTS setting.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineNoMatch([.anySequence, "-import-underlying-module", "-Xcc", "-ivfsoverlay", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/foo.build/unextended-module-overlay.yaml", .anySequence])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func resourceEmbedInCodeGeneration() async throws {
        let testProject = try await TestPackageProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("best.txt"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "GENERATE_EMBED_IN_CODE_ACCESSORS": "YES",
                    "USE_HEADERMAP": "NO"]),
            ],
            targets: [
                TestStandardTarget(
                    "tool",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestCopyFilesBuildPhase([TestBuildFile(.file("best.txt"), resourceRule: .embedInCode)], destinationSubfolder: .builtProductsDir),
                    ]
                ),
            ]
        )
        let tester = try await TaskConstructionTester(getCore(), testProject)

        if let sourceRoot = tester.workspace.projects.first?.sourceRoot {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: sourceRoot.str), withIntermediateDirectories: true)
            try "hello world".write(to: URL(fileURLWithPath: "\(sourceRoot.str)/best.txt"), atomically: true, encoding: .utf8)
        }

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("tool") { target in
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("embedded_resources.swift")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("static let best_txt: [UInt8] ="))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func resourceBundleAccessorGeneration() async throws {
        let testProject = try await TestPackageProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("main.m"),
                    TestFile("Assets.xcassets"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ASSETCATALOG_EXEC": "$(DEVELOPER_DIR)/usr/bin/actool",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "GENERATE_RESOURCE_ACCESSORS": "YES",
                    "USE_HEADERMAP": "NO"]),
            ],
            targets: [
                TestAggregateTarget(
                    "ALL",
                    dependencies: ["tool", "objctool",
                                   "tool_without_resource_bundle_without_catalog",
                                   "tool_without_resource_bundle_with_catalog"]
                ),
                TestStandardTarget(
                    "tool", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "USE_HEADERMAP": "NO",
                            "DEFINES_MODULE": "YES",
                            "PACKAGE_RESOURCE_BUNDLE_NAME": "tool_resources",
                            "EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES": "tool_resources",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestFrameworksBuildPhase([TestBuildFile(.target("toolslib"))]),
                    ],
                    dependencies: ["mallory", "toolslib"]
                ),
                TestStandardTarget(
                    "objctool", type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "USE_HEADERMAP": "NO",
                            "DEFINES_MODULE": "YES",
                            "PACKAGE_RESOURCE_BUNDLE_NAME": "tool_resources",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.m"]),
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
                            "PACKAGE_RESOURCE_BUNDLE_NAME":
                                """
                                "
                                print("/etc/passwd")
                                _ = "
                                """,
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                    ]
                ),
                TestStandardTarget(
                    "toolslib", type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "PACKAGE_RESOURCE_BUNDLE_NAME": "tools_resources",
                        ], impartedBuildProperties: TestImpartedBuildProperties(buildSettings: [
                            "EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES": "$(inherited) tool_resources",
                        ]))
                    ]
                ),
                TestStandardTarget(
                    "tool_without_resource_bundle_without_catalog", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "USE_HEADERMAP": "NO",
                            "DEFINES_MODULE": "YES",
                            "PACKAGE_RESOURCE_TARGET_KIND": "regular",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestFrameworksBuildPhase([TestBuildFile(.target("toolslib"))]),
                    ],
                    dependencies: ["mallory", "toolslib"]
                ),
                TestStandardTarget(
                    "tool_without_resource_bundle_with_catalog", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "USE_HEADERMAP": "NO",
                            "DEFINES_MODULE": "YES",
                            "PACKAGE_RESOURCE_TARGET_KIND": "regular",
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestResourcesBuildPhase(["Assets.xcassets"]),
                        TestFrameworksBuildPhase([TestBuildFile(.target("toolslib"))]),
                    ],
                    dependencies: ["mallory", "toolslib"]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("tool") { target in
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("resource_bundle_accessor.swift")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("static let module: Bundle"))
                    XCTAssertMatch(contents.unsafeStringValue, .contains("let bundleName = \"tool_resources\""))
                }
            }

            results.checkTarget("objctool") { target in
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("resource_bundle_accessor.m")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("NSBundle* tool_resources_SWIFTPM_MODULE_BUNDLE()"))
                    XCTAssertMatch(contents.unsafeStringValue, .contains("NSString *bundleName = @\"tool_resources\";"))
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("resource_bundle_accessor.h")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("__BEGIN_DECLS"))
                    XCTAssertMatch(contents.unsafeStringValue, .contains("#define SWIFTPM_MODULE_BUNDLE tool_resources_SWIFTPM_MODULE_BUNDLE()"))
                }

                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("main.m")) { task in
                    task.checkCommandLineContains(["-include", "/tmp/Test/aProject/build/aProject.build/Debug/objctool.build/DerivedSources/resource_bundle_accessor.h"])
                }
            }

            results.checkTarget("mallory") { target in
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("resource_bundle_accessor.swift")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("static let module: Bundle"))

                    // Make sure our string injection attack was foiled
                    XCTAssertMatch(contents.unsafeStringValue, .contains("let bundleName = \"\\\"\\nprint(\\\"/etc/passwd\\\")\\n_ = \\\"\""))
                }
            }

            // Packages that don't have resource bundles or asset catalogs shouldn't generate a resource bundle accessor or they'll opt projects into importing Foundation.
            results.checkTarget("tool_without_resource_bundle_without_catalog") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("resource_bundle_accessor.swift"))
            }

            // Playground apps won't have a resource bundle but they will have asset catalogs, so they should get a resource bundle accessor.
            results.checkTarget("tool_without_resource_bundle_with_catalog") { target in
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("resource_bundle_accessor.swift")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("static let module = {"))
                    XCTAssertMatch(contents.unsafeStringValue, .not(.contains("let bundleName = \"tool_resources\"")))
                    XCTAssertMatch(contents.unsafeStringValue, .not(.contains("let bundleName = \"tools_resources\"")))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func packageResourceBundleEmbedding() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SwiftyJSON.swift"),
                    TestFile("app.swift"),
                    TestFile("appex.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                    "MACOSX_DEPLOYMENT_TARGET": "10.15",
                    "IPHONEOS_DEPLOYMENT_TARGET": "13.0",
                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    "SUPPORTS_MACCATALYST": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "app", type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["app.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("SwiftyJSON"))
                        ]),
                    ],
                    dependencies: [
                        "appex",
                        "SwiftyJSON",
                    ]),

                TestStandardTarget(
                    "appex", type: .applicationExtension,
                    buildPhases: [
                        TestSourcesBuildPhase(["appex.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("SwiftyJSON"))
                        ]),
                    ],
                    dependencies: [
                        "SwiftyJSON",
                    ]),

                TestStandardTarget(
                    "SwiftyJSON", type: .objectFile,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", impartedBuildProperties: TestImpartedBuildProperties(buildSettings: [
                            "EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES": "FOO",
                        ])),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift"]),
                    ],
                    dependencies: [
                        "FOO",
                    ]),

                TestStandardTarget(
                    "FOO", type: .bundle
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("app") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FOO.bundle")) { task in
                    task.checkCommandLineContains(["/tmp/Test/aProject/build/Debug/FOO.bundle", "/tmp/Test/aProject/build/Debug/app.app/Contents/Resources"])
                }
            }
            results.checkTarget("appex") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FOO.bundle")) { task in
                    task.checkCommandLineContains(["/tmp/Test/aProject/build/Debug/appex.appex/Contents/Resources"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageResourceCoreData() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SwiftyJSON.swift"),
                    TestFile("CoreDataModel.xcdatamodeld"),
                    TestFile("CoreDataMapping.xcmappingmodel"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                    "MACOSX_DEPLOYMENT_TARGET": "10.15",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "SwiftyJSON", type: .objectFile,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PACKAGE_RESOURCE_TARGET_KIND": "regular",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift", "CoreDataModel.xcdatamodeld"]),
                    ],
                    dependencies: [
                        "SwiftyJSON_RESOURCES",
                    ]),

                TestStandardTarget(
                    "SwiftyJSON_RESOURCES", type: .bundle,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PACKAGE_RESOURCE_TARGET_KIND": "resource",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase(["CoreDataModel.xcdatamodeld", "CoreDataMapping.xcmappingmodel"]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        /// Client to generate files from the core data model.
        final class TestCoreDataCompilerTaskPlanningClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
            override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                if commandLine.first.map(Path.init)?.basename == "momc", let outputDir = commandLine.last.map(Path.init) {
                    return .result(status: .exit(0), stdout: Data([
                        outputDir.join("EntityOne+CoreDataClass.swift"),
                        outputDir.join("EntityOne+CoreDataProperties.swift"),
                    ].map { $0.str }.joined(separator: "\n").utf8), stderr: .init())
                }
                return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
            }
        }

        await tester.checkBuild(runDestination: .macOS, clientDelegate: TestCoreDataCompilerTaskPlanningClientDelegate()) { results in
            results.checkNoDiagnostics()
            results.checkTarget("SwiftyJSON") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("DataModelCompile"))
                results.checkTask(.matchTarget(target), .matchRuleType("DataModelCodegen")) { task in
                    task.checkCommandLineContains(["--module", "SwiftyJSON"])
                }
            }
            results.checkTarget("SwiftyJSON_RESOURCES") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("DataModelCodegen"))
                results.checkTask(.matchTarget(target), .matchRuleType("DataModelCompile")) { task in
                    task.checkCommandLineContains(["momc", "/tmp/Test/aProject/CoreDataModel.xcdatamodeld", "/tmp/Test/aProject/build/Debug/SwiftyJSON_RESOURCES.bundle/Contents/Resources/"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("MappingModelCompile")) { task in
                    task.checkCommandLineContains(["mapc", "/tmp/Test/aProject/CoreDataMapping.xcmappingmodel", "/tmp/Test/aProject/build/Debug/SwiftyJSON_RESOURCES.bundle/Contents/Resources/CoreDataMapping.cdm"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func packageProductCannotBeInStandardTarget() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SwiftyJSON.swift"),
                    TestFile("main.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "SWIFT_VERSION": "4.2",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "SKIP_INSTALL": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "tool", type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("SwiftyJSON")),
                        ]),
                    ],
                    dependencies: [
                        "SwiftyJSON",
                    ]),
                TestPackageProductTarget(
                    "SwiftyJSON",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("PACKAGE::SwiftyJSON"))]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "USES_SWIFTPM_UNSAFE_FLAGS": "YES",
                        ]),
                    ],
                    dependencies: ["PACKAGE::SwiftyJSON"]),

                TestStandardTarget(
                    "PACKAGE::SwiftyJSON", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase(["SwiftyJSON.swift"])
                    ]),
            ])
        await #expect(throws: (any Error).self, "package target 'SwiftyJSON' must be contained within a package") {
            try await TaskConstructionTester(getCore(), testProject)
        }
    }
}
