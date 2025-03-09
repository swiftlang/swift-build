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

@Suite
fileprivate struct ModuleMapTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func definesModuleOff() async throws {
        let testProject = await TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("ObjCOnly.h"),
                    TestFile("ObjCOnly.modulemap"),
                    TestFile("SwiftOnly.modulemap"),
                    TestFile("ObjCAndSwift.h"),
                    TestFile("ObjCAndSwift.modulemap"),
                    TestFile("ObjCAndSwift.private.modulemap"),
                    TestFile("SwiftSource.swift"),
                    TestFile("Info.plist"),
                ]),
            targets: [
                TestStandardTarget(
                    "ObjCOnly",
                    type: .framework,
                    buildConfigurations: [
                        // DEFINES_MODULE defaults to off.
                        try buildConfiguration(withName: "Default", extraSettings: [:]),
                        // If DEFINES_MODULE is off, don't generate a module map file, even when a juicy umbrella header is present.
                        try buildConfiguration(withName: "DefinesModuleNo", extraSettings: ["DEFINES_MODULE": "NO"]),
                        // Don't copy a module map file.
                        try buildConfiguration(withName: "ModuleFile", extraSettings: ["MODULEMAP_FILE": "ObjCOnly.modulemap"]),
                        // Don't write module map contents.
                        try buildConfiguration(withName: "ModuleContents", extraSettings: ["MODULEMAP_FILE_CONTENTS": "framework module ObjCOnly {}"]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ObjCOnly.h", headerVisibility: .public),
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "SwiftOnly",
                    type: .framework,
                    buildConfigurations: [
                        // If DEFINES_MODULE is off, don't generate a module map file, even when the Objective-C compatibility header is present.
                        try buildConfiguration(withName: "Default", extraSettings: [:]),
                        // Don't copy a module map file.
                        try buildConfiguration(withName: "ModuleFile", extraSettings: ["MODULEMAP_FILE": "SwiftOnly.modulemap"]),
                        // Don't write module map contents.
                        try buildConfiguration(withName: "ModuleContents", extraSettings: ["MODULEMAP_FILE_CONTENTS": "framework module SwiftOnly {}"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "ObjCAndSwift",
                    type: .framework,
                    buildConfigurations: [
                        // If DEFINES_MODULE is off, don't generate a module map file, even when the Objective-C compatibility header is present.
                        try buildConfiguration(withName: "Default", extraSettings: [:]),
                        // Don't copy a module map file.
                        try buildConfiguration(withName: "ModuleFile", extraSettings: [
                            "MODULEMAP_FILE": "ObjCAndSwift.modulemap",
                            "MODULEMAP_PRIVATE_FILE": "ObjCAndSwift.private.modulemap",
                        ]),
                        // Don't write module map contents.
                        try buildConfiguration(withName: "ModuleContents", extraSettings: ["MODULEMAP_FILE_CONTENTS": "framework module ObjCAndSwift {}"]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ObjCAndSwift.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let didNotCopyModuleMapFile = "[targetIntegrity] MODULEMAP_FILE has no effect if DEFINES_MODULE is not set"
        let didNotCopyPrivateModuleMapFile = "[targetIntegrity] MODULEMAP_PRIVATE_FILE has no effect if DEFINES_MODULE is not set"
        let didNotWriteModuleMapContents = "[targetIntegrity] MODULEMAP_FILE_CONTENTS has no effect if DEFINES_MODULE is not set"

        let builds = [("ObjCOnly", "Default", []),
                      ("ObjCOnly", "DefinesModuleNo", []),
                      ("ObjCOnly", "ModuleFile", [didNotCopyModuleMapFile]),
                      ("ObjCOnly", "ModuleContents", [didNotWriteModuleMapContents]),
                      ("SwiftOnly", "Default", []),
                      ("SwiftOnly", "ModuleFile", [didNotCopyModuleMapFile]),
                      ("SwiftOnly", "ModuleContents", [didNotWriteModuleMapContents]),
                      ("ObjCAndSwift", "Default", []),
                      ("ObjCAndSwift", "ModuleFile", [didNotCopyModuleMapFile, didNotCopyPrivateModuleMapFile]),
                      ("ObjCAndSwift", "ModuleContents", [didNotWriteModuleMapContents]),
        ]
        for (targetName, configurationName, warnings) in builds {
            await tester.checkBuild(BuildParameters(configuration: configurationName), runDestination: .macOS, targetName: targetName) { results in
                results.checkTarget(targetName) { target in
                    // The build directories are hard coded to "Debug" and don't use the configuration name being built.
                    let generatedModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/module.modulemap"
                    let installedModuleMap = "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Modules/module.modulemap"

                    // No module map is written.
                    results.checkNoTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", generatedModuleMap]))
                    // No module map is installed.
                    results.checkNoTask(.matchTarget(target), .matchRule(["Copy", installedModuleMap, generatedModuleMap]))

                    // Ignore expected tasks.
                    results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { _ in }
                    checkExpectedTasks(in: results, for: target)
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])
                // There should be warnings from the extra module build settings that don't have any effect,
                // but no task construction errors.
                for warning in warnings {
                    results.checkWarning(.prefix(warning))
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func dontInstallModule() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("SomeHeader.h"),
                    TestFile("ProjectInternalUmbrellaHeader.h"),
                    TestFile("SwiftSource.swift"),
                    TestFile("PrivateModuleOnly.private.modulemap"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "DEFINES_MODULE": "YES",
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                ])
            ],
            targets: [
                // Don't generate a module if there's no umbrella header.
                TestStandardTarget(
                    "NoUmbrellaHeader",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("SomeHeader.h", headerVisibility: .public),
                        ]),
                    ]
                ),
                // Don't generate a module if the thing that looks like an umbrella header is project internal.
                TestStandardTarget(
                    "ProjectInternalUmbrellaHeader",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            "ProjectInternalUmbrellaHeader.h",
                        ]),
                    ]
                ),
                // Don't generate a module if the Objective-C compatibility header isn't generated.
                TestStandardTarget(
                    "NoObjCCompatibilityHeader",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_OBJC_INTERFACE_HEADER_NAME": "",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
                // Don't generate a module if the Objective-C compatibility header isn't installed.
                TestStandardTarget(
                    "ObjCCompatibilityHeaderNotInstalled",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
                // Don't install the private module if there's no public module.
                TestStandardTarget(
                    "PrivateModuleOnly",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MODULEMAP_PRIVATE_FILE": "PrivateModuleOnly.private.modulemap",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("SomeHeader.h", headerVisibility: .private),
                        ]),
                    ]
                ),
                // Don't install the private module if there's no public module and the
                // Objective-C compatibility header isn't installed.
                TestStandardTarget(
                    "PrivateModuleInternalSwift",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "MODULEMAP_PRIVATE_FILE": "PrivateModuleOnly.private.modulemap",
                            "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("SomeHeader.h", headerVisibility: .private),
                        ]),
                        TestSourcesBuildPhase([
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let builds = [("NoUmbrellaHeader", false),
                      ("ProjectInternalUmbrellaHeader", false),
                      ("NoObjCCompatibilityHeader", false),
                      ("ObjCCompatibilityHeaderNotInstalled", false),
                      ("PrivateModuleOnly", true),
                      ("PrivateModuleInternalSwift", true),
        ]
        for (targetName, hasPrivateModuleMap) in builds {
            await tester.checkBuild(runDestination: .macOS, targetName: targetName) { results in
                results.checkTarget(targetName) { target in
                    let generatedModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/module.modulemap"
                    let installedModuleMap = "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Modules/module.modulemap"
                    let generatedPrivateModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/module.private.modulemap"
                    let installedPrivateModuleMap = "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Modules/module.private.modulemap"

                    results.checkNoTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", generatedModuleMap]))
                    results.checkNoTask(.matchTarget(target), .matchRule(["Copy", installedModuleMap, generatedModuleMap]))
                    results.checkNoTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", generatedPrivateModuleMap]))
                    results.checkNoTask(.matchTarget(target), .matchRule(["Copy", installedPrivateModuleMap, generatedPrivateModuleMap]))

                    results.checkTasks(.matchRuleType("SwiftDriver Compilation")) { _ in }
                    checkExpectedTasks(in: results, for: target)
                }

                #expect(results.otherTargets == [])
                results.checkWarning(.prefix("[targetIntegrity] DEFINES_MODULE was set, but no umbrella header could be found to generate the module map"))
                if hasPrivateModuleMap {
                    results.checkWarning(.prefix("[targetIntegrity] MODULEMAP_PRIVATE_FILE has no effect if there is no public module"))
                }
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func moduleMapGeneration() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("CookieCutter.h"),
                    TestFile("CPlusPlus.hpp"),
                    TestFile("PrivateHeadersOnly.H"),
                    TestFile("mismatchedcase.hxx"),
                    TestFile("publicheaderpreferred.hh"),
                    TestFile("PublicHeaderPreferred.h"),
                    TestFile("ExactMatchPreferred.hp"),
                    TestFile("exactmatchpreferred.hh"),
                    TestFile("ExactMatchPreferred.h"),
                    TestFile("noncpluspluspreferred.H"),
                    TestFile("noncpluspluspreferred.hh"),
                    TestFile("NonCPlusPlusPreferred.h"),
                    TestFile("NoObjCCompatibilityHeader.h"),
                    TestFile("ObjCCompatibilityHeaderNotInstalled.h"),
                    TestFile("ObjCCompatibilityHeader.h"),
                    TestFile("Unifdef.h"),
                    TestFile("CSource.c"),
                    TestFile("SwiftSource.swift"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "DEFINES_MODULE": "YES",
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                ])
            ],
            targets: [
                // Typical cookie cutter framework - matching umbrella header.
                TestStandardTarget(
                    "CookieCutter",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("CookieCutter.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                        ]),
                    ]
                ),
                // C++ umbrella headers are fine too.
                TestStandardTarget(
                    "CPlusPlus",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("CPlusPlus.hpp", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                        ]),
                    ]
                ),
                // Generate a module map for frameworks with only private headers.
                TestStandardTarget(
                    "PrivateHeadersOnly",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("PrivateHeadersOnly.H", headerVisibility: .private),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                        ]),
                    ]
                ),
                // It's ok if the umbrella header doesn't match case with the framework/module name.
                TestStandardTarget(
                    "MismatchedCase",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("mismatchedcase.hxx", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                        ]),
                    ]
                ),
                // Public umbrellas are preferred over private ones.
                TestStandardTarget(
                    "PublicHeaderPreferred",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("publicheaderpreferred.hh", headerVisibility: .public),
                            TestBuildFile("PublicHeaderPreferred.h", headerVisibility: .private),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                        ]),
                    ]
                ),
                // Exact matches are preferred over case insensitive ones.
                TestStandardTarget(
                    "ExactMatchPreferred",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ExactMatchPreferred.hp", headerVisibility: .public),
                            TestBuildFile("exactmatchpreferred.hh", headerVisibility: .public),
                            TestBuildFile("ExactMatchPreferred.h", headerVisibility: .private),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                        ]),
                    ]
                ),
                // Non-C++ umbrellas are preferred over C++ ones.
                TestStandardTarget(
                    "NonCPlusPlusPreferred",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("noncpluspluspreferred.H", headerVisibility: .public),
                            TestBuildFile("noncpluspluspreferred.hh", headerVisibility: .public),
                            TestBuildFile("NonCPlusPlusPreferred.h", headerVisibility: .private),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                        ]),
                    ]
                ),
                // There are some more tie breakers in the code but they're arbitrary and we don't
                // really care which umbrella looking header gets used.
                // 1. x.h is preferred over y.H.
                // 2. When all else fails, lexicographic order is used.

                // Don't add Swift contents to the module if the Objective-C compatibility header isn't generated.
                TestStandardTarget(
                    "NoObjCCompatibilityHeader",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_OBJC_INTERFACE_HEADER_NAME": "",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("NoObjCCompatibilityHeader.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
                // Don't add Swift contents to the module if the Objective-C compatibility header isn't installed.
                TestStandardTarget(
                    "ObjCCompatibilityHeaderNotInstalled",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ObjCCompatibilityHeaderNotInstalled.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
                // A Swift-only framework has the Objective-C compatibility header in the top level module.
                TestStandardTarget(
                    "SwiftOnly",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
                // A mixed Objective-C and Swift framework has the Objective-C compatibility header in a submodule.
                TestStandardTarget(
                    "ObjCCompatibilityHeader",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ObjCCompatibilityHeader.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
                // Unifdef doesn't get applied to the generated module map.
                TestStandardTarget(
                    "Unifdef",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "COPY_HEADERS_RUN_UNIFDEF": "YES",
                            "COPY_HEADERS_UNIFDEF_FLAGS": "-DENABLE_FEATURE",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Unifdef.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "CSource.c",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let targetParameters = [("CookieCutter", "CookieCutter.h", false),
                                ("CPlusPlus", "CPlusPlus.hpp", false),
                                ("PrivateHeadersOnly", "PrivateHeadersOnly.H", false),
                                ("MismatchedCase", "mismatchedcase.hxx", false),
                                ("PublicHeaderPreferred", "publicheaderpreferred.hh", false),
                                ("ExactMatchPreferred", "ExactMatchPreferred.hp", false),
                                ("NonCPlusPlusPreferred", "noncpluspluspreferred.H", false),
                                ("NoObjCCompatibilityHeader", "NoObjCCompatibilityHeader.h", true),
                                ("ObjCCompatibilityHeaderNotInstalled", "ObjCCompatibilityHeaderNotInstalled.h", true),
                                ("Unifdef", "Unifdef.h", false),
        ]
        for (targetName, umbrellaHeader, hasSwiftSource) in targetParameters {
            await tester.checkBuild(runDestination: .macOS, targetName: targetName) { results in
                results.checkTarget(targetName) { target in
                    let generatedModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/module.modulemap"
                    let unextendedModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/unextended-module.modulemap"
                    let swiftVFS = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/unextended-module-overlay.yaml"
                    let installedModuleMap = "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Modules/module.modulemap"

                    let copyModuleMap = TaskCondition.matchRule(["Copy", installedModuleMap, generatedModuleMap])

                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", generatedModuleMap])) { task, contents in
                        #expect(contents == (OutputByteStream()
                                             <<< "framework module \(targetName) {\n"
                                             <<< "  umbrella header \"\(umbrellaHeader)\"\n"
                                             <<< "  export *\n"
                                             <<< "\n"
                                             <<< "  module * { export * }\n"
                                             <<< "}\n").bytes)
                    }

                    results.checkNoTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", unextendedModuleMap]))
                    results.checkNoTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", swiftVFS]))

                    results.checkTask(.matchTarget(target), copyModuleMap) { _ in }

                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) {tasks in
                        for task in tasks {
                            results.checkTaskFollows(task, copyModuleMap)
                        }
                    }
                    if hasSwiftSource {
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            for task in tasks {
                                results.checkTaskFollows(task, copyModuleMap)
                            }
                        }
                    }

                    results.checkNoTask(.matchTarget(target), .matchRulePattern(["Unifdef", .or(.equal(generatedModuleMap), .equal(installedModuleMap)), .any]))
                    checkExpectedTasks(in: results, for: target)
                }

                #expect(results.otherTargets == [])
                results.checkNoDiagnostics()
            }
        }

        await tester.checkBuild(runDestination: .macOS, targetName: "SwiftOnly") { results in
            results.checkTarget("SwiftOnly") { target in
                let generatedModuleMap = "\(SRCROOT)/build/Project.build/Debug/SwiftOnly.build/module.modulemap"
                let unextendedModuleMap = "\(SRCROOT)/build/Project.build/Debug/SwiftOnly.build/unextended-module.modulemap"
                let swiftVFS = "\(SRCROOT)/build/Project.build/Debug/SwiftOnly.build/unextended-module-overlay.yaml"
                let installedModuleMap = "\(SRCROOT)/build/Debug/SwiftOnly.framework/Versions/A/Modules/module.modulemap"

                let copyModuleMap = TaskCondition.matchRule(["Copy", installedModuleMap, generatedModuleMap])

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", generatedModuleMap])) { task, contents in
                    #expect(contents == (OutputByteStream()
                                         <<< "framework module SwiftOnly {\n"
                                         <<< "  header \"SwiftOnly-Swift.h\"\n"
                                         <<< "  requires objc\n"
                                         <<< "}\n").bytes)
                }

                // Swift-only frameworks don't use -import-underlying-module, and so don't use their own clang module
                // or need an un-extended module map or VFS to hide the Swift generated ObjC API.
                results.checkNoTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", unextendedModuleMap]))
                results.checkNoTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", swiftVFS]))

                results.checkTask(.matchTarget(target), copyModuleMap) { _ in }

                results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                    for task in tasks {
                        results.checkTaskFollows(task, copyModuleMap)
                    }
                }

                results.checkNoTask(.matchTarget(target), .matchRulePattern(["Unifdef", .or(.equal(generatedModuleMap), .equal(installedModuleMap)), .any]))
                checkExpectedTasks(in: results, for: target)
            }

            #expect(results.otherTargets == [])
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(runDestination: .macOS, targetName: "ObjCCompatibilityHeader") { results in
            results.checkTarget("ObjCCompatibilityHeader") { target in
                let generatedModuleMap = "\(SRCROOT)/build/Project.build/Debug/ObjCCompatibilityHeader.build/module.modulemap"
                let unextendedModuleMap = "\(SRCROOT)/build/Project.build/Debug/ObjCCompatibilityHeader.build/unextended-module.modulemap"
                let swiftVFS = "\(SRCROOT)/build/Project.build/Debug/ObjCCompatibilityHeader.build/unextended-module-overlay.yaml"
                let installedModuleMap = "\(SRCROOT)/build/Debug/ObjCCompatibilityHeader.framework/Versions/A/Modules/module.modulemap"

                let copyModuleMap = TaskCondition.matchRule(["Copy", installedModuleMap, generatedModuleMap])

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", generatedModuleMap])) { task, contents in
                    #expect(contents == (OutputByteStream()
                                         <<< "framework module ObjCCompatibilityHeader {\n"
                                         <<< "  umbrella header \"ObjCCompatibilityHeader.h\"\n"
                                         <<< "  export *\n"
                                         <<< "\n"
                                         <<< "  module * { export * }\n"
                                         <<< "}\n"
                                         <<< "\n"
                                         <<< "module ObjCCompatibilityHeader.Swift {\n"
                                         <<< "  header \"ObjCCompatibilityHeader-Swift.h\"\n"
                                         <<< "  requires objc\n"
                                         <<< "}\n").bytes)
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", unextendedModuleMap])) { task, contents in
                    #expect(contents == (OutputByteStream()
                                         <<< "framework module ObjCCompatibilityHeader {\n"
                                         <<< "  umbrella header \"ObjCCompatibilityHeader.h\"\n"
                                         <<< "  export *\n"
                                         <<< "\n"
                                         <<< "  module * { export * }\n"
                                         <<< "}\n"
                                         <<< "\n"
                                         <<< "module ObjCCompatibilityHeader.__Swift {\n"
                                         <<< "  exclude header \"ObjCCompatibilityHeader-Swift.h\"\n"
                                         <<< "}\n").bytes)
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", swiftVFS])) { task, contents in
                    #expect(contents == (OutputByteStream()
                                         <<< "{\n"
                                         <<< "  \"version\": 0,\n"
                                         <<< "  \"use-external-names\": false,\n"
                                         <<< "  \"case-sensitive\": false,\n"
                                         <<< "  \"roots\": [{\n"
                                         <<< "    \"type\": \"directory\",\n"
                                         <<< "    \"name\": \"\(SRCROOT)/build/Debug/ObjCCompatibilityHeader.framework/Modules\",\n"
                                         <<< "    \"contents\": [{\n"
                                         <<< "      \"type\": \"file\",\n"
                                         <<< "      \"name\": \"module.modulemap\",\n"
                                         <<< "      \"external-contents\": \"\(unextendedModuleMap)\",\n"
                                         <<< "    }]\n"
                                         <<< "    },\n"
                                         <<< "    {\n"
                                         <<< "    \"type\": \"directory\",\n"
                                         <<< "    \"name\": \"\(SRCROOT)/build/Debug/ObjCCompatibilityHeader.framework/Headers\",\n"
                                         <<< "    \"contents\": [{\n"
                                         <<< "      \"type\": \"file\",\n"
                                         <<< "      \"name\": \"ObjCCompatibilityHeader-Swift.h\",\n"
                                         <<< "      \"external-contents\": \"\(SRCROOT)/build/Project.build/Debug/ObjCCompatibilityHeader.build/unextended-interface-header.h\",\n"
                                         <<< "    }]\n"
                                         <<< "  }]\n"
                                         <<< "}\n").bytes)
                }
                // unextended-interface-header.h doesn't get written and doesn't exist.

                results.checkTask(.matchTarget(target), copyModuleMap) { _ in }

                results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) {tasks in
                    for task in tasks {
                        results.checkTaskFollows(task, copyModuleMap)
                    }
                }
                results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                    for task in tasks {
                        results.checkTaskFollows(task, copyModuleMap)
                    }
                }

                results.checkNoTask(.matchTarget(target), .matchRulePattern(["Unifdef", .or(.equal(generatedModuleMap), .equal(installedModuleMap)), .any]))
                checkExpectedTasks(in: results, for: target)
            }

            #expect(results.otherTargets == [])
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func staticModuleMapContents() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("ObjCOnly.h"),
                    TestFile("ObjCCompatibilityHeader.h"),
                    TestFile("ObjCCompatibilityHeader.swift"),
                    TestFile("ObjCSource.m"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGN_IDENTITY": "",
                    "DEFINES_MODULE": "YES",
                    "INFOPLIST_FILE": "Info.plist",
                    "MODULEMAP_FILE_CONTENTS": "framework module Framework {}",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                ])
            ],
            targets: [
                // Don't generate a module map for the umbrella header, use the provided contents.
                TestStandardTarget(
                    "ObjCOnly",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ObjCOnly.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "ObjCSource.m",
                        ]),
                    ]
                ),
                // Don't add Swift contents to the module, use the provided contents as-is.
                // Unifdef doesn't get applied to the provided contents.
                TestStandardTarget(
                    "ObjCCompatibilityHeader",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "COPY_HEADERS_RUN_UNIFDEF": "YES",
                            "COPY_HEADERS_UNIFDEF_FLAGS": "-DENABLE_FEATURE",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ObjCCompatibilityHeader.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "ObjCSource.m",
                            "ObjCCompatibilityHeader.swift",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let targetParameters = [("ObjCOnly", false),
                                ("ObjCCompatibilityHeader", true),
        ]
        for (targetName, hasSwiftSource) in targetParameters {
            await tester.checkBuild(runDestination: .macOS, targetName: targetName) { results in
                results.checkTarget(targetName) { target in
                    let generatedModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/module.modulemap"
                    let unextendedModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/unextended-module.modulemap"
                    let swiftVFS = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/unextended-module-overlay.yaml"
                    let installedModuleMap = "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Modules/module.modulemap"

                    let copyModuleMap = TaskCondition.matchRule(["Copy", installedModuleMap, generatedModuleMap])

                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", generatedModuleMap])) { task, contents in
                        #expect(contents == (OutputByteStream()
                                             <<< "framework module Framework {}").bytes)
                    }

                    results.checkNoTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", unextendedModuleMap]))
                    results.checkNoTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", swiftVFS]))

                    results.checkTask(.matchTarget(target), copyModuleMap) { _ in }

                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) {tasks in
                        for task in tasks {
                            results.checkTaskFollows(task, copyModuleMap)
                        }
                    }
                    if hasSwiftSource {
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            for task in tasks {
                                results.checkTaskFollows(task, copyModuleMap)
                            }
                        }
                    }

                    results.checkNoTask(.matchTarget(target), .matchRulePattern(["Unifdef", .or(.equal(generatedModuleMap), .equal(installedModuleMap)), .any]))
                    checkExpectedTasks(in: results, for: target)
                }

                #expect(results.otherTargets == [])
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func copyModuleMaps() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("ObjCOnly.h"),
                    TestFile("ObjCOnly.modulemap"),
                    TestFile("ObjCOnly_Private.h"),
                    TestFile("ObjCOnly.private.modulemap"),
                    TestFile("PublicSwiftPrivateObjC_Private.h"),
                    TestFile("PublicSwiftPrivateObjC.private.modulemap"),
                    TestFile("ObjCAndSwift.h"),
                    TestFile("ObjCAndSwift_Private.h"),
                    TestFile("ObjCSource.m"),
                    TestFile("SwiftSource.swift"),
                    TestFile("Info.plist"),
                ]),
            targets: [
                TestStandardTarget(
                    "ObjCOnly",
                    type: .framework,
                    buildConfigurations: [
                        // MODULEMAP_FILE supersedes MODULEMAP_FILE_CONTENTS, and doesn't require MODULEMAP_PRIVATE_FILE.
                        try buildConfiguration(withName: "PublicModuleOnly", extraSettings: [
                            "DEFINES_MODULE": "YES",
                            "MODULEMAP_FILE": "ObjCOnly.modulemap",
                            "MODULEMAP_FILE_CONTENTS": "ERROR",
                        ]),
                        // MODULEMAP_PRIVATE_FILE requires a public module map to be installed in some way.
                        try buildConfiguration(withName: "GeneratedPublicWithPrivate", extraSettings: [
                            "DEFINES_MODULE": "YES",
                            "MODULEMAP_PRIVATE_FILE": "ObjCOnly.private.modulemap",
                        ]),
                        try buildConfiguration(withName: "ContentsPublicWithPrivate", extraSettings: [
                            "DEFINES_MODULE": "YES",
                            "MODULEMAP_FILE_CONTENTS": "framework module ObjCOnly {}\n",
                            "MODULEMAP_PRIVATE_FILE": "ObjCOnly.private.modulemap",
                        ]),
                        // MODULEMAP_FILE and MODULEMAP_PRIVATE_FILE get unifdef'ed.
                        try buildConfiguration(withName: "FilePublicWithPrivate", extraSettings: [
                            "COPY_HEADERS_RUN_UNIFDEF": "YES",
                            "COPY_HEADERS_UNIFDEF_FLAGS": "-DENABLE_FEATURE",
                            "DEFINES_MODULE": "YES",
                            "MODULEMAP_FILE": "ObjCOnly.modulemap",
                            "MODULEMAP_PRIVATE_FILE": "ObjCOnly.private.modulemap",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ObjCOnly.h", headerVisibility: .public),
                            TestBuildFile("ObjCOnly_Private.h", headerVisibility: .private),
                        ]),
                        TestSourcesBuildPhase([
                            "ObjCSource.m",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "PublicSwiftPrivateObjC",
                    type: .framework,
                    buildConfigurations: [
                        // MODULEMAP_PRIVATE_FILE works when the public module is only Swift.
                        try buildConfiguration(withName: "GeneratedPublicWithPrivate", extraSettings: [
                            "DEFINES_MODULE": "YES",
                            "MODULEMAP_PRIVATE_FILE": "PublicSwiftPrivateObjC.private.modulemap",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("PublicSwiftPrivateObjC_Private.h", headerVisibility: .private),
                        ]),
                        TestSourcesBuildPhase([
                            "ObjCSource.m",
                            "SwiftSource.swift",
                        ])
                    ]
                ),
                TestStandardTarget(
                    "ObjCAndSwift",
                    type: .framework,
                    buildConfigurations: [
                        // Swift contents are appended to the end of the public module map.
                        buildConfiguration(withName: "PublicModuleOnly", extraSettings: [
                            "DEFINES_MODULE": "YES",
                            "MODULEMAP_FILE": "$(DERIVED_FILE_DIR)/ObjCAndSwift.modulemap",
                        ]),
                        // The private module doesn't get Swift contents.
                        buildConfiguration(withName: "FilePublicWithPrivate", extraSettings: [
                            "COPY_HEADERS_RUN_UNIFDEF": "YES",
                            "COPY_HEADERS_UNIFDEF_FLAGS": "-DENABLE_FEATURE",
                            "DEFINES_MODULE": "YES",
                            "MODULEMAP_FILE": "$(DERIVED_FILE_DIR)/ObjCAndSwift.modulemap",
                            "MODULEMAP_PRIVATE_FILE": "$(DERIVED_FILE_DIR)/ObjCAndSwift.private.modulemap",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ObjCAndSwift.h", headerVisibility: .public),
                            TestBuildFile("ObjCAndSwift_Private.h", headerVisibility: .private),
                        ]),
                        TestShellScriptBuildPhase(
                            name: "GenerateModuleMaps",
                            originalObjectID: "GenerateModuleMaps",
                            outputs: [
                                "$(DERIVED_FILE_DIR)/ObjCAndSwift.modulemap",
                                "$(DERIVED_FILE_DIR)/ObjCAndSwift.private.modulemap",
                            ]),
                        TestSourcesBuildPhase([
                            "ObjCSource.m",
                            "SwiftSource.swift",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let sourceRoot = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        for publicModule in ["ObjCOnly"] {
            let sourceModuleMap = Path("\(publicModule).modulemap").makeAbsolute(relativeTo: sourceRoot)!
            try await fs.writeFileContents(sourceModuleMap) { contents in
                contents <<< "framework module \(publicModule) {}\n"
            }
        }
        for privateModule in ["ObjCOnly", "PublicSwiftPrivateObjC"] {
            let sourcePrivateModuleMap = Path("\(privateModule).private.modulemap").makeAbsolute(relativeTo: sourceRoot)!
            try await fs.writeFileContents(sourcePrivateModuleMap) { contents in
                contents <<< "framework module \(privateModule)_Private {}\n"
            }
        }

        let SRCROOT = sourceRoot.str
        let builds = [("ObjCOnly", "PublicModuleOnly", true, false, false, false, false),
                      ("ObjCOnly", "GeneratedPublicWithPrivate", false, false, true, false, false),
                      ("ObjCOnly", "ContentsPublicWithPrivate", false, false, true, false, false),
                      ("ObjCOnly", "FilePublicWithPrivate", true, false, true, false, true),
                      ("PublicSwiftPrivateObjC", "GeneratedPublicWithPrivate", false, true, true, false, false),
                      ("ObjCAndSwift", "PublicModuleOnly", true, true, false, true, false),
                      ("ObjCAndSwift", "FilePublicWithPrivate", true, true, true, true, true),
        ]
        for (targetName, configurationName, copiesPublicModuleMap, hasSwiftExtension, copiesPrivateModuleMap, generatesSourceModuleMaps, copiesUseUnifdef) in builds {
            await tester.checkBuild(BuildParameters(configuration: configurationName), runDestination: .macOS, targetName: targetName, fs: fs) { results in
                results.checkTarget(targetName) { target in
                    // The build directories are hard coded to "Debug" and don't use the configuration name being built.
                    let sourceModuleMap = generatesSourceModuleMaps
                    ? "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/DerivedSources/\(targetName).modulemap"
                    : "\(SRCROOT)/\(targetName).modulemap"
                    let originalGeneratedModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/module-original.modulemap"
                    let moduleMapExtension = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/module-swiftextension.modulemap"
                    let generatedModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/module.modulemap"
                    let moduleMapUnextension = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/unextended-module-swiftunextension.modulemap"
                    let unextendedModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/unextended-module.modulemap"
                    let swiftVFS = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/unextended-module-overlay.yaml"
                    let installedModuleMap = "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Modules/module.modulemap"
                    let sourcePrivateModuleMap = generatesSourceModuleMaps
                    ? "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/DerivedSources/\(targetName).private.modulemap"
                    : "\(SRCROOT)/\(targetName).private.modulemap"
                    let generatedPrivateModuleMap = "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/module.private.modulemap"
                    let installedPrivateModuleMap = "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Modules/module.private.modulemap"

                    let copyModuleMap = TaskCondition.matchRule(["Copy", installedModuleMap, generatedModuleMap])
                    let copyPrivateModuleMap = TaskCondition.matchRule(["Copy", installedPrivateModuleMap, generatedPrivateModuleMap])

                    // The module map is read from source and written to the "generated" file.
                    if copiesPublicModuleMap {
                        if hasSwiftExtension {
                            results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", moduleMapExtension])) { task, contents in
                                #expect(contents == (OutputByteStream()
                                                     <<< "\n"
                                                     <<< "module \(targetName).Swift {\n"
                                                     <<< "  header \"\(targetName)-Swift.h\"\n"
                                                     <<< "  requires objc\n"
                                                     <<< "}\n").bytes)
                            }

                            let concatenateSourceModuleMap: String
                            if copiesUseUnifdef {
                                results.checkTask(.matchTarget(target), .matchRule(["Unifdef", originalGeneratedModuleMap, sourceModuleMap])) { task in
                                    if generatesSourceModuleMaps {
                                        results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "GenerateModuleMaps", "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/Script-GenerateModuleMaps.sh"]))
                                    }
                                    task.checkCommandLine(["unifdef", "-x", "2", "-DENABLE_FEATURE", "-o", originalGeneratedModuleMap, sourceModuleMap])
                                }
                                concatenateSourceModuleMap = originalGeneratedModuleMap
                            } else {
                                concatenateSourceModuleMap = sourceModuleMap
                            }
                            results.checkTask(.matchTarget(target), .matchRule(["Concatenate", generatedModuleMap, concatenateSourceModuleMap, moduleMapExtension])) { task in
                                if !copiesUseUnifdef && generatesSourceModuleMaps {
                                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "GenerateModuleMaps", "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/Script-GenerateModuleMaps.sh"]))
                                }
                            }

                            results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", moduleMapUnextension])) { task, contents in
                                #expect(contents == (OutputByteStream()
                                                     <<< "\n"
                                                     <<< "module \(targetName).__Swift {\n"
                                                     <<< "  exclude header \"\(targetName)-Swift.h\"\n"
                                                     <<< "}\n").bytes)
                            }
                            results.checkTask(.matchTarget(target), .matchRule(["Concatenate", unextendedModuleMap, concatenateSourceModuleMap, moduleMapUnextension])) { _ in }
                            results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", swiftVFS])) { task, contents in
                                #expect(contents == (OutputByteStream()
                                                     <<< "{\n"
                                                     <<< "  \"version\": 0,\n"
                                                     <<< "  \"use-external-names\": false,\n"
                                                     <<< "  \"case-sensitive\": false,\n"
                                                     <<< "  \"roots\": [{\n"
                                                     <<< "    \"type\": \"directory\",\n"
                                                     <<< "    \"name\": \"\(SRCROOT)/build/Debug/\(targetName).framework/Modules\",\n"
                                                     <<< "    \"contents\": [{\n"
                                                     <<< "      \"type\": \"file\",\n"
                                                     <<< "      \"name\": \"module.modulemap\",\n"
                                                     <<< "      \"external-contents\": \"\(unextendedModuleMap)\",\n"
                                                     <<< "    }]\n"
                                                     <<< "    },\n"
                                                     <<< "    {\n"
                                                     <<< "    \"type\": \"directory\",\n"
                                                     <<< "    \"name\": \"\(SRCROOT)/build/Debug/\(targetName).framework/Headers\",\n"
                                                     <<< "    \"contents\": [{\n"
                                                     <<< "      \"type\": \"file\",\n"
                                                     <<< "      \"name\": \"\(targetName)-Swift.h\",\n"
                                                     <<< "      \"external-contents\": \"\(SRCROOT)/build/Project.build/Debug/\(targetName).build/unextended-interface-header.h\",\n"
                                                     <<< "    }]\n"
                                                     <<< "  }]\n"
                                                     <<< "}\n").bytes)
                            }
                        } else if copiesUseUnifdef {
                            results.checkTask(.matchTarget(target), .matchRule(["Unifdef", generatedModuleMap, sourceModuleMap])) { task in
                                if generatesSourceModuleMaps {
                                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "GenerateModuleMaps", "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/Script-GenerateModuleMaps.sh"]))
                                }
                                task.checkCommandLine(["unifdef", "-x", "2", "-DENABLE_FEATURE", "-o", generatedModuleMap, sourceModuleMap])
                            }
                        } else {
                            results.checkTask(.matchTarget(target), .matchRule(["Copy", generatedModuleMap, sourceModuleMap])) { task in
                                if generatesSourceModuleMaps {
                                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "GenerateModuleMaps", "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/Script-GenerateModuleMaps.sh"]))
                                }
                            }
                        }
                    } else {
                        // Just make sure the public module was written and installed, its contents have been tested thoroughly already.
                        results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", generatedModuleMap])) { _ in }
                    }
                    results.checkTask(.matchTarget(target), copyModuleMap) { _ in }

                    if copiesPrivateModuleMap {
                        if copiesUseUnifdef {
                            results.checkTask(.matchTarget(target), .matchRule(["Unifdef", generatedPrivateModuleMap, sourcePrivateModuleMap])) { task in
                                if generatesSourceModuleMaps {
                                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "GenerateModuleMaps", "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/Script-GenerateModuleMaps.sh"]))
                                }
                                task.checkCommandLine(["unifdef", "-x", "2", "-DENABLE_FEATURE", "-o", generatedPrivateModuleMap, sourcePrivateModuleMap])
                            }
                        } else {
                            results.checkTask(.matchTarget(target), .matchRule(["Copy", generatedPrivateModuleMap, sourcePrivateModuleMap])) { task in
                                if generatesSourceModuleMaps {
                                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "GenerateModuleMaps", "\(SRCROOT)/build/Project.build/Debug/\(targetName).build/Script-GenerateModuleMaps.sh"]))
                                }
                            }
                        }
                        results.checkTask(.matchTarget(target), copyPrivateModuleMap) { _ in }
                    } else {
                        results.checkNoTask(.matchTarget(target), .matchRule(["Copy", generatedPrivateModuleMap, sourcePrivateModuleMap]))
                        results.checkNoTask(.matchTarget(target), .matchRule(["Copy", installedPrivateModuleMap, generatedPrivateModuleMap]))
                    }

                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) {tasks in
                        for task in tasks {
                            results.checkTaskFollows(task, copyModuleMap)
                            if hasSwiftExtension && copiesPublicModuleMap {
                                results.checkTaskFollows(task, .matchRulePattern(["Concatenate", .equal(unextendedModuleMap), .any, .equal(moduleMapUnextension)]))
                            }
                            if copiesPrivateModuleMap {
                                results.checkTaskFollows(task, copyPrivateModuleMap)
                            }
                        }
                    }
                    if hasSwiftExtension {
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            for task in tasks {
                                results.checkTaskFollows(task, copyModuleMap)
                                if hasSwiftExtension && copiesPublicModuleMap {
                                    results.checkTaskFollows(task, .matchRulePattern(["Concatenate", .equal(unextendedModuleMap), .any, .equal(moduleMapUnextension)]))
                                }
                                if copiesPrivateModuleMap {
                                    results.checkTaskFollows(task, copyPrivateModuleMap)
                                }
                            }
                        }
                    }

                    checkExpectedTasks(in: results, for: target)
                }

                #expect(results.otherTargets == [])
                results.checkNoDiagnostics()
            }
        }
    }

    private func buildConfiguration(withName name: String, extraSettings: [String: String]) async throws -> TestBuildConfiguration {
        return try await TestBuildConfiguration(name, buildSettings: [
            "CODE_SIGN_IDENTITY": "",
            "INFOPLIST_FILE": "Info.plist",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SWIFT_EXEC": swiftCompilerPath.str,
            "SWIFT_VERSION": swiftVersion,
        ].merging(extraSettings, uniquingKeysWith: { a, b in a }))
    }

    private func checkExpectedTasks(in planningResults: TaskConstructionTester.PlanningResults, for target: ConfiguredTarget) {
        // Skip task types we don't care about.
        planningResults.checkTasks(.matchRuleType("Gate")) { _ in }
        planningResults.checkTasks(.matchRuleType("MkDir")) { _ in }
        planningResults.checkTasks(.matchRuleType("SymLink")) { _ in }
        planningResults.checkTasks(.matchRuleType("SwiftDriver Compilation Requirements")) { _ in }
        planningResults.checkTasks(.matchRuleType("GenerateTAPI")) { _ in }
        planningResults.checkTasks(.matchRuleType("Ld")) { _ in }
        planningResults.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
        planningResults.checkTasks(.matchRuleType("CpHeader")) { _ in }
        planningResults.checkTasks(.matchRuleType("SwiftMergeGeneratedHeaders")) { _ in }
        planningResults.checkTasks(.matchRuleType("Touch")) { _ in }
        planningResults.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
        planningResults.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
        planningResults.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
        planningResults.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

        // Skip the remaining Concatenate, Copy, PhaseScriptExecution, Unifdef and WriteAuxiliaryFiles tasks.
        planningResults.checkTasks(.matchRuleType("Concatenate")) { _ in }
        planningResults.checkTasks(.matchRuleType("Copy")) { _ in }
        planningResults.checkTasks(.matchRuleType("PhaseScriptExecution")) { _ in }
        planningResults.checkTasks(.matchRuleType("Unifdef")) { _ in }
        planningResults.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

        // There should be no other tasks for this target.
        planningResults.checkNoTask(.matchTarget(target))
    }
}
