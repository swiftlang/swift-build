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
import SWBTestSupport
import SWBUtil
import Foundation

@Suite(.requireXcode16())
fileprivate struct UnitTestTaskConstructionTests: CoreBasedTests {

    // MARK: Framework test target

    /// Test task construction for a unit test target for macOS which is testing a framework.
    @Test(.requireSDKs(.macOS))
    func frameworkUnitTestTarget_macOS() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // Framework sources
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),
                    TestFile("FrameworkTarget-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("TestTwo.swift"),
                    TestFile("UnitTestTarget-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "macosx",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                        "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "NO",
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "UnitTestTarget",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "UnitTestTarget-Info.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                            "TestTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "FrameworkTarget.framework",
                        ])
                    ],
                    dependencies: ["FrameworkTarget"]
                ),
                TestStandardTarget(
                    "FrameworkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "FrameworkTarget-Info.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ])
                    ]
                ),
            ])
        let core = try await getCore()
        let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let MACOSX_DEPLOYMENT_TARGET = core.loadSDK(.macOS).defaultDeploymentTarget

        let fs = PseudoFS()

        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }

        // Write the test baseline files.
        guard let baselineDir = (tester.workspace.projects.first?.targets.first as? SWBCore.StandardTarget)?.performanceTestsBaselinesPath else {
            Issue.record("Could not get path to performance test baselines.")
            return
        }
        try fs.createDirectory(baselineDir, recursive: true)
        try await fs.writePlist(baselineDir.join("Info.plist"), .plDict([:]))
        try await fs.writePlist(baselineDir.join("Some-Test-Data.plist"), .plDict([:]))

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate and build directory tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check that results for the framework target were generated, but they're not what we're testing here.
            results.checkTarget("FrameworkTarget") { target in
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the unit test target.
            results.checkTarget("UnitTestTarget") { target in
                // There should be an Info.plist processing task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkRuleInfo(["ProcessInfoPlistFile", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/Info.plist", "\(SRCROOT)/UnitTestTarget-Info.plist"])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation Requirements", "UnitTestTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    task.checkCommandLineContains([[swiftCompilerPath.str, "-module-name", "UnitTestTarget", "-O", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-g", /* options from the xcspec which sometimes change appear here */ "-swift-version", swiftVersion, "-I", "\(SRCROOT)/build/Debug", "-F", "\(SRCROOT)/build/Debug", "-F", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-c", "-j\(compilerParallelismLevel)", "-incremental", "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.swiftmodule", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget-generated-files.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget-own-target-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget-project-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/Debug/include", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/DerivedSources-normal/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-Swift.h", "-working-directory", SRCROOT]].reduce([], +))

                    task.checkInputs([
                        .path("\(SRCROOT)/TestOne.swift"),
                        .path("\(SRCROOT)/TestTwo.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget_const_extract_protocols.json"),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix("copy-headers-completion")),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget Swift Compilation Requirements Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.swiftmodule"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.swiftsourceinfo"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.abi.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-Swift.h"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.swiftdoc"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "UnitTestTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    task.checkCommandLineContains([[swiftCompilerPath.str, "-module-name", "UnitTestTarget", "-O", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-g", /* options from the xcspec which sometimes change appear here */ "-swift-version", swiftVersion, "-I", "\(SRCROOT)/build/Debug", "-F", "\(SRCROOT)/build/Debug", "-F", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-c", "-j\(compilerParallelismLevel)", "-incremental", "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.swiftmodule", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget-generated-files.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget-own-target-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget-project-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/Debug/include", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/DerivedSources-normal/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-Swift.h", "-working-directory", SRCROOT]].reduce([], +))

                    task.checkInputs([
                        .path("\(SRCROOT)/TestOne.swift"),
                        .path("\(SRCROOT)/TestTwo.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget_const_extract_protocols.json"),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix("generated-headers")),
                        .namePattern(.suffix("copy-headers-completion")),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget Swift Compilation Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/TestOne.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/TestTwo.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/TestOne.swiftconstvalues"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/TestTwo.swiftconstvalues"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-OutputFileMap.json"])) { task in
                    task.checkInputs([
                        .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-OutputFileMap.json"),])
                }

                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget_const_extract_protocols.json"])) { task in
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.SwiftFileList"])) { task, contents in
                    let inputFiles = ["\(SRCROOT)/TestOne.swift", "\(SRCROOT)/TestTwo.swift"]
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == inputFiles + [""])
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.SwiftConstValuesFileList"])) { task, contents in
                    let inputFiles = ["\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/TestOne.swiftconstvalues",
                                      "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/TestTwo.swiftconstvalues"]
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == inputFiles + [""])
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget.DependencyMetadataFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == ["\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Resources/Metadata.appintents/extract.actionsdata", ""])
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/UnitTestTarget.DependencyStaticMetadataFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == [""])
                }

                // There should be one link task, and a task to generate its link file list.
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.LinkFileList"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/MacOS/UnitTestTarget", "normal"])
                    task.checkCommandLineMatches(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-bundle", "-isysroot", .equal(core.loadSDK(.macOS).path.str), "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-L\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/usr/lib", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-iframework", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Frameworks", .anySequence, "-filelist", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.LinkFileList", "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.swiftmodule", "-Xlinker", "-needed_framework", "-Xlinker", "XCTest", "-framework", "XCTest", "-Xlinker", "-needed-lXCTestSwiftSupport", "-lXCTestSwiftSupport", "-framework", "FrameworkTarget", "-o", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/MacOS/UnitTestTarget"])
                }

                // There should be a 'Copy' of the generated header.
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/DerivedSources/UnitTestTarget-Swift.h", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget-Swift.h"])) { _ in }

                // There should be a 'Copy' of the module file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTarget.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.swiftmodule"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTarget.swiftmodule/x86_64-apple-macos.abi.json", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.abi.json"])) { _ in }

                // There should be a 'swiftsourceinfo' of the module file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTarget.swiftmodule/Project/x86_64-apple-macos.swiftsourceinfo", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.swiftsourceinfo"])) { _ in }

                // There should be a 'Copy' of the doc file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTarget.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/Objects-normal/x86_64/UnitTestTarget.swiftdoc"])) { _ in }

                // There should be the expected mkdir tasks for the test bundle.
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { (tasks) -> Void in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    #expect(sortedTasks.count == 4)
                    for (idx, (ruleInfo, commandLine)) in [
                        (["MkDir", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest"], ["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest"]),
                        (["MkDir", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents"], ["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents"]),
                        (["MkDir", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/MacOS"], ["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/MacOS"]),
                        (["MkDir", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/Resources"], ["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/Resources"]),
                    ].enumerated() {
                        // Assuming we have at least 'idx' many tasks, then check the rule info and command line.
                        if idx < sortedTasks.count {
                            sortedTasks[idx].checkRuleInfo(ruleInfo)
                            sortedTasks[idx].checkCommandLine(commandLine)
                        }
                    }
                })

                // There should be a task to copy the testing baselines.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/Resources/xcbaselines", baselineDir.str])) { _ in }

                // Verify there is a task to create the VFS.
                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")])
                }

                // check the remaining auxiliary files tasks, which should just be headermaps.
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { tasks in
                    for task in tasks {
                        XCTAssertMatch(task.ruleInfo[1], .suffix(".hmap"))
                    }
                }

                // There should be a 'CopySwiftLibs' task.
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { task in
                    task.checkRuleInfo(["CopySwiftLibs", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest"])
                    task.checkCommandLine(["builtin-swiftStdLibTool", "--copy", "--verbose", "--scan-executable", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/MacOS/UnitTestTarget", "--scan-folder", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/Frameworks", "--scan-folder", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/PlugIns", "--scan-folder", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/Library/SystemExtensions", "--scan-folder", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/Extensions", "--scan-folder", "\(SRCROOT)/build/Debug/FrameworkTarget.framework", "--platform", "macosx", "--toolchain", defaultToolchain.path.str, "--destination", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest/Contents/Frameworks", "--strip-bitcode", "--scan-executable", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestSwiftSupport.dylib", "--strip-bitcode-tool", "\(defaultToolchain.path.str)/usr/bin/bitcode_strip", "--emit-dependency-info", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTarget.build/SwiftStdLibToolInputDependencies.dep", "--filter-for-swift-os"])
                }

                // There should be a 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug/UnitTestTarget.xctest"])) { _ in }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.linux))
    func unitTestTarget_linux() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("TestOne.swift"),
                    TestFile("TestTwo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "linux",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "UnitTestTarget",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                            "TestTwo.swift",
                        ]),
                    ],
                    dependencies: []
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        let fs = PseudoFS()

        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }

        await tester.checkBuild(runDestination: .linux, fs: fs) { results in
            results.checkTarget("UnitTestTarget") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTestEntryPoint")) { task in
                    task.checkCommandLineMatches([.suffix("builtin-generateTestEntryPoint"), "--output", .suffix("test_entry_point.swift")])
                    task.checkOutputs([.pathPattern(.suffix("test_entry_point.swift"))])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkInputs(contain: [.pathPattern(.suffix("test_entry_point.swift"))])
                }
            }

            results.checkNoDiagnostics()
        }
    }


    // MARK: Application test target using TEST_HOST

    /// Test task construction for an application target on macOS with two test targets which are testing it using TEST_HOST. Both debug and install builds are tested.
    ///
    /// Two targets are used to check that the test frameworks are only copied once, and the app target is only re-signed once.
    @Test(.requireSDKs(.macOS))
    func applicationUnitTestTarget_macOS() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),
                    TestFile("AppTarget-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("UnitTestTargetOne-Info.plist"),
                    TestFile("TestTwo.swift"),
                    TestFile("UnitTestTargetTwo-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "SDKROOT": "macosx",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                        "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                TestAggregateTarget(
                    "All",
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    dependencies: ["UnitTestTargetOne", "UnitTestTargetTwo"]
                ),
                TestStandardTarget(
                    "UnitTestTargetOne",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "UnitTestTargetOne-Info.plist",
                                                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                                                "BUNDLE_LOADER": "$(TEST_HOST)",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                        ]),
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "UnitTestTargetTwo",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "UnitTestTargetTwo-Info.plist",
                                                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                                                "BUNDLE_LOADER": "$(TEST_HOST)",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestTwo.swift",
                        ]),
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "AppTarget-Info.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ])
                    ]
                ),
            ])
        let core = try await getCore()
        let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let MACOSX_DEPLOYMENT_TARGET = core.loadSDK(.macOS).defaultDeploymentTarget

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writePlist(Path("/tmp/Test/aProject/Entitlements.plist"), .plDict([:]))
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }

        // For this test, assume XCUIAutomation.framework is not present in the
        // platform. Later, we'll validate there are no tasks related to it.
        let testFrameworkSubpaths = await testFrameworkSubpaths(includeXCUIAutomation: false)

        for frameworkSubpath in testFrameworkSubpaths {
            let frameworkPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(frameworkPath.dirname, recursive: true)
            try fs.write(frameworkPath, contents: ByteString(encodingAsUTF8: frameworkPath.basename))
        }

        // Check a debug build.
        try await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate and build directory related tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            var testTargetCompileTasks = [any PlannedTask]()
            var testTargetLinkTasks = [any PlannedTask]()
            var testTargetSigningTasks = [any PlannedTask]()

            // Check the first unit test target.  This one does not perform the copying of the test frameworks or re-signing the app target's product.
            results.checkTarget("UnitTestTargetOne") { target in
                // There should be an Info.plist processing task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkRuleInfo(["ProcessInfoPlistFile", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/Info.plist", "\(SRCROOT)/UnitTestTargetOne-Info.plist"])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation Requirements", "UnitTestTargetOne", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    task.checkCommandLineContains(([[swiftCompilerPath.str, "-module-name", "UnitTestTargetOne", "-O", "@\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.SwiftFileList", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-g", /* options from the xcspec which sometimes change appear here */ "-swift-version", swiftVersion, "-I", "\(SRCROOT)/build/Debug", "-F", "\(SRCROOT)/build/Debug", "-F", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-parse-as-library", "-c", "-j\(compilerParallelismLevel)", "-incremental", "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftmodule", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne-generated-files.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne-own-target-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne-project-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/Debug/include", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/DerivedSources-normal/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-Swift.h", "-working-directory", SRCROOT]] as [[String]]).reduce([], +))

                    task.checkInputs([
                        .path("\(SRCROOT)/TestOne.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne_const_extract_protocols.json"),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix("copy-headers-completion")),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne Swift Compilation Requirements Finished"),

                            .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftmodule"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftsourceinfo"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.abi.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-Swift.h"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftdoc"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "UnitTestTargetOne", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    task.checkCommandLineContains(([[swiftCompilerPath.str, "-module-name", "UnitTestTargetOne", "-O", "@\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.SwiftFileList", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-g", /* options from the xcspec which sometimes change appear here */ "-swift-version", swiftVersion, "-I", "\(SRCROOT)/build/Debug", "-F", "\(SRCROOT)/build/Debug", "-F", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-parse-as-library", "-c", "-j\(compilerParallelismLevel)", "-incremental", "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftmodule", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne-generated-files.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne-own-target-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne-project-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/Debug/include", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/DerivedSources-normal/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-Swift.h", "-working-directory", SRCROOT]] as [[String]]).reduce([], +))

                    task.checkInputs([
                        .path("\(SRCROOT)/TestOne.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne_const_extract_protocols.json"),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix("generated-headers")),
                        .namePattern(.suffix("copy-headers-completion")),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne Swift Compilation Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/TestOne.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/TestOne.swiftconstvalues")
                    ])

                    testTargetCompileTasks.append(task)
                }

                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-OutputFileMap.json"])) { task in
                    task.checkInputs([
                        .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-OutputFileMap.json"),])

                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.SwiftFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == ["\(SRCROOT)/TestOne.swift", ""])
                }

                // There should be one link task, and a task to generate its link file list.
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.LinkFileList"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/MacOS/UnitTestTargetOne", "normal"])
                    task.checkCommandLineMatches(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-bundle", "-isysroot", .equal(core.loadSDK(.macOS).path.str), "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-L\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/usr/lib", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-iframework", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Frameworks", .anySequence, "-filelist", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.LinkFileList", "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-bundle_loader", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftmodule", "-Xlinker", "-needed_framework", "-Xlinker", "XCTest", "-framework", "XCTest", "-Xlinker", "-needed-lXCTestSwiftSupport", "-lXCTestSwiftSupport", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/MacOS/UnitTestTargetOne"])

                    testTargetLinkTasks.append(task)
                }

                // There should be a 'Copy' of the generated header.
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/DerivedSources/UnitTestTargetOne-Swift.h", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-Swift.h"])) { _ in }

                // There should be a 'Copy' of the module file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetOne.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftmodule"])) { _ in }

                // There should be a 'Copy' of the sourceinfo file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetOne.swiftmodule/Project/x86_64-apple-macos.swiftsourceinfo", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftsourceinfo"])) { _ in }

                // There should be a 'Copy' of the doc file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetOne.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftdoc"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetOne.swiftmodule/x86_64-apple-macos.abi.json", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.abi.json"])) { _ in }

                // There should be the expected mkdir tasks for the test bundle.

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/MacOS"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/MacOS"])
                }

                // Verify there is a task to create the VFS.
                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")])
                }

                // There should be a task to write the entitlements plist.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Entitlements.plist")) { _ in }

                // check the remaining auxiliary files tasks, which should just be headermaps.
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".hmap"))) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix("const_extract_protocols.json"))) { _ in }

                // There should be a 'CopySwiftLibs' task.
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { task in
                    task.checkRuleInfo(["CopySwiftLibs", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"])
                    task.checkCommandLine(["builtin-swiftStdLibTool", "--copy", "--verbose", "--sign", "-", "--scan-executable", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/MacOS/UnitTestTargetOne", "--scan-folder", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/Frameworks", "--scan-folder", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/PlugIns", "--scan-folder", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/Library/SystemExtensions", "--scan-folder", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/Extensions", "--platform", "macosx", "--toolchain", defaultToolchain.path.str, "--destination", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/Frameworks", "--strip-bitcode", "--scan-executable", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestSwiftSupport.dylib", "--strip-bitcode-tool", "\(defaultToolchain.path.str)/usr/bin/bitcode_strip", "--emit-dependency-info", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/SwiftStdLibToolInputDependencies.dep", "--filter-for-swift-os"])
                }

                // There should be a task to sign the test bundle, and one to generate entitlements for it.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { task in
                    task.checkRuleInfo(["ProcessProductPackaging", "/tmp/Test/aProject/Entitlements.plist", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent"])
                    task.checkCommandLine(["builtin-productPackagingUtility", "/tmp/Test/aProject/Entitlements.plist", "-entitlements", "-format", "xml", "-o", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent"])
                    task.checkInputs([
                        .path("/tmp/Test/aProject/Entitlements.plist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/DerivedSources/Entitlements.plist"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent"))) { task in
                    task.checkRuleInfo(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent.der"])
                    task.checkCommandLine(["/usr/bin/derq", "query", "-f", "xml", "-i", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent", "-o", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent.der", "--raw"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent.der"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("UnitTestTargetOne.xctest")) { task in
                    task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"])
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"),
                        .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"),
                        .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/Info.plist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent"),
                        .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/MacOS/UnitTestTargetOne"),
                        .any,   // -will-sign
                        .any,   // -Barrier-ChangeAlternatePermissions
                        .any,   // -entry
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"),
                        .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/Contents/MacOS/UnitTestTargetOne"),
                        .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest/_CodeSignature"),
                        .name("CodeSign \(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"),
                    ])
                    testTargetSigningTasks.append(task)
                }

                // There should be a 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetOne.xctest"])) { _ in }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.SwiftConstValuesFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == ["\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/TestOne.swiftconstvalues", ""])
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.DependencyMetadataFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == ["\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/Metadata.appintents/extract.actionsdata", ""])
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.DependencyStaticMetadataFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == [""])
                }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check the second unit test target.  We don't check all of the commands for this target, but we do check that it copies the test frameworks and re-signs the app target..
            results.checkTarget("UnitTestTargetTwo") { target in
                // Match tasks we're not carefully checking.
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    testTargetCompileTasks.append(task)
                }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { #expect($0.count > 0) }
                results.checkTasks(.matchTarget(target), .matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    testTargetLinkTasks.append(task)
                }
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/DerivedSources/UnitTestTargetTwo-Swift.h", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/Objects-normal/x86_64/UnitTestTargetTwo-Swift.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetTwo.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/Objects-normal/x86_64/UnitTestTargetTwo.swiftmodule"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetTwo.swiftmodule/x86_64-apple-macos.abi.json", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/Objects-normal/x86_64/UnitTestTargetTwo.abi.json"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetTwo.swiftmodule/Project/x86_64-apple-macos.swiftsourceinfo", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/Objects-normal/x86_64/UnitTestTargetTwo.swiftsourceinfo"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetTwo.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/Objects-normal/x86_64/UnitTestTargetTwo.swiftdoc"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetTwo.xctest"])) { _ in }

                // There should be a task to sign the test bundle.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("UnitTestTargetTwo.xctest")) { task in
                    testTargetSigningTasks.append(task)
                }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check the tasks of the app target that we care about.
            try results.checkTarget("AppTarget") { target in
                // There should be tasks to copy the test frameworks into the app bundle and re-sign them.
                var testFrameworkCopyingTasks = [any PlannedTask]()
                for framework in testFrameworkSubpaths {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(frameworkName)) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/\(frameworkPath.str)"])
                        task.checkInputs([
                            .path("\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/\(frameworkPath.str)"),
                            .any,
                            .any,
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/\(frameworkName)"),
                            .name("CopyTestFramework \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/\(frameworkName)"),
                        ])
                        testFrameworkCopyingTasks.append(task)
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(frameworkName)")) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/\(frameworkName)"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/\(frameworkName)"),
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/\(frameworkName)"),
                            .name("CopyTestFramework \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/\(frameworkName)"),
                            .any,
                            .any,
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/\(frameworkName)"),
                            .name("SignTestFramework \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/\(frameworkName)"),
                        ])
                        testFrameworkCopyingTasks.append(task)
                    }
                }

                // Capture some other tasks from the app.
                _ = try #require(results.getTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")), "unable to find Swift compilation requirements task for AppTarget target")
                let appCompileTask = try #require(results.getTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")), "unable to find Swift compilation task for AppTarget target")
                let appLinkTask = try #require(results.getTask(.matchTarget(target), .matchRuleType("Ld")), "unable to find link task for AppTarget target")
                let appSigningTask = try #require(results.getTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app")), "unable to find sign task for AppTarget target")
                results.checkTaskFollows(appLinkTask, antecedent: appCompileTask)
                results.checkTaskFollows(appSigningTask, antecedent: appLinkTask)

                // Check that there's a signing task, and check that it follows other tasks across all targets that we expect it to follow.
                for testTask in testFrameworkCopyingTasks + testTargetCompileTasks + testTargetLinkTasks + testTargetSigningTasks {
                    results.checkTaskFollows(appSigningTask, antecedent: testTask)
                }

                // Specifically check that there are no tasks related to XCUIAutomation
                // since this test assumes it is not present in the platform.
                results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("XCUIAutomation.framework"))

                // We don't care about the rest of the app target's tasks for this test.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate and build directory tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check the first unit test target.  This one does not perform the copying of the test frameworks or re-signing the app target's product.
            results.checkTarget("UnitTestTargetOne") { target in
                // Match tasks we're not carefully checking.
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/DerivedSources/UnitTestTargetOne-Swift.h", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne-Swift.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetOne.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftmodule"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetOne.swiftmodule/x86_64-apple-macos.abi.json", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.abi.json"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetOne.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/Objects-normal/x86_64/UnitTestTargetOne.swiftdoc"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/UnitTestTargetOne.xctest", "../UninstalledProducts/macosx/UnitTestTargetOne.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Touch")) { _ in }

                // There should be the expected mkdir tasks for the test bundle.

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest/Contents"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest/Contents"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest/Contents/MacOS"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest/Contents/MacOS"])
                }

                // There should be a task to sign the test bundle, and one to generate entitlements for it.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("UnitTestTargetOne.xctest")) { task in
                    task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest"])
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent", "--generate-entitlement-der", "\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest/Contents/Info.plist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetOne.build/UnitTestTargetOne.xctest.xcent"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest/Contents/MacOS/UnitTestTargetOne"),
                        .any,   // -will-sign
                        .any,   // -Barrier-ChangeAlternatePermissions
                        .any,   // -entry
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest/Contents/MacOS/UnitTestTargetOne"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest/_CodeSignature"),
                        .name("CodeSign \(SRCROOT)/build/UninstalledProducts/macosx/UnitTestTargetOne.xctest"),
                    ])
                }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check the second unit test target.  We don't check all of the commands for this target, but we do check that it copies the test frameworks and re-signs the app target..
            results.checkTarget("UnitTestTargetTwo") { target in
                // Match tasks we're not carefully checking.
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/DerivedSources/UnitTestTargetTwo-Swift.h", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/Objects-normal/x86_64/UnitTestTargetTwo-Swift.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetTwo.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/Objects-normal/x86_64/UnitTestTargetTwo.swiftmodule"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetTwo.swiftmodule/x86_64-apple-macos.abi.json", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/Objects-normal/x86_64/UnitTestTargetTwo.abi.json"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UnitTestTargetTwo.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug/UnitTestTargetTwo.build/Objects-normal/x86_64/UnitTestTargetTwo.swiftdoc"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("UnitTestTargetTwo.xctest")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/UnitTestTargetTwo.xctest", "../UninstalledProducts/macosx/UnitTestTargetTwo.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Touch")) { _ in }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check the tasks of the app target that we care about.
            results.checkTarget("AppTarget") { target in
                // Since this is an install build, there should *not* be tasks to copy the testing frameworks into the test host app and re-sign them.
                for framework in testFrameworkSubpaths {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(frameworkName))
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(frameworkName)"))
                }

                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test task construction for a unit test target for watchOS.  Both debug and install builds are tested for the device, and a debug build is tested for the simulator.
    ///
    /// This test is primarily intended to validate some peculiarities of building for watchOS.
    @Test(.requireSDKs(.watchOS))
    func applicationUnitTestTarget_watchOS() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),
                    TestFile("AppTarget-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("TestTwo.swift"),
                    TestFile("UnitTestTarget-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ARCHS[sdk=watchos*]": "arm64_32",
                        "ARCHS[sdk=watchsimulator*]": "x86_64",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "SDKROOT": "watchos",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "UnitTestTarget",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "UnitTestTarget-Info.plist",
                                                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/AppTarget",
                                                "BUNDLE_LOADER": "$(TEST_HOST)",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                        ]),
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "AppTarget-Info.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ])
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writePlist(Path("/tmp/Test/aProject/Entitlements.plist"), .plDict([:]))
        try await fs.writeFileContents(self.swiftCompilerPath) { $0 <<< "binary" }
        for frameworkSubpath in await testFrameworkSubpaths() {
            let watchosframeworkPath = core.developerPath.path.join("Platforms/WatchOS.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(watchosframeworkPath.dirname, recursive: true)
            try fs.write(watchosframeworkPath, contents: ByteString(encodingAsUTF8: watchosframeworkPath.basename))

            let watchsimframeworkPath = core.developerPath.path.join("Platforms/WatchSimulator.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(watchsimframeworkPath.dirname, recursive: true)
            try fs.write(watchsimframeworkPath, contents: ByteString(encodingAsUTF8: watchosframeworkPath.basename))
        }

        // Check a debug build for the device.
        await tester.checkBuild(runDestination: .watchOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check the unit test target.
            results.checkTarget("UnitTestTarget") { target in
                let targetName = target.target.name

                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(targetName).build/DerivedSources/\(targetName)-Swift.h", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(targetName).build/Objects-normal/arm64_32/\(targetName)-Swift.h"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug-watchos/AppTarget.app/PlugIns/\(targetName).xctest"])) { _ in }

                // There should be a task to sign the test bundle.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).xctest")) { _ in }

                // There should be tasks to generate a dSYM file for the test target and touch it - the watchOS platform enables dSYM generation by default.
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("\(targetName).xctest.dSYM")) { _ in }
            }

            // Check the tasks of the app target that we care about.
            await results.checkTarget("AppTarget") { target in
                // There should be tasks to copy the test frameworks into the app bundle and re-sign them.
                for framework in await testFrameworkSubpaths() {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    var copyTask: (any PlannedTask)? = nil
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(frameworkName)) { task in
                        copyTask = task
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug-watchos/AppTarget.app/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/WatchOS.platform/Developer/\(frameworkPath.str)"])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(frameworkName)) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug-watchos/AppTarget.app/Frameworks/\(frameworkName)"])
                        if let copyTask {
                            results.checkTaskFollows(task, antecedent: copyTask)
                        }
                    }
                }

                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install build for the device.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .watchOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check that results for the app target were generated, but they're not what we're testing here.
            results.checkTarget("AppTarget") { target in
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the unit test target.
            await results.checkTarget("UnitTestTarget") { target in
                let targetName = target.target.name

                // Match tasks we're not carefully checking.
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(targetName).build/DerivedSources/\(targetName)-Swift.h", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(targetName).build/Objects-normal/arm64_32/\(targetName)-Swift.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-watchos/\(targetName).swiftmodule/arm64_32-apple-watchos.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(targetName).build/Objects-normal/arm64_32/\(targetName).swiftmodule"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-watchos/\(targetName).swiftmodule/arm64_32-apple-watchos.abi.json", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(targetName).build/Objects-normal/arm64_32/\(targetName).abi.json"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-watchos/\(targetName).swiftmodule/arm64_32-apple-watchos.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug-watchos/\(targetName).build/Objects-normal/arm64_32/\(targetName).swiftdoc"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).xctest")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug-watchos/\(targetName).xctest", "../UninstalledProducts/watchos/\(targetName).xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/UninstalledProducts/watchos/\(targetName).xctest"])) { _ in }

                // Since this is an install build, there should *not* be tasks to copy the testing frameworks into the test host app and re-sign them.
                for framework in await testFrameworkSubpaths() {
                    let frameworkName = Path(framework).basename
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(frameworkName))
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(frameworkName))
                }

                // There should be tasks to generate a dSYM file for the test target and touch it - the watchOS platform enables dSYM generation by default.
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("\(targetName).xctest.dSYM")) { _ in }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check a debug build for the simulator.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .watchOSSimulator, fs: fs) { results in
            // For debugging convenience, consume all the Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check the unit test target.
            results.checkTarget("UnitTestTarget") { target in
                let targetName = target.target.name

                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/\(targetName).build/DerivedSources/\(targetName)-Swift.h", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/\(targetName).build/Objects-normal/x86_64/\(targetName)-Swift.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-watchsimulator/\(targetName).swiftmodule/x86_64-apple-watchos-simulator.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/\(targetName).build/Objects-normal/x86_64/\(targetName).swiftmodule"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-watchsimulator/\(targetName).swiftmodule/x86_64-apple-watchos-simulator.abi.json", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/\(targetName).build/Objects-normal/x86_64/\(targetName).abi.json"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-watchsimulator/\(targetName).swiftmodule/Project/x86_64-apple-watchos-simulator.swiftsourceinfo", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/\(targetName).build/Objects-normal/x86_64/\(targetName).swiftsourceinfo"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-watchsimulator/\(targetName).swiftmodule/x86_64-apple-watchos-simulator.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug-watchsimulator/\(targetName).build/Objects-normal/x86_64/\(targetName).swiftdoc"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix("UnitTestTarget.xctest.xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix("UnitTestTarget.xctest.xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix("UnitTestTarget.xctest-Simulated.xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix("UnitTestTarget.xctest-Simulated.xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug-watchsimulator/AppTarget.app/PlugIns/\(targetName).xctest"])) { _ in }

                // There should be a task to sign the test bundle.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).xctest")) { _ in }

                // There should be tasks to generate a dSYM file for the test target and touch it - the watch simulator platform enables dSYM generation by default.
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("\(targetName).xctest.dSYM")) { _ in }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check the tasks of the app target that we care about.
            await results.checkTarget("AppTarget") { target in
                // There should be tasks to copy the test frameworks.  But the test frameworks are not signed for the simulator.
                for framework in await testFrameworkSubpaths() {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(frameworkName)) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug-watchsimulator/AppTarget.app/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/WatchSimulator.platform/Developer/\(frameworkPath.str)"])
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(frameworkName))
                }

                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test task construction for a unit test target for a watchOS application extension.  Both debug and install builds are tested for the device, and a debug build is tested for the simulator.
    ///
    /// This tests a scenario to make sure there isn't a race between the test target being built (directly into the appex) and the watchOS app which embeds the appex copying the appex into itself.
    @Test(.requireSDKs(.watchOS))
    func appExtensionUnitTestTarget_watchOS() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("WatchApp-Info.plist"),

                    // AppEx sources
                    TestFile("ClassOne.swift"),
                    TestFile("WatchExtension-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("ExtensionTests-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ARCHS[sdk=watchos*]": "arm64_32",
                        "ARCHS[sdk=watchsimulator*]": "x86_64",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "SDKROOT": "watchos",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "WatchApp",
                    type: .watchKitApp,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "WatchApp-Info.plist"]),
                    ],
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            TestBuildFile("WatchExtension.appex", codeSignOnCopy: true)
                        ], destinationSubfolder: .plugins, onlyForDeployment: false),
                    ],
                    dependencies: ["WatchExtension"]
                ),
                TestStandardTarget(
                    "WatchExtension",
                    type: .watchKitExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "WatchExtension-Info.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "ExtensionTests",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "ExtensionTests-Info.plist",
                                                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/WatchExtension.appex/WatchExtension",
                                                "BUNDLE_LOADER": "$(TEST_HOST)",
                                                "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                        ]),
                    ],
                    dependencies: ["WatchExtension"]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writePlist(Path("/tmp/Test/aProject/Entitlements.plist"), .plDict([:]))
        try await fs.writeFileContents(self.swiftCompilerPath) { $0 <<< "binary" }
        for frameworkSubpath in await testFrameworkSubpaths() {
            let watchosframeworkPath = core.developerPath.path.join("Platforms/WatchOS.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(watchosframeworkPath.dirname, recursive: true)
            try fs.write(watchosframeworkPath, contents: ByteString(encodingAsUTF8: watchosframeworkPath.basename))

            let watchsimframeworkPath = core.developerPath.path.join("Platforms/WatchSimulator.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(watchsimframeworkPath.dirname, recursive: true)
            try fs.write(watchsimframeworkPath, contents: ByteString(encodingAsUTF8: watchosframeworkPath.basename))
        }
        try fs.createDirectory(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit"), recursive: true)
        try fs.write(core.loadSDK(.watchOS).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")
        try fs.createDirectory(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit"), recursive: true)
        try fs.write(core.loadSDK(.watchOSSimulator).path.join("Library/Application Support/WatchKit/WK"), contents: "WatchKitStub")

        // We build the app target and the test target.
        let topLevelTargets = [tester.workspace.projects[0].targets[0], tester.workspace.projects[0].targets[2]]

        // Check a debug build for the device.
        let deviceParameters = BuildParameters(action: .build, configuration: "Debug")
        let debugBuildRequest = BuildRequest(parameters: deviceParameters, buildTargets: topLevelTargets.map({ BuildRequest.BuildTargetInfo(parameters: deviceParameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        try await tester.checkBuild(runDestination: .watchOS, buildRequest: debugBuildRequest, fs: fs) { results in
            // Ignore task types we don't plan to examine.
            results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "RegisterExecutionPolicyException"])

            var linkTask: (any PlannedTask)? = nil
            var signTask: (any PlannedTask)? = nil

            // The order here is that:
            //  1. The extension target builds its product.
            //  2. The test target builds its product into the extension and signs its product.
            //  3. The extension target embeds the test frameworks into itself and then signs its product.
            //  4. The app target embeds the extension into its product.

            results.checkTarget("ExtensionTests") { target in
                let targetName = target.target.name
                let productName = "\(targetName).xctest"

                // Capture some tasks we'll use later to check ordering.
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    linkTask = task
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(productName)) { task in
                    signTask = task
                }

                // Match the remaining tasks for this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }
            let testLinkTask = try #require(linkTask, "unable to find link task for ExtensionTests target")
            let testSignTask = try #require(signTask, "unable to find sign task for ExtensionTests target")

            await results.checkTarget("WatchExtension") { target in
                let targetName = target.target.name
                let productName = "\(targetName).appex"

                // Check that the link task for the test target follows the link task for this target.  This is important because setting BUNDLE_LOADER to $(TEST_HOST) establishes a linkage requirement, even though we don't actually detect that until we process the discovered dependencies info.
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    results.checkTaskFollows(testLinkTask, antecedent: task)
                }

                // Check that the extension target is responsible for embedding the test frameworks inside itself, and signing them.
                var copyFrameworksTasks = [any PlannedTask]()
                for framework in await testFrameworkSubpaths() {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    var copyTask: (any PlannedTask)? = nil
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(frameworkName)) { task in
                        copyTask = task
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug-watchos/\(productName)/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/WatchOS.platform/Developer/\(frameworkPath.str)"])
                        copyFrameworksTasks.append(task)
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(frameworkName)) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug-watchos/\(productName)/Frameworks/\(frameworkName)"])
                        if let copyTask {
                            results.checkTaskFollows(task, antecedent: copyTask)
                        }
                        copyFrameworksTasks.append(task)
                    }
                }

                // Check that the signing task for this target follows the signing task for the test target, as well as follows all the copy-frameworks tasks.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(productName)) { task in
                    results.checkTaskFollows(task, antecedent: testSignTask)
                    for copyFrameworkTask in copyFrameworksTasks {
                        results.checkTaskFollows(task, antecedent: copyFrameworkTask)
                    }

                    signTask = task
                }

                // Match the remaining tasks for this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }
            let extSignTask = try #require(signTask, "unable to find sign task for WatchExtension target")

            results.checkTarget("WatchApp") { target in
                let targetName = target.target.name
                let productName = "\(targetName).app"

                // Check that some tasks in the app target follow the signing tasks in both the extension and test targets, since if they don't then we could end up with broken content.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("WatchExtension.appex")) { task in
                    results.checkTaskFollows(task, antecedent: extSignTask)
                    results.checkTaskFollows(task, antecedent: testSignTask)
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(productName)")) { task in
                    results.checkTaskFollows(task, antecedent: extSignTask)
                    results.checkTaskFollows(task, antecedent: testSignTask)
                }

                // Match the remaining tasks for this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install build for the device.
        let installParameters = BuildParameters(action: .install, configuration: "Debug")
        let installBuildRequest = BuildRequest(parameters: installParameters, buildTargets: topLevelTargets.map({ BuildRequest.BuildTargetInfo(parameters: deviceParameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        try await tester.checkBuild(runDestination: .watchOS, buildRequest: installBuildRequest, fs: fs) { results in
            // Ignore task types we don't plan to examine.
            results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "RegisterExecutionPolicyException"])

            var swiftTask: (any PlannedTask)? = nil
            var signTask: (any PlannedTask)? = nil

            // The order here is that:
            //  1. The extension target builds its product.
            //  2. The test target builds its product into the extension and signs its product.
            //  3. The extension target embeds the test frameworks into itself and then signs its product.
            //  4. The app target embeds the extension into its product.

            results.checkTarget("ExtensionTests") { target in
                let targetName = target.target.name
                let productName = "\(targetName).xctest"

                // Capture some tasks we'll use later to check ordering.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    swiftTask = task
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(productName)) { task in
                    signTask = task
                }

                // Match the remaining tasks for this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }
            let testSwiftTask = try #require(swiftTask, "unable to find Swift planning task for ExtensionTests target")
            let testSignTask = try #require(signTask, "unable to find sign task for ExtensionTests target")

            await results.checkTarget("WatchExtension") { target in
                let targetName = target.target.name
                let productName = "\(targetName).appex"

                // Check that the Swift task for the test target follows the Swift task for this target.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    results.checkTaskFollows(testSwiftTask, antecedent: task)
                }

                // Since this is an install build, there should *not* be tasks to copy the testing frameworks into the host product and sign them.
                for framework in await testFrameworkSubpaths() {
                    let frameworkName = Path(framework).basename
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(frameworkName))
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(frameworkName))
                }

                // Check that the signing task for this target follows the signing task for the test target.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(productName)) { task in
                    results.checkTaskFollows(task, antecedent: testSignTask)

                    signTask = task
                }

                // Match the remaining tasks for this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }
            let extSignTask = try #require(signTask, "unable to find sign task for WatchExtension target")

            results.checkTarget("WatchApp") { target in
                let targetName = target.target.name
                let productName = "\(targetName).app"

                // Check that some tasks in the app target follow the signing tasks in both the extension and test targets, since if they don't then we could end up with broken content.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("WatchExtension.appex")) { task in
                    results.checkTaskFollows(task, antecedent: extSignTask)
                    results.checkTaskFollows(task, antecedent: testSignTask)
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(productName)")) { task in
                    results.checkTaskFollows(task, antecedent: extSignTask)
                    results.checkTaskFollows(task, antecedent: testSignTask)
                }

                // Match the remaining tasks for this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check a debug build for the simulator.
        let simParameters = BuildParameters(action: .build, configuration: "Debug")
        let simBuildRequest = BuildRequest(parameters: simParameters, buildTargets: topLevelTargets.map({ BuildRequest.BuildTargetInfo(parameters: simParameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        try await tester.checkBuild(runDestination: .watchOSSimulator, buildRequest: simBuildRequest, fs: fs) { results in
            // Ignore task types we don't plan to examine.
            results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "RegisterExecutionPolicyException"])

            var swiftTask: (any PlannedTask)? = nil
            var signTask: (any PlannedTask)? = nil

            // The order here is that:
            //  1. The extension target builds its product.
            //  2. The test target builds its product into the extension and signs its product.
            //  3. The extension target embeds the test frameworks into itself and then signs its product.
            //  4. The app target embeds the extension into its product.

            results.checkTarget("ExtensionTests") { target in
                let targetName = target.target.name
                let productName = "\(targetName).xctest"

                // Capture some tasks we'll use later to check ordering.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    swiftTask = task
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(productName)) { task in
                    signTask = task
                }

                // Match the remaining tasks for this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }
            let testSwiftTask = try #require(swiftTask, "unable to find Swift compilation requirements task for ExtensionTests target")
            let testSignTask = try #require(signTask, "unable to find sign task for ExtensionTests target")

            await results.checkTarget("WatchExtension") { target in
                let targetName = target.target.name
                let productName = "\(targetName).appex"

                // Check that the Swift task for the test target follows the Swift task for this target.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    results.checkTaskFollows(testSwiftTask, antecedent: task)
                }

                // Check that the extension target is responsible for embedding the test frameworks inside itself.  But not signing them, because we don't sign for the simulator.
                var copyFrameworksTasks = [any PlannedTask]()
                for framework in await testFrameworkSubpaths() {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(frameworkName)) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug-watchsimulator/\(productName)/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/WatchSimulator.platform/Developer/\(frameworkPath.str)"])
                        copyFrameworksTasks.append(task)
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(frameworkName))
                }

                // Check that the signing task for this target follows the signing task for the test target, as well as follows all the copy-frameworks tasks.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(productName)) { task in
                    results.checkTaskFollows(task, antecedent: testSignTask)
                    for copyFrameworkTask in copyFrameworksTasks {
                        results.checkTaskFollows(task, antecedent: copyFrameworkTask)
                    }

                    signTask = task
                }

                // Match the remaining tasks for this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }
            let extSignTask = try #require(signTask, "unable to find sign task for WatchExtension target")

            results.checkTarget("WatchApp") { target in
                let targetName = target.target.name
                let productName = "\(targetName).app"

                // Check that some tasks in the app target follow the signing tasks in both the extension and test targets, since if they don't then we could end up with broken content.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("WatchExtension.appex")) { task in
                    results.checkTaskFollows(task, antecedent: extSignTask)
                    results.checkTaskFollows(task, antecedent: testSignTask)
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(productName)")) { task in
                    results.checkTaskFollows(task, antecedent: extSignTask)
                    results.checkTaskFollows(task, antecedent: testSignTask)
                }

                // Match the remaining tasks for this target.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test task construction for an iOS app-hosted unit test target being built for macCatalyst. This test
    /// is primarily intended to validate that the test bundle and frameworks are embedded at the correct
    /// location even though the TEST_HOST build setting is configured for a shallow bundle, but the macCatalyst
    /// build produces a deep bundle.
    @Test(.requireSDKs(.macOS, .iOS))
    func applicationUnitTestTarget_macCatalyst() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("ClassOne.swift"),
                    TestFile("AppTarget-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("UnitTestTarget-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "ENABLE_HARDENED_RUNTIME": "NO",
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "SDKROOT": "iphoneos",
                        "SUPPORTS_MACCATALYST": "YES",
                        "SWIFT_VERSION": swiftVersion,
                        "INFOPLIST_FILE": "$(TARGET_NAME)-Info.plist"
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "UnitTestTarget",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/AppTarget",
                                                "BUNDLE_LOADER": "$(TEST_HOST)",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                        ]),
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writePlist(Path("/tmp/Test/aProject/Entitlements.plist"), .plDict([:]))
        try await fs.writeFileContents(self.swiftCompilerPath) { $0 <<< "binary" }
        for frameworkSubpath in await testFrameworkSubpaths() {
            let frameworkPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(frameworkPath.dirname, recursive: true)
            try fs.write(frameworkPath, contents: ByteString(encodingAsUTF8: frameworkPath.basename))
        }

        // Check a debug build for macCatalyst
        await tester.checkBuild(runDestination: .macCatalyst, fs: fs) { results in

            results.checkTarget("UnitTestTarget") { target in
                let targetName = target.target.name

                // Check that the test bundle is being created at the correct location
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/PlugIns/\(targetName).xctest"])) { _ in }

                // Check that the link task uses the correct -bundle_loader path
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/PlugIns/UnitTestTarget.xctest/Contents/MacOS/UnitTestTarget", "normal"])
                    task.checkCommandLineContainsUninterrupted(["-bundle_loader", "\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/MacOS/AppTarget"])
                }
            }

            // Check the tasks of the app target that we care about.
            await results.checkTarget("AppTarget") { target in
                // There should be tasks to copy the test frameworks and re-sign them.
                for framework in await testFrameworkSubpaths() {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename(frameworkName)) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/\(frameworkPath.str)"])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(frameworkName)) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/Frameworks/\(frameworkName)"])
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename(frameworkName))
                }

                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            results.checkNoDiagnostics()
        }
    }


    /// Due to the interleaving of a host and hosted target, if Parallelize Build is turned *off* we take special measures to avoid known dependency cycles.  (Serial target builds are far more likely to lead to dependency cycles because of the strict ordering of targets.)  c.f. rdar://problem/72563741
    @Test(.requireSDKs(.macOS))
    func applicationUnitTestTarget_usingSerializedTargetBuild() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("ClassOne.swift"),
                    TestFile("AppTarget-Info.plist"),

                    // Framework sources
                    TestFile("ClassTwo.swift"),
                    TestFile("FwkTarget-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("HostedTestTargetOne-Info.plist"),
                    TestFile("TestTwo.swift"),
                    TestFile("HostedTestTargetTwo-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "SDKROOT": "macosx",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                        "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "AppTarget-Info.plist",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "HostedTestTargetOne",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "HostedTestTargetOne-Info.plist",
                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                            "BUNDLE_LOADER": "$(TEST_HOST)",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                        ]),
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "HostedTestTargetTwo",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "HostedTestTargetTwo-Info.plist",
                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                            "BUNDLE_LOADER": "$(TEST_HOST)",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestTwo.swift",
                        ]),
                    ],
                    dependencies: ["AppTarget"]
                ),
                // The framework target exists just to be a buffer between the app target and the test targets, which previously triggered a cycle.
                TestStandardTarget(
                    "FwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "FwkTarget-Info.plist",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassTwo.swift",
                        ]),
                    ],
                    dependencies: []
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writePlist(Path("/tmp/Test/aProject/Entitlements.plist"), .plDict([:]))
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }

        for frameworkSubpath in await testFrameworkSubpaths() {
            let frameworkPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(frameworkPath.dirname, recursive: true)
            try fs.write(frameworkPath, contents: ByteString(encodingAsUTF8: frameworkPath.basename))
        }

        let xctrunnerPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app")
        try await fs.writeXCTRunnerApp(xctrunnerPath, archs: ["arm64", "arm64e", "x86_64"], platform: .macOS, infoLookup: core)

        // Perform a build which has a specific target order in the top-level targets, and which has Parallelize Build turned off.  Specifically we insert the framework test target *after* the app target, but *before* the hosted test targets.
        let topLevelTargets = [tester.workspace.projects[0].targets[0], tester.workspace.projects[0].targets[3], tester.workspace.projects[0].targets[1], tester.workspace.projects[0].targets[2]]
        let deviceParameters = BuildParameters(action: .build, configuration: "Debug")
        let debugBuildRequest = BuildRequest(parameters: deviceParameters, buildTargets: topLevelTargets.map({ BuildRequest.BuildTargetInfo(parameters: deviceParameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        try await tester.checkBuild(runDestination: .macOS, buildRequest: debugBuildRequest, fs: fs) { results in
            // Ignore task types we don't plan to examine.
            results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "RegisterExecutionPolicyException"])

            var targetName = ""
            var hostedTargetTasks = [any PlannedTask]()

            // Check the first hosted test target.
            targetName = "HostedTestTargetOne"
            results.checkTarget(targetName) { target in
                var tasks = [any PlannedTask]()
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    tasks.append(task)
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).xctest")) { task in
                    tasks.append(task)
                }
                hostedTargetTasks.append(contentsOf: tasks)

                // We don't care about the rest of the app target's tasks for this test.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the second hosted test target.
            targetName = "HostedTestTargetTwo"
            results.checkTarget(targetName) { target in
                let hostedTestOneTasks = hostedTargetTasks

                var tasks = [any PlannedTask]()
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    tasks.append(task)
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).xctest")) { task in
                    tasks.append(task)
                }
                hostedTargetTasks.append(contentsOf: tasks)

                // Make sure the second host target follows the first.
                for task in tasks {
                    for hostedTestOneTask in hostedTestOneTasks {
                        results.checkTaskFollows(task, antecedent: hostedTestOneTask)
                    }
                }

                // We don't care about the rest of the app target's tasks for this test.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the tasks of the app target.
            targetName = "AppTarget"
            var appTargetTasks = [any PlannedTask]()
            try results.checkTarget(targetName) { target in
                var capturedTask: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    capturedTask = task
                }
                let appCompilationTask = try #require(capturedTask, "unable to find compilation task for \(targetName) target")
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    capturedTask = task
                }
                let appLinkTask = try #require(capturedTask, "unable to find link task for \(targetName) target")
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).app")) { task in
                    capturedTask = task
                }
                let appSigningTask = try #require(capturedTask, "unable to find sign task for \(targetName) target")
                appTargetTasks.append(contentsOf: [appCompilationTask, appLinkTask, appSigningTask])

                // Check that the app's tasks are ordered as we expect.
                results.checkTaskFollows(appLinkTask, antecedent: appCompilationTask)
                results.checkTaskFollows(appSigningTask, antecedent: appLinkTask)

                // Check that the hosted targets' tasks are ordered with respect to the app target as we expect.
                for testTask in hostedTargetTasks {
                    // Tasks that run before the hosted test targets' tasks.
                    results.checkTaskFollows(testTask, antecedent: appCompilationTask)
                    results.checkTaskFollows(testTask, antecedent: appLinkTask)

                    // Tasks that run after.
                    results.checkTaskFollows(appSigningTask, antecedent: testTask)
                }

                // We don't care about the rest of the app target's tasks for this test.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the tasks of the framework target.
            targetName = "FwkTarget"
            results.checkTarget(targetName) { target in
                var tasks = [any PlannedTask]()
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    tasks.append(task)
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).framework"))

                // The framework target ends up disconnected from all the other targets, because it has no explicit dependencies on any of them.
                // The hosted test targets aren't ordered after it because it would lead to a cycle per rdar://problem/72563741.
                // And it isn't ordered after the host app target because that *could* lead to a cycle per rdar://problem/73210420.  It doesn't in this case, but in order to confirm that we would need to check whether the any of the test targets depend on it, and while we can fairly easily check for immediate dependencies, we can't easily check for transitive dependencies.
                // So while this notionally violates the spirit of serialized target builds, I don't presently see an easy way out of it.
                // In theory it *should* be ordered after both other targets, as this commented-out code suggests, and maybe someday we'll get there.
                //                for task in tasks {
                //                    for antecedentTask in hostedTargetTasks + appTargetTasks {
                //                        results.checkTaskFollows(task, antecedent: antecedentTask)
                //                    }
                //                }

                // We don't care about the rest of the app target's tasks for this test.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }


    /// This test exercises another case where when Parallelize Build is turned *off* there could be a cycle. In this case, the test target depends on the app target and an additional framework target, which used to result in a cycle if the framework target were listed after the app target.  c.f. rdar://problem/73210420
    ///
    /// This is different from `testApplicationUnitTestTarget_usingSerializedTargetBuild()` above because the framework target is a dependency of the test target, rather than being an intervening top-level target.
    @Test(.requireSDKs(.macOS))
    func applicationUnitTestTarget_usingSerializedTargetBuild_withAdditionalDependency() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("ClassOne.swift"),
                    TestFile("AppTarget-Info.plist"),

                    // Framework sources
                    TestFile("ClassTwo.swift"),
                    TestFile("FwkTarget-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("HostedTestTarget-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "SDKROOT": "macosx",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                        "DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "AppTarget-Info.plist",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.swift",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "HostedTestTarget",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "HostedTestTarget-Info.plist",
                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                            "BUNDLE_LOADER": "$(TEST_HOST)",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                        ]),
                    ],
                    // This is the key to this test: If FwkTarget is listed after AppTarget here, then there would previously have been a cycle.
                    dependencies: [
                        "AppTarget",
                        "FwkTarget",
                    ]
                ),
                TestStandardTarget(
                    "FwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "FwkTarget-Info.plist",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassTwo.swift",
                        ]),
                    ],
                    dependencies: []
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writePlist(Path("/tmp/Test/aProject/Entitlements.plist"), .plDict([:]))
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }

        for frameworkSubpath in await testFrameworkSubpaths() {
            let frameworkPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(frameworkPath.dirname, recursive: true)
            try fs.write(frameworkPath, contents: ByteString(encodingAsUTF8: frameworkPath.basename))
        }

        let xctrunnerPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app")
        try await fs.writeXCTRunnerApp(xctrunnerPath, archs: ["arm64", "arm64e", "x86_64"], platform: .macOS, infoLookup: core)

        // Perform a build where only the app and test targets are top-level targets, and which has Parallelize Build turned off.
        let topLevelTargets = [tester.workspace.projects[0].targets[0], tester.workspace.projects[0].targets[1]]
        let deviceParameters = BuildParameters(action: .build, configuration: "Debug")
        let debugBuildRequest = BuildRequest(parameters: deviceParameters, buildTargets: topLevelTargets.map({ BuildRequest.BuildTargetInfo(parameters: deviceParameters, target: $0) }), continueBuildingAfterErrors: false, useParallelTargets: false, useImplicitDependencies: true, useDryRun: false)
        try await tester.checkBuild(runDestination: .macOS, buildRequest: debugBuildRequest, fs: fs) { results in
            // Ignore task types we don't plan to examine.
            results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "RegisterExecutionPolicyException"])

            var targetName = ""

            // Capture tasks for the framework target.
            targetName = "FwkTarget"
            var fwkTargetTasks = [any PlannedTask]()
            results.checkTarget(targetName) { target in
                var tasks = [any PlannedTask]()
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    tasks.append(task)
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).framework"))
                fwkTargetTasks.append(contentsOf: tasks)

                // We don't care about the rest of the framework target's tasks for this test.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check tasks for the hosted test target.  At this point all we care about is that its tasks follow the framework target's tasks.
            targetName = "HostedTestTarget"
            var hostedTargetTasks = [any PlannedTask]()
            results.checkTarget(targetName) { target in
                var tasks = [any PlannedTask]()
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    tasks.append(task)
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).xctest")) { task in
                    tasks.append(task)
                }
                hostedTargetTasks.append(contentsOf: tasks)

                // We don't care about the rest of the app target's tasks for this test.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })

                // Check that the hosted targets' tasks follow the framework target's tasks.
                for task in hostedTargetTasks {
                    for antecedentTask in fwkTargetTasks {
                        results.checkTaskFollows(task, antecedent: antecedentTask)
                    }
                }
            }

            // Finally, check the tasks of the app target.  As usual, the hosted test target's tasks should come after compiling/linking and before signing.
            // But the real check is its relationship to the framework target's tasks, and to make sure there's no cycle here.
            // Since this is tricky to envision (or was for me), here's how the cycle would work if we establish that dependency:
            //  1. The test target depends on the framework target (explicitly).
            //  2. The framework target depends on the app target because of the ordering.  This means that its start task depends on the end task of the app target.
            //  3. The app target's end task depends on the app's postprocessing tasks such as codesigning, and eventually goes back to its will-sign task.
            //  4. The app target's will-sign task depends on the end task of the test target.  This establishes the cycle and brings us back to step 1.
            // We avoid the cycle in TargetOrderTaskProducer.inputsForDependencies() by not performing the ordering in (2).
            targetName = "AppTarget"
            var appTargetTasks = [any PlannedTask]()
            try results.checkTarget(targetName) { target in
                var capturedTask: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    capturedTask = task
                }
                let compilationTask = try #require(capturedTask, "unable to find compilation task for \(targetName) target")
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    capturedTask = task
                }
                let linkTask = try #require(capturedTask, "unable to find link task for \(targetName) target")
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).app")) { task in
                    capturedTask = task
                }
                let signingTask = try #require(capturedTask, "unable to find sign task for \(targetName) target")
                appTargetTasks.append(contentsOf: [compilationTask, linkTask, signingTask])

                // Check that the app's tasks are ordered as we expect.
                results.checkTaskFollows(linkTask, antecedent: compilationTask)
                results.checkTaskFollows(signingTask, antecedent: linkTask)

                // Check that the hosted targets' tasks are ordered with respect to the app target as we expect.
                for testTask in hostedTargetTasks {
                    // Tasks that run before the hosted test targets' tasks.
                    results.checkTaskFollows(testTask, antecedent: compilationTask)
                    results.checkTaskFollows(testTask, antecedent: linkTask)

                    // Tasks that run after.
                    results.checkTaskFollows(signingTask, antecedent: testTask)
                }

                // Check that the framework target's tasks don't follow any of the app target's tasks.
                for appTask in appTargetTasks {
                    for fwkTask in fwkTargetTasks {
                        results.checkTaskDoesNotFollow(fwkTask, antecedent: appTask)
                    }
                }

                // Check that the app target's compile and link tasks don't follow the framework target's tasks, but that the app target's codesign task does.
                for fwkTask in fwkTargetTasks {
                    results.checkTaskDoesNotFollow(compilationTask, antecedent: fwkTask)
                    results.checkTaskDoesNotFollow(linkTask, antecedent: fwkTask)
                    results.checkTaskFollows(signingTask, antecedent: fwkTask)
                }

                // We don't care about the rest of the app target's tasks for this test.
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }


    // MARK: UI test target using a test runner


    /// Test task construction for a UI test target for macOS.  Both debug and install builds are tested.
    @Test(.requireSDKs(.macOS))
    func uITestTarget_macOS() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("main.swift"),
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),
                    TestFile("AppTarget-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("TestTwo.swift"),
                    TestFile("UITestTarget-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "macosx",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                        "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "NO",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "UITestTarget",
                    type: .uiTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "UITestTarget-Info.plist",
                                                "PRODUCT_BUNDLE_IDENTIFIER": "com.dev.UITestTarget",
                                                "CODE_SIGN_IDENTITY": "-",
                                                "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                                                "TEST_FRAMEWORK_DEVELOPER_VARIANT_SUBPATH": "",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                            "TestTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ])
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "AppTarget-Info.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                            "ClassOne.swift",
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ])
                    ]
                ),
            ])
        let core = try await getCore()
        let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let MACOSX_DEPLOYMENT_TARGET = core.loadSDK(.macOS).defaultDeploymentTarget

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writePlist(Path("/tmp/Test/aProject/Entitlements.plist"), .plDict([:]))
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }

        for frameworkSubpath in await testFrameworkSubpaths(variantSubpath: "") {
            let frameworkPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(frameworkPath.dirname, recursive: true)
            try fs.write(frameworkPath, contents: ByteString(encodingAsUTF8: frameworkPath.basename))
        }

        // Create the XCTRunner.app source to copy.
        let xctrunnerPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app")
        try await fs.writeXCTRunnerApp(xctrunnerPath, archs: ["arm64", "arm64e", "x86_64"], platform: .macOS, infoLookup: core)

        // Check a debug build.
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check that results for the app target were generated, but they're not what we're testing here.
            results.checkTarget("AppTarget") { target in
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the unit test target.
            await results.checkTarget("UITestTarget") { target in
                // There should be an Info.plist processing task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkRuleInfo(["ProcessInfoPlistFile", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/Info.plist", "\(SRCROOT)/UITestTarget-Info.plist"])
                }

                // There should be one Swift compile phase, and a task to generate its output file map.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "UITestTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                    task.checkCommandLineContains(([[swiftCompilerPath.str, "-module-name", "UITestTarget", "-O", "@\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.SwiftFileList", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-g", /* options from the xcspec which sometimes change appear here */ "-swift-version", swiftVersion, "-I", "\(SRCROOT)/build/Debug", "-F", "\(SRCROOT)/build/Debug", "-F", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Frameworks", "-c", "-j\(compilerParallelismLevel)", "-incremental", "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftmodule", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-generated-files.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-own-target-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-project-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/Debug/include", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/DerivedSources-normal/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget-Swift.h", "-working-directory", SRCROOT]] as [[String]]).reduce([], +))
                    task.checkInputs([
                        .path("\(SRCROOT)/TestOne.swift"),
                        .path("\(SRCROOT)/TestTwo.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget_const_extract_protocols.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-generated-files.hmap"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-own-target-headers.hmap"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-all-target-headers.hmap"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-project-headers.hmap"),
                        .namePattern(.suffix("generated-headers")),
                        .namePattern(.suffix("copy-headers-completion")),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget Swift Compilation Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/TestOne.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/TestTwo.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/TestOne.swiftconstvalues"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/TestTwo.swiftconstvalues"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation Requirements", "UITestTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                    task.checkInputs([
                        .path("\(SRCROOT)/TestOne.swift"),
                        .path("\(SRCROOT)/TestTwo.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget_const_extract_protocols.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-generated-files.hmap"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-own-target-headers.hmap"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-all-target-headers.hmap"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget-project-headers.hmap"),
                        .namePattern(.suffix("copy-headers-completion")),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget Swift Compilation Requirements Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftmodule"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftsourceinfo"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.abi.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget-Swift.h"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftdoc"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget-OutputFileMap.json"])) { task in
                    task.checkInputs([
                        .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget-OutputFileMap.json"),])
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.SwiftFileList"])) { task, contents in
                    let inputFiles = ["\(SRCROOT)/TestOne.swift", "\(SRCROOT)/TestTwo.swift"]
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == inputFiles + [""])
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.SwiftConstValuesFileList"])) { task, contents in
                    let inputFiles = ["\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/TestOne.swiftconstvalues",
                                      "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/TestTwo.swiftconstvalues"]
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == inputFiles + [""])
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.DependencyMetadataFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == ["\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/Metadata.appintents/extract.actionsdata", ""])
                }
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.DependencyStaticMetadataFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == [""])
                }


                // There should be one link task, and a task to generate its link file list.
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.LinkFileList"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/MacOS/UITestTarget", "normal"])
                    task.checkCommandLineMatches(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-bundle", "-isysroot", .equal(core.loadSDK(.macOS).path.str), "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-L\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/usr/lib", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-iframework", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Frameworks", .anySequence, "-filelist", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.LinkFileList", "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftmodule", "-Xlinker", "-needed_framework", "-Xlinker", "XCTest", "-framework", "XCTest", "-Xlinker", "-needed-lXCTestSwiftSupport", "-lXCTestSwiftSupport", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/MacOS/UITestTarget"])
                }

                // There should be a 'Copy' of the generated header.
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/DerivedSources/UITestTarget-Swift.h", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget-Swift.h"])) { _ in }

                // There should be a 'Copy' of the module file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UITestTarget.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftmodule"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UITestTarget.swiftmodule/x86_64-apple-macos.abi.json", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.abi.json"])) { _ in }

                // There should be a 'Copy' of the sourceinfo file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UITestTarget.swiftmodule/Project/x86_64-apple-macos.swiftsourceinfo", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftsourceinfo"])) { _ in }

                // There should be a 'Copy' of the doc file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UITestTarget.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftdoc"])) { _ in }

                // There should be the expected mkdir tasks for the test bundle.

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/MacOS"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/MacOS"])
                }

                // Verify there is a task to create the VFS.
                results.checkTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")])
                }

                // There should be a task to write the entitlements plist.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Entitlements.plist")) { _ in }

                // There should be a task to write the product type Info.plist additions file.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("ProductTypeInfoPlistAdditions.plist")) { _ in }

                // check the remaining auxiliary files tasks, which should just be headermaps.
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".hmap"))) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix("const_extract_protocols.json"))) { _ in }

                // There should be a 'CopySwiftLibs' task.
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { task in
                    task.checkRuleInfo(["CopySwiftLibs", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"])
                    task.checkCommandLine(["builtin-swiftStdLibTool", "--copy", "--verbose", "--sign", "-", "--scan-executable", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/MacOS/UITestTarget", "--scan-folder", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/Frameworks", "--scan-folder", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/PlugIns", "--scan-folder", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/Library/SystemExtensions", "--scan-folder", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/Extensions", "--platform", "macosx", "--toolchain", "\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain", "--destination", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/Frameworks", "--strip-bitcode", "--scan-executable", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/usr/lib/libXCTestSwiftSupport.dylib", "--strip-bitcode-tool", "\(defaultToolchain.path.str)/usr/bin/bitcode_strip", "--emit-dependency-info", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/SwiftStdLibToolInputDependencies.dep", "--filter-for-swift-os"])
                }

                // Check selected tasks to copy the XCTRunner.app.
                results.checkTask(.matchTarget(target), .matchRule(["CopyAndPreserveArchs", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"])) { task in
                    task.checkCommandLine(["lipo", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Contents/MacOS/XCTRunner", "-output", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner", "-extract", "x86_64"])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .name("Copy \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PkgInfo", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Contents/PkgInfo"])) { task in
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PkgInfo"),
                        .name("Copy \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PkgInfo"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CopyPlistFile", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Info.plist", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Contents/Info.plist"])) { task in
                    task.checkCommandLine(["builtin-copyPlist", "--validate", "--convert", "xml1", "--macro-expansion", "WRAPPEDPRODUCTNAME", "UITestTarget-Runner", "--macro-expansion", "WRAPPEDPRODUCTBUNDLEIDENTIFIER", "com.dev.UITestTarget.xctrunner", "--macro-expansion", "TESTPRODUCTNAME", "UITestTarget", "--macro-expansion", "TESTPRODUCTBUNDLEIDENTIFIER", "com.dev.UITestTarget", "--copy-value", "UIDeviceFamily", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/Info.plist", "--outdir", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents", "--", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Contents/Info.plist"])
                    task.checkInputs(contain: [
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/Info.plist"),
                        .path("\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Contents/Info.plist"),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ProductPostprocessingTaskProducer"))),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Info.plist"),
                        .name("Preprocess \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Info.plist"),
                    ])
                }

                var nestedSigningTasks = [any PlannedTask]()

                // There should be tasks to copy the test frameworks and re-sign them.
                for framework in await testFrameworkSubpaths(variantSubpath: "") {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(frameworkName)")) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/\(frameworkPath.str)"])
                        task.checkInputs(contain: [
                            .path("\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/\(frameworkPath.str)"),
                            .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ProductPostprocessingTaskProducer"))),
                            .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                            .name("CopyTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(frameworkName)")) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"])
                        task.checkInputs(contain: [
                            .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                            .name("CopyTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                            .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ProductPostprocessingTaskProducer"))),
                            .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                            .name("SignTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                        ])

                        nestedSigningTasks.append(task)
                    }
                }

                // There should be tasks to sign the test bundle and the XCTRunner app, and one to generate entitlements which are used to sign each of them.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging")) { task in
                    task.checkRuleInfo(["ProcessProductPackaging", "/tmp/Test/aProject/Entitlements.plist", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent"])
                    task.checkCommandLine(["builtin-productPackagingUtility", "/tmp/Test/aProject/Entitlements.plist", "-entitlements", "-format", "xml", "-o", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent"])
                    task.checkInputs([
                        .path("/tmp/Test/aProject/Entitlements.plist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/DerivedSources/Entitlements.plist"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER")) { task in
                    task.checkRuleInfo(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent.der"])
                    task.checkCommandLine(["/usr/bin/derq", "query", "-f", "xml", "-i", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent", "-o", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent.der", "--raw"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent.der"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget.xctest")) { task in
                    task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"])
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"])
                    task.checkInputs(contain: [
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent"),
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/MacOS/UITestTarget"),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ChangeAlternatePermissions"))),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/MacOS/UITestTarget"),
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/_CodeSignature"),
                        .name("CodeSign \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                    ])

                    nestedSigningTasks.append(task)
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget-Runner.app")) { task in
                    task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app"])
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app"])
                    task.checkInputs(contain: ([[
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent"),
                        // The task to sign the runner depends on the tasks to copy the runner and the test frameworks.
                        .name("MkDir \(SRCROOT)/build/Debug/UITestTarget-Runner.app"),
                        .name("Preprocess \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Info.plist"),
                        .name("Copy \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PkgInfo"),
                        .name("Copy \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .name("SignTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/XCTest.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/XCUnit.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/XCUIAutomation.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/XCTestCore.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/XCTestSupport.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/XCTAutomationSupport.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/libXCTestSwiftSupport.dylib"),
                        .name("SignTestFramework \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/Frameworks/Testing.framework"),
                        .name("CodeSign \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .name("Copy \(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ProductPostprocessingTaskProducer"))),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                    ]] as [[NodePattern]]).reduce([], +))
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app"),
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .path("\(SRCROOT)/build/Debug/UITestTarget-Runner.app/_CodeSignature"),
                        .name("CodeSign \(SRCROOT)/build/Debug/UITestTarget-Runner.app"),
                    ])

                    // Check that this task follows all of the nested signing tasks.
                    for nestedSigningTask in nestedSigningTasks {
                        results.checkTaskFollows(task, antecedent: nestedSigningTask)
                    }
                }

                // There should be a 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"])) { _ in }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check that results for the app target were generated, but they're not what we're testing here.
            results.checkTarget("AppTarget") { target in
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the unit test target.
            await results.checkTarget("UITestTarget") { target in
                // Match tasks we're not carefully checking.
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/DerivedSources/UITestTarget-Swift.h", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget-Swift.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UITestTarget.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftmodule"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UITestTarget.swiftmodule/x86_64-apple-macos.abi.json", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.abi.json"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/UITestTarget.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftdoc"])) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { _ in })
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }
                // For an install build there should be a symlink in the built products dir for both the test bundle and the test runner app.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/UITestTarget.xctest", "../UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/UITestTarget-Runner.app", "../UninstalledProducts/macosx/UITestTarget-Runner.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Touch")) { _ in }

                // Check selected tasks to copy the XCTRunner.app.
                results.checkTask(.matchTarget(target), .matchRule(["CopyAndPreserveArchs", "/tmp/Test/aProject/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"])) { task in
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .name("Copy \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PkgInfo", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Contents/PkgInfo"])) { task in
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PkgInfo"),
                        .name("Copy \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PkgInfo"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CopyPlistFile", "\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Info.plist", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Contents/Info.plist"])) { task in
                    task.checkInputs(contain: [
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/Info.plist"),
                        .path("\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Contents/Info.plist"),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ProductPostprocessingTaskProducer"))),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Info.plist"),
                        .name("Preprocess \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Info.plist"),
                    ])
                }

                var nestedSigningTasks = [any PlannedTask]()

                // There should be tasks to copy the test frameworks and re-sign them.
                for framework in await testFrameworkSubpaths(variantSubpath: "") {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("\(frameworkName)")) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/\(frameworkPath.str)"])
                        task.checkInputs(contain: [
                            .path("\(core.developerPath.path.str)/Platforms/MacOSX.platform/Developer/\(frameworkPath.str)"),
                            .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ProductPostprocessingTaskProducer"))),
                            .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                            .name("CopyTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(frameworkName)")) { task in
                        task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"])
                        task.checkInputs(contain: [
                            .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                            .name("CopyTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                            .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ProductPostprocessingTaskProducer"))),
                            .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                            .name("SignTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/\(frameworkName)"),
                        ])

                        nestedSigningTasks.append(task)
                    }
                }

                // There should be tasks to sign the test bundle and the XCTRunner app, and one to generate entitlements which are used to sign each of them.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent"))) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget.xctest")) { task in
                    task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"])
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent", "--generate-entitlement-der", "\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"])
                    task.checkInputs(contain: [
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/MacOS/UITestTarget"),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ChangeAlternatePermissions"))),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/Contents/MacOS/UITestTarget"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest/_CodeSignature"),
                        .name("CodeSign \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                    ])

                    nestedSigningTasks.append(task)
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget-Runner.app")) { task in
                    task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app"])
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent", "--generate-entitlement-der", "\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app"])
                    task.checkInputs(contain: ([[
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/UITestTarget.build/UITestTarget.xctest.xcent"),
                        // The task to sign the runner depends on the tasks to copy the runner and the test frameworks.
                        .name("MkDir \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app"),
                        .name("Preprocess \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Info.plist"),
                        .name("Copy \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PkgInfo"),
                        .name("Copy \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .name("SignTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/XCTest.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/XCUnit.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/XCUIAutomation.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/XCTestCore.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/XCTestSupport.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/XCTAutomationSupport.framework"),
                        .name("SignTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/libXCTestSwiftSupport.dylib"),
                        .name("SignTestFramework \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/Frameworks/Testing.framework"),
                        .name("CodeSign \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/PlugIns/UITestTarget.xctest"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .name("Copy \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-ProductPostprocessingTaskProducer"))),
                        .namePattern(.and(.prefix("target-UITestTarget-"), .suffix("-entry"))),
                    ]] as [[NodePattern]]).reduce([], +))
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/Contents/MacOS/UITestTarget-Runner"),
                        .path("\(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app/_CodeSignature"),
                        .name("CodeSign \(SRCROOT)/build/UninstalledProducts/macosx/UITestTarget-Runner.app"),
                    ])

                    // Check that this task follows all of the nested signing tasks.
                    for nestedSigningTask in nestedSigningTasks {
                        results.checkTaskFollows(task, antecedent: nestedSigningTask)
                    }
                }


                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test task construction for a UI test target for iOS.  Both debug and install builds are tested for the device, and a debug build is tested for the simulator.
    ///
    /// This test is primarily intended to validate that building for iOS works, to check that the different bundle packaging for iOS is being handled, and to check some ways in which building for iOS differs from building for macOS.  The corresponding macOS test dives deeper into checking details of the tasks.
    @Test(.requireSDKs(.macOS, .iOS))
    func uITestTarget_iOS() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // App sources
                    TestFile("main.swift"),
                    TestFile("ClassOne.swift"),
                    TestFile("ClassTwo.swift"),
                    TestFile("AppTarget-Info.plist"),

                    // Test target sources
                    TestFile("TestOne.swift"),
                    TestFile("TestTwo.swift"),
                    TestFile("UITestTarget-Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ARCHS[sdk=iphoneos*]": "arm64",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "UITestTarget",
                    type: .uiTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "UITestTarget-Info.plist",
                                                "CODE_SIGN_IDENTITY": "Apple Development",
                                                "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "TestOne.swift",
                            "TestTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ])
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "AppTarget-Info.plist",
                                                "CODE_SIGN_IDENTITY": "Apple Development",
                                                "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                            "ClassOne.swift",
                            "ClassTwo.swift",
                        ]),
                        TestFrameworksBuildPhase([
                        ])
                    ]
                ),
            ])
        let core = try await getCore()
        let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try await fs.writePlist(Path("/tmp/Test/aProject/Entitlements.plist"), .plDict([:]))
        try await fs.writeFileContents(self.swiftCompilerPath) { $0 <<< "binary" }
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
        for frameworkSubpath in await testFrameworkSubpaths() {
            let iosframeworkPath = core.developerPath.path.join("Platforms/iPhoneOS.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(iosframeworkPath.dirname, recursive: true)
            try fs.write(iosframeworkPath, contents: ByteString(encodingAsUTF8: iosframeworkPath.basename))

            let isimframeworkPath = core.developerPath.path.join("Platforms/iPhoneSimulator.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(isimframeworkPath.dirname, recursive: true)
            try fs.write(isimframeworkPath, contents: ByteString(encodingAsUTF8: iosframeworkPath.basename))
        }

        // Create the XCTRunner.app source to copy.
        let deviceXctrunnerPath = core.developerPath.path.join("Platforms/iPhoneOS.platform/Developer/Library/Xcode/Agents/XCTRunner.app")
        try await fs.writeXCTRunnerApp(deviceXctrunnerPath, archs: ["arm64", "arm64e"], platform: .iOS, infoLookup: core)

        let simXctrunnerPath = core.developerPath.path.join("Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/XCTRunner.app")
        try await fs.writeXCTRunnerApp(simXctrunnerPath, archs: ["x86_64"], platform: .iOSSimulator, infoLookup: core)

        // Check a debug build for the device.
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check that results for the app target were generated, but they're not what we're testing here.
            results.checkTarget("AppTarget") { target in
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the unit test target.
            await results.checkTarget("UITestTarget") { target in

                // There should be the expected mkdir tasks for the test bundle.
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { _ in }

                // There should be two tasks to copy the XCTRunner.app, and one to preprocess its Info.plist
                results.checkTask(.matchTarget(target), .matchRule(["CopyAndPreserveArchs", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/UITestTarget-Runner"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PkgInfo", "\(core.developerPath.path.str)/Platforms/iPhoneOS.platform/Developer/Library/Xcode/Agents/XCTRunner.app/PkgInfo"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyPlistFile", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/Info.plist", "\(core.developerPath.path.str)/Platforms/iPhoneOS.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Info.plist"])) { _ in }

                // There should be tasks to copy the test frameworks and re-sign them.
                var nestedSigningTasks = [any PlannedTask]()
                for framework in await testFrameworkSubpaths() {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/iPhoneOS.platform/Developer/\(frameworkPath.str)"])) { _ in }
                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/Frameworks/\(frameworkName)"])) { task in
                        nestedSigningTasks.append(task)
                    }
                }

                // There should be a task to generate the provisioning profile in the XCTRunner app.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/embedded.mobileprovision"])) { _ in }

                // There should be a task to generate a dSYM file for the target. This is placed in the PlugIns directory alongside the .xctest bundle.
                var generateDSYMTask: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRule(["GenerateDSYMFile", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest.dSYM", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest/UITestTarget"])) { task in
                    generateDSYMTask = task
                }

                // There should be tasks to sign the test bundle and the XCTRunner app, and one to generate entitlements which are used to sign each of them.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "/tmp/Test/aProject/Entitlements.plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/UITestTarget.xctest.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/UITestTarget.xctest.xcent", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/UITestTarget.xctest.xcent.der"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { task in
                    nestedSigningTasks.append(task)
                }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app"])) { task in
                    // Check that this task follows all of the nested signing tasks.
                    for nestedSigningTask in nestedSigningTasks {
                        results.checkTaskFollows(task, antecedent: nestedSigningTask)
                    }
                    // Check that this task follows the GenerateDSYMFile task, since the dSYM is placed inside the Runner.app's PlugIns folder.
                    if let generateDSYMTask {
                        results.checkTaskFollows(task, antecedent: generateDSYMTask)
                    }
                }

                // Match tasks we're not specifically checking.
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/DerivedSources/UITestTarget-Swift.h", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/Objects-normal/arm64/UITestTarget-Swift.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget.swiftmodule/arm64-apple-ios.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/Objects-normal/arm64/UITestTarget.swiftmodule"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget.swiftmodule/arm64-apple-ios.abi.json", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/Objects-normal/arm64/UITestTarget.abi.json"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget.swiftmodule/Project/arm64-apple-ios.swiftsourceinfo", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/Objects-normal/arm64/UITestTarget.swiftsourceinfo"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget.swiftmodule/arm64-apple-ios.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/Objects-normal/arm64/UITestTarget.swiftdoc"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { _ in }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install build for the device.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            // For debugging convenience, consume all the Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check that results for the app target were generated, but they're not what we're testing here.
            results.checkTarget("AppTarget") { target in
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the unit test target.
            await results.checkTarget("UITestTarget") { target in

                // There should be the expected mkdir tasks for the test bundle.
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { _ in }

                // There should be two tasks to copy the XCTRunner.app, and one to preprocess its Info.plist
                results.checkTask(.matchTarget(target), .matchRule(["CopyAndPreserveArchs", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/UITestTarget-Runner"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/PkgInfo", "\(core.developerPath.path.str)/Platforms/iPhoneOS.platform/Developer/Library/Xcode/Agents/XCTRunner.app/PkgInfo"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyPlistFile", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/Info.plist", "\(core.developerPath.path.str)/Platforms/iPhoneOS.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Info.plist"])) { _ in }

                // There should be tasks to copy the test frameworks and re-sign them.
                var nestedSigningTasks = [any PlannedTask]()
                for framework in await testFrameworkSubpaths() {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/iPhoneOS.platform/Developer/\(frameworkPath.str)"])) { _ in }
                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/Frameworks/\(frameworkName)"])) { task in
                        nestedSigningTasks.append(task)
                    }
                }

                // There should be a task to generate the provisioning profile in the XCTRunner app.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/embedded.mobileprovision"])) { _ in }

                // There should be a task to generate a dSYM file for the target. This is placed in the PlugIns directory alongside the .xctest bundle.
                var generateDSYMTask: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRule(["GenerateDSYMFile", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest.dSYM", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest/UITestTarget"])) { task in
                    generateDSYMTask = task
                }

                // There should be tasks to sign the test bundle and the XCTRunner app, and one to generate entitlements which are used to sign each of them.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "/tmp/Test/aProject/Entitlements.plist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/UITestTarget.xctest.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/UITestTarget.xctest.xcent", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/UITestTarget.xctest.xcent.der"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { task in
                    nestedSigningTasks.append(task)
                }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app"])) { task in
                    // Check that this task follows all of the nested signing tasks.
                    for nestedSigningTask in nestedSigningTasks {
                        results.checkTaskFollows(task, antecedent: nestedSigningTask)
                    }
                    // Check that this task follows the GenerateDSYMFile task, since the dSYM is placed inside the Runner.app's PlugIns folder.
                    if let generateDSYMTask {
                        results.checkTaskFollows(task, antecedent: generateDSYMTask)
                    }
                }

                // Match tasks we're not specifically checking.
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/DerivedSources/UITestTarget-Swift.h", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/Objects-normal/arm64/UITestTarget-Swift.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget.swiftmodule/arm64-apple-ios.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/Objects-normal/arm64/UITestTarget.swiftmodule"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget.swiftmodule/arm64-apple-ios.abi.json", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/Objects-normal/arm64/UITestTarget.abi.json"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget.swiftmodule/arm64-apple-ios.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/Objects-normal/arm64/UITestTarget.swiftdoc"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }
                // For an install build there should be a symlink in the built products dir for both the test bundle and the test runner app.
                results.checkTask(.matchTarget(target), .matchRuleType("SymLink"), .matchRule(["SymLink", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget.xctest", "../UninstalledProducts/iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SymLink"), .matchRule(["SymLink", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app", "../UninstalledProducts/iphoneos/UITestTarget-Runner.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/UninstalledProducts/iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { _ in }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check a debug build for the simulator.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOSSimulator, fs: fs) { results in
            // For debugging convenience, consume all the Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all build directory tasks
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }

            // Check that results for the app target were generated, but they're not what we're testing here.
            results.checkTarget("AppTarget") { target in
                results.checkTasks(.matchTarget(target), body: { (tasks) -> Void in #expect(tasks.count > 0) })
            }

            // Check the unit test target.
            await results.checkTarget("UITestTarget") { target in

                // There should be the expected mkdir tasks for the test bundle.
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { _ in }

                // There should be two tasks to copy the XCTRunner.app, and one to preprocess its Info.plist
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app/UITestTarget-Runner", "\(core.developerPath.path.str)/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/XCTRunner.app/XCTRunner"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app/PkgInfo", "\(core.developerPath.path.str)/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/XCTRunner.app/PkgInfo"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyPlistFile", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app/Info.plist", "\(core.developerPath.path.str)/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/XCTRunner.app/Info.plist"])) { _ in }

                // There should be tasks to copy the test frameworks.  But the test frameworks are not signed for the simulator.
                var nestedSigningTasks = [any PlannedTask]()
                for framework in await testFrameworkSubpaths() {
                    let frameworkPath = Path(framework)
                    let frameworkName = frameworkPath.basename
                    results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app/Frameworks/\(frameworkName)", "\(core.developerPath.path.str)/Platforms/iPhoneSimulator.platform/Developer/\(frameworkPath.str)"])) { _ in }
                }

                // There should be a task to generate a dSYM file for the target. This is placed in the PlugIns directory alongside the .xctest bundle.
                var generateDSYMTask: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRule(["GenerateDSYMFile", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest.dSYM", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest/UITestTarget"])) { task in
                    generateDSYMTask = task
                }

                // There should tasks to generate signed & simulated entitlements and one to sign the test bundle.
                // But for the simulator there is no task to sign the runner app, nor to embed the provisioning profile in it.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "/tmp/Test/aProject/Entitlements.plist", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/UITestTarget.xctest.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/UITestTarget.xctest.xcent", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/UITestTarget.xctest.xcent.der"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "/tmp/Test/aProject/Entitlements.plist", "/tmp/Test/aProject/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/UITestTarget.xctest-Simulated.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "/tmp/Test/aProject/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/UITestTarget.xctest-Simulated.xcent", "/tmp/Test/aProject/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/UITestTarget.xctest-Simulated.xcent.der"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { task in
                    nestedSigningTasks.append(task)
                }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app"])) { task in
                    // Check that this task follows all of the nested signing tasks.
                    for nestedSigningTask in nestedSigningTasks {
                        results.checkTaskFollows(task, antecedent: nestedSigningTask)
                    }
                    // Check that this task follows the GenerateDSYMFile task, since the dSYM is placed inside the Runner.app's PlugIns folder.
                    if let generateDSYMTask {
                        results.checkTaskFollows(task, antecedent: generateDSYMTask)
                    }
                }

                // Match tasks we're not specifically checking.
                results.checkTaskExists(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/DerivedSources/UITestTarget-Swift.h", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/Objects-normal/x86_64/UITestTarget-Swift.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget.swiftmodule/x86_64-apple-ios-simulator.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftmodule"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget.swiftmodule/x86_64-apple-ios-simulator.abi.json", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/Objects-normal/x86_64/UITestTarget.abi.json"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget.swiftmodule/Project/x86_64-apple-ios-simulator.swiftsourceinfo", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftsourceinfo"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget.swiftmodule/x86_64-apple-ios-simulator.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/UITestTarget.build/Objects-normal/x86_64/UITestTarget.swiftdoc"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug-iphonesimulator/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])) { _ in }

                // Check there are no more tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check a build for a pre-Swift-in-the-OS deployment target
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["IPHONEOS_DEPLOYMENT_TARGET": "12.0"]), runDestination: .macOS, fs: fs) { results in
            results.checkTarget("UITestTarget") { target in

                // There should be a 'CopySwiftLibs' task that includes a reference to the libXCTestSwiftSupport.dylib executable.
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { task in
                    task.checkRuleInfo(["CopySwiftLibs", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest"])
                    task.checkCommandLine(["builtin-swiftStdLibTool", "--copy", "--verbose", "--sign", "105DE4E702E4", "--scan-executable", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest/UITestTarget", "--scan-folder", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest/Frameworks", "--scan-folder", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest/PlugIns", "--scan-folder", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest/SystemExtensions", "--scan-folder", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest/Extensions", "--platform", "iphoneos", "--toolchain", "\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain", "--destination", "\(SRCROOT)/build/Debug-iphoneos/UITestTarget-Runner.app/PlugIns/UITestTarget.xctest/Frameworks", "--strip-bitcode", "--scan-executable", "\(core.developerPath.path.str)/Platforms/iPhoneOS.platform/Developer/usr/lib/libXCTestSwiftSupport.dylib", "--strip-bitcode-tool", "\(defaultToolchain.path.str)/usr/bin/bitcode_strip", "--emit-dependency-info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/UITestTarget.build/SwiftStdLibToolInputDependencies.dep", "--back-deploy-swift-concurrency"])
                }
            }

            results.checkNoDiagnostics()
        }
    }

    // MARK: Helpers

    /// Get the array of test framework subpaths, based on the specified options.
    ///
    /// - Parameters:
    ///     - variantSubpath: A path to prefix each of the returned subpaths
    ///         with. Defaults to an empty string, i.e. no prefix.
    ///     - includeXCUIAutomation: Whether XCUIAutomation.framework should be
    ///         included. Defaults to `true`.
    ///
    /// - Returns: An array of test framework subpaths.
    private func testFrameworkSubpaths(
        variantSubpath: String = "",
        includeXCUIAutomation: Bool = true
    ) async -> [String] {
        var subpaths = [
            "Library/Frameworks/XCTest.framework",
            "Library/Frameworks/Testing.framework",
            "Library/PrivateFrameworks/XCTestCore.framework",
            "Library/PrivateFrameworks/XCUnit.framework",
            "Library/PrivateFrameworks/XCTestSupport.framework",
            "Library/PrivateFrameworks/XCTAutomationSupport.framework",
            "usr/lib/libXCTestSwiftSupport.dylib",
        ]

        if includeXCUIAutomation {
            subpaths.append("Library/Frameworks/XCUIAutomation.framework")
        }

        return subpaths.map { "\(variantSubpath)\($0)" }
    }
}
