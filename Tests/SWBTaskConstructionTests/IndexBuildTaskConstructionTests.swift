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
import SWBProtocol
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct IndexBuildTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func multiPlatformTargets() async throws {
        let macApp = TestStandardTarget(
            "macApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.c",]),
                TestFrameworksBuildPhase(["FwkTarget.framework"]),
            ])

        let iosApp = TestStandardTarget(
            "iosApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.c",]),
            ])

        let fwkTarget_mac = TestStandardTarget(
            "FwkTarget_mac",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "PRODUCT_NAME": "FwkTarget",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.c",]),
            ]
        )

        let fwkTarget_ios = TestStandardTarget(
            "FwkTarget_ios",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                    "PRODUCT_NAME": "FwkTarget",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.c",]),
            ]
        )

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                    ])],
            targets: [
                macApp,
                iosApp,
                fwkTarget_mac,
                fwkTarget_ios,
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check that we get tasks for all the supported platforms, independent of the run destination in the build request.

        func checkResults(_ results: TaskConstructionTester.PlanningResults) {
            results.checkTarget(macApp.name) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("Debug/macApp.build/Objects-normal/x86_64/main.o"), .suffix("main.c"), .equal("normal"), .equal("x86_64"), .any, .any])
                }
            }
            results.checkTarget(fwkTarget_mac.name) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("Debug/FwkTarget_mac.build/Objects-normal/x86_64/main.o"), .suffix("main.c"), .equal("normal"), .equal("x86_64"), .any, .any])
                }
            }
            results.checkTarget(iosApp.name, platformDiscriminator: "iphonesimulator") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("Debug-iphonesimulator/iosApp.build/Objects-normal/x86_64/main.o"), .suffix("main.c"), .equal("normal"), .equal("x86_64"), .any, .any])
                }
            }
            results.checkTarget(iosApp.name, platformDiscriminator: "iphoneos") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("Debug-iphoneos/iosApp.build/Objects-normal/arm64/main.o"), .suffix("main.c"), .equal("normal"), .equal("arm64"), .any, .any])
                }
            }
            results.checkTarget(fwkTarget_ios.name, platformDiscriminator: "iphonesimulator") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("Debug-iphonesimulator/FwkTarget_ios.build/Objects-normal/x86_64/main.o"), .suffix("main.c"), .equal("normal"), .equal("x86_64"), .any, .any])
                }
            }
            results.checkTarget(fwkTarget_ios.name, platformDiscriminator: "iphoneos") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("Debug-iphoneos/FwkTarget_ios.build/Objects-normal/arm64/main.o"), .suffix("main.c"), .equal("normal"), .equal("arm64"), .any, .any])
                }
            }
            results.checkTarget(fwkTarget_ios.name, platformDiscriminator: "iosmac") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("Debug-maccatalyst/FwkTarget_ios.build/Objects-normal/x86_64/main.o"), .suffix("main.c"), .equal("normal"), .equal("x86_64"), .any, .any])
                }
            }

            #expect(results.otherTargets == [])
            results.checkNoDiagnostics()
        }

        try await tester.checkIndexBuild(runDestination: .macOS, body: checkResults)
        try await tester.checkIndexBuild(runDestination: .iOS, body: checkResults)
        try await tester.checkIndexBuild(runDestination: .iOSSimulator, body: checkResults)
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func vfsAndHeaderMapContents() async throws {

        let fwkTarget1 = TestStandardTarget(
            "FrameworkTarget1",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                    "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                    "INFOPLIST_FILE": "MyInfo.plist",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase([
                    "main.c",
                ]),
                TestHeadersBuildPhase([
                    TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                ]),
            ]
        )

        let fwkTarget2 = TestStandardTarget(
            "FrameworkTarget2",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "INFOPLIST_FILE": "MyInfo.plist",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase([
                    "main.c",
                ]),
                TestHeadersBuildPhase([
                    TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                ]),
            ]
        )

        let fwkTarget3 = TestStandardTarget(
            "FrameworkTarget3",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "unknown",
                    "SUPPORTED_PLATFORMS": "unknown",
                    "INFOPLIST_FILE": "MyInfo.plist",
                    "PRODUCT_NAME": "FrameworkTarget3"
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase([
                    "main.c",
                ]),
                TestHeadersBuildPhase([
                    TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                ]),
            ]
        )

        let fwkTarget4 = TestStandardTarget(
            "FrameworkTarget4",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "INFOPLIST_FILE": "MyInfo.plist",
                    "EFFECTIVE_PLATFORM_NAME": "-custom",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase([
                    "main.c",
                ]),
                TestHeadersBuildPhase([
                    TestBuildFile("FrameworkTarget4.h", headerVisibility: .public),
                ]),
            ]
        )

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.c"),
                    TestFile("FrameworkTarget.h"),
                    TestFile("FrameworkTarget4.h"),
                    TestFile("MyInfo.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                ]),
            ],
            targets: [fwkTarget1, fwkTarget2, fwkTarget3, fwkTarget4])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        var vfs_sim: ByteString?
        var vfs_ios: ByteString?
        var vfs_macos: ByteString?
        var vfs_iosmac: ByteString?
        var vfs_custom: ByteString?

        var hmap1_sim: [String: String]?
        var hmap1_ios: [String: String]?
        var hmap1_macos: [String: String]?
        var hmap1_iosmac: [String: String]?
        var hmap2_macos: [String: String]?
        var hmap4_macos: [String: String]?

        try await tester.checkIndexBuild() { results in
            func checkVFSContents(_ task: any PlannedTask, _ target: ConfiguredTarget, _ platformDir: String, _ contents: ByteString, sourceLocation: SourceLocation = #_sourceLocation) {
                func recursivelyForEachDict(_ item: PropertyListItem, _ body: ([String:PropertyListItem]) -> Void) {
                    if let item = item.dictValue {
                        body(item)
                        for (_, value) in item {
                            recursivelyForEachDict(value, body)
                        }
                    } else if let item = item.arrayValue {
                        for value in item {
                            recursivelyForEachDict(value, body)
                        }
                    }
                }

                do {
                    let plistItem = try PropertyList.fromJSONData(contents)
                    let buildPath = try #require(results.arena).buildProductsPath
                    let platformPath = buildPath.join(platformDir)
                    let pathToSearchFor = platformPath.join("\(target.target.name).framework/Headers").str
                    var found = false
                    recursivelyForEachDict(plistItem) { dict in
                        if let toCheck = dict["name"]?.stringValue {
                            if toCheck == pathToSearchFor {
                                found = true
                            }
                            if toCheck.hasPrefix(buildPath.str + "/") && !toCheck.hasPrefix(platformPath.str + "/") {
                                Issue.record("File outside the effective platform directory: \(toCheck)", sourceLocation: sourceLocation)
                            }
                            if toCheck.contains(fwkTarget3.name) {
                                Issue.record("Found mapping for \(fwkTarget3.name) that should never be added", sourceLocation: sourceLocation)
                            }
                        }
                    }
                    #expect(found, "did not find path '\(pathToSearchFor)' in VFS contents", sourceLocation: sourceLocation)
                } catch {
                    Issue.record("Could not parse VFS file", sourceLocation: sourceLocation)
                }
            }

            results.checkTarget(fwkTarget1.name, platformDiscriminator: "iphonesimulator") { target in
                results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS-iphonesimulator/all-product-headers.yaml")])) { task, contents in
                    vfs_sim = contents
                    checkVFSContents(task, target, "Debug-iphonesimulator", contents)
                }
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                    hmap1_sim = headermap.contents
                    headermap.checkNoEntries()
                }
            }
            results.checkTarget(fwkTarget1.name, platformDiscriminator: "iphoneos") { target in
                results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS-iphoneos/all-product-headers.yaml")])) { task, contents in
                    vfs_ios = contents
                    checkVFSContents(task, target, "Debug-iphoneos", contents)
                }
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                    hmap1_ios = headermap.contents
                    headermap.checkNoEntries()
                }
            }
            results.checkTarget(fwkTarget1.name, platformDiscriminator: "macos") { target in
                results.checkTarget(fwkTarget2.name, platformDiscriminator: "macos") { target2 in
                    results.checkTarget(fwkTarget4.name, platformDiscriminator: "macos") { target4 in
                        results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS/all-product-headers.yaml")])) { task, contents in
                            vfs_macos = contents
                            checkVFSContents(task, target, "Debug", contents)
                            checkVFSContents(task, target2, "Debug", contents)
                        }
                        results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS-custom/all-product-headers.yaml")])) { task, contents in
                            vfs_custom = contents
                            checkVFSContents(task, target4, "Debug-custom", contents)
                        }
                        results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                            hmap1_macos = headermap.contents
                            headermap.checkNoEntries()
                        }
                        results.checkHeadermapGenerationTask(.matchTarget(target2), .matchRuleItemBasename("\(target2.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                            hmap2_macos = headermap.contents
                            headermap.checkNoEntries()
                        }
                        results.checkHeadermapGenerationTask(.matchTarget(target4), .matchRuleItemBasename("\(target4.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                            hmap4_macos = headermap.contents
                            headermap.checkNoEntries()
                        }
                    }
                }
            }
            results.checkTarget(fwkTarget1.name, platformDiscriminator: "iosmac") { target in
                results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS-maccatalyst/all-product-headers.yaml")])) { task, contents in
                    vfs_iosmac = contents
                    checkVFSContents(task, target, "Debug-maccatalyst", contents)
                }
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                    hmap1_iosmac = headermap.contents
                    headermap.checkNoEntries()
                }
            }

            #expect(results.otherTargets.isEmpty, "unexpected extra \(results.otherTargets.count) targets")
            results.checkNoDiagnostics()
        }

        try await tester.checkIndexBuild(targets: [fwkTarget1]) { results in
            results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS-iphonesimulator/all-product-headers.yaml")])) { task, contents in
                #expect(contents == vfs_sim)
            }
            results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS-iphoneos/all-product-headers.yaml")])) { task, contents in
                #expect(contents == vfs_ios)
            }
            results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS-maccatalyst/all-product-headers.yaml")])) { task, contents in
                #expect(contents == vfs_iosmac)
            }
            results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS/all-product-headers.yaml")])) { task, contents in
                #expect(contents == vfs_macos)
            }
            results.checkTarget(fwkTarget1.name, platformDiscriminator: "iphonesimulator") { target in
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                    #expect(headermap.contents == hmap1_sim)
                }
            }
            results.checkTarget(fwkTarget1.name, platformDiscriminator: "iphoneos") { target in
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                    #expect(headermap.contents == hmap1_ios)
                }
            }
            results.checkTarget(fwkTarget1.name, platformDiscriminator: "macos") { target in
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                    #expect(headermap.contents == hmap1_macos)
                }
            }
            results.checkTarget(fwkTarget1.name, platformDiscriminator: "iosmac") { target in
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                    #expect(headermap.contents == hmap1_iosmac)
                }
            }

            #expect(results.otherTargets.isEmpty, "unexpected extra \(results.otherTargets.count) targets")
            results.checkNoDiagnostics()
        }

        try await tester.checkIndexBuild(targets: [fwkTarget2]) { results in
            results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS/all-product-headers.yaml")])) { task, contents in
                #expect(contents == vfs_macos)
            }
            results.checkTarget(fwkTarget2.name, platformDiscriminator: "macos") { target in
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                    #expect(headermap.contents == hmap2_macos)
                }
            }

            #expect(results.otherTargets.isEmpty, "unexpected extra \(results.otherTargets.count) targets")
            results.checkNoDiagnostics()
        }

        try await tester.checkIndexBuild(targets: [fwkTarget4]) { results in
            results.checkWriteAuxiliaryFileTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("VFS-custom/all-product-headers.yaml")])) { task, contents in
                #expect(contents == vfs_custom)
            }

            results.checkTarget(fwkTarget4.name, platformDiscriminator: "macos") { target in
                results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("\(target.target.name)-all-non-framework-target-headers.hmap")) { headermap in
                    #expect(headermap.contents == hmap4_macos)
                }
            }

            #expect(results.otherTargets.isEmpty, "unexpected extra \(results.otherTargets.count) targets")
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func ignoredDeploymentLocation() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.c"),
                    TestFile("FrameworkTarget.h"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                    "DEPLOYMENT_LOCATION": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "MyFrame",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "DEPLOYMENT_LOCATION": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.c",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                        ]),
                    ]
                ),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        try await tester.checkIndexBuild() { results in
            let productsRoot = try #require(results.arena).buildProductsPath.str
            results.checkTask(.matchRule(["CpHeader", "\(productsRoot)/Debug/MyFrame.framework/Versions/A/Headers/FrameworkTarget.h", "\(SRCROOT)/FrameworkTarget.h"])) { _ in }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftWithIndexBuildArena() async throws {
        let swiftFeatures = try await self.swiftFeatures
        let buildSettings: [String: String] = try await [
            "GENERATE_INFOPLIST_FILE": "YES",
            "CODE_SIGN_IDENTITY": "",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            // Set 'singlefile' and check that it is ignored.
            "SWIFT_COMPILATION_MODE": "singlefile",
            "SWIFT_WHOLE_MODULE_OPTIMIZATION": "NO",
            "SWIFT_OPTIMIZATION_LEVEL": "-O",
            "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
            "CURRENT_PROJECT_VERSION": "3.1",
            "SWIFT_EXEC": swiftCompilerPath.str,
            "SWIFT_VERSION": swiftVersion,
            "SWIFT_INCLUDE_PATHS": "/tmp/some-dir",
        ]
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [ TestFile("main.swift") ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: buildSettings)
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "OTHER_SWIFT_FLAGS": "$(inherited) -vfsoverlay /must/be/after/fallback/overlay.yaml",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([ "main.swift" ])
                    ]),
                TestStandardTarget(
                    "AppTargetNoRemap",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "INDEX_DISABLE_VFS_DIRECTORY_REMAP": "YES",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"])
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        try await tester.checkIndexBuild() { results in
            let arena = try #require(results.arena)

            results.checkNoTask(.matchCommandLineArgument("clang-stat-cache"))

            try results.checkTask(.matchTargetName("AppTarget"), .matchRuleItem("SwiftDriver Compilation Requirements")) { task in
                task.checkRuleInfo(["SwiftDriver Compilation Requirements", "AppTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                // Explicit modules are disabled for semantic functionality currently, make sure it is also disabled
                // for preparation in general.
                task.checkCommandLineDoesNotContain("-explicit-module-build")

                let skipFlag = swiftFeatures.has(.experimentalSkipAllFunctionBodies) ? "-experimental-skip-all-function-bodies" : "-experimental-skip-non-inlinable-function-bodies"
                task.checkCommandLineContains(["-module-name", "AppTarget", "-Onone", "-Xfrontend", skipFlag, "-emit-dependencies", "-emit-module", "-emit-module-path", "-emit-objc-header", "-emit-objc-header-path"])
                if swiftFeatures.has(.experimentalAllowModuleWithCompilerErrors) {
                    task.checkCommandLineContains(["-Xfrontend", "-experimental-allow-module-with-compiler-errors"])
                    task.checkCommandLineContains(["-Xcc", "-Xclang", "-Xcc", "-fallow-pcm-with-compiler-errors"])
                } else {
                    task.checkCommandLineDoesNotContain("-experimental-allow-module-with-compiler-errors")
                }
                task.checkCommandLineContains([
                    "-vfsoverlay", "\(arena.buildIntermediatesPath.str)/index-overlay.yaml",
                    "-vfsoverlay", "/must/be/after/fallback/overlay.yaml",
                ])
                if swiftFeatures.has(.emptyABIDescriptor) {
                    task.checkCommandLineContains(["-Xfrontend", "-empty-abi-descriptor"])
                } else {
                    task.checkCommandLineDoesNotContain("-empty-abi-descriptor")
                }
                task.checkCommandLineDoesNotContain("-ivfsstatcache")
                // Check we add supplementary Clang options. There's many here, but we can assume that if one is added, they all are.
                task.checkCommandLineContains(["-Xcc", "-fretain-comments-from-system-headers"])
                task.checkCommandLineContains(["-whole-module-optimization"])
                task.checkCommandLineDoesNotContain("-index-store-path")

                let indexingInfo = task.generateIndexingInfo(input: .fullInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                let info = try #require(indexingInfo.only?.indexingInfo as? SwiftSourceFileIndexingInfo)
                let commandLine = try #require(info.propertyListItem.dictValue?["swiftASTCommandArguments"]?.stringArrayValue)
                #expect(!commandLine.contains("-experimental-skip-non-inlinable-function-bodies"))
                #expect(!commandLine.contains("-experimental-skip-all-function-bodies"))
                if swiftFeatures.has(.experimentalAllowModuleWithCompilerErrors) {
                    #expect(commandLine.contains("-experimental-allow-module-with-compiler-errors"))
                    #expect(commandLine.contains("-fallow-pcm-with-compiler-errors"))
                } else {
                    #expect(!commandLine.contains("-experimental-allow-module-with-compiler-errors"))
                }
                if swiftFeatures.has(.vfsDirectoryRemap) {
                    #expect(commandLine.contains("-vfsoverlay"))
                }
                if swiftFeatures.has(.emptyABIDescriptor) {
                    #expect(commandLine.contains("-empty-abi-descriptor"))
                }
            }

            results.checkTask(.matchTargetName("AppTargetNoRemap"), .matchRuleItem("SwiftDriver Compilation Requirements")) { task in
                task.checkCommandLineDoesNotContain("-vfsoverlay")
            }

            results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("index-overlay.yaml")) { task, contents in
                let contentsStr = contents.unsafeStringValue
                #expect(contentsStr == "{\"case-sensitive\":\"false\",\"redirecting-with\":\"fallback\",\"roots\":[{\"external-contents\":\"\(arena.indexRegularBuildProductsPath?.str ?? "missing")\",\"name\":\"\(arena.buildProductsPath.str)\",\"type\":\"directory-remap\"},{\"external-contents\":\"\(arena.indexRegularBuildIntermediatesPath?.str ?? "missing")\",\"name\":\"\(arena.buildIntermediatesPath.str)\",\"type\":\"directory-remap\"}],\"version\":0}")
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func noIndexStorePathForGenerateSwiftModule() async throws {
        let buildSettings: [String: String] = try await [
            "GENERATE_INFOPLIST_FILE": "YES",
            "CODE_SIGN_IDENTITY": "",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "ALWAYS_SEARCH_USER_PATHS": "NO",

            "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
            "CURRENT_PROJECT_VERSION": "3.1",
            "SWIFT_EXEC": swiftCompilerPath.str,
            "SWIFT_VERSION": swiftVersion,
            "SWIFT_INCLUDE_PATHS": "/tmp/some-dir",

            // See <rdar://65242911>
            "SWIFT_INDEX_STORE_PATH": "/path/to/index/store",
            "SWIFT_COMPILATION_MODE": "wholemodule",

            // See Swift.xcspec
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
            "COMPILER_INDEX_STORE_ENABLE": "YES",
            "SWIFT_INDEX_STORE_ENABLE": "YES",

            "SWIFT_EMIT_MODULE_INTERFACE": "YES",
            "SWIFT_MODULE_ONLY_ARCHS": "i386",

            "SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET": "11.0",

        ]
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [ TestFile("main.swift") ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: buildSettings)
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: buildSettings)
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([ "main.swift" ])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .anyMac) { results in
            results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchRuleItem("i386-macos")) { task in
                task.checkCommandLineContains(["-whole-module-optimization"])
                task.checkCommandLineDoesNotContain("-index-store-path")
            }

            results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchRuleItem("x86_64")) { task in
                task.checkCommandLineContains(["-whole-module-optimization"])
                task.checkCommandLineContains(["-index-store-path", "/path/to/index/store"])
            }

            results.checkWarning(.equal("SWIFT_MODULE_ONLY_ARCHS assigned at levels: project, target. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'AppTarget' from project 'aProject')"))
            results.checkWarning(.equal("SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET assigned at levels: project, target. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'AppTarget' from project 'aProject')"))

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func customEffectivePlatformName() async throws {
        // rdar://128421634 - Check that a target with an
        // EFFECTIVE_PLATFORM_NAME gets its own separate product directory.
        let target1 = TestStandardTarget(
            "Target1",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "Mod",
                ]),
            ],
            buildPhases: [TestSourcesBuildPhase(["a.swift"])]
        )
        let target2 = TestStandardTarget(
            "Target2",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "Mod",
                    "EFFECTIVE_PLATFORM_NAME": "-custom"
                ]),
            ],
            buildPhases: [TestSourcesBuildPhase(["a.swift"])]
        )

        let project = try await TestProject(
            "proj",
            groupTree: TestGroup(
                "SomeFiles",
                children: [ TestFile("a.swift") ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "SDKROOT": "macosx",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                ])
            ],
            targets: [target1, target2]
        )

        let tester = try await TaskConstructionTester(getCore(), project)
        try await tester.checkIndexBuild { results in
            results.checkTarget(target1.name, platformDiscriminator: "macos") { target in
                results.checkTask(
                    .matchTarget(target),
                    .matchRuleType("Copy"),
                    .matchRuleItemPattern(.suffix(".swiftmodule"))
                ) { task in
                    task.checkOutputs(contain: [
                        .pathPattern(.suffix("Products/Debug/Mod.swiftmodule/x86_64-apple-macos.swiftmodule"))
                    ])
                }
            }
            results.checkTarget(target2.name, platformDiscriminator: "macos") { target in
                results.checkTask(
                    .matchTarget(target),
                    .matchRuleType("Copy"),
                    .matchRuleItemPattern(.suffix(".swiftmodule"))
                ) { task in
                    task.checkOutputs(contain: [
                        .pathPattern(.suffix("Products/Debug-custom/Mod.swiftmodule/x86_64-apple-macos.swiftmodule"))
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func clangWithIndexBuildArena() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let clangFeatures = try await self.clangFeatures
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [ TestFile("main.c") ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "CC": clangCompilerPath.str,
                        "CLANG_USE_RESPONSE_FILE": "NO",
                    ])],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "OTHER_CFLAGS": "$(inherited) -ivfsoverlay /must/be/after/fallback/overlay.yaml",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])
                    ]),
                TestStandardTarget(
                    "AppTargetNoRemap",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "INDEX_DISABLE_VFS_DIRECTORY_REMAP": "YES",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        try await tester.checkIndexBuild() { results in
            let arena = try #require(results.arena)

            results.checkNoTask(.matchCommandLineArgument("clang-stat-cache"))

            // Explicit modules are disabled for semantic functionality currently, make sure it is also disabled
            // for preparation in general.
            results.checkNoTask(.matchRuleItem("ScanDependencies"))

            try results.checkTask(.matchTargetName("AppTarget"), .matchRuleItem("CompileC")) { task in
                if clangFeatures.has(.allowPcmWithCompilerErrors) {
                    task.checkCommandLineContains(["-Xclang", "-fallow-pcm-with-compiler-errors"])
                } else {
                    task.checkCommandLineDoesNotContain("-fallow-pcm-with-compiler-errors")
                }

                if clangFeatures.has(.vfsRedirectingWith) {
                    task.checkCommandLineContains([
                        "-ivfsoverlay", "\(arena.buildIntermediatesPath.str)/index-overlay.yaml",
                        "-ivfsoverlay", "/must/be/after/fallback/overlay.yaml",
                    ])
                }

                task.checkCommandLineDoesNotContain("-ivfsstatcache")

                let indexingInfo = task.generateIndexingInfo(input: .fullInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                let info = try #require(indexingInfo.only?.indexingInfo)
                let commandLine = try #require(info.propertyListItem.dictValue?["clangASTCommandArguments"]?.stringArrayValue)
                if clangFeatures.has(.allowPcmWithCompilerErrors) {
                    #expect(commandLine.contains("-fallow-pcm-with-compiler-errors"))
                } else {
                    #expect(!commandLine.contains("-fallow-pcm-with-compiler-errors"))
                }
                if clangFeatures.has(.vfsDirectoryRemap) {
                    #expect(commandLine.contains("-ivfsoverlay"))
                }
            }

            results.checkTask(.matchTargetName("AppTargetNoRemap"), .matchRuleItem("CompileC")) { task in
                task.checkCommandLineDoesNotContain("-ivfsoverlay")
            }

            if clangFeatures.has(.vfsRedirectingWith) {
                results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("index-overlay.yaml")) { task, contents in
                    let contentsStr = contents.unsafeStringValue
                    #expect(contentsStr == "{\"case-sensitive\":\"false\",\"redirecting-with\":\"fallback\",\"roots\":[{\"external-contents\":\"\(arena.indexRegularBuildProductsPath?.str ?? "missing")\",\"name\":\"\(arena.buildProductsPath.str)\",\"type\":\"directory-remap\"},{\"external-contents\":\"\(arena.indexRegularBuildIntermediatesPath?.str ?? "missing")\",\"name\":\"\(arena.buildIntermediatesPath.str)\",\"type\":\"directory-remap\"}],\"version\":0}")
                }
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func withCompilationCaching() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("file.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CLANG_ENABLE_COMPILE_CACHE": "YES",
                        "CLANG_COMPILE_CACHE_PATH": tmpDirPath.join("CompilationCache").str,
                    ])],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["file.c"]),
                        ]),
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            try await tester.checkIndexBuild() { results in
                results.checkNoTask(.matchRuleType("ScanDependencies"))
            }
        }
    }

    @Test(.requireSDKs(.driverKit))
    func driverKitWithIndexBuildArena() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("interface.iig"),
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "SDKROOT": "driverkit",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "IIG_EXEC": iigPath.str,
                    ])],
            targets: [
                TestStandardTarget(
                    "DextTarget",
                    type: .driverExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug")
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "interface.iig",
                            "main.c",
                        ])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        try await tester.checkIndexBuild { results in
            results.checkTask(.matchRule(["Iig", "\(SRCROOT)/interface.iig"])) { task in
                #expect(task.preparesForIndexing)
            }

            try results.checkTask(.matchRuleItem("CompileC"), .matchRuleItemPattern(.suffix("/main.o"))) { task in
                let indexingInfo = task.generateIndexingInfo(input: .fullInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                let info = try #require(indexingInfo.only?.indexingInfo)
                let commandLine = try #require(info.propertyListItem.dictValue?["clangASTCommandArguments"]?.stringArrayValue)
                #expect(commandLine.contains("\(SRCROOT)/main.c"), "actual: \(commandLine)")
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func clangExplicitModulesIndexingInfo() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        for enableExplicitModules in [true, false] {
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [ TestFile("main.c") ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CLANG_ENABLE_MODULES": "YES",
                            "CLANG_ENABLE_EXPLICIT_MODULES": enableExplicitModules ? "YES" : "NO",
                            "CC": clangCompilerPath.str,
                        ])],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["main.c"])
                        ]),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            try await tester.checkIndexBuild { results in
                try results.checkTask(.matchTargetName("AppTarget"), .matchRuleItem("CompileC")) { task in
                    let indexingInfo = task.generateIndexingInfo(input: .outputPathInfo)
                    let info = try #require(indexingInfo.only?.indexingInfo)
                    #expect(info.propertyListItem.dictValue?["outputFilePath"]?.stringValue.map(Path.init)?.basename == "main.o")
                }

                // No other tasks should generate indexing info (specifically, when explicit modules are enabled the scanner task shouldn't generate any).
                results.checkTasks(.matchTargetName("AppTarget")) { tasks in
                    for task in tasks {
                        #expect(task.generateIndexingInfo(input: .outputPathInfo).count == 0)
                    }
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildDirIndependentOfConfigurationName() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.c"),
                    TestFile("FrameworkTarget.h"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Staging",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "GCC_PREPROCESSOR_DEFINITIONS": "$(CONFIGURATION)",
                        "CLANG_USE_RESPONSE_FILE": "NO",
                    ])],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"]),
                        TestFrameworksBuildPhase(["Fwk.framework"]),
                    ]),
                TestStandardTarget(
                    "Fwk", type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase(["main.c"])
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        try await tester.checkIndexBuild { results in
            let arena = try #require(results.arena)

            try results.checkTask(.matchTargetName("AppTarget"), .matchRuleItem("CompileC")) { task in
                let indexingInfo = task.generateIndexingInfo(input: .fullInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                let info = try #require(indexingInfo.only?.indexingInfo)
                let commandLine = try #require(info.propertyListItem.dictValue?["clangASTCommandArguments"]?.stringArrayValue)
                #expect(commandLine.contains("-F\(arena.buildProductsPath.str)/Debug"))
            }

            try results.checkTask(.matchTargetName("Fwk"), .matchRuleItem("CompileC")) { task in
                let indexingInfo = task.generateIndexingInfo(input: .fullInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                let info = try #require(indexingInfo.only?.indexingInfo)
                let commandLine = try #require(info.propertyListItem.dictValue?["clangASTCommandArguments"]?.stringArrayValue)
                #expect(commandLine.contains("-F\(arena.buildProductsPath.str)/Debug"))
            }

            results.checkTask(.matchRule(["CpHeader", "\(arena.buildProductsPath.str)/Debug/Fwk.framework/Versions/A/Headers/FrameworkTarget.h", "\(SRCROOT)/FrameworkTarget.h"])) { _ in }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func scriptTargetWithoutOutputs() async throws {
        let appTarget = TestStandardTarget(
            "AppTarget",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase([
                    "main.c",
                ]),
                TestShellScriptBuildPhase(
                    name: "ScriptNoOut", originalObjectID: "ScriptNoOut", contents: "exit 0", inputs: [], outputs: [])
            ])

        let testProject =  TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                ])],
            targets: [
                appTarget,
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        try await tester.checkIndexBuild(runDestination: .iOS) { results in
            results.checkWarning("Run script build phase 'ScriptNoOut' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase. (in target 'AppTarget' from project 'aProject')")
            results.checkWarning("Run script build phase 'ScriptNoOut' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase. (in target 'AppTarget' from project 'aProject')")
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func aggregateScriptDependentByMacCatalyst() async throws {
        let catalystAppTarget = TestStandardTarget(
            "catalystApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "iphoneos",
                    "SUPPORTS_MACCATALYST": "YES",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase([
                    "main.c",
                ]),
            ],
            dependencies: [
                "script1",
            ])

        let appTarget = TestStandardTarget(
            "AppTarget1",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "SUPPORTED_PLATFORMS": "macosx",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase([
                    "main.c",
                ]),
            ],
            dependencies: [
                "script1",
            ])

        let scriptTarget = TestAggregateTarget(
            "script1",
            buildPhases: [
                TestShellScriptBuildPhase(
                    name: "Script1", originalObjectID: "Script1", contents: "echo Script1 > \"${DERIVED_FILE_DIR}/script1-output\"", inputs: [], outputs: [
                        "$(DERIVED_FILE_DIR)/script1-output"
                    ])
            ]
        )

        let testProject =  TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "SDKROOT": "macosx",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                ])],
            targets: [
                catalystAppTarget,
                appTarget,
                scriptTarget,
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        try await tester.checkIndexBuild { results in
            results.checkTarget(scriptTarget.name, platformDiscriminator: "macos") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution")) { task in
                    task.checkRuleInfo([.equal("PhaseScriptExecution"), .equal("Script1"), .suffix("Debug/script1.build/Script-Script1.sh")])
                }
            }
            results.checkTarget(scriptTarget.name, platformDiscriminator: "iosmac") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution")) { task in
                    task.checkRuleInfo([.equal("PhaseScriptExecution"), .equal("Script1"), .suffix("Debug-maccatalyst/script1.build/Script-Script1.sh")])
                }
            }
            results.checkTarget(scriptTarget.name, platformDiscriminator: "iphoneos") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution")) { task in
                    task.checkRuleInfo([.equal("PhaseScriptExecution"), .equal("Script1"), .suffix("Debug-iphoneos/script1.build/Script-Script1.sh")])
                }
            }
            results.checkTarget(scriptTarget.name, platformDiscriminator: "iphonesimulator") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution")) { task in
                    task.checkRuleInfo([.equal("PhaseScriptExecution"), .equal("Script1"), .suffix("Debug-iphonesimulator/script1.build/Script-Script1.sh")])
                }
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func macCatalystAppWithZipperedFramework() async throws {
        let catalystAppTarget = TestStandardTarget(
            "catalystApp",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "SUPPORTS_MACCATALYST": "YES",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
                TestFrameworksBuildPhase(["zipperFrame.framework"]),
            ]
        )

        let zipperedFrameTarget = TestStandardTarget(
            "zipperFrame", type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "SUPPORTED_PLATFORMS": "macosx",
                    "IS_ZIPPERED": "YES",
                ])
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ]
        )

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "SDKROOT": "macosx",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    // Ensure that the index build forces distinct build directories for macOS vs macCatalyst, even if the project overrides and sets the same EFFECTIVE_PLATFORM_NAME.
                    "EFFECTIVE_PLATFORM_NAME[sdk=macos*]": "-mac",
                ])],
            targets: [
                catalystAppTarget,
                zipperedFrameTarget,
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        try await tester.checkIndexBuild { results in
            results.checkTarget(zipperedFrameTarget.name, platformDiscriminator: "macos") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkOutputs(contain: [.pathPattern(.suffix("Debug-mac/zipperFrame.build/Objects-normal/x86_64/zipperFrame.swiftmodule"))])
                }
            }
            results.checkTarget(zipperedFrameTarget.name, platformDiscriminator: "iosmac") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkOutputs(contain: [.pathPattern(.suffix("Debug-maccatalyst/zipperFrame.build/Objects-normal/x86_64/zipperFrame.swiftmodule"))])
                }
            }

            results.checkTarget(catalystAppTarget.name, platformDiscriminator: "macos") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkOutputs(contain: [.pathPattern(.suffix("Debug-mac/catalystApp.build/Objects-normal/x86_64/catalystApp.swiftmodule"))])
                }
            }
            results.checkTarget(catalystAppTarget.name, platformDiscriminator: "iosmac") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkOutputs(contain: [.pathPattern(.suffix("Debug-maccatalyst/catalystApp.build/Objects-normal/x86_64/catalystApp.swiftmodule"))])
                }
            }

            results.checkNoDiagnostics()
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
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "GENERATE_RESOURCE_ACCESSORS": "YES",
                    "USE_HEADERMAP": "NO"]),
            ],
            targets: [
                TestAggregateTarget(
                    "ALL",
                    dependencies: ["tool", "objctool"]
                ),
                TestStandardTarget(
                    "tool", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
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
                    dependencies: ["toolslib"]
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
                        ])
                                              )]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        try await tester.checkIndexBuild(workspaceOperation: false) { results in
            results.checkNoDiagnostics()
            results.checkTarget("tool") { target in
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("resource_bundle_accessor.swift")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("static let module: Bundle"))
                    XCTAssertMatch(contents.unsafeStringValue, .contains("let bundleName = \"tool_resources\""))
                }
            }

            try results.checkTarget("objctool") { target in
                let intermediatesRoot = try #require(results.arena).buildIntermediatesPath.str

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("resource_bundle_accessor.m")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("NSBundle* tool_resources_SWIFTPM_MODULE_BUNDLE()"))
                    XCTAssertMatch(contents.unsafeStringValue, .contains("NSString *bundleName = @\"tool_resources\";"))
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("resource_bundle_accessor.h")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("#define SWIFTPM_MODULE_BUNDLE tool_resources_SWIFTPM_MODULE_BUNDLE()"))
                }

                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("main.m")) { task in
                    task.checkCommandLineContains(["-include", "\(intermediatesRoot)/aProject.build/Debug/objctool.build/DerivedSources/resource_bundle_accessor.h"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func singleVariantOnly() async throws {

        let multiVariantTarget = TestStandardTarget(
            "multiVariantTarget",
            type: .application,
            buildPhases: [
                TestSourcesBuildPhase(["main.swift"]),
            ])

        let singleIndexVariantTarget = TestStandardTarget(
            "singleIndexVariantTarget",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "INDEX_BUILD_VARIANT": "dev",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main2.swift"]),
            ])

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "Files",
                children: [
                    TestFile("main.swift"),
                    TestFile("main2.swift"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "BUILD_VARIANTS": "normal asan dev",
                        "OTHER_SWIFT_FLAGS[variant=dev]": "-DSOME_DEV_FLAG",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ])
            ],
            targets: [
                multiVariantTarget,
                singleIndexVariantTarget,
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        try await tester.checkIndexBuild { results in
            results.checkTarget(multiVariantTarget.name) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    let info = IndexingInfo(sourceInfo: task.generateIndexingInfo(input: .fullInfo).only?.indexingInfo)
                    info.swift.checkCommandLineDoesNotContain("-DSOME_DEV_FLAG")
                }
            }

            results.checkTarget(singleIndexVariantTarget.name) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    let info = IndexingInfo(sourceInfo: task.generateIndexingInfo(input: .fullInfo).only?.indexingInfo)
                    info.swift.checkCommandLineContains(["-DSOME_DEV_FLAG"])
                }
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func noAnalyzerTasks() async throws {

        let testTarget = TestStandardTarget(
            "testTarget",
            type: .application,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "RUN_CLANG_STATIC_ANALYZER": "YES",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.c"]),
            ])

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Files",
                children: [
                    TestFile("main.c"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ])
            ],
            targets: [
                testTarget,
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        try await tester.checkIndexBuild { results in
            results.checkTarget(testTarget.name) { target in
                results.checkNoTask(.matchTarget(target), .matchRulePattern([.contains("Analyze")]))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func moduleMapTasks() async throws {

        // A target with a generated module map.
        let targetImplicitModMap = TestStandardTarget(
            "HasImplicitModMap",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "DEFINES_MODULE": "YES",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.c"]),
                TestHeadersBuildPhase([
                    TestBuildFile("HasImplicitModMap.h", headerVisibility: .public)
                ])
            ])

        // A target with explicit module maps that get copied into the product.
        let targetExplicitModMap = TestStandardTarget(
            "HasExplicitModMap",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "DEFINES_MODULE": "YES",
                    "MODULEMAP_FILE": "ExplicitMod.modulemap",
                    "MODULEMAP_PRIVATE_FILE": "ExplicitMod.private.modulemap",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase(["main.c"]),
            ])

        // A target with an explicit module map that gets extended before being
        // copied into the product.
        let targetExtendedExplicitModMap = TestStandardTarget(
            "HasExtendedExplicitModMap",
            type: .framework,
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "DEFINES_MODULE": "YES",
                    "SWIFT_INSTALL_OBJC_HEADER": "YES",
                    "MODULEMAP_FILE": "ExtExplicitMod.modulemap",
                ]),
            ],
            buildPhases: [
                TestSourcesBuildPhase(["a.swift"]),
            ])

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "Files",
                children: [
                    TestFile("main.c"),
                    TestFile("a.swift"),
                    TestFile("ExplicitMod.modulemap"),
                    TestFile("ExtExplicitMod.modulemap"),
                    TestFile("HasImplicitModMap.h"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ])
            ],
            targets: [
                targetImplicitModMap,
                targetExplicitModMap,
                targetExtendedExplicitModMap,
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        try await tester.checkIndexBuild { results in
            results.checkNoDiagnostics()

            // Check that the public module map gets generated.
            results.checkTarget(targetImplicitModMap.name) { target in
                let intermediateModMap: StringPattern = .contains(
                    "HasImplicitModMap.build/module.modulemap"
                )
                let frameworkModMap: StringPattern = .contains(
                    "HasImplicitModMap.framework/Versions/A/Modules/module.modulemap"
                )
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("WriteAuxiliaryFile"),
                    .matchRuleItemPattern(intermediateModMap)
                ) { task in
                    task.checkOutputs(contain: [.pathPattern(intermediateModMap)])
                }
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("Copy"),
                    .matchRuleItemPattern(frameworkModMap)
                ) { task in
                    task.checkInputs(contain: [.pathPattern(intermediateModMap)])
                    task.checkOutputs(contain: [.pathPattern(frameworkModMap)])
                }
            }

            // Check that both public and private module maps get copied into
            // the intermediates and products.
            results.checkTarget(targetExplicitModMap.name) { target in
                let srcModMap: StringPattern = .contains(
                    "ExplicitMod.modulemap"
                )
                let srcPrivateModMap: StringPattern = .contains(
                    "ExplicitMod.private.modulemap"
                )
                let intermediateModMap: StringPattern = .contains(
                    "HasExplicitModMap.build/module.modulemap"
                )
                let intermediatePrivateModMap: StringPattern = .contains(
                    "HasExplicitModMap.build/module.private.modulemap"
                )
                let frameworkModMap: StringPattern = .contains(
                    "HasExplicitModMap.framework/Versions/A/Modules/module.modulemap"
                )
                let frameworkPrivateModMap: StringPattern = .contains(
                    "HasExplicitModMap.framework/Versions/A/Modules/module.private.modulemap"
                )
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("Copy"),
                    .matchRuleItemPattern(srcModMap)
                ) { task in
                    task.checkInputs(contain: [.pathPattern(srcModMap)])
                    task.checkOutputs(contain: [.pathPattern(intermediateModMap)])
                }
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("Copy"),
                    .matchRuleItemPattern(srcPrivateModMap)
                ) { task in
                    task.checkInputs(contain: [.pathPattern(srcPrivateModMap)])
                    task.checkOutputs(contain: [.pathPattern(intermediatePrivateModMap)])
                }
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("Copy"),
                    .matchRuleItemPattern(frameworkModMap)
                ) { task in
                    task.checkInputs(contain: [.pathPattern(intermediateModMap)])
                    task.checkOutputs(contain: [.pathPattern(frameworkModMap)])
                }
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("Copy"),
                    .matchRuleItemPattern(frameworkPrivateModMap)
                ) { task in
                    task.checkInputs(contain: [.pathPattern(intermediatePrivateModMap)])
                    task.checkOutputs(contain: [.pathPattern(frameworkPrivateModMap)])
                }
            }

            // Check that a module map needing extension gets the necessary
            // tasks.
            results.checkTarget(targetExtendedExplicitModMap.name) { target in
                let srcModMap: StringPattern = .contains(
                    "ExtExplicitMod.modulemap"
                )
                let intermediateModMap: StringPattern = .contains(
                    "HasExtendedExplicitModMap.build/module.modulemap"
                )
                let unextensionModMap: StringPattern = .contains(
                    "HasExtendedExplicitModMap.build/unextended-module-swiftunextension.modulemap"
                )
                let unextendedModMap: StringPattern = .contains(
                    "HasExtendedExplicitModMap.build/unextended-module.modulemap"
                )
                let frameworkModMap: StringPattern = .contains(
                    "HasExtendedExplicitModMap.framework/Versions/A/Modules/module.modulemap"
                )
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("Concatenate"),
                    .matchRuleItemPattern(srcModMap),
                    .matchRuleItemPattern(intermediateModMap)
                ) { task in
                    task.checkInputs(contain: [.pathPattern(srcModMap)])
                    task.checkOutputs(contain: [.pathPattern(intermediateModMap)])
                }
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("WriteAuxiliaryFile"),
                    .matchRuleItemPattern(unextensionModMap)
                ) { task in
                    task.checkOutputs(contain: [.pathPattern(unextensionModMap)])
                }
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("Concatenate"),
                    .matchRuleItemPattern(srcModMap),
                    .matchRuleItemPattern(unextendedModMap)
                ) { task in
                    task.checkInputs(contain: [
                        .pathPattern(srcModMap), .pathPattern(unextensionModMap)
                    ])
                    task.checkOutputs(contain: [.pathPattern(unextendedModMap)])
                }
                results.checkTask(
                    .matchTarget(target), .matchRuleItem("Copy"),
                    .matchRuleItemPattern(frameworkModMap)
                ) { task in
                    task.checkInputs(contain: [.pathPattern(intermediateModMap)])
                    task.checkOutputs(contain: [.pathPattern(frameworkModMap)])
                }
            }
        }
    }
}
