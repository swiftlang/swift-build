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
@_spi(Testing) import SWBUtil

import SWBTaskConstruction
import Foundation

/// Task construction tests related to Swift compilation.
@Suite
fileprivate struct SwiftTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func swiftInBundleResourcesPhase() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift")
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CURRENT_PROJECT_VERSION": "3.1",
                        "SWIFT_VERSION": swiftVersion,
                    ]
                )
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug"
                        )
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "main.swift"
                        ])
                    ]
                )
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkWarning(StringPattern(stringLiteral: "The Swift file \"\(SRCROOT)/main.swift\" cannot be processed by a Copy Bundle Resources build phase (in target 'AppTarget' from project 'aProject')"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftAppBasics_preSwiftOS() async throws {
        try await _testSwiftAppBasics(deploymentTargetVersion: "10.14.0", shouldEmitSwiftRPath: true, shouldFilterSwiftLibs: false, shouldBackDeploySwiftConcurrency: true)
    }

    @Test(.requireSDKs(.macOS))
    func swiftAppBasics_postSwiftOS() async throws {
        try await _testSwiftAppBasics(deploymentTargetVersion: "12.0", shouldEmitSwiftRPath: false, shouldFilterSwiftLibs: true, shouldBackDeploySwiftConcurrency: false)
    }

    @Test(.requireSDKs(.macOS))
    func swiftAppBasics_preSwiftOSDeploymentTarget_postSwiftOSTargetDevice() async throws {
        try await _testSwiftAppBasics(deploymentTargetVersion: "10.14.0", targetDeviceOSVersion: "11.0", targetDevicePlatformName: "macosx", shouldEmitSwiftRPath: true, shouldFilterSwiftLibs: true, shouldBackDeploySwiftConcurrency: true)
    }

    @Test(.requireSDKs(.macOS))
    func swiftAppBasics_preSwiftOSDeploymentTarget_postSwiftOSTargetDevice_mixedPlatform() async throws {
        try await _testSwiftAppBasics(deploymentTargetVersion: "10.14.0", targetDeviceOSVersion: "14.0", targetDevicePlatformName: "iphoneos", shouldEmitSwiftRPath: true, shouldFilterSwiftLibs: false, shouldBackDeploySwiftConcurrency: true)
    }

    @Test(.requireSDKs(.macOS))
    func swiftAppBasics_postSwiftOSDeploymentTarget_preSwiftConcurrencySupportedNatively() async throws {
        try await _testSwiftAppBasics(deploymentTargetVersion: "11.0", shouldEmitSwiftRPath: true, shouldFilterSwiftLibs: true, shouldBackDeploySwiftConcurrency: true)
    }

    @Test(.requireSDKs(.macOS), .userDefaults(["AllowRuntimeSearchPathAdditionForSwiftConcurrency": "0"]))
    func swiftAppBasics_postSwiftOSDeploymentTarget_preSwiftConcurrencySupportedNatively_DisallowRpathInjection() async throws {
        try await _testSwiftAppBasics(deploymentTargetVersion: "11.0", shouldEmitSwiftRPath:false, shouldFilterSwiftLibs: true, shouldBackDeploySwiftConcurrency: true)
    }

    func _testSwiftAppBasics(deploymentTargetVersion: String, targetDeviceOSVersion: String? = nil, targetDevicePlatformName: String? = nil, toolchain toolchainIdentifier: String = "default", shouldEmitSwiftRPath: Bool, shouldFilterSwiftLibs: Bool, shouldBackDeploySwiftConcurrency: Bool) async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let swiftFeatures = try await self.swiftFeatures

        // Test the basics of task construction for an app.
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("foo.swift"),
                    TestFile("bar.swift"),
                    TestFile("baz.fake-swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "CURRENT_PROJECT_VERSION": "3.1",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "MACOSX_DEPLOYMENT_TARGET": deploymentTargetVersion,
                        "SWIFT_EMIT_MODULE_INTERFACE": "YES",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                        "SWIFT_INCLUDE_PATHS": "/tmp/include",
                        "SWIFT_SYSTEM_INCLUDE_PATHS": "/tmp/system/include",
                        "TAPI_EXEC": tapiToolPath.str,
                    ])],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "VERSIONING_SYSTEM": "apple-generic",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                            "foo.swift",
                            "baz.fake-swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "FwkTarget.framework"])
                    ],
                    buildRules: [TestBuildRule(filePattern: "*/*.fake-swift", script: "echo \"make some swift stuff\"", outputs: [
                        "$(DERIVED_FILES_DIR)/$(INPUT_FILE_BASE).swift"
                    ])],
                    dependencies: ["FwkTarget"]),
                TestStandardTarget(
                    "FwkTarget",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "bar.swift"])],
                    dependencies: ["MockTarget"]),
                // This target is a mock to ensure we still generate a VFS, even if we wouldn't for the "key" target.
                TestAggregateTarget("MockTarget"),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let MACOSX_DEPLOYMENT_TARGET = deploymentTargetVersion

        // Create a fake codesign_allocate tool so it can be found in the executable search paths.
        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        try await fs.writeFileContents(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate")) { $0 <<< "binary" }

        // NOTE: The toolchain cannot be set normally and must be passed in as an override.
        var overrides = ["TOOLCHAINS": toolchainIdentifier]
        overrides["TARGET_DEVICE_OS_VERSION"] = targetDeviceOSVersion
        overrides["TARGET_DEVICE_PLATFORM_NAME"] = targetDevicePlatformName
        let parameters = BuildParameters(configuration: "Debug", overrides: overrides)
        let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let effectiveToolchain = core.toolchainRegistry.lookup(toolchainIdentifier) ?? defaultToolchain

        // Check the debug build.
        await tester.checkBuild(parameters, runDestination: .macOS, fs: fs) { results in
            results.checkTarget("AppTarget") { target in
                // There should be a WriteAuxiliaryFile task to create the versioning file.
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c"])) { task, contents in
                    task.checkInputs([
                        .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c")])

                    #expect(contents == " extern const unsigned char AppTargetVersionString[];\n extern const double AppTargetVersionNumber;\n\n const unsigned char AppTargetVersionString[] __attribute__ ((used)) = \"@(#)PROGRAM:AppTarget  PROJECT:aProject-3.1\" \"\\n\";\n const double AppTargetVersionNumber __attribute__ ((used)) = (double)3.1;\n")
                }

                // There should be one RuleScriptExecution task.
                results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution")) { task in
                    task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/baz.swift", "\(SRCROOT)/baz.fake-swift", "normal", "x86_64"])
                    task.checkCommandLine(["/bin/sh", "-c", "echo \"make some swift stuff\""])
                    task.checkInputs([
                        .path("\(SRCROOT)/baz.fake-swift"),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/baz.swift")
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", target.target.name, "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                    task.checkCommandLineContains([swiftCompilerPath.str, "-module-name", "AppTarget", "-O", "@\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.SwiftFileList", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", /* options from the xcspec which sometimes change appear here */ "-swift-version", swiftVersion, "-I", "\(SRCROOT)/build/Debug", "-I", "/tmp/include", "-Isystem", "/tmp/system/include", "-F", "\(SRCROOT)/build/Debug", "-c", "-j\(compilerParallelismLevel)", "-incremental", "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftmodule", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget-generated-files.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget-own-target-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget-project-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/Debug/include", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-Swift.h", "-working-directory", SRCROOT])

                    task.checkInputs([
                        .path("\(SRCROOT)/main.swift"),
                        .path("\(SRCROOT)/foo.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/baz.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_const_extract_protocols.json"),
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
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget Swift Compilation Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/main.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/foo.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/baz.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/main.swiftconstvalues"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/foo.swiftconstvalues"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/baz.swiftconstvalues"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation Requirements", target.target.name, "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                    task.checkCommandLineContains([swiftCompilerPath.str, "-module-name", "AppTarget", "-O", "@\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.SwiftFileList", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", /* options from the xcspec which sometimes change appear here */ "-swift-version", swiftVersion, "-I", "\(SRCROOT)/build/Debug", "-I", "/tmp/include", "-Isystem", "/tmp/system/include", "-F", "\(SRCROOT)/build/Debug", "-c", "-j\(compilerParallelismLevel)", "-incremental", "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftmodule", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget-generated-files.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget-own-target-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget-project-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/Debug/include", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-Swift.h", "-working-directory", SRCROOT])

                    task.checkInputs([
                        .path("\(SRCROOT)/main.swift"),
                        .path("\(SRCROOT)/foo.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/baz.swift"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_const_extract_protocols.json"),
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
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget Swift Compilation Requirements Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftmodule"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-linker-args.resp"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftsourceinfo"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.abi.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftinterface"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.private.swiftinterface"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-Swift.h"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftdoc")
                    ])
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-OutputFileMap.json"])) { task, contents in
                    // Check the inputs and outputs.
                    task.checkInputs([
                        .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-OutputFileMap.json")])

                    // Check the contents.
                    guard let plist = try? PropertyList.fromJSONData(contents) else {
                        Issue.record("could not convert output file map from JSON to plist")
                        return
                    }
                    guard let dict = plist.dictValue else {
                        Issue.record("output file map is not a dictionary")
                        return
                    }

                    #expect(dict.count == 4)

                    // Check the global dictionary.
                    if let globalDict = dict[""] {
                        XCTAssertEqualPropertyListItems(globalDict, .plDict([
                            "swift-dependencies": .plString("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-master.swiftdeps"),
                            "diagnostics": .plString("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-master.dia"),
                            "emit-module-diagnostics": .plString("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-master-emit-module.dia"),
                            "emit-module-dependencies": .plString("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-master-emit-module.d"),
                            "pch": .plString("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-master-Bridging-header.pch"),
                        ]))
                    }
                    else {
                        Issue.record("output file map does not contain a global dictionary")
                    }

                    // Check the dictionary for the Swift file.
                    for filepath in [
                        "\(SRCROOT)/main.swift",
                        "\(SRCROOT)/foo.swift",
                        "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/baz.swift",
                    ] {
                        let filename = Path(filepath).basenameWithoutSuffix
                        if let fileDict = dict[filepath]?.dictValue {
                            #expect(fileDict["object"]?.stringValue == "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/\(filename).o")
                            #expect(fileDict["diagnostics"]?.stringValue == "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/\(filename).dia")
                            #expect(fileDict["dependencies"]?.stringValue == "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/\(filename).d")
                            #expect(fileDict["swift-dependencies"]?.stringValue == "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/\(filename).swiftdeps")
                            #expect(fileDict["swiftmodule"]?.stringValue == "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/\(filename)~partial.swiftmodule")
                            #expect(fileDict["const-values"]?.stringValue == "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/\(filename).swiftconstvalues")
                            if swiftFeatures.has(.indexUnitOutputPathWithoutWarning) {
                                #expect(fileDict["index-unit-output-path"]?.stringValue == "/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/\(filename).o")
                                #expect(fileDict.count == 7)
                            } else {
                                #expect(fileDict.count == 6)
                            }
                        }
                        else {
                            Issue.record("output file map does not contain a dictionary for '\(filename).swift'")
                        }
                    }
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.SwiftFileList"])) { task, contents in
                    let inputFiles = ["\(SRCROOT)/main.swift", "\(SRCROOT)/foo.swift", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/baz.swift"]
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == inputFiles + [""])
                }

                // There should be one 'CompileC' task (of the _vers file).
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_vers.o", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget_vers.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])
                }

                // There should be a 'Copy' of the generated header.
                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/AppTarget-Swift.h", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-Swift.h"])) { _ in }

                // There should be a 'Copy' of the module file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/AppTarget.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftmodule"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/AppTarget.swiftmodule/x86_64-apple-macos.abi.json", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.abi.json"])) { _ in }
                // There should be a 'Copy' of the doc file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/AppTarget.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftdoc"])) { _ in }

                // There should be a 'Copy' of the sourceinfo file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/AppTarget.swiftmodule/Project/x86_64-apple-macos.swiftsourceinfo", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftsourceinfo"])) { _ in }

                // There should be a 'Copy' of the swiftinterface file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/AppTarget.swiftmodule/x86_64-apple-macos.swiftinterface", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftinterface"])) { _ in }

                // There should be a 'Copy' of the private swiftinterface file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/AppTarget.swiftmodule/x86_64-apple-macos.private.swiftinterface", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.private.swiftinterface"])) { _ in }

                // There should be one link task, and a task to generate its link file list.
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget", "normal"])

                    let toolchain = toolchainIdentifier != "default" ? "OSX10.15" : "XcodeDefault"
                    task.checkCommandLine(([
                        ["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList"],
                        shouldEmitSwiftRPath ? ["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"] : [],
                        ["-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/\(toolchain).xctoolchain/usr/lib/swift/macosx", "-L/usr/lib/swift", "-framework", "FwkTarget", "-o", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget"]
                    ] as [[String]]).reduce([], +))

                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_vers.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/main.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/foo.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/baz.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList"),
                        .path("\(SRCROOT)/build/Debug"),
                        .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                        .namePattern(.prefix("target-"))])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget"),
                        .namePattern(.prefix("Linked Binary \(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget")),
                        .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_dependency_info.dat"),
                    ])
                }

                // There should be a task to embed the Swift standard libraries.
                // There should be a 'CopySwiftLibs' task.
                results.checkTask(.matchTarget(target), .matchRuleType("CopySwiftLibs")) { task -> Void in
                    task.checkRuleInfo(["CopySwiftLibs", "\(SRCROOT)/build/Debug/AppTarget.app"])
                    task.checkCommandLine(([["builtin-swiftStdLibTool", "--copy", "--verbose", "--scan-executable", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget", "--scan-folder", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks", "--scan-folder", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns", "--scan-folder", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Library/SystemExtensions", "--scan-folder", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Extensions", "--scan-folder", "\(SRCROOT)/build/Debug/FwkTarget.framework", "--platform", "macosx", "--toolchain", effectiveToolchain.path.str], (toolchainIdentifier == "default" ? [] : ["--toolchain", defaultToolchain.path.str]), ["--destination", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks", "--strip-bitcode", "--strip-bitcode-tool", "\(effectiveToolchain.path.str)/usr/bin/bitcode_strip", "--emit-dependency-info", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/SwiftStdLibToolInputDependencies.dep"], shouldFilterSwiftLibs ? ["--filter-for-swift-os"] : [], shouldBackDeploySwiftConcurrency ? ["--back-deploy-swift-concurrency"] : []] as [[String]]).reduce([], +))

                    task.checkInputs([
                        .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget"),
                        .namePattern(.prefix("target-")),
                        .namePattern(.prefix("target-")),
                        .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                    task.checkOutputs([
                        .name("CopySwiftStdlib \(SRCROOT)/build/Debug/AppTarget.app"),])

                    task.checkEnvironment([
                        "CODESIGN_ALLOCATE":    .equal(core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/bin/codesign_allocate").str),
                        "DEVELOPER_DIR":        .equal(core.developerPath.path.str),
                        "SDKROOT":              .equal(core.loadSDK(.macOS).path.str),
                        // This is coming from our overrides in unit test infrastructure.
                        "TOOLCHAINS": .equal(toolchainIdentifier),
                    ], exact: true)
                }

                // There should be a product 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRuleType("Touch")) { task in
                    task.checkRuleInfo(["Touch", "\(SRCROOT)/build/Debug/AppTarget.app"])
                    task.checkCommandLine(["/usr/bin/touch", "-c", "\(SRCROOT)/build/Debug/AppTarget.app"])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("RegisterExecutionPolicyException")) { task in
                    task.checkRuleInfo(["RegisterExecutionPolicyException", "\(SRCROOT)/build/Debug/AppTarget.app"])
                }

                // There should be a 'RegisterWithLaunchServices' task.
                results.checkTask(.matchTarget(target), .matchRuleType("RegisterWithLaunchServices")) { task in
                    task.checkRuleInfo(["RegisterWithLaunchServices", "\(SRCROOT)/build/Debug/AppTarget.app"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/Debug/AppTarget.app"),
                        .namePattern(.and(.prefix("target-"), .suffix("-Barrier-Validate"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                        .namePattern(.and(.prefix("target"), .suffix("-entry"))),
                    ])
                    #expect(task.outputs.map{ $0.name } == [
                        "AppTarget.app", "LSRegisterURL \(SRCROOT)/build/Debug/AppTarget.app"])
                }

                // Ignore all the MkDir tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir")) { _ in }
            }

            // Check the framework target - it exists to check that swift-stdlib-tool examines it, but we match its tasks so we can assert that all tasks are matched.
            results.checkTarget("FwkTarget") { target in
                // There should be one Swift compilation phase (3 tasks) a link step, and a tapi step.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }

                // check the presence of a couple auxiliary files.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("FwkTarget-OutputFileMap.json")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("FwkTarget.SwiftFileList")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("FwkTarget.LinkFileList")) { _ in }
                if SWBFeatureFlag.enableEagerLinkingByDefault.value {
                    results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("FwkTarget-normal.json")) { _ in }
                }

                // Ignore various boring task types for this target.
                results.checkTasks(.matchTarget(target), .matchRuleType("Copy")) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("SymLink")) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("Touch")) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("CreateBuildDirectory")) { _ in }
            }

            // Verify there is a task to create the VFS.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml")) { tasks in
                let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                sortedTasks[0].checkRuleInfo(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")])
            }

            // Verify there is a task to create the mock Info.plist
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("empty.plist")) { tasks in
                let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value {
                    sortedTasks[0].checkRuleInfo(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/AppTarget.build/empty.plist"])
                    sortedTasks[1].checkRuleInfo(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/FwkTarget.build/empty.plist"])
                }
            }

            // check the remaining auxiliary files tasks, which should just be headermaps.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in
                #expect(tasks.contains(where: {$0.ruleInfo[1].hasSuffix(".hmap")}))
                #expect(tasks.contains(where: {$0.ruleInfo[1].hasSuffix("const_extract_protocols.json")}))
            }

            // Ignore all Gate and build directory tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

            // Skip the validate task.
            results.checkTasks(.matchRuleType("Validate")) { _ in }

            // Ignore all Extract App Intents Metadata tasks.
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }

            // There should be no other unmatched tasks.
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftMinimumSupportedSimulatorDeviceFallback() async throws {
        let testProject = try await TestProject(
            "Test",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "auto",
                    "SDK_VARIANT": "auto",
                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Executable",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "iphoneos",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File1.swift")]),
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOSSimulator) { results in
            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/Test/build/Debug-iphonesimulator/Executable.app/Executable")) { task in
                task.checkCommandLineNoMatch([.equal("-Xlinker"), .equal("-rpath"), .equal("-Xlinker"), .equal("/usr/lib/swift")])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftModuleWithoutUmbrellaHeader() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "DEFINES_MODULE": "YES",
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                                "TAPI_EXEC": tapiToolPath.str,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.swift",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            // Check the actual module map.
            results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/module.modulemap"])) { task, contents in
                #expect(contents == (OutputByteStream()
                                     <<< "framework module CoreFoo {\n"
                                     <<< "  header \"CoreFoo-Swift.h\"\n"
                                     <<< "  requires objc\n"
                                     <<< "}\n").bytes)
            }
        }
    }

    // Tests a package interface generation when SWIFT_PACKAGE_NAME is set.
    @Test(.requireSDKs(.macOS), .enabled(if: LibSwiftDriver.supportsDriverFlag(spelled: "-emit-package-module-interface-path")), .requireSwiftFeatures(.emitPackageModuleInterfacePath))
    func packageInterfaceGen() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                    TestFile("CoreFoo.h"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "DEFINES_MODULE": "YES",
                                                "SWIFT_VERSION": swiftVersion,
                                                "SWIFT_PACKAGE_NAME": "FooPkg",
                                                "SWIFT_EMIT_MODULE_INTERFACE": "YES",
                                                "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.swift",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("CoreFoo.h", headerVisibility: .public),
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }

        // We intentionally check an install build here, to ensure the unextended module map contents are rewritten appropriately.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkTarget("CoreFoo") { target in
                let _ = results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "CoreFoo", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                    task.checkCommandLineMatches([
                        .anySequence,
                        .equal(swiftCompilerPath.str),
                        "-module-name", "CoreFoo", "-O",
                        .anySequence,
                        // The Swift response file
                        "@/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.SwiftFileList",
                        .anySequence,
                        "-sdk", .equal(core.loadSDK(.macOS).path.str),
                        "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)",
                        /* options from the xcspec which sometimes change appear here */
                        .anySequence,
                        "-swift-version", .equal(swiftVersion),
                        // The Swift search arguments.
                        "-I", "/tmp/Test/aProject/build/Debug", "-F", "/tmp/Test/aProject/build/Debug",
                        // Compilation mode arguments.
                        "-parse-as-library", "-c", "-j\(compilerParallelismLevel)",
                        .anySequence,
                        "-incremental",
                        // The output file map.
                        "-output-file-map", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-OutputFileMap.json",
                        .anySequence,
                        // Configure the output.
                        "-serialize-diagnostics", "-emit-dependencies",
                        // The module emission arguments.
                        "-emit-module", "-emit-module-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftmodule",
                        "-emit-module-interface-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftinterface",
                        "-emit-private-module-interface-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.private.swiftinterface",
                        // Package interface path argument should be present
                        "-emit-package-module-interface-path",
                        "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.package.swiftinterface",
                        .anySequence,
                        // Package name argument should be present
                        "-package-name", "FooPkg",
                        // The C-family include arguments, for the Clang importer.
                        "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/swift-overrides.hmap",
                        .anySequence,
                        "-Xcc", "-iquote", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-generated-files.hmap", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-own-target-headers.hmap", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-all-non-framework-target-headers.hmap", "-Xcc", "-ivfsoverlay", "-Xcc", .suffix("all-product-headers.yaml"), "-Xcc", "-iquote", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-project-headers.hmap", "-Xcc", "-I/tmp/Test/aProject/build/Debug/include", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources-normal/x86_64", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources/x86_64", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources",
                        // Generated API header arguments.
                        "-emit-objc-header", "-emit-objc-header-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-Swift.h",
                        .anySequence,
                        // Import the target's public module, while hiding the Swift generated header.
                        "-import-underlying-module", "-Xcc", "-ivfsoverlay", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/unextended-module-overlay.yaml",
                        "-working-directory", "/tmp/Test/aProject",
                        .anySequence])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo Swift Compilation Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/Foo.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/Foo.swiftconstvalues"),
                    ])
                    return task
                }

                let _ = results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation Requirements", "CoreFoo", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                    task.checkCommandLineMatches([
                        .anySequence,
                        .equal(swiftCompilerPath.str),
                        "-module-name", "CoreFoo", "-O",
                        .anySequence,
                        // The Swift response file
                        "@/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.SwiftFileList",
                        .anySequence,
                        "-sdk", .equal(core.loadSDK(.macOS).path.str),
                        "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)",
                        /* options from the xcspec which sometimes change appear here */
                        .anySequence,
                        "-swift-version", .equal(swiftVersion),
                        // The Swift search arguments.
                        "-I", "/tmp/Test/aProject/build/Debug", "-F", "/tmp/Test/aProject/build/Debug",
                        // Compilation mode arguments.
                        "-parse-as-library", "-c", "-j\(compilerParallelismLevel)",
                        .anySequence,
                        "-incremental",
                        // The output file map.
                        "-output-file-map", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-OutputFileMap.json",
                        .anySequence,
                        // Configure the output.
                        "-serialize-diagnostics", "-emit-dependencies",
                        // The module emission arguments.
                        "-emit-module", "-emit-module-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftmodule",
                        "-emit-module-interface-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftinterface",
                        "-emit-private-module-interface-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.private.swiftinterface",
                        // Package interface path argument should be present
                        "-emit-package-module-interface-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.package.swiftinterface",
                        .anySequence,
                        // Package name argument should be present
                        "-package-name", "FooPkg",
                        // The C-family include arguments, for the Clang importer.
                        "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/swift-overrides.hmap",
                        .anySequence,
                        "-Xcc", "-iquote", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-generated-files.hmap", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-own-target-headers.hmap", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-all-non-framework-target-headers.hmap", "-Xcc", "-ivfsoverlay", "-Xcc", .suffix("all-product-headers.yaml"), "-Xcc", "-iquote", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-project-headers.hmap", "-Xcc", "-I/tmp/Test/aProject/build/Debug/include", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources-normal/x86_64", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources/x86_64", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources",
                        // Generated API header arguments.
                        "-emit-objc-header", "-emit-objc-header-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-Swift.h",
                        .anySequence,
                        // Import the target's public module, while hiding the Swift generated header.
                        "-import-underlying-module", "-Xcc", "-ivfsoverlay", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/unextended-module-overlay.yaml",
                        "-working-directory", "/tmp/Test/aProject",
                        .anySequence])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo Swift Compilation Requirements Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftmodule"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-linker-args.resp"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftsourceinfo"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.abi.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftinterface"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.private.swiftinterface"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.package.swiftinterface"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-Swift.h"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftdoc"),
                    ])
                    return task
                }

                // There should be a 'Copy' of .swiftinterface file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/Modules/CoreFoo.swiftmodule/x86_64-apple-macos.swiftinterface", "\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftinterface"])) { _ in }

                // There should be a 'Copy' of .private.swiftinterface file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/Modules/CoreFoo.swiftmodule/x86_64-apple-macos.private.swiftinterface", "\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.private.swiftinterface"])) { _ in }

                // There should be a 'Copy' of .package.swiftinterface file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/Modules/CoreFoo.swiftmodule/x86_64-apple-macos.package.swiftinterface", "\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.package.swiftinterface"])) { _ in }
            }
            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of the Swift compiler, from task construction purposes.
    ///
    /// Command line specific checks should typically be tested via the Core Spec tests, instead of here, unless the important pieces are the interactions between tasks.
    @Test(.requireSDKs(.macOS))
    func swiftCompiler() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                    TestFile("CoreFoo.h"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "DEFINES_MODULE": "YES",
                                                "SWIFT_VERSION": swiftVersion,
                                                "SWIFT_EMIT_MODULE_INTERFACE": "YES",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.swift",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("CoreFoo.h", headerVisibility: .public),
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()

        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }

        // We intentionally check an install build here, to ensure the unextended module map contents are rewritten appropriately.
        try await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            try results.checkTarget("CoreFoo") { target in
                let swiftCompilationRequirementsTask: any PlannedTask = try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "CoreFoo", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    task.checkCommandLineMatches([
                        .anySequence,
                        .equal(swiftCompilerPath.str),
                        "-module-name", "CoreFoo", "-O",
                        .anySequence,
                        // The Swift response file
                        "@/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.SwiftFileList",
                        .anySequence,
                        "-sdk", .equal(core.loadSDK(.macOS).path.str),
                        "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)",
                        /* options from the xcspec which sometimes change appear here */
                        .anySequence,
                        "-swift-version", .equal(swiftVersion),

                        // The Swift search arguments.
                        "-I", "/tmp/Test/aProject/build/Debug", "-F", "/tmp/Test/aProject/build/Debug",

                        // Compilation mode arguments.
                        "-parse-as-library", "-c", "-j\(compilerParallelismLevel)",

                            .anySequence,
                        "-incremental",

                        // The output file map.
                        "-output-file-map", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-OutputFileMap.json",
                        .anySequence,

                        // Configure the output.
                        "-serialize-diagnostics", "-emit-dependencies",

                        // The module emission arguments.
                        "-emit-module", "-emit-module-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftmodule",
                        "-emit-module-interface-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftinterface",
                        "-emit-private-module-interface-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.private.swiftinterface",
                        .anySequence,

                        // The C-family include arguments, for the Clang importer.
                        "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/swift-overrides.hmap",
                        .anySequence,
                        "-Xcc", "-iquote", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-generated-files.hmap", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-own-target-headers.hmap", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-all-non-framework-target-headers.hmap", "-Xcc", "-ivfsoverlay", "-Xcc", .suffix("all-product-headers.yaml"), "-Xcc", "-iquote", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-project-headers.hmap", "-Xcc", "-I/tmp/Test/aProject/build/Debug/include", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources-normal/x86_64", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources/x86_64", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources",

                        // Generated API header arguments.
                        "-emit-objc-header", "-emit-objc-header-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-Swift.h",
                        .anySequence,

                        // Import the target's public module, while hiding the Swift generated header.
                        "-import-underlying-module", "-Xcc", "-ivfsoverlay", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/unextended-module-overlay.yaml",

                        "-working-directory", "/tmp/Test/aProject",
                        .anySequence])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/Foo.swift"),
                        .path("/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo_const_extract_protocols.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/unextended-module.modulemap"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/unextended-module-overlay.yaml"),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix("all-product-headers.yaml")),
                        .namePattern(.suffix(".hmap")),
                        .path("/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/Modules/module.modulemap"),
                        .namePattern(.suffix("generated-headers")),
                        .namePattern(.suffix("copy-headers-completion")),
                        .namePattern(.prefix("target")),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo Swift Compilation Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/Foo.o"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/Foo.swiftconstvalues"),
                    ])


                    return task
                }

                let swiftCompilationTask: any PlannedTask = try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation Requirements", "CoreFoo", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    task.checkCommandLineMatches([
                        .anySequence,
                        .equal(swiftCompilerPath.str),
                        "-module-name", "CoreFoo", "-O",
                        .anySequence,
                        // The Swift response file
                        "@/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.SwiftFileList",
                        .anySequence,
                        "-sdk", .equal(core.loadSDK(.macOS).path.str),
                        "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)",
                        /* options from the xcspec which sometimes change appear here */
                        .anySequence,
                        "-swift-version", .equal(swiftVersion),

                        // The Swift search arguments.
                        "-I", "/tmp/Test/aProject/build/Debug", "-F", "/tmp/Test/aProject/build/Debug",

                        // Compilation mode arguments.
                        "-parse-as-library", "-c", "-j\(compilerParallelismLevel)",

                            .anySequence,
                        "-incremental",

                        // The output file map.
                        "-output-file-map", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-OutputFileMap.json",
                        .anySequence,

                        // Configure the output.
                        "-serialize-diagnostics", "-emit-dependencies",

                        // The module emission arguments.
                        "-emit-module", "-emit-module-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftmodule",
                        "-emit-module-interface-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftinterface",
                        "-emit-private-module-interface-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.private.swiftinterface",
                        .anySequence,

                        // The C-family include arguments, for the Clang importer.
                        "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/swift-overrides.hmap",
                        .anySequence,
                        "-Xcc", "-iquote", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-generated-files.hmap", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-own-target-headers.hmap", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-all-non-framework-target-headers.hmap", "-Xcc", "-ivfsoverlay", "-Xcc", .suffix("all-product-headers.yaml"), "-Xcc", "-iquote", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/CoreFoo-project-headers.hmap", "-Xcc", "-I/tmp/Test/aProject/build/Debug/include", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources-normal/x86_64", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources/x86_64", "-Xcc", "-I/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/DerivedSources",

                        // Generated API header arguments.
                        "-emit-objc-header", "-emit-objc-header-path", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-Swift.h",
                        .anySequence,

                        // Import the target's public module, while hiding the Swift generated header.
                        "-import-underlying-module", "-Xcc", "-ivfsoverlay", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/unextended-module-overlay.yaml",

                        "-working-directory", "/tmp/Test/aProject",
                        .anySequence])

                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/Foo.swift"),
                        .path("/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.SwiftFileList"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-OutputFileMap.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo_const_extract_protocols.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/unextended-module.modulemap"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/unextended-module-overlay.yaml"),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix(".hmap")),
                        .namePattern(.suffix("all-product-headers.yaml")),
                        .namePattern(.suffix(".hmap")),
                        .path("/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/Modules/module.modulemap"),
                        .namePattern(.suffix("copy-headers-completion")),
                        .namePattern(.prefix("target")),
                        .namePattern(.prefix("target-")),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo Swift Compilation Requirements Finished"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftmodule"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-linker-args.resp"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftsourceinfo"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.abi.json"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftinterface"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.private.swiftinterface"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-Swift.h"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.swiftdoc"),
                    ])


                    return task
                }

                results.checkTask(.matchRuleType("SwiftMergeGeneratedHeaders")) { task in
                    task.checkRuleInfo(["SwiftMergeGeneratedHeaders", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/Headers/CoreFoo-Swift.h", "\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-Swift.h"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-Swift.h"),
                        .namePattern(.and(.prefix("target"), .suffix("begin-compiling"))),
                        .name("WorkspaceHeaderMapVFSFilesWritten")
                    ])
                    task.checkOutputs([
                        .path("/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/Headers/CoreFoo-Swift.h")
                    ])
                    task.checkCommandLine(["builtin-swiftHeaderTool", "-arch", "x86_64", "\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo-Swift.h", "-o", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/Headers/CoreFoo-Swift.h"])
                }

                // Check the content of the Swift response file creation task
                results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/Objects-normal/x86_64/CoreFoo.SwiftFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == ["/tmp/Test/aProject/Sources/Foo.swift", ""])
                }

                // Check the overlay which redirects to the unextended module map.
                results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/unextended-module-overlay.yaml"])) { task, contents in
                    let stream = OutputByteStream()
                    stream <<< "{\n"
                    stream <<< "  \"version\": 0,\n"
                    stream <<< "  \"use-external-names\": false,\n"
                    stream <<< "  \"case-sensitive\": false,\n"
                    stream <<< "  \"roots\": [{\n"
                    stream <<< "    \"type\": \"directory\",\n"
                    stream <<< "    \"name\": \"/tmp/Test/aProject/build/Debug/CoreFoo.framework/Modules\",\n"
                    stream <<< "    \"contents\": [{\n"
                    stream <<< "      \"type\": \"file\",\n"
                    stream <<< "      \"name\": \"module.modulemap\",\n"
                    stream <<< "      \"external-contents\": \"/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/unextended-module.modulemap\",\n"
                    stream <<< "    }]\n"
                    stream <<< "    },\n"
                    stream <<< "    {\n"
                    stream <<< "    \"type\": \"directory\",\n"
                    stream <<< "    \"name\": \"/tmp/Test/aProject/build/Debug/CoreFoo.framework/Headers\",\n"
                    stream <<< "    \"contents\": [{\n"
                    stream <<< "      \"type\": \"file\",\n"
                    stream <<< "      \"name\": \"CoreFoo-Swift.h\",\n"
                    stream <<< "      \"external-contents\": \"/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/unextended-interface-header.h\",\n"
                    stream <<< "    }]\n"
                    stream <<< "  }]\n"
                    stream <<< "}\n"
                    #expect(contents == stream.bytes)
                }

                // Check the actual module map.
                results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/module.modulemap"])) { task, contents in
                    let stream = OutputByteStream()
                    stream <<< "framework module CoreFoo {\n"
                    stream <<< "  umbrella header \"CoreFoo.h\"\n"
                    stream <<< "  export *\n"
                    stream <<< "\n"
                    stream <<< "  module * { export * }\n"
                    stream <<< "}\n"
                    stream <<< "\n"
                    stream <<< "module CoreFoo.Swift {\n"
                    stream <<< "  header \"CoreFoo-Swift.h\"\n"
                    stream <<< "  requires objc\n"
                    stream <<< "}\n"
                    #expect(contents == stream.bytes)

                    results.checkTaskDependsOn(swiftCompilationTask, antecedent: task)
                    results.checkTaskDependsOn(swiftCompilationRequirementsTask, antecedent: task)
                }

                // Check the unextended module map.
                results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/unextended-module.modulemap"])) { task, contents in
                    let stream = OutputByteStream()
                    stream <<< "framework module CoreFoo {\n"
                    stream <<< "  umbrella header \"CoreFoo.h\"\n"
                    stream <<< "  export *\n"
                    stream <<< "\n"
                    stream <<< "  module * { export * }\n"
                    stream <<< "}\n"
                    stream <<< "\n"
                    stream <<< "module CoreFoo.__Swift {\n"
                    stream <<< "  exclude header \"CoreFoo-Swift.h\"\n"
                    stream <<< "}\n"
                    #expect(contents == stream.bytes)
                }

                // Check the copied module map.
                results.checkTask(.matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/Modules/module.modulemap", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/module.modulemap"])) { task in
                    results.checkTaskDependsOn(swiftCompilationTask, antecedent: task)
                    results.checkTaskDependsOn(swiftCompilationRequirementsTask, antecedent: task)
                }

                // Ignore the CpHeader task (of the public header).
                results.checkTask(.matchTarget(target), .matchRuleType("CpHeader")) { _ in }

                // Ignore the link.
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }
            }
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
            // Ignore all the mkdir, symlink, and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("SymLink")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }
            // Ignore all Gate tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            // Ignore all RegisterWithLaunchServices tasks.
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            // Ignore all Copy tasks.
            results.checkTasks(.matchRuleType("Copy")) { _ in }
            // Ignore all build directory related tasks.
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            // Ignore all Extract App Intents Metadata tasks.
            results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }

            // Ignore other install tasks.
            results.checkTasks(.matchRuleType("SetMode")) { _ in  }
            results.checkTasks(.matchRuleType("SetOwnerAndGroup")) { _ in  }
            results.checkTasks(.matchRuleType("Strip")) { _ in  }

            // Check there are no other tasks.
            results.checkNoTask()

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftModuleCacheFlags() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                        "SWIFT_EXPLICIT_MODULES_OUTPUT_PATH": "/path/to/ExplicitModules",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "SWIFT_VERSION": swiftVersion,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.swift",
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        let fs = PseudoFS()

        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        let arena = ArenaInfo(derivedDataPath: Path("/path/to/DerivedData"), buildProductsPath: Path.root, buildIntermediatesPath: Path.root, pchPath: Path.root, indexRegularBuildProductsPath: nil, indexRegularBuildIntermediatesPath: nil, indexPCHPath: Path.root, indexDataStoreFolderPath: nil, indexEnableDataStore: false)
        await tester.checkBuild(BuildParameters(configuration: "Debug", arena: arena), runDestination: .macOS, fs: fs) { results in
            results.checkTarget("CoreFoo")  { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-module-cache-path", "/path/to/ExplicitModules"])
                    if LibSwiftDriver.supportsDriverFlag(spelled: "-clang-scanner-module-cache-path") {
                        task.checkCommandLineContains(["-clang-scanner-module-cache-path", "/path/to/DerivedData/ModuleCache.noindex"])
                    }
                    if LibSwiftDriver.supportsDriverFlag(spelled: "-sdk-module-cache-path") {
                        task.checkCommandLineContains(["-sdk-module-cache-path", "/path/to/DerivedData/ModuleCache.noindex"])
                    }
                }
            }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftLTO() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                    TestFile("Bar.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": swiftVersion,
                        "LIBTOOL": libtoolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Foo.swift"]),
                        TestFrameworksBuildPhase([TestBuildFile("libBar.a"),])
                    ], dependencies: ["Bar"]),
                TestStandardTarget(
                    "Bar", type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Bar.swift",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        for ltoSetting in ["YES", "YES_THIN"] {
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_LTO": ltoSetting]), runDestination: .macOS, fs: fs) { results in
                results.checkNoDiagnostics()
                results.checkTarget("Bar") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { compileTask in
                        if ltoSetting == "YES" {
                            compileTask.checkCommandLineContains(["-lto=llvm-full"])
                        } else {
                            compileTask.checkCommandLineContains(["-lto=llvm-thin"])
                        }
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { archiverTask in
                        results.checkTaskFollows(archiverTask, .matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                    }
                }
                results.checkTarget("CoreFoo") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { compileTask in
                        if ltoSetting == "YES" {
                            compileTask.checkCommandLineContains(["-lto=llvm-full"])
                        } else {
                            compileTask.checkCommandLineContains(["-lto=llvm-thin"])
                        }
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { linkerTask in
                        results.checkTaskFollows(linkerTask, .matchTarget(target), .matchRuleType("SwiftDriver Compilation"))
                        if ltoSetting == "YES_THIN" {
                            linkerTask.checkCommandLineMatches([.anySequence, "-Xlinker", "-cache_path_lto", "-Xlinker", .suffix("/LTOCache"), .anySequence])
                        }
                    }
                }
            }
        }
    }

    /// Check handling of multiple archs.
    func testMultipleArchs(runDestination: RunDestinationInfo, archs: [String], excludedArchs: [String] = [], targetTripleSuffix: String) async throws {
        let sdkroot = runDestination.sdk
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                    TestFile("CoreFoo.h"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "SWIFT_ALLOW_INSTALL_OBJC_HEADER": "YES",
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": sdkroot,
                                                "DEFINES_MODULE": "YES",
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                                "ARCHS": archs.joined(separator: " "),
                                                "EXCLUDED_ARCHS": excludedArchs.joined(separator: " "),
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.swift",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("CoreFoo.h", headerVisibility: .public),
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        func configurationDir(configuration: String) -> String {
            "\(configuration)\(runDestination.builtProductsDirSuffix)"
        }

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")

        await tester.checkBuild(runDestination: runDestination, fs: fs) { results in
            results.checkTarget("CoreFoo") { target in
                // We should have one planning per arch.
                for arch in archs {
                    results.checkTaskExists(.matchRule(["SwiftDriver Compilation", "CoreFoo", "normal", arch, "com.apple.xcode.tools.swift.compiler"]))
                    results.checkTaskExists(.matchRule(["SwiftDriver Compilation Requirements", "CoreFoo", "normal", arch, "com.apple.xcode.tools.swift.compiler"]))
                }

                // We should have a Copy of the appropriate arch.
                for arch in archs {
                    results.checkTask(.matchRule(["Copy", "\(SRCROOT)/build/\(configurationDir(configuration: "Debug"))/CoreFoo.framework/Modules/CoreFoo.swiftmodule/\(arch)\(targetTripleSuffix).swiftmodule", "\(SRCROOT)/build/aProject.build/\(configurationDir(configuration: "Debug"))/CoreFoo.build/Objects-normal/\(arch)/CoreFoo.swiftmodule"])) { _ in }
                }

                // Check we only have one task for the Swift generated API header file.
                if archs.count > 1 {
                    results.checkTask(.matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("CoreFoo-Swift.h")) { task in
                        task.checkRuleInfo(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/\(configurationDir(configuration: "Debug"))/CoreFoo.framework/Headers/CoreFoo-Swift.h"] + archs.sorted().map { arch in "\(SRCROOT)/build/aProject.build/\(configurationDir(configuration: "Debug"))/CoreFoo.build/Objects-normal/\(arch)/CoreFoo-Swift.h" })
                    }
                } else {
                    results.checkTask(.matchRuleType("SwiftMergeGeneratedHeaders"), .matchRuleItemBasename("CoreFoo-Swift.h")) { task in
                        task.checkRuleInfo(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/\(configurationDir(configuration: "Debug"))/CoreFoo.framework/Headers/CoreFoo-Swift.h", "\(SRCROOT)/build/aProject.build/\(configurationDir(configuration: "Debug"))/CoreFoo.build/Objects-normal/\(archs[0])/CoreFoo-Swift.h"])
                    }
                }
            }

            for arch in archs.filter({ ["armv7", "armv7s"].contains($0) }) where sdkroot == "iphoneos" {
                results.checkWarning(.equal("The \(arch) architecture is deprecated for your deployment target (iOS \(results.runDestinationSDK.version)). You should update your ARCHS build setting to remove the \(arch) architecture. (in target 'CoreFoo' from project 'aProject')"))
            }

            for arch in archs.filter({ ["armv7k"].contains($0) }) where sdkroot == "watchos" && (results.runDestinationSDK.buildVersion?.major ?? 0) >= 20 {
                results.checkWarning(.equal("The \(arch) architecture is deprecated for your deployment target (watchOS \(results.runDestinationSDK.version)). You should update your ARCHS build setting to remove the \(arch) architecture. (in target 'CoreFoo' from project 'aProject')"))
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func multipleArchs_iOS() async throws {
        try await testMultipleArchs(
            runDestination: .anyiOSDevice,
            archs: ["arm64", "arm64e"],
            targetTripleSuffix: "-apple-ios")
    }

    @Test(.requireSDKs(.watchOS))
    func multipleArchs_watchOS() async throws {
        try await testMultipleArchs(
            runDestination: .anywatchOSDevice,
            archs: ["armv7k"],
            targetTripleSuffix: "-apple-watchos")

        try await testMultipleArchs(
            runDestination: .anywatchOSDevice,
            archs: ["arm64_32"],
            targetTripleSuffix: "-apple-watchos")

        try await testMultipleArchs(
            runDestination: .anywatchOSDevice,
            archs: ["armv7k", "arm64_32"],
            targetTripleSuffix: "-apple-watchos")
    }

    /// Check handling of Swift combined with explicit module map files.
    @Test(.requireSDKs(.macOS))
    func swiftModuleAndExplicitModuleMap() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "MODULEMAP_FILE": "Foo.modulemap",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "DEFINES_MODULE": "YES",
                                                "SWIFT_VERSION": swiftVersion,
                                                "TAPI_EXEC": tapiToolPath.str,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.swift",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        try fs.createDirectory(SRCROOT, recursive: true)
        try fs.write(SRCROOT.join("Foo.modulemap"), contents: [])

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkTarget("CoreFoo") { target in
                // Check the Swift planning.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "CoreFoo", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    task.checkCommandLineContains([
                        // Import the target's public module, while hiding the Swift generated header.
                        "-import-underlying-module", "-Xcc", "-ivfsoverlay", "-Xcc", "/tmp/Test/aProject/build/aProject.build/Debug/CoreFoo.build/unextended-module-overlay.yaml"])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func cXXInteropDisablesExplicitModules() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Exec", type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("Exec") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineContains(["-explicit-module-build"])
                }
            }
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_OBJC_INTEROP_MODE": "objcxx"]), runDestination: .macOS) { results in
            results.checkTarget("Exec") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineDoesNotContain("-explicit-module-build")
                }
            }
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["OTHER_SWIFT_FLAGS": "-cxx-interoperability-mode=default"]), runDestination: .macOS) { results in
            results.checkTarget("Exec") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineDoesNotContain("-explicit-module-build")
                }
            }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func swift4DisablesExplicitModules() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Exec", type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VERSION": "6.0"]), runDestination: .macOS) { results in
            results.checkTarget("Exec") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineContains(["-explicit-module-build"])
                }
            }
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VERSION": "5.0"]), runDestination: .macOS) { results in
            results.checkTarget("Exec") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineContains(["-explicit-module-build"])
                }
            }
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VERSION": "4.0"]), runDestination: .macOS) { results in
            results.checkTarget("Exec") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineDoesNotContain("-explicit-module-build")
                }
            }
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VERSION": "4.2"]), runDestination: .macOS) { results in
            results.checkTarget("Exec") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineDoesNotContain("-explicit-module-build")
                }
            }
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VERSION": "4.2", "_SWIFT_EXPLICIT_MODULES_ALLOW_BEFORE_SWIFT_5": "YES"]), runDestination: .macOS) { results in
            results.checkTarget("Exec") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineContains(["-explicit-module-build"])
                }
            }
            results.checkNoDiagnostics()
        }
    }

    /// Check control of whether Swift module is copied for other targets to use.
    @Test(.requireSDKs(.macOS))
    func swiftModuleNotCopiedWhenAskedNotTo() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Exec", type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                                "SWIFT_INSTALL_MODULE": "NO",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkTarget("Exec") { target in
                // Check the Swift compile.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation Requirements", "Exec", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                    task.checkOutputs(contain: [.pathPattern(.suffix("Exec.swiftmodule"))])
                }

                // Check that nothing is copying (or in any other way putting) the .swiftmodule into the build directory.
                results.checkNoTask(.matchTarget(target), .matchRuleItemPattern(.contains("/Debug/Exec.swiftmodule/")))
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check handling of Swift bridging header.
    @Test(.requireSDKs(.macOS))
    func swiftBridgingHeader() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "FooApp", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "SWIFT_OBJC_BRIDGING_HEADER": "swift-bridge-header.h",
                                                "SWIFT_VERSION": swiftVersion,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.swift",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        try fs.createDirectory(SRCROOT, recursive: true)
        let bridgeHeader = SRCROOT.join("swift-bridge-header.h")
        try fs.write(bridgeHeader, contents: [])

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkTarget("FooApp") { target in
                // Check the Swift compile.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "FooApp", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    task.checkCommandLineContains([
                        "-import-objc-header", bridgeHeader.str])
                    task.checkInputs(contain: [.path(bridgeHeader.str)])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check that the path of Swift bridging header is being normalized.
    @Test(.requireSDKs(.macOS))
    func swiftBridgingHeaderPathNormalized() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "FooApp", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                                "SWIFT_OBJC_BRIDGING_HEADER": "../aProject/./swift-bridge-header.h",
                                                "SWIFT_VERSION": swiftVersion,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.swift",
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        try fs.createDirectory(SRCROOT, recursive: true)
        let bridgeHeader = SRCROOT.join("swift-bridge-header.h")
        try fs.write(bridgeHeader, contents: [])

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkTarget("FooApp") { target in
                // Check the Swift compile.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "FooApp", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    task.checkCommandLineContains([
                        "-import-objc-header", bridgeHeader.str])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check control of whether Swift Objective-C interface header is copied for other targets to use.
    @Test(.requireSDKs(.macOS))
    func swiftObjectiveCHeaderInstallation() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "LIBTOOL": libtoolPath.str,
                    ]),
            ],
            targets: [
                TestAggregateTarget(
                    "All",
                    dependencies: [
                        "DynamicFramework",
                        "StaticFramework",
                        "DynamicFrameworkNoInstallHeader",
                        "StaticFrameworkNoInstallHeader",
                        "DynamicFrameworkNoInstallModule",
                        "StaticFrameworkNoInstallModule",
                    ]),
                TestStandardTarget(
                    "DynamicFramework",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "StaticFramework",
                    type: .staticFramework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "DynamicFrameworkNoInstallHeader",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "StaticFrameworkNoInstallHeader",
                    type: .staticFramework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "DynamicFrameworkNoInstallModule",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_INSTALL_MODULE": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "StaticFrameworkNoInstallModule",
                    type: .staticFramework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_INSTALL_MODULE": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let fs = PseudoFS()

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            // Check that dynamic and static frameworks get their header and module installed by default

            results.checkTarget("DynamicFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders")) { task in
                    task.checkOutputs([
                        .path("/tmp/Test/aProject/build/Debug/DynamicFramework.framework/Versions/A/Headers/DynamicFramework-Swift.h"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".swiftmodule"))) { task in
                    task.checkRuleInfo(["Copy", "/tmp/Test/aProject/build/Debug/DynamicFramework.framework/Versions/A/Modules/DynamicFramework.swiftmodule/\(results.runDestinationTargetArchitecture)-apple-macos.swiftmodule", "/tmp/Test/aProject/build/aProject.build/Debug/DynamicFramework.build/Objects-normal/\(results.runDestinationTargetArchitecture)/DynamicFramework.swiftmodule"])
                }
            }

            results.checkTarget("StaticFramework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders")) { task in
                    task.checkOutputs([
                        .path("/tmp/Test/aProject/build/Debug/StaticFramework.framework/Versions/A/Headers/StaticFramework-Swift.h"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".swiftmodule"))) { task in
                    task.checkRuleInfo(["Copy", "/tmp/Test/aProject/build/Debug/StaticFramework.framework/Versions/A/Modules/StaticFramework.swiftmodule/\(results.runDestinationTargetArchitecture)-apple-macos.swiftmodule", "/tmp/Test/aProject/build/aProject.build/Debug/StaticFramework.build/Objects-normal/\(results.runDestinationTargetArchitecture)/StaticFramework.swiftmodule"])
                }
            }

            // Check that dynamic and static frameworks don't get their header and module installed when requested

            results.checkTarget("DynamicFrameworkNoInstallHeader") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders")) { task in
                    task.checkOutputs([
                        .path("/tmp/Test/aProject/build/aProject.build/Debug/DynamicFrameworkNoInstallHeader.build/DerivedSources/DynamicFrameworkNoInstallHeader-Swift.h"),
                    ])
                }
            }

            results.checkTarget("StaticFrameworkNoInstallHeader") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders")) { task in
                    task.checkOutputs([
                        .path("/tmp/Test/aProject/build/aProject.build/Debug/StaticFrameworkNoInstallHeader.build/DerivedSources/StaticFrameworkNoInstallHeader-Swift.h"),
                    ])
                }
            }

            results.checkTarget("DynamicFrameworkNoInstallModule") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".swiftmodule")))
            }

            results.checkTarget("StaticFrameworkNoInstallModule") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("SwiftMergeGeneratedHeaders"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".swiftmodule")))
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func emitConstValues() async throws {
        let sdkRoot = "macosx"
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let swiftFeatures = try await self.swiftFeatures
        let testProject = TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("TestFile.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "TestTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "CODE_SIGNING_ALLOWED": "NO",
                            "PRODUCT_NAME": "TestProduct",
                            "ARCHS": "x86_64",
                            "SWIFT_VERSION": swiftVersion,
                            "SDKROOT": sdkRoot,
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_ENABLE_EMIT_CONST_VALUES": "YES",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile.swift"),
                        ]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("TestTarget") { target in
                // Check the compilation command-line effects
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    results.checkNoDiagnostics()
                    if swiftFeatures.has(.emitContValuesSidecar) {
                        task.checkCommandLineContains(["-emit-const-values"])
                        task.checkCommandLineContains(["-const-gather-protocols-file"])
                    } else {
                        task.checkCommandLineDoesNotContain("-emit-const-values")
                        task.checkCommandLineDoesNotContain("-const-gather-protocols-file")
                    }
                }

                if swiftFeatures.has(.emitContValuesSidecar) {
                    // Verify protocol list specification contents
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/ProjectName.build/Debug/TestTarget.build/Objects-normal/x86_64/TestTarget_const_extract_protocols.json"])) { task, contents in
                        guard let plist = try? PropertyList.fromJSONData(contents),
                              let array = plist.arrayValue else {
                            Issue.record("could not convert output file map from JSON to plist array")
                            return
                        }
                        #expect(array.contains(.plString("Foo")))
                        #expect(array.contains(.plString("Bar")))
                    }
                }

                // Verify output file map contents
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/ProjectName.build/Debug/TestTarget.build/Objects-normal/x86_64/TestTarget-OutputFileMap.json"])) { task, contents in
                    guard let plist = try? PropertyList.fromJSONData(contents),
                          let dict = plist.dictValue else {
                        Issue.record("could not convert output file map from JSON to plist dictionary")
                        return
                    }

                    let filepath = "\(SRCROOT)/Sources/TestFile.swift"
                    let filename = Path(filepath).basenameWithoutSuffix
                    if let fileDict = dict[filepath]?.dictValue {
                        #expect(fileDict["object"]?.stringValue == "\(SRCROOT)/build/ProjectName.build/Debug/TestTarget.build/Objects-normal/x86_64/\(filename).o")
                        if swiftFeatures.has(.emitContValuesSidecar) {
                            #expect(fileDict["const-values"]?.stringValue == "\(SRCROOT)/build/ProjectName.build/Debug/TestTarget.build/Objects-normal/x86_64/\(filename).swiftconstvalues")
                        } else {
                            #expect(fileDict["const-values"] == nil)
                        }
                    }
                    else {
                        Issue.record("output file map does not contain a dictionary for '\(filename).swift'")
                    }

                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func autolinkingFlags() async throws {
        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("TestFile.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "TestTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "CODE_SIGNING_ALLOWED": "NO",
                            "PRODUCT_NAME": "TestProduct",
                            "ARCHS": "x86_64",
                            "SWIFT_VERSION": swiftVersion,
                            "SDKROOT": "macosx",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile.swift"),
                        ]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("TestTarget") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineDoesNotContain("-disable-all-autolinking")
                }
            }
        }
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_MODULES_AUTOLINK": "NO"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("TestTarget") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-Xfrontend", "-disable-all-autolinking"])
                }
            }
        }
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_SKIP_AUTOLINKING_ALL_FRAMEWORKS": "YES"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("TestTarget") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-Xfrontend", "-disable-autolink-frameworks"])
                }
            }
        }
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_SKIP_AUTOLINKING_FRAMEWORKS": "Foundation"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("TestTarget") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "Foundation"])
                }
            }
        }
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_SKIP_AUTOLINKING_LIBRARIES": "Bar"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("TestTarget") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-Xfrontend", "-disable-autolink-library", "-Xfrontend", "Bar"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func installAPISetting() async throws {
        let sdkRoot = "macosx"
        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File2.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "ARCHS": "x86_64",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                            "SUPPORTS_TEXT_BASED_API": "YES",
                            "SDKROOT": sdkRoot
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File2.swift"),
                        ]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        let params = BuildParameters(action: .installAPI, configuration: "Debug")
        await tester.checkBuild(params, runDestination: .macOS) { results in
            results.checkTarget("TargetName") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineContains(["-emit-tbd-path"])
                    task.checkCommandLineContains(["-experimental-skip-non-inlinable-function-bodies"])
                    results.checkNoDiagnostics()
                }
            }
        }

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("TargetName") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    task.checkCommandLineContains(["-emit-tbd-path"])
                    task.checkCommandLineDoesNotContain("-experimental-skip-non-inlinable-function-bodies")
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    private func createTester(swiftVersion: String) async throws -> TaskConstructionTester {
        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File1.m"),
                    TestFile("File2.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "ARCHS": "x86_64",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.m"),
                            TestBuildFile("File2.swift"),
                        ]),
                    ])
            ])
        return try await TaskConstructionTester(getCore(), testProject)
    }

    @Test(.requireSDKs(.macOS))
    func emptySwiftVersion() async throws {
        let tester = try await createTester(swiftVersion: "")
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkError(.prefix("SWIFT_VERSION \'\' is unsupported"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func unsupportedSwiftVersion() async throws {
        let tester = try await createTester(swiftVersion: "1.1")
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkError(.prefix("SWIFT_VERSION \'1.1\' is unsupported"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func unparseableSwiftVersion() async throws {
        let tester = try await createTester(swiftVersion: "test")
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkError(.prefix("SWIFT_VERSION \'test\' is unsupported"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func minorSwiftVersions() async throws {
        let tester = try await createTester(swiftVersion: "4.1")
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["GENERATE_INFOPLIST_FILE": "YES"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
        }
    }

    // Checks that we pass `-add_ast_path` for each Swift module we link when linking statically.
    @Test(.requireSDKs(.macOS))
    func swiftAstPathForStaticLibraries() async throws {
        let testProject = try await TestProject(
            "Test",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                    TestFile("File2.swift"),
                    TestFile("File3.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Executable",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File1.swift")]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("libFirstLib.a"),
                            TestBuildFile("libSecondLib.a")])
                    ]),
                TestStandardTarget(
                    "FirstLib",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File2.swift")])
                    ]),
                TestStandardTarget(
                    "SecondLib",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File3.swift")])
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Executable") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    let commandLine = task.commandLine.map { $0.asString }
                    let modules = commandLine.indices.filter { commandLine[$0] == "-add_ast_path" }.map { $0.advanced(by: 2) }.map { commandLine[$0] }
                    let expectedModules = results.workspace.projects.first?.targets.map { "/tmp/Test/Test/build/Test.build/Debug/\($0.name).build/Objects-normal/x86_64/\($0.name).swiftmodule" }
                    #expect(expectedModules == modules)
                }
            }
        }
    }

    // Checks that we pass `-add_ast_path` for each Swift module we link when linking statically.
    @Test(.requireSDKs(.iOS, .watchOS))
    func swiftAstPathForStaticLibrariesMultiPlatform() async throws {
        let testProject = try await TestProject(
            "Test",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                    TestFile("File2.swift"),
                    TestFile("File3.swift"),
                    TestFile("SwiftyJSON.swift")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "auto",
                    "SDK_VARIANT": "auto",
                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Executable",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "iphoneos",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File1.swift")]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("libFirstLib.a"),
                            TestBuildFile("libSecondLib.a"),
                        ]),
                    ],
                    dependencies: ["WatchExecutable"]),
                TestStandardTarget(
                    "WatchExecutable",
                    type: .applicationExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "watchos",
                            "SUPPORTED_PLATFORMS": "watchos watchsimulator",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File1.swift")]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("libFirstLib.a"),
                            TestBuildFile("libSecondLib.a"),
                        ]),
                    ]),
                TestStandardTarget(
                    "FirstLib",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File2.swift")])
                    ]),
                TestStandardTarget(
                    "SecondLib",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File3.swift")])
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOSSimulator) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Executable") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    let commandLine = task.commandLine.map { $0.asString }
                    let modules = commandLine.indices.filter { commandLine[$0] == "-add_ast_path" }.map { $0.advanced(by: 2) }.map { commandLine[$0] }
                    let expectedModules = results.workspace.projects.first?.targets.filter { $0.name != "WatchExecutable" }.map { "/tmp/Test/Test/build/Test.build/Debug-iphonesimulator/\($0.name).build/Objects-normal/x86_64/\($0.name.replacingOccurrences(of: ":", with: "_")).swiftmodule" }
                    #expect(expectedModules == modules)
                }
            }
            results.checkTarget("WatchExecutable") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("x86_64")) { task in
                    let commandLine = task.commandLine.map { $0.asString }
                    let modules = commandLine.indices.filter { commandLine[$0] == "-add_ast_path" }.map { $0.advanced(by: 2) }.map { commandLine[$0] }
                    let expectedModules = results.workspace.projects.first?.targets.filter { $0.name != "Executable" }.map { "/tmp/Test/Test/build/Test.build/Debug-watchsimulator/\($0.name).build/Objects-normal/x86_64/\($0.name.replacingOccurrences(of: ":", with: "_")).swiftmodule" }
                    #expect(expectedModules == modules)
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("x86_64"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func commandLineSwiftFileList() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("foo.swift"),
                    TestFile("bar.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "CURRENT_PROJECT_VERSION": "3.1",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "USE_SWIFT_RESPONSE_FILE": "YES",
                        // remove in 51621328
                        "SWIFT_RESPONSE_FILE_PATH": "$(SWIFT_RESPONSE_FILE_PATH_$(variant)_$(arch))",
                    ])],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "VERSIONING_SYSTEM": "apple-generic",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                            "foo.swift",
                            "bar.swift",
                        ])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check the debug build.
        try await tester.checkBuild(runDestination: .macOS) { results in
            results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.SwiftFileList"])) { task, contents in task.checkOutputs([.pathPattern(.suffix("Objects-normal/x86_64/AppTarget.SwiftFileList"))])

                #expect(contents.asString.components(separatedBy: .newlines).dropLast().sorted() == ["\(SRCROOT)/bar.swift", "\(SRCROOT)/foo.swift", "\(SRCROOT)/main.swift"])
            }

            try results.checkTask(.matchRule(["SwiftDriver Compilation Requirements", "AppTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])) { task in
                task.checkInputs(contain: [.pathPattern(.suffix("main.swift")), .pathPattern(.suffix("foo.swift")), .pathPattern(.suffix("bar.swift")), .pathPattern(.suffix("Objects-normal/x86_64/AppTarget.SwiftFileList"))])

                for pattern in [StringPattern.suffix("main.swift"), .suffix("foo.swift"), .contains("bar.swift")] {
                    #expect(!task.commandLineAsStrings.contains(where: { pattern ~= $0 }), "Expected that the command line for Swift compiler invocations doesn't contain input files beside the response file, but found an argument matching \(pattern).")
                }

                // Test indexing - should still contain the individual file paths!
                let indexingInfo = task.generateIndexingInfo(input: .fullInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                #expect(indexingInfo.count == 3, "Expected to get indexing info for all input files.")
                XCTAssertMatch(indexingInfo[0].path.str, .suffix("bar.swift"))
                XCTAssertMatch(indexingInfo[1].path.str, .suffix("foo.swift"))
                XCTAssertMatch(indexingInfo[2].path.str, .suffix("main.swift"))

                let swiftIndexingInfo = indexingInfo.compactMap { $0.indexingInfo as? SwiftSourceFileIndexingInfo }
                #expect(swiftIndexingInfo.count == 3, "Expected that every indexing info for a Swift file is of type \(SwiftSourceFileIndexingInfo.self)")
                XCTAssertMatch(swiftIndexingInfo[0].propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("bar.o"))
                XCTAssertMatch(swiftIndexingInfo[1].propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("foo.o"))
                XCTAssertMatch(swiftIndexingInfo[2].propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("main.o"))
                // The rest of the indexing info should be the same
                for info in swiftIndexingInfo {
                    let commandLine = try #require(info.propertyListItem.dictValue?["swiftASTCommandArguments"]?.stringArrayValue)

                    for pattern in [StringPattern.suffix("swiftc"), "-emit-dependencies", "-serialize-diagnostics", "-incremental", "-parseable-output", "-whole-module-optimization", "-o", "-output-file-map", .prefix("@")] {

                        #expect(!commandLine.contains(where: { pattern ~= $0 }), "Expected that \(pattern) is not included in command line arguments.")
                    }

                    // All Swift files should be included in the command line invocation
                    for inputPath in task.inputs.map({ $0.path }) where inputPath.str.hasSuffix(".swift") {
                        #expect(commandLine.contains(inputPath.str), "Expected that \(inputPath.str) is included in command line arguments.")
                    }
                }

            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func generateIndexingInfo() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("foo.swift"),
                    TestFile("bar.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "CURRENT_PROJECT_VERSION": "3.1",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ])],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "VERSIONING_SYSTEM": "apple-generic",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                            "foo.swift",
                            "bar.swift",
                        ])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check the debug build.
        try await tester.checkBuild(runDestination: .macOS) { results in
            try results.checkTask(.matchRule(["SwiftDriver Compilation Requirements", "AppTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])) { task in

                // Test full info.
                do {
                    let results = task.generateIndexingInfo(input: .fullInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                    #expect(results.count == 3, "Expected to get indexing info for all input files.")
                    XCTAssertMatch(results[0].path.str, .suffix("bar.swift"))
                    XCTAssertMatch(results[1].path.str, .suffix("foo.swift"))
                    XCTAssertMatch(results[2].path.str, .suffix("main.swift"))

                    let infoForFiles = results.map { $0.indexingInfo }
                    #expect(infoForFiles.count == 3, "Expected that every indexing info for a Swift file is of type \(SwiftSourceFileIndexingInfo.self)")
                    XCTAssertMatch(infoForFiles[0].propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("bar.o"))
                    XCTAssertMatch(infoForFiles[1].propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("foo.o"))
                    XCTAssertMatch(infoForFiles[2].propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("main.o"))
                    // The rest of the indexing info should be the same
                    for info in infoForFiles {
                        let commandLine = try #require(info.propertyListItem.dictValue?["swiftASTCommandArguments"]?.stringArrayValue)

                        for pattern in [StringPattern.suffix("swiftc"), "-emit-dependencies", "-serialize-diagnostics", "-incremental", "-parseable-output", "-whole-module-optimization", "-o", "-output-file-map", .prefix("@")] {

                            #expect(!commandLine.contains(where: { pattern ~= $0 }), "Expected that \(pattern) is not included in command line arguments.")
                        }

                        // All Swift files should be included in the command line invocation
                        for inputPath in task.inputs.map({ $0.path }) where inputPath.str.hasSuffix(".swift") {
                            #expect(commandLine.contains(inputPath.str), "Expected that \(inputPath.str) is included in command line arguments.")
                        }
                    }
                }
                // Test info for a single file.
                do {
                    let results = task.generateIndexingInfo(input: .init(requestedSourceFile: Path("\(SRCROOT)/foo.swift"), outputPathOnly: false))
                    let info = try #require(results.first?.indexingInfo as? SwiftSourceFileIndexingInfo)
                    #expect(results.count == 1, "Expected to get indexing info for single file.")
                    XCTAssertMatch(results[0].path.str, .suffix("foo.swift"))

                    XCTAssertMatch(info.propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("foo.o"))
                    // The rest of the indexing info should be the same
                    let commandLine = try #require(info.propertyListItem.dictValue?["swiftASTCommandArguments"]?.stringArrayValue)

                    for pattern in [StringPattern.suffix("swiftc"), "-emit-dependencies", "-serialize-diagnostics", "-incremental", "-parseable-output", "-whole-module-optimization", "-o", "-output-file-map", .prefix("@")] {

                        #expect(!commandLine.contains(where: { pattern ~= $0 }), "Expected that \(pattern) is not included in command line arguments.")
                    }

                    // All Swift files should be included in the command line invocation
                    for inputPath in task.inputs.map({ $0.path }) where inputPath.str.hasSuffix(".swift") {
                        #expect(commandLine.contains(inputPath.str), "Expected that \(inputPath.str) is included in command line arguments.")
                    }
                }
                // Test output path only.
                do {
                    let results = task.generateIndexingInfo(input: .outputPathInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                    #expect(results.count == 3, "Expected to get indexing info for all input files.")
                    XCTAssertMatch(results[0].path.str, .suffix("bar.swift"))
                    XCTAssertMatch(results[1].path.str, .suffix("foo.swift"))
                    XCTAssertMatch(results[2].path.str, .suffix("main.swift"))

                    let infoForFiles = results.map { $0.indexingInfo }
                    #expect(infoForFiles.count == 3, "Expected that every indexing info for a Swift file is of type \(SwiftSourceFileIndexingInfo.self)")
                    XCTAssertMatch(infoForFiles[0].propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("bar.o"))
                    XCTAssertMatch(infoForFiles[1].propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("foo.o"))
                    XCTAssertMatch(infoForFiles[2].propertyListItem.dictValue?["outputFilePath"]?.stringValue, .suffix("main.o"))
                    // The rest of the indexing info should be the same
                    for info in infoForFiles {
                        guard info.propertyListItem.dictValue?["swiftASTCommandArguments"] == nil else {
                            Issue.record("arguments included when only output path was requested")
                            break
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func generateIndexingInfoWithEnableFixFor23297285() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [ TestFile("main.swift") ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "CURRENT_PROJECT_VERSION": "3.1",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "SWIFT_INCLUDE_PATHS": "/tmp/some-dir",
                    ])],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "VERSIONING_SYSTEM": "apple-generic",
                                               ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([ "main.swift" ])
                    ])
            ])

        do {
            let tester = try await TaskConstructionTester(getCore(), testProject)
            try await tester.checkBuild(runDestination: .macOS) { results in
                try results.checkTask(.matchRule(["SwiftDriver Compilation Requirements", "AppTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])) { task in

                    let indexingInfo = task.generateIndexingInfo(input: .fullInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                    #expect(indexingInfo.count == 1)
                    let info = try #require(indexingInfo[0].indexingInfo as? SwiftSourceFileIndexingInfo)
                    let commandLine = try #require(info.propertyListItem.dictValue?["swiftASTCommandArguments"]?.stringArrayValue)
                    let ccSearchPaths = commandLine.indices.filter { commandLine[$0] == "-Xcc" && commandLine[$0.advanced(by: 1)] == "-I" }.map { $0.advanced(by: 3) }.map { commandLine[$0] }
                    #expect(["/tmp/Test/aProject/build/Debug", "/tmp/some-dir"] == ccSearchPaths)
                }
            }
        }

        try await UserDefaults.withEnvironment(["EnableFixFor23297285": "0"]) {
            let tester = try await TaskConstructionTester(getCore(), testProject)
            try await tester.checkBuild(runDestination: .macOS) { results in
                try results.checkTask(.matchRule(["SwiftDriver Compilation Requirements", "AppTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])) { task in

                    let indexingInfo = task.generateIndexingInfo(input: .fullInfo).sorted(by: { (lhs, rhs) in lhs.path < rhs.path })
                    #expect(indexingInfo.count == 1)
                    let info = try #require(indexingInfo[0].indexingInfo as? SwiftSourceFileIndexingInfo)
                    let commandLine = try #require(info.propertyListItem.dictValue?["swiftASTCommandArguments"]?.stringArrayValue)
                    let ccSearchPaths = commandLine.indices.filter { commandLine[$0] == "-Xcc" && commandLine[$0.advanced(by: 1)] == "-I" }.map { $0.advanced(by: 3) }.map { commandLine[$0] }
                    #expect(ccSearchPaths.isEmpty)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func emptySwiftFileListUserDefaultOn() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [ TestFile("main.swift") ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "CURRENT_PROJECT_VERSION": "3.1",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "SWIFT_RESPONSE_FILE_PATH": "",
                        "USE_SWIFT_RESPONSE_FILE": "YES",
                    ])],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "VERSIONING_SYSTEM": "apple-generic",
                                               ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([ "main.swift" ])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkError("The path for Swift input file list cannot be empty. (in target 'AppTarget' from project 'aProject')")
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func emptySwiftFileListUserDefaultOff() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [ TestFile("main.swift") ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "CURRENT_PROJECT_VERSION": "3.1",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "SWIFT_RESPONSE_FILE_PATH": "",
                        "USE_SWIFT_RESPONSE_FILE": "NO",
                    ])],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "VERSIONING_SYSTEM": "apple-generic",
                                               ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([ "main.swift" ])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftFileListFileNameWithNewLine() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [ TestFile("ma\nin.swift") ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                        "CURRENT_PROJECT_VERSION": "3.1",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "USE_SWIFT_RESPONSE_FILE": "YES",
                        // remove in 51621328
                        "SWIFT_RESPONSE_FILE_PATH": "$(SWIFT_RESPONSE_FILE_PATH_$(variant)_$(arch))",
                    ])],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "VERSIONING_SYSTEM": "apple-generic",
                                               ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([ "ma\nin.swift" ])
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let srcroot = tester.workspace.projects[0].sourceRoot
        await tester.checkBuild(runDestination: .macOS) { results in

            results.checkWriteAuxiliaryFileTask(.matchRuleItemPattern(.suffix("AppTarget.SwiftFileList"))) { task, contents in
                task.checkRuleInfo(["WriteAuxiliaryFile", .suffix("AppTarget.SwiftFileList")])
                task.checkOutputs(contain: [.namePattern(.suffix("AppTarget.SwiftFileList"))])
                #expect(contents.asString == srcroot.join("ma\\\nin.swift\n").str)
            }

            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkInputs(contain: [.namePattern(.contains("ma\nin.swift"))])
            }

            results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements")) { task in
                task.checkInputs(contain: [.namePattern(.contains("ma\nin.swift"))])
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftLinkerSearchPaths() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift")
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGNING_ALLOWED": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                        "SUPPORTS_MACCATALYST": "YES",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ]
                )
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug"
                        )
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift"
                        ])
                    ]
                )
            ]
        )

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", "\(core.loadSDK(.macOS).path.str)", "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftmodule", "@\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-linker-args.resp", "-o", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget"])
            }
            results.checkNoDiagnostics()
        }

        let macosBaseSDK = try #require(core.sdkRegistry.lookup("macosx"), "unable to find macosx SDK")
        let catalystVariant = try #require(macosBaseSDK.variant(for: MacCatalystInfo.sdkVariantName), "unable to find catalyst SDKVariant")
        let catalystVersion = try #require(catalystVariant.defaultDeploymentTarget, "unable to load defaultDeploymentTarget for iosmac SDKVariant")

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macCatalyst) { results in
            results.checkTask(.matchRuleType("Ld")) { task in
                let containsSubFrameworksPath = task.commandLineAsStrings.contains("\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/SubFrameworks")
                let expectedCommandLine: [String] = [
                    ["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-ios\(catalystVersion.description)-macabi", "-isysroot", "\(core.loadSDK(.macOS).path.str)", "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug-maccatalyst", "-L\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)", "-L\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/lib", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/maccatalyst", "-L\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/lib", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/maccatalyst", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug-maccatalyst", "-F\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)", "-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks"],
                    (containsSubFrameworksPath ? ["-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/SubFrameworks"] : []),
                    ["-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks"],
                    (containsSubFrameworksPath ? ["-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/SubFrameworks"] : []),
                    ["-filelist", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList", "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/x86_64/AppTarget_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/x86_64/AppTarget_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", "-L/System/iOSSupport/usr/lib/swift", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftmodule", "@\(SRCROOT)/build/aProject.build/Debug-maccatalyst/AppTarget.build/Objects-normal/x86_64/AppTarget-linker-args.resp", "-o", "\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/MacOS/AppTarget"],
                ].reduce([], +)
                task.checkCommandLine(expectedCommandLine)
            }
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: ["IS_ZIPPERED": "YES"]), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", "\(core.loadSDK(.macOS).path.str)", "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftmodule", "@\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget-linker-args.resp", "-o", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget"])
            }
            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: ["IS_ZIPPERED": "YES"]), runDestination: .macCatalyst) { results in
            results.checkTask(.matchRuleType("Ld")) { task in
                let containsSubFrameworksPath = task.commandLineAsStrings.contains("\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/SubFrameworks")
                let expectedCommandLine: [String] = [
                    ["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-ios\(catalystVersion.description)-macabi", "-isysroot", "\(core.loadSDK(.macOS).path.str)", "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug-maccatalyst", "-L\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)", "-L\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/lib", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/maccatalyst", "-L\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/lib", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/maccatalyst", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug-maccatalyst", "-F\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)", "-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks"],
                    (containsSubFrameworksPath ? ["-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/SubFrameworks"] : []),
                    ["-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks"],
                    (containsSubFrameworksPath ? ["-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/SubFrameworks"] : []),
                    ["-filelist", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList", "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/x86_64/AppTarget_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/x86_64/AppTarget_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/x86_64/AppTarget.swiftmodule", "@\(SRCROOT)/build/aProject.build/Debug-maccatalyst/AppTarget.build/Objects-normal/x86_64/AppTarget-linker-args.resp", "-o", "\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/MacOS/AppTarget"],
                ].reduce([], +)
                task.checkCommandLine(expectedCommandLine)
            }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func swiftHeaderTool() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourceRoot = tmpDir.join("Project")

            let project = try await TestProject(
                "Project",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("Source.swift"),
                        TestFile("Header.h"),
                        TestFile("Source.m"),
                    ]
                ),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "ARCHS": "arm64 arm64e",
                        "SDKROOT": "iphoneos",
                        "SWIFT_OBJC_INTERFACE_HEADER_NAME": "Target-Swift.h",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ]
                )],
                targets: [
                    TestStandardTarget("Target", type: .framework, buildPhases: [
                        TestHeadersBuildPhase([TestBuildFile("Header.h", headerVisibility: .public)]),
                        TestSourcesBuildPhase(["Source.swift", "Source.m"]),
                    ])
                ]
            )

            // Create files in the filesystem so they're known to exist.
            let fs = PseudoFS()
            try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
            try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")

            let tester = try await TaskConstructionTester(getCore(), project)
            let parameters = BuildParameters(configuration: "Debug")
            await tester.checkBuild(parameters, runDestination: .iOS, fs: fs) { results in
                results.checkTask(.matchRuleItemPattern(.contains("swift-generated-headers"))) { gateTask in
                    results.checkTaskFollows(gateTask, .matchRuleItemPattern(.suffix("Target-Swift.h")))
                }

                results.checkNoDiagnostics()
            }
        }
    }

    /// Tests that per-file flags are not passed to the Swift compiler, because they are not supported.
    @Test(.requireSDKs(.macOS))
    func swiftPerFileFlags() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Foo.swift", additionalArgs: ["-customflag"])
                        ]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkCommandLineDoesNotContain("-customflag")
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireLLBuild(apiVersion: 12))
    func driver_enabled() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Foo.swift")
                        ]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        try await tester.checkBuild(runDestination: .macOS) { results in
            try results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements")) { task in
                try task.checkTaskAction(toolIdentifier: "swift-driver-compilation-requirement")
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func driver_disabled() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "SWIFT_USE_INTEGRATED_DRIVER": "NO",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                        "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "NO",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Foo.swift")
                        ]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        try await tester.checkBuild(runDestination: .macOS) { results in
            try results.checkTask(.matchRuleType("CompileSwiftSources")) { task in
                try task.checkTaskAction(toolIdentifier: nil)
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireLLBuild(apiVersion: 12))
    func eagerCompilation() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,

                        "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("Foo.swift")
                        ]),
                    ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        let buildParameters = BuildParameters(configuration: "Debug", overrides: ["SWIFT_USE_INTEGRATED_DRIVER": "NO", "SWIFT_ENABLE_EXPLICIT_MODULES": "NO", "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "NO"])
        await tester.checkBuild(buildParameters, runDestination: .macOS) { results in
            results.checkNoTask(.matchRuleType("SwiftDriver"))

            results.checkNoErrors()
        }

        try await tester.checkBuild(runDestination: .macOS) { results in
            try results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements")) { task in
                try task.checkTaskAction(toolIdentifier: "swift-driver-compilation-requirement")
                task.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements"])
            }

            try results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                try task.checkTaskAction(toolIdentifier: "swift-driver-compilation")
                task.checkCommandLineMatches(["builtin-Swift-Compilation"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func tBDOutput() async throws {
        let target = try await TestStandardTarget(
            "Core", type: .framework,
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "TAPI_EXEC": tapiToolPath.str,
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                    "GENERATE_INFOPLIST_FILE": "YES",
                ])],
            buildPhases: [
                TestSourcesBuildPhase(["foo.swift"])
            ])
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", children: [
                TestFile("foo.swift")
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ]
            )],
            targets: [target])
        let testWorkspace = TestWorkspace("Test", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        // If eager compilation is on, the tbd file is an output of the compilation requirements (module emission) step
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements")) { moduleTask in
                moduleTask.checkOutputs([.pathPattern(.suffix("Core Swift Compilation Requirements Finished")),
                                         .pathPattern(.suffix("Swift-API.tbd")),
                                         .pathPattern(.suffix("Core.swiftmodule")),
                                         .pathPattern(.suffix("Core-linker-args.resp")),
                                         .pathPattern(.suffix("Core.swiftsourceinfo")),
                                         .pathPattern(.suffix("Core.abi.json")),
                                         .pathPattern(.suffix("Core-Swift.h")),
                                         .pathPattern(.suffix("Core.swiftdoc")),
                ])

            }
            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { compileTask in
                compileTask.checkOutputs([.pathPattern(.suffix("Core Swift Compilation Finished")),
                                          .pathPattern(.suffix("foo.o")),
                                          .pathPattern(.suffix("foo.swiftconstvalues")),
                ])

            }
        }

        // If eager compilation is off, everything is an output of CompileSwiftSources.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_USE_INTEGRATED_DRIVER": "NO","SWIFT_ENABLE_EXPLICIT_MODULES": "NO", "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "NO",]), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("CompileSwiftSources")) { moduleTask in
                moduleTask.checkOutputs([.pathPattern(.suffix("foo.o")),
                                         .pathPattern(.suffix("foo.swiftconstvalues")),
                                         .pathPattern(.suffix("Swift-API.tbd")),
                                         .pathPattern(.suffix("Core.swiftmodule")),
                                         .pathPattern(.suffix("Core.swiftsourceinfo")),
                                         .pathPattern(.suffix("Core.abi.json")),
                                         .pathPattern(.suffix("Core-Swift.h")),
                                         .pathPattern(.suffix("Core.swiftdoc")),
                ])
            }

        }
    }

    /// Check that Swift Build passes -access-notes-path iff (a) `SWIFT_ACCESS_NOTES_PATH` is set and (b) it contains an accessible access notes file for the project in question.
    @Test(.requireSDKs(.macOS))
    func accessNotes() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("File1.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "ProductName",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ])
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            let fs = PseudoFS()

            // Create source file
            let path = srcRoot.join("Sources", preserveRoot: true, normalize: true)
            try fs.createDirectory(path, recursive: true)
            try fs.write(path.join("File1.swift"), contents: "// nothing")

            // Create exists.accessnotes
            let missingFile = tmpDir.join("missing.accessnotes")
            let existingFile = tmpDir.join("exists.accessnotes")
            try fs.write(existingFile, contents: "# nothing")

            // Test with no SWIFT_ACCESS_NOTES_PATH
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [:]), runDestination: .macOS, fs: fs) { results in
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineDoesNotContain("-access-notes-path")
                }
            }

            // Test with SWIFT_ACCESS_NOTES_PATH pointing to missing file
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_ACCESS_NOTES_PATH": missingFile.str]), runDestination: .macOS, fs: fs) { results in
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineDoesNotContain("-access-notes-path")
                    task.checkNoInputs(contain: [.path(missingFile.str)])
                }
            }

            // Test with SWIFT_ACCESS_NOTES_PATH pointing to extant file
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_ACCESS_NOTES_PATH": existingFile.str]), runDestination: .macOS, fs: fs) { results in
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-access-notes-path", existingFile.str])
                    task.checkInputs(contain: [.path(existingFile.str)])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func enableBareSlashRegexLiterals() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("File1.swift"),
                        TestFile("File2.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "AppWithoutRegex",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "ProductName",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                                "SWIFT_ENABLE_BARE_SLASH_REGEX": "NO",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ], dependencies: ["FrameworkWithRegex"]),
                    TestStandardTarget(
                        "FrameworkWithRegex",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "ProductName",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": "5.0",
                                "SWIFT_ENABLE_BARE_SLASH_REGEX": "YES",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File2.swift"),
                            ]),
                        ])
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
                results.checkTarget("AppWithoutRegex") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineDoesNotContain("-enable-bare-slash-regex")
                        task.checkCommandLineDoesNotContain("BareSlashRegexLiterals")
                    }
                }
                results.checkTarget("FrameworkWithRegex") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-enable-bare-slash-regex"])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func strictConcurrencyFlag() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("File1.swift"),
                        TestFile("File2.swift"),
                        TestFile("File3.swift"),
                        TestFile("File4.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "Default",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": "5.0",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ], dependencies: ["Minimal", "Targeted", "Complete"]),
                    TestStandardTarget(
                        "Minimal",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": "5.0",
                                "SWIFT_STRICT_CONCURRENCY": "minimal",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File2.swift"),
                            ]),
                        ]),
                    TestStandardTarget(
                        "Targeted",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": "5.0",
                                "SWIFT_STRICT_CONCURRENCY": "targeted",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File3.swift"),
                            ]),
                        ]),
                    TestStandardTarget(
                        "Complete",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": "5.0",
                                "SWIFT_STRICT_CONCURRENCY": "complete",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File4.swift"),
                            ]),
                        ]),
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
                results.checkTarget("Default") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineNoMatch([.prefix("-strict-concurrency")])
                        task.checkCommandLineNoMatch([.prefix("StrictConcurrency")])
                    }
                }
                results.checkTarget("Minimal") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineNoMatch([.prefix("-strict-concurrency")])
                        task.checkCommandLineNoMatch([.prefix("StrictConcurrency")])
                    }
                }
                results.checkTarget("Targeted") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-strict-concurrency=targeted"])
                    }
                }
                results.checkTarget("Complete") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-enable-upcoming-feature", "StrictConcurrency"])
                    }
                }
            }
        }
    }

    // Test frontend flag -library-level inference from the INSTALL_PATH.
    @Test(.requireSDKs(.macOS))
    func libraryLevel() async throws {
        if try await !swiftFeatures.has(.libraryLevel) {
            try await checkLibraryLevelForConfig(targetType: .framework,
                                                 buildSettings: ["SWIFT_LIBRARY_LEVEL" : "api"]) { task in
                task.checkCommandLineDoesNotContain("-library-level")
            }
            return
        }

        // Explicit library-level build setting.
        try await checkLibraryLevelForConfig(targetType: .framework,
                                             buildSettings: ["SWIFT_LIBRARY_LEVEL" : "api"]) { task in
            task.checkCommandLineContains(["-library-level", "api"])
        }

        // Infer "api" from public install path.
        try await checkLibraryLevelForConfig(targetType: .framework,
                                             buildSettings: ["INSTALL_PATH" : "/System/Library/Frameworks/MyFramework"]) { task in
            task.checkCommandLineContains(["-library-level", "api"])
        }
        try await checkLibraryLevelForConfig(targetType: .framework,
                                             buildSettings: ["INSTALL_PATH" : "/System/Library/SubFrameworks/MyFramework"]) { task in
            task.checkCommandLineContains(["-library-level", "api"])
        }

        // Don't infer library-level from an unknown install path.
        try await checkLibraryLevelForConfig(targetType: .framework,
                                             buildSettings: [:]) { task in
            task.checkCommandLineDoesNotContain("-library-level")
        }
        try await checkLibraryLevelForConfig(targetType: .framework,
                                             buildSettings: ["INSTALL_PATH" : "/SomeOtherApp/MyFramework"]) { task in
            task.checkCommandLineDoesNotContain("-library-level")
        }

        // Don't infer library-level for a non-framework.
        try await checkLibraryLevelForConfig(targetType: .application,
                                             buildSettings: ["INSTALL_PATH" : "/System/Library/Frameworks/MyFramework"]) { task in
            task.checkCommandLineDoesNotContain("-library-level")
        }
    }

    @Test(.skipHostOS(.macOS), .skipHostOS(.windows), .requireSDKs(.host))
    func autolinkExtract() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("File1.swift"),
                        TestFile("File2.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "Tool",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                                TestBuildFile("File2.swift"),
                            ]),
                        ]),
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .host) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchRuleType("SwiftAutolinkExtract")) { task in
                    task.checkCommandLineMatches([.suffix("swift-autolink-extract"), .suffix("File1.o"), .suffix("File2.o"), "-o", .suffix("Tool.autolink")])
                    task.checkInputs([.pathPattern(.suffix("File1.o")), .pathPattern(.suffix("File2.o")), .any, .any, .any])
                    task.checkOutputs([.pathPattern(.suffix("Tool.autolink"))])
                    results.checkTaskFollows(task, .matchRuleType("SwiftDriver Compilation"))
                }
                results.checkTask(.matchRuleType("Ld")) { task in
                    results.checkTaskFollows(task, .matchRuleType("SwiftAutolinkExtract"))
                    task.checkInputs(contain: [.pathPattern(.suffix("Tool.autolink"))])
                }
            }
        }
    }

    private func checkLibraryLevelForConfig(targetType: TestStandardTarget.TargetType,
                                            buildSettings: [String:String],
                                            body: (any PlannedTask) -> Void) async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("File1.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: targetType,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "ProductName",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                            ].addingContents(of: buildSettings)),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ])
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"), body: body)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func validateClangModulesOnce() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("File1.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "ProductName",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ])
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION":"YES"]), runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-validate-clang-modules-once", "-clang-build-session-file"])
                    }
                }
            }

            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION":"NO"]), runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineDoesNotContain("-validate-clang-modules-once")
                        task.checkCommandLineDoesNotContain("-clang-build-session-file")
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func skipABIDescriptorInstall() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("File1.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "ProductName",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ])
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                        task.checkOutputs(contain: [.namePattern(.suffix(".abi.json"))])
                    }
                    results.checkTaskExists(.matchRulePattern(["Copy", .suffix(".abi.json"), .suffix(".abi.json")]))
                }
            }

            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_INSTALL_MODULE_ABI_DESCRIPTOR": "NO"]), runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                        task.checkNoOutputs(contain: [.namePattern(.suffix(".abi.json"))])
                    }
                    results.checkNoTask(.matchRulePattern(["Copy", .suffix(".abi.json"), .suffix(".abi.json")]))
                }
            }
        }
    }

        @Test(.requireSDKs(.macOS))
        func workingDirectoryOverride() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("File1.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "ProductName",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ])
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-working-directory", srcRoot.str])
                        #expect(task.workingDirectory == srcRoot)
                    }
                }
            }

            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["COMPILER_WORKING_DIRECTORY": "/foo/bar"]), runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-working-directory", "/foo/bar"])
                        #expect(task.workingDirectory == Path("/foo/bar"))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func userModuleVersion() async throws {
        func checkUserModuleVersionForConfig(targetType: TestStandardTarget.TargetType,
                                             buildSettings: [String:String],
                                             body: (any PlannedTask) -> Void) async throws {
            try await withTemporaryDirectory { tmpDir in
                let srcRoot = tmpDir.join("srcroot")
                let testProject = try await TestProject(
                    "ProjectName",
                    sourceRoot: srcRoot,
                    groupTree: TestGroup(
                        "SomeFiles", path: "Sources",
                        children: [
                            TestFile("File1.swift"),
                        ]),
                    targets: [
                        TestStandardTarget(
                            "TargetName",
                            type: targetType,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "PRODUCT_NAME": "ProductName",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    "SWIFT_VERSION": swiftVersion,
                                ].addingContents(of: buildSettings)),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    TestBuildFile("File1.swift"),
                                ]),
                            ])
                    ])

                let tester = try await TaskConstructionTester(getCore(), testProject)
                await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
                    results.checkTarget("TargetName") { target in
                        results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"), body: body)
                    }
                }
            }
        }

        try await checkUserModuleVersionForConfig(targetType: .framework,
                                                  buildSettings: [:]) { task in
            task.checkCommandLineDoesNotContain("-user-module-version")
        }

        try await checkUserModuleVersionForConfig(targetType: .framework,
                                                  buildSettings: ["SWIFT_USER_MODULE_VERSION": ""]) { task in
            task.checkCommandLineDoesNotContain("-user-module-version")
        }

        try await checkUserModuleVersionForConfig(targetType: .framework,
                                                  buildSettings: ["SWIFT_USER_MODULE_VERSION": "22"]) { task in
            task.checkCommandLineContains(["-user-module-version", "22"])
        }

        try await checkUserModuleVersionForConfig(targetType: .framework,
                                                  buildSettings: ["SWIFT_USER_MODULE_VERSION": "22",
                                                                  "OTHER_SWIFT_FLAGS": "-user-module-version 42"]) { task in
            task.checkCommandLineContains(["-user-module-version", "42", "-user-module-version", "22"])
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftTakesCxxFlagsIfCxxInteropEnabled() async throws {

        func setupInteropTest(_ tmpDir: Path, enableInterop: Bool,
                              cxxLangStandard: String = "gnu++20") async throws -> TaskConstructionTester {
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                        TestFile("source.cpp")
                    ]),
                targets: [
                    TestStandardTarget(
                        "testFramework", type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                                "SWIFT_OBJC_INTEROP_MODE": enableInterop ? "objcxx" : "objc",
                                "CLANG_CXX_LANGUAGE_STANDARD": cxxLangStandard
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift", "source.cpp"])
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            return tester
        }

        try await withTemporaryDirectory { tmpDir in
            let tester = try await setupInteropTest(tmpDir, enableInterop: true)
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContainsUninterrupted(["-Xcc", "-std=gnu++20"])
                }
            }
        }

        // C++14 and earlier language standards don't have to be passed to the clang
        // importer.
        try await withTemporaryDirectory { tmpDir in
            let tester = try await setupInteropTest(tmpDir, enableInterop: true, cxxLangStandard: "gnu++14")
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineNoMatch([.prefix("-std=")])
                }
            }
        }

        // Verify that we don't pass C++ settings to Swift compilations when C++
        // interoperability is disabled.
        try await withTemporaryDirectory { tmpDir in
            let tester = try await setupInteropTest(tmpDir, enableInterop: false)
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineNoMatch([.prefix("-std=")])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func cxxInteropLinkerArgGeneration() async throws {
        // When Swift is generating additional linker args, we should not try to inject the response file when a target is a dependent of a cxx-interop target but has no Swift source of its own.
        let testProject = try await TestProject(
            "Test",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File1.swift"),
                    TestFile("File2.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "LIBTOOL": libtoolPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File2.c")]),
                        TestFrameworksBuildPhase(["libStaticLib.a"])
                    ], dependencies: ["StaticLib"]),
                TestStandardTarget(
                    "StaticLib",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_OBJC_INTEROP_MODE": "objcxx"
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("File1.swift")])
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Framework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkCommandLineNoMatch([.suffix("-linker-args.resp")])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func upcomingFeatures() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "CODE_SIGN_IDENTITY": "",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ])
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VERSION": "5.0"]), runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["-enable-upcoming-feature", "ConciseMagicFile"])
                    }
                }
            }

            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VERSION": "6.0"]), runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in

                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineDoesNotContain("ConciseMagicFile")
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func layoutStringValueWitnesses() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "CODE_SIGN_IDENTITY": "",
                                "SWIFT_VERSION": swiftVersion,
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ])
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_ENABLE_LAYOUT_STRING_VALUE_WITNESSES": "NO"]), runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineDoesNotContain("LayoutStringValueWitnesses")
                        task.checkCommandLineDoesNotContain("LayoutStringValueWitnessesInstantiation")
                        task.checkCommandLineDoesNotContain("-enable-layout-string-value-witnesses")
                        task.checkCommandLineDoesNotContain("-enable-layout-string-value-witnesses-instantiation")
                    }
                }
            }

            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_ENABLE_LAYOUT_STRING_VALUE_WITNESSES": "YES"]), runDestination: .macOS) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContainsUninterrupted(["-enable-experimental-feature", "LayoutStringValueWitnesses"])
                        task.checkCommandLineContainsUninterrupted(["-enable-experimental-feature", "LayoutStringValueWitnessesInstantiation"])
                        task.checkCommandLineContainsUninterrupted(["-Xfrontend", "-enable-layout-string-value-witnesses"])
                        task.checkCommandLineContainsUninterrupted(["-Xfrontend", "-enable-layout-string-value-witnesses-instantiation"])
                    }
                }
            }
        }
    }
    @Test(.requireSDKs(.host))
    func nonConformantPathsCauseDiagnostics() async throws {
        let destination: RunDestinationInfo = .host
        let testFilename = (destination == .windows) ? "main\t\n.swift": "main\u{0}.swift"
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile(testFilename),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Exec", type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile(testFilename),
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .host) { results in
            results.checkError(.regex(#/Input .* is non-conformant to path conventions on this platform/#))
            results.checkError(.regex(#/Response file input .* is non-conformant to path conventions on this platform/#))
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.host))
    func warningAsWarningsGroups() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SWIFT_WARNINGS_AS_WARNINGS_GROUPS": "Unsafe DeprecatedDeclaration",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SDKROOT": "$(HOST_PLATFORM)",
                                "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ])
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            try await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VERSION": swiftVersion]), runDestination: .host) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains([
                            "-Wwarning", "Unsafe",
                            "-Wwarning", "DeprecatedDeclaration"
                        ])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func warningAsErrorsGroups() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File1.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SWIFT_WARNINGS_AS_ERRORS_GROUPS": "UnknownWarningGroup PreconcurrencyImport",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SDKROOT": "$(HOST_PLATFORM)",
                                "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                            ]),
                        ])
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            try await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["SWIFT_VERSION": swiftVersion]), runDestination: .host) { results in
                results.checkTarget("TargetName") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains([
                            "-Werror", "UnknownWarningGroup",
                            "-Werror","PreconcurrencyImport"
                        ])
                    }
                }
            }
        }
    }
}

private func XCTAssertEqual(_ lhs: EnvironmentBindings, _ rhs: [String: String], file: StaticString = #filePath, line: UInt = #line) {
    #expect(lhs.bindingsDictionary == rhs)
}
