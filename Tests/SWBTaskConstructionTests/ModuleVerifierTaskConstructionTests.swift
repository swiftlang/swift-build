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

import struct Foundation.Data

import SWBProtocol
import SWBCore
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct ModuleVerifierTaskConstructionTests: CoreBasedTests {
    /// Test the core functionality of the modules verifier.
    @Test(.requireSDKs(.macOS))
    func builtinModuleVerifierTargetSetDiagnostics() async throws {
        let archs = ["arm64", "arm64", "x86_64"]
        let targetName = "Orange"
        let clangCompilerPath = try await self.clangCompilerPath
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Group",
                path: "Sources",
                children: [
                    TestFile("Orange.h"),
                    TestFile("Orange.defs"),
                    TestFile("main.m"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ARCHS": archs.joined(separator: " "),
                            "DEFINES_MODULE": "YES",
                            "ENABLE_MODULE_VERIFIER": "YES",
                            "MODULE_VERIFIER_KIND": "builtin",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS": "x86_64-apple-macos14.0-macabi x86_64-apple-macos14.0-macabi arm64e-apple-macos14.0-macabi",
                            "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu11 rust-1.71",
                            "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++ rust",
                            "MODULE_VERIFIER_VERBOSE": "YES",
                            "MODULE_VERIFIER_LSV": "YES",
                            "MODULES_VERIFIER_EXEC": "/alternate/modules-verifier",
                            "OTHER_MODULE_VERIFIER_FLAGS": "-- -I$(BUILT_PRODUCTS_DIR)/usr/include",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CC": clangCompilerPath.str,
                            "CLANG_USE_RESPONSE_FILE": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Orange.h", headerVisibility: .public),
                            TestBuildFile("Orange.defs", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .anyMac) { results in
            results.checkError("No standard in \"gnu11\" is valid for language objective-c++")
            results.checkWarning("Duplicate target architectures found - x86_64-apple-macos14.0-macabi, x86_64-apple-macos14.0-macabi")
            results.checkWarning("No matching target for target variant - arm64e-apple-macos14.0-macabi")
            results.checkWarning("Unsupported module verifier language \"rust\" (in target 'Orange' from project 'aProject')")
            results.checkWarning("Unsupported module verifier language standard \"rust-1.71\" (in target 'Orange' from project 'aProject')")
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS), .requireClangFeatures(.wSystemHeadersInModule))
    func builtinModuleVerifier() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let archs = ["arm64", "x86_64"]
        let targetName = "Orange"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Group",
                path: "Sources",
                children: [
                    TestFile("Orange.h"),
                    TestFile("Orange.defs"),
                    TestFile("main.m"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ARCHS": archs.joined(separator: " "),
                            "DEFINES_MODULE": "YES",
                            "ENABLE_MODULE_VERIFIER": "YES",
                            "MODULE_VERIFIER_KIND": "builtin",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu11 gnu17 gnu++20",
                            "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
                            "MODULE_VERIFIER_VERBOSE": "YES",
                            "MODULE_VERIFIER_LSV": "YES",
                            "MODULES_VERIFIER_EXEC": "/alternate/modules-verifier",
                            "OTHER_MODULE_VERIFIER_FLAGS": "-- -I$(BUILT_PRODUCTS_DIR)/usr/include",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CC": clangCompilerPath.str,
                            "OTHER_CFLAGS": "-DTARGET_FLAG",
                            "FRAMEWORK_SEARCH_PATHS": "/TARGET_PATH",
                            "CLANG_USE_RESPONSE_FILE": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Orange.h", headerVisibility: .public),
                            TestBuildFile("Orange.defs", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                    ]),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let xcconfig = tester.workspace.projects[0].sourceRoot.join("env.xcconfig")

        let fs = PseudoFS()
        try fs.createDirectory(xcconfig.dirname, recursive: true)
        try fs.write(xcconfig, contents: """
            FRAMEWORK_SEARCH_PATHS = /XCCONFIG_PATH
            """)

        // A regular build will just build the correct architecture.
        await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: ["OTHER_CFLAGS": "-DCLI_FLAG"], environmentConfigOverridesPath: xcconfig), runDestination: .macOS, fs: fs) { results in
            let arch = results.runDestinationTargetArchitecture
            results.checkNoDiagnostics()

            results.checkTarget(targetName) { target in
                results.checkTasks(.matchRuleType("VerifyModuleC")) {tasks in
                    #expect(tasks.count == 6)
                    var ruleInfos: Set<[String]> = []
                    for task in tasks {
                        ruleInfos.insert(task.ruleInfo)
                        guard task.ruleInfo.count > 5 else { continue }
                        let language = task.ruleInfo[5]
                        task.checkCommandLineContainsUninterrupted(["-x", language])
                        task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)"])
                        task.checkCommandLineContains([
                            "-F\(SRCROOT)/build/Debug",
                            "-F\(SRCROOT)/build/aProject.build/Debug/Orange.build/VerifyModule/Orange/\(language)",
                            "-Wsystem-headers-in-module=Orange",
                            "-Werror=non-modular-include-in-module",
                            "-Werror=non-modular-include-in-framework-module",
                            "-Werror=incomplete-umbrella",
                            "-Werror=quoted-include-in-framework-header",
                            "-Werror=atimport-in-framework-header",
                            "-Werror=framework-include-private-from-public",
                            "-Werror=incomplete-framework-module-declaration",
                            "-Wundef-prefix=TARGET_OS",
                            "-Werror=undef-prefix",
                            "-Werror=module-import-in-extern-c",
                            "-ferror-limit=0",
                            "-I\(SRCROOT)/build/Debug/usr/include",
                        ])

                        task.checkCommandLineContains(["-DCLI_FLAG"])
                        task.checkCommandLineDoesNotContain("-DTARGET_FLAG")

                        task.checkCommandLineContains(["-F/XCCONFIG_PATH"])
                        task.checkCommandLineDoesNotContain("-F/TARGET_PATH")

                        if language.hasSuffix("++") {
                            task.checkCommandLineContains([
                                "-std=gnu++20",
                                "-fcxx-modules",
                            ])
                        } else {
                            task.checkCommandLineMatches([
                                .or("-std=gnu11", "-std=gnu17"),
                            ])
                        }
                        guard task.ruleInfo.count > 7 else { continue }
                        let lsv = task.ruleInfo[7] == "lsv"
                        if lsv {
                            task.checkCommandLineContains(["-fmodules-local-submodule-visibility"])
                        } else {
                            task.checkCommandLineDoesNotContain("-fmodules-local-submodule-visibility")
                        }

                    }

                    #expect(ruleInfos == [
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", arch, "objective-c", "gnu11", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", arch, "objective-c", "gnu17", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", arch, "objective-c++", "gnu++20", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", arch, "objective-c", "gnu11", "lsv", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", arch, "objective-c", "gnu17", "lsv", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", arch, "objective-c++", "gnu++20", "lsv", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                    ])
                }
                // Check that we have a modules verifier task.
                results.checkTasks(.matchTarget(target), .matchRuleType("GenerateVerifyModuleInput")) { tasks in
                    var languages: Set<String> = []
                    for task in tasks {
                        let language = task.ruleInfo.last!
                        let outputPath = "\(SRCROOT)/build/aProject.build/Debug/Orange.build/VerifyModule/Orange/\(language)"
                        task.checkCommandLineMatches([
                            "builtin-GenerateVerifyModuleInput",
                            "\(SRCROOT)/build/Debug/Orange.framework",
                            "--language",
                            .equal(language),
                            "--main-output",
                            .prefix("\(outputPath)/Test.m"),
                            "--header-output",
                            "\(outputPath)/Test.framework/Headers/Test.h",
                            "--module-map-output",
                            "\(outputPath)/Test.framework/Modules/module.modulemap",
                        ])
                        languages.insert(language)

                        // Make sure GenerateVerifyModuleInput runs *after* we produce a module map, headers and copy them over.
                        results.checkTaskFollows(task, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/Orange-diagnostic-filename-map.json"]))
                        results.checkTaskFollows(task, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/module.modulemap"]))
                        results.checkTaskFollows(task, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/Orange.framework/Versions/A/Headers/Orange.h", "\(SRCROOT)/Sources/Orange.h"]))
                        results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/Orange.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/module.modulemap"]))

                        // Make sure there is no ordering relationship between the verifier and compile tasks
                        results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) { compileTasks in
                            for compileTask in compileTasks {
                                results.checkTaskDoesNotFollow(task, antecedent: compileTask)
                                results.checkTaskDoesNotFollow(compileTask, antecedent: task)
                            }
                        }

                        // Make sure the verifier runs only if its input files change.
                        #expect(!task.alwaysExecuteTask)
                        task.checkInputs(contain: [
                            .name("module.modulemap"),
                            .name("Orange.h")
                        ])
                        task.checkNoInputs(contain: [
                            .name("Orange.defs")
                        ])
                    }
                    #expect(languages == ["objective-c", "objective-c++"])
                }
            }
        }

        // An install build will build all architectures, but invoke modules-verifier once with all of them specified.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .anyMac) { results in
            results.checkNoDiagnostics()

            results.checkTarget(targetName) { target in
                results.checkTasks(.matchRuleType("VerifyModuleC")) {tasks in
                    #expect(tasks.count == 12)
                    var ruleInfos: Set<[String]> = []
                    for task in tasks {
                        ruleInfos.insert(task.ruleInfo)
                    }

                    #expect(ruleInfos == [
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "arm64", "objective-c", "gnu11", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "arm64", "objective-c", "gnu17", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "arm64", "objective-c++", "gnu++20", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "x86_64", "objective-c", "gnu11", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "x86_64", "objective-c", "gnu17", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "x86_64", "objective-c++", "gnu++20", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "arm64", "objective-c", "gnu11",  "lsv", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "arm64", "objective-c", "gnu17",  "lsv", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "arm64", "objective-c++", "gnu++20",  "lsv", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "x86_64", "objective-c", "gnu11",  "lsv", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "x86_64", "objective-c", "gnu17",  "lsv", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", "x86_64", "objective-c++", "gnu++20",  "lsv", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                    ])
                }
                results.checkTasks(.matchTarget(target), .matchRuleType("GenerateVerifyModuleInput")) { tasks in
                    var languages: Set<String> = []
                    #expect(tasks.count == 2)
                    for task in tasks {
                        let language = task.ruleInfo.last!
                        languages.insert(language)
                    }
                    #expect(languages == ["objective-c", "objective-c++"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireClangFeatures(.wSystemHeadersInModule))
    func builtinModuleVerifierSDK() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        try await withTemporaryDirectory { tmpDir in
            let sdkPath = tmpDir.join("MySDK.sdk")
            try await writeSDK(name: sdkPath.basename, parentDir: sdkPath.dirname, settings: [
                "CanonicalName": "com.apple.my_sdk.1.0",
                "IsBaseSDK": true,
                "DefaultProperties": [
                    "PLATFORM_NAME": "macosx",
                ],
                "CustomProperties": [
                    "SYSTEM_FRAMEWORK_SEARCH_PATHS": "$(inherited) $(SDKROOT)$(SYSTEM_PREFIX)$(SYSTEM_LIBRARY_DIR)/PrivateFrameworks"
                ],
                "SupportedTargets": [
                    "default": [
                        "LLVMTargetTripleVendor": "apple",
                    ]
                ]
            ])

            let targetName = "Orange"
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("Orange.h"),
                        TestFile("Orange.defs"),
                        TestFile("main.m"),
                    ]),
                targets: [
                    TestStandardTarget(
                        targetName,
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS": "x86_64",
                                "DEFINES_MODULE": "YES",
                                "ENABLE_MODULE_VERIFIER": "YES",
                                "MODULE_VERIFIER_KIND": "builtin",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": sdkPath.str,
                                "CC": clangCompilerPath.str,
                                "CLANG_USE_RESPONSE_FILE": "NO",
                            ]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("Orange.h", headerVisibility: .public),
                                TestBuildFile("Orange.defs", headerVisibility: .public),
                            ]),
                            TestSourcesBuildPhase([
                                "main.m",
                            ]),
                        ]),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            // A regular build will just build the correct architecture.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                results.checkTarget(targetName) { target in
                    results.checkTask(.matchRuleType("VerifyModuleC")) { task in
                        task.checkCommandLineContains([
                            "-isysroot", sdkPath.str,
                            "-iframework", sdkPath.join("System/Library/PrivateFrameworks").str,
                        ])
                    }
                }
            }
        }
    }

    /// Tests iosmac variant applied for verifying a macos target due to `MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS`.
    @Test(.requireSDKs(.macOS), .requireClangFeatures(.wSystemHeadersInModule))
    func builtinModuleVerifierSDKVariantFromMacOS() async throws {
        let settings: [String: PropertyListItem] = [
            "CanonicalName": "com.apple.my_sdk.1.0",
            "IsBaseSDK": true,
            "DefaultVariant": "macos",
            "DefaultProperties": [
                "PLATFORM_NAME": "macosx",
                "IOS_UNZIPPERED_TWIN_PREFIX_PATH": "/System/iOSSupport",
            ],
            "SupportedTargets": [
                "macos": [
                    "LLVMTargetTripleVendor": "apple",
                ],
                "iosmac": [
                    "LLVMTargetTripleVendor": "apple",
                ]
            ],
            "Variants": .plArray([
                .plDict([
                    "Name": "iosmac",
                    "BuildSettings": [
                        "LLVM_TARGET_TRIPLE_OS_VERSION": "ios17.0",
                        "SYSTEM_FRAMEWORK_SEARCH_PATHS": "$(inherited) $(SDKROOT)$(IOS_UNZIPPERED_TWIN_PREFIX_PATH)/System/Library/PrivateFrameworks"
                    ]
                ]),
                .plDict([
                    "Name": "macos",
                    "BuildSettings": [
                        "LLVM_TARGET_TRIPLE_OS_VERSION": "macos14.0",
                        "SYSTEM_FRAMEWORK_SEARCH_PATHS": "$(inherited) $(SDKROOT)/System/Library/PrivateFrameworks",
                    ]
                ])
            ])
        ]
        try await withTemporaryDirectory { tmpDir in
            let sdkPath = tmpDir.join("MySDK.sdk")
            try await writeSDK(name: sdkPath.basename, parentDir: sdkPath.dirname, settings: settings)

            let targetName = "Orange"
            let clangCompilerPath = try await self.clangCompilerPath
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("Orange.h"),
                        TestFile("Orange.defs"),
                        TestFile("main.m"),
                    ]),
                targets: [
                    TestStandardTarget(
                        targetName,
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS": "x86_64",
                                "DEFINES_MODULE": "YES",
                                "ENABLE_MODULE_VERIFIER": "YES",
                                "MODULE_VERIFIER_KIND": "builtin",
                                "MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS": "x86_64-apple-ios17.0-macabi",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": sdkPath.str,
                                "CC": clangCompilerPath.str,
                                "CLANG_USE_RESPONSE_FILE": "NO",
                            ]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("Orange.h", headerVisibility: .public),
                                TestBuildFile("Orange.defs", headerVisibility: .public),
                            ]),
                            TestSourcesBuildPhase([
                                "main.m",
                            ]),
                        ]),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            // A regular build will just build the correct architecture.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                results.checkTarget(targetName) { target in
                    results.checkTasks(.matchRuleType("VerifyModuleC")) { tasks in
                        #expect(tasks.count == 2)
                        for task in tasks {
                            let targetVariant = task.ruleInfo[2]
                            if targetVariant == "x86_64-apple-ios17.0-macabi" {
                                task.checkCommandLineContains([
                                    "-target", "x86_64-apple-macos14.0",
                                    "-target-variant", "x86_64-apple-ios17.0-macabi",
                                    "-isysroot", sdkPath.str,
                                    "-iframework", sdkPath.join("System/iOSSupport/System/Library/PrivateFrameworks").str,
                                ])
                            } else {
                                #expect(targetVariant == "x86_64-apple-macos14.0")
                                task.checkCommandLineContains([
                                    "-target", "x86_64-apple-ios17.0-macabi",
                                    "-target-variant", "x86_64-apple-macos14.0",
                                    "-isysroot", sdkPath.str,
                                    "-iframework", sdkPath.join("System/Library/PrivateFrameworks").str,
                                ])
                            }
                        }

                    }
                }
            }
        }
    }

    /// Tests iosmac variant applied for verifying an iosmac target due to `SDK_VARIANT`.
    @Test(.requireSDKs(.macOS), .requireClangFeatures(.wSystemHeadersInModule))
    func builtinModuleVerifierSDKVariantFromIOSMac() async throws {
        let settings: [String: PropertyListItem] = [
            "CanonicalName": "com.apple.my_sdk.1.0",
            "IsBaseSDK": true,
            "DefaultVariant": "macos",
            "DefaultProperties": [
                "PLATFORM_NAME": "macosx",
                "IOS_UNZIPPERED_TWIN_PREFIX_PATH": "/System/iOSSupport",
            ],
            "SupportedTargets": [
                "macos": [
                    "LLVMTargetTripleVendor": "apple",
                ],
                "iosmac": [
                    "LLVMTargetTripleVendor": "apple",
                ]
            ],
            "Variants": .plArray([
                .plDict([
                    "Name": "iosmac",
                    "BuildSettings": [
                        "LLVM_TARGET_TRIPLE_OS_VERSION": "ios17.0",
                        "LLVM_TARGET_TRIPLE_SUFFIX": "-macabi",
                        "SYSTEM_FRAMEWORK_SEARCH_PATHS": "$(inherited) $(SDKROOT)$(IOS_UNZIPPERED_TWIN_PREFIX_PATH)/System/Library/PrivateFrameworks"
                    ]
                ]),
                .plDict([
                    "Name": "macos",
                    "BuildSettings": [
                        "LLVM_TARGET_TRIPLE_OS_VERSION": "macos14.0",
                        "SYSTEM_FRAMEWORK_SEARCH_PATHS": "$(inherited) $(SDKROOT)/System/Library/PrivateFrameworks",
                    ]
                ])
            ])
        ]
        try await withTemporaryDirectory { tmpDir in
            let sdkPath = tmpDir.join("MySDK.sdk")
            try await writeSDK(name: sdkPath.basename, parentDir: sdkPath.dirname, settings: settings)

            let targetName = "Orange"
            let clangCompilerPath = try await self.clangCompilerPath
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("Orange.h"),
                        TestFile("Orange.defs"),
                        TestFile("main.m"),
                    ]),
                targets: [
                    TestStandardTarget(
                        targetName,
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS": "x86_64",
                                "DEFINES_MODULE": "YES",
                                "ENABLE_MODULE_VERIFIER": "YES",
                                "MODULE_VERIFIER_KIND": "builtin",
                                "MODULE_VERIFIER_TARGET_TRIPLE_VARIANTS": "",
                                "SDK_VARIANT": "iosmac",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": sdkPath.str,
                                "CC": clangCompilerPath.str,
                                "CLANG_USE_RESPONSE_FILE": "NO",
                            ]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("Orange.h", headerVisibility: .public),
                                TestBuildFile("Orange.defs", headerVisibility: .public),
                            ]),
                            TestSourcesBuildPhase([
                                "main.m",
                            ]),
                        ]),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            // A regular build will just build the correct architecture.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                results.checkTarget(targetName) { target in
                    results.checkTask(.matchRuleType("VerifyModuleC")) { task in
                        let targetVariant = task.ruleInfo[2]
                        #expect(targetVariant == "")
                        task.checkCommandLineContains([
                            "-target", "x86_64-apple-ios17.0-macabi",
                            "-isysroot", sdkPath.str,
                            "-iframework", sdkPath.join("System/iOSSupport/System/Library/PrivateFrameworks").str,
                        ])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireClangFeatures(.wSystemHeadersInModule))
    func builtinModuleVerifierDefaultStandards() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let archs = ["arm64", "x86_64"]
        let targetName = "Orange"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Group",
                path: "Sources",
                children: [
                    TestFile("Orange.h"),
                    TestFile("Orange.defs"),
                    TestFile("main.m"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ARCHS": archs.joined(separator: " "),
                            "DEFINES_MODULE": "YES",
                            "ENABLE_MODULE_VERIFIER": "YES",
                            "MODULE_VERIFIER_KIND": "builtin",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "",
                            "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CC": clangCompilerPath.str,
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Orange.h", headerVisibility: .public),
                            TestBuildFile("Orange.defs", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // A regular build will just build the correct architecture.
        await tester.checkBuild(runDestination: .macOS) { results in
            let arch = results.runDestinationTargetArchitecture
            results.checkNoDiagnostics()

            results.checkTarget(targetName) { target in
                results.checkTasks(.matchRuleType("VerifyModuleC")) {tasks in
                    var ruleInfos: Set<[String]> = []
                    for task in tasks {
                        ruleInfos.insert(task.ruleInfo)
                    }

                    #expect(ruleInfos == [
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", arch, "objective-c", "gnu17", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                        ["VerifyModuleC", "\(SRCROOT)/build/Debug/Orange.framework", "", "", arch, "objective-c++", "gnu++20", "", "com.apple.compilers.llvm.clang.1_0.verify_module"],
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func externalModuleVerifier() async throws {
        let archs = ["arm64", "x86_64"]
        let targetName = "Orange"
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Group",
                path: "Sources",
                children: [
                    TestFile("Orange.h"),
                    TestFile("Orange.defs"),
                    TestFile("main.m"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ARCHS": archs.joined(separator: " "),
                            "DEFINES_MODULE": "YES",
                            "ENABLE_MODULE_VERIFIER": "YES",
                            "MODULE_VERIFIER_KIND": "external",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu11 gnu17 gnu++20",
                            "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
                            "MODULE_VERIFIER_VERBOSE": "YES",
                            "MODULE_VERIFIER_LSV": "YES",
                            "MODULES_VERIFIER_EXEC": "/alternate/modules-verifier",
                            "OTHER_MODULE_VERIFIER_FLAGS": "-- -I$(BUILT_PRODUCTS_DIR)/usr/include",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Orange.h", headerVisibility: .public),
                            TestBuildFile("Orange.defs", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                    ]),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // A regular build will just build the correct architecture.
        await tester.checkBuild(runDestination: .macOS) { results in
            let arch = results.runDestinationTargetArchitecture
            results.checkNoDiagnostics()

            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("VerifyModule")) { task in
                    task.checkRuleInfo(["VerifyModule", "\(SRCROOT)/build/Debug/Orange.framework"])

                    let expectedCommandLine = [
                        "/alternate/modules-verifier",
                        "\(SRCROOT)/build/Debug/Orange.framework",
                        "--clang", "clang",
                        "--diagnostic-filename-map", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/Orange-diagnostic-filename-map.json",
                        "--sdk", core.loadSDK(.macOS).path.str,
                        "--intermediates-directory", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/VerifyModule",
                        "--target", "\(arch)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)",
                        "--language", "objective-c", "--language", "objective-c++",
                        "--standard", "gnu11", "--standard", "gnu17", "--standard", "gnu++20",
                        "--verbose",
                        "--enable-local-submodule-visibility",
                        "--", "-I\(SRCROOT)/build/Debug/usr/include",
                    ]
                    task.checkCommandLine(expectedCommandLine)

                    // Make sure VerifyModule runs *after* we produce a module map, headers and copy them over.
                    results.checkTaskFollows(task, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/Orange-diagnostic-filename-map.json"]))
                    results.checkTaskFollows(task, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/module.modulemap"]))
                    results.checkTaskFollows(task, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/Orange.framework/Versions/A/Headers/Orange.h", "\(SRCROOT)/Sources/Orange.h"]))
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/Orange.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/module.modulemap"]))

                    // Make sure there is no ordering relationship between the verifier and compile tasks
                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) { compileTasks in
                        for compileTask in compileTasks {
                            results.checkTaskDoesNotFollow(task, antecedent: compileTask)
                            results.checkTaskDoesNotFollow(compileTask, antecedent: task)
                        }
                    }

                    // Make sure the verifier runs only if its input files change.
                    #expect(!task.alwaysExecuteTask)
                    task.checkInputs(contain: [
                        .name("module.modulemap"),
                        .name("Orange.h")
                    ])
                    task.checkNoInputs(contain: [
                        .name("Orange.defs")
                    ])
                }
            }
        }

        // An install build will build all architectures, but invoke modules-verifier once with all of them specified.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .anyMac) { results in
            results.checkNoDiagnostics()

            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("VerifyModule")) { task in
                    task.checkRuleInfo(["VerifyModule", "\(SRCROOT)/build/Debug/Orange.framework"])

                    let expectedCommandLine = [
                        "/alternate/modules-verifier",
                        "\(SRCROOT)/build/Debug/Orange.framework",
                        "--clang", "clang",
                        "--diagnostic-filename-map", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/Orange-diagnostic-filename-map.json",
                        "--sdk", core.loadSDK(.macOS).path.str,
                        "--intermediates-directory", "\(SRCROOT)/build/aProject.build/Debug/Orange.build/VerifyModule"
                    ]
                    + archs.flatMap { ["--target", "\($0)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)"] } + [
                        "--language", "objective-c", "--language", "objective-c++",
                        "--standard", "gnu11", "--standard", "gnu17", "--standard", "gnu++20",
                        "--verbose",
                        "--enable-local-submodule-visibility",
                        "--", "-I\(SRCROOT)/build/Debug/usr/include",
                    ]
                    task.checkCommandLine(expectedCommandLine)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireClangFeatures(.wSystemHeadersInModule))
    func excludedFilesBuiltin() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let targetName = "Orange"
        let testProject = TestProject("aProject",
                                      groupTree: TestGroup(targetName, path: targetName,
                                                           children: [
                                                            TestFile("Orange.h"),
                                                            TestFile("Excluded.h"),
                                                            TestFile("iOS.h")
                                                           ]),
                                      targets: [
                                        TestStandardTarget(targetName,
                                                           type: .framework,
                                                           buildConfigurations: [
                                                            TestBuildConfiguration("Debug",
                                                                                   buildSettings: [
                                                                                    "DEFINES_MODULE": "YES",
                                                                                    "ENABLE_MODULE_VERIFIER": "YES",
                                                                                    "MODULE_VERIFIER_KIND": "builtin",
                                                                                    "EXCLUDED_SOURCE_FILE_NAMES": "Excluded.h",
                                                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                    "CC": clangCompilerPath.str,
                                                                                   ]),
                                                           ],
                                                           buildPhases: [
                                                            TestHeadersBuildPhase([
                                                                TestBuildFile("Orange.h", headerVisibility: .public),
                                                                TestBuildFile("Excluded.h", headerVisibility: .public),
                                                                TestBuildFile("iOS.h", headerVisibility: .public, platformFilters: PlatformFilter.iOSFilters),
                                                            ]),
                                                           ]),
                                      ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .macOS, targetName: targetName) { results in
            results.checkNoDiagnostics()
            results.checkTarget(targetName) { target in
                results.checkNoDiagnostics()
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateVerifyModuleInput")) { task in
                    task.checkInputs(contain: [
                        .name("Orange.h"),
                    ])
                    task.checkNoInputs(contain: [
                        .name("Excluded.h"),
                        .name("iOS.h"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("VerifyModuleC")) { task in
                    results.checkTaskFollows(task, .matchRuleType("GenerateVerifyModuleInput"))
                    task.checkNoInputs(contain: [
                        .name("Excluded.h"),
                        .name("iOS.h"),
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func excludedFilesExternal() async throws {
        let targetName = "Orange"
        let testProject = TestProject("aProject",
                                      groupTree: TestGroup(targetName, path: targetName,
                                                           children: [
                                                            TestFile("Orange.h"),
                                                            TestFile("Excluded.h"),
                                                            TestFile("iOS.h")
                                                           ]),
                                      targets: [
                                        TestStandardTarget(targetName,
                                                           type: .framework,
                                                           buildConfigurations: [
                                                            TestBuildConfiguration("Debug",
                                                                                   buildSettings: [
                                                                                    "DEFINES_MODULE": "YES",
                                                                                    "ENABLE_MODULE_VERIFIER": "YES",
                                                                                    "MODULE_VERIFIER_KIND": "external",
                                                                                    "EXCLUDED_SOURCE_FILE_NAMES": "Excluded.h",
                                                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                   ]),
                                                           ],
                                                           buildPhases: [
                                                            TestHeadersBuildPhase([
                                                                TestBuildFile("Orange.h", headerVisibility: .public),
                                                                TestBuildFile("Excluded.h", headerVisibility: .public),
                                                                TestBuildFile("iOS.h", headerVisibility: .public, platformFilters: PlatformFilter.iOSFilters),
                                                            ]),
                                                           ]),
                                      ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .macOS, targetName: targetName) { results in
            results.checkNoDiagnostics()
            results.checkTarget(targetName) { target in
                results.checkNoDiagnostics()
                results.checkTask(.matchTarget(target), .matchRuleType("VerifyModule")) { task in
                    task.checkInputs(contain: [
                        .name("Orange.h"),
                    ])
                    task.checkNoInputs(contain: [
                        .name("Excluded.h"),
                        .name("iOS.h"),
                    ])
                }
            }
        }
    }
}

fileprivate final class TestIntentsCompilerTaskPlanningClientDelegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
    override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
        let commandName = commandLine.first.map(Path.init)?.basename
        switch commandName {
        case "intentbuilderc":
            if let input = commandLine.elementAfterElements(["-input"]).map(Path.init)?.basenameWithoutSuffix,
               let outputDir = commandLine.elementAfterElements(["-output"]).map(Path.init) {
                let classPrefix = commandLine.elementAfterElements(["-classPrefix"]) ?? ""
                let language = commandLine.elementAfterElements(["-language"]) ?? "Objective-C"
                switch language {
                case "Objective-C":
                    let outputFiles = [outputDir.join("\(classPrefix)\(input).h").str, outputDir.join("\(classPrefix)\(input).m").str]
                    return .result(status: .exit(0), stdout: Data(outputFiles.joined(separator: "\n").utf8), stderr: .init())
                case "Swift":
                    let outputFile = outputDir.join("\(classPrefix)\(input).swift").str
                    return .result(status: .exit(0), stdout: Data(outputFile.utf8), stderr: .init())
                default:
                    throw StubError.error("unknown language '\(language)'")
                }
            } else {
                throw StubError.error("Missing one of [-input, -output] in \(commandLine)")
            }
        default:
            break
        }
        return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
    }
}

protocol ClangModuleVerifierTaskConstructionTestsProtocol: CoreBasedTests {
    var verifierKind: String { get }
    var verifierRuleName: String { get }
    var verifierInputRuleName: String { get }
}

extension ClangModuleVerifierTaskConstructionTestsProtocol {
    func _noHeaders() async throws {
        let targetName = "Orange"
        let clangCompilerPath = try await self.clangCompilerPath
        let testProject = TestProject(
            "Project",
            groupTree: TestGroup(
                targetName,
                children: [
                    TestFile("Orange.modulemap"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "DEFINES_MODULE": "YES",
                            "ENABLE_MODULE_VERIFIER": "YES",
                            "MODULE_VERIFIER_KIND": verifierKind,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "MODULEMAP_FILE": "Orange.modulemap",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CC": clangCompilerPath.str,
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let sourceRoot = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        try await fs.writeFileContents(sourceRoot.join("Orange.modulemap")) { contents in
            contents <<< "framework module Orange {}\n"
        }

        await tester.checkBuild(runDestination: .macOS, targetName: targetName, fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTarget(targetName) { target in
                let task = results.findOneMatchingTask([.matchTarget(target), .matchRuleType(verifierRuleName)])

                #expect((task?.alwaysExecuteTask ?? false) == false)
                task?.checkInputs(contain: [
                    .name("module.modulemap"),
                ])
            }
        }
    }

    func _modulesVerifierEagerCompilation() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let testProject = TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("A.h"),
                    TestFile("A.m"),
                    TestFile("B.h"),
                    TestFile("B.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "DEFINES_MODULE": "YES",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "EAGER_COMPILATION_REQUIRE": "YES",
                    "ENABLE_MODULE_VERIFIER": "YES",
                    "MODULE_VERIFIER_KIND": verifierKind,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CC": clangCompilerPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "A",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("A.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "A.m",
                        ]),
                    ]),
                TestStandardTarget(
                    "B",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("B.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "B.m",
                        ]),
                    ],
                    dependencies: [
                        "A",
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS, targetName: "B") { results in
            results.checkNoDiagnostics()

            func noDependency(from task1: [TaskCondition], to task2: [TaskCondition], sourceLocation: SourceLocation = #_sourceLocation) {
                let res = results.createCopy()
                res.checkTask(task1, sourceLocation: sourceLocation) { foundTask in
                    res.checkTaskDoesNotFollow(foundTask, task2, sourceLocation: sourceLocation)
                }
            }

            // no dependency on own compile tasks
            noDependency(from: [.matchTargetName("A"), .matchRuleType(verifierRuleName)],
                         to: .compileC("A", fileName: "A.m"))
            noDependency(from: [.matchTargetName("B"), .matchRuleType(verifierRuleName)],
                         to: .compileC("B", fileName: "B.m"))

            // no dependency on compile tasks from downstream target
            noDependency(from: [.matchTargetName("B"), .matchRuleType(verifierRuleName)],
                         to: .compileC("A", fileName: "A.m"))

            // no dependency of copying header to entry of target
            noDependency(from: [.matchTargetName("A"), .matchRuleType("CpHeader")],
                         to: [.matchTargetName("A"), .matchRuleItemPattern(.suffix("-entry"))])
        }
    }

    /// Test that the modules verifier task does not run during `installhdrs` or `installapi`.
    func _noModulesVerifierUnlessBuild() async throws {
        let targetName = "Orange"
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("Orange.h"),
                    TestFile("main.m"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "DEFINES_MODULE": "YES",
                            "ENABLE_MODULE_VERIFIER": "YES",
                            "MODULE_VERIFIER_KIND": verifierKind,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SUPPORTS_TEXT_BASED_API": "YES",
                            "TAPI_EXEC": tapiToolPath.str,
                            "CC": clangCompilerPath.str,
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Orange.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        for action in BuildAction.allCases.filter({ !$0.buildComponents.contains("build") }) {
            await tester.checkBuild(BuildParameters(action: action, configuration: "Release"), runDestination: .macOS) { results in
                results.checkNoDiagnostics()
                results.checkTarget(targetName) { target in
                    // Check that we DO NOT have a modules verifier task.
                    results.checkNoTask(.matchTarget(target), .matchRuleType(verifierRuleName))
                }
            }
        }
    }

    /// Test that the modules verifier task doesn't depend on the compile task in its target or in other related targets, and vice versa.
    func _modulesVerifierIndependence() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Group",
                path: "Sources",
                children: [
                    TestFile("AAA.h"),
                    TestFile("AAA.m"),
                    TestFile("BBB.h"),
                    TestFile("BBB.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                        "EAGER_COMPILATION_REQUIRE": "YES",
                                        "ENABLE_MODULE_VERIFIER": "YES",
                                        "MODULE_VERIFIER_KIND": verifierKind,
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "CC": clangCompilerPath.str,
                                       ]),
            ],
            targets: [
                TestStandardTarget(
                    "AAA",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("AAA.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "AAA.m",
                        ]),
                    ]),
                TestStandardTarget(
                    "BBB",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("BBB.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "BBB.m",
                        ]),
                    ],
                    dependencies: [
                        "AAA",
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS, targetName: "BBB") { results in
            results.checkNoDiagnostics()

            // Note checkTarget() removes the target from that list, but not all its tasks (which is what we want here)
            results.checkTarget("AAA") { AAATarget in
                // Check that we have an modules verifier task.
                results.checkTask(.matchTarget(AAATarget), .matchRuleType(verifierRuleName)) { AAAVerifierTask in
                    if verifierKind == "external" {
                        AAAVerifierTask.checkRuleInfo([verifierRuleName, "\(SRCROOT)/build/Debug/AAA.framework"])
                    } else {
                        AAAVerifierTask.checkRuleInfo([verifierRuleName, "\(SRCROOT)/build/Debug/AAA.framework", "", "", "x86_64", "objective-c", "gnu17", "", "com.apple.compilers.llvm.clang.1_0.verify_module"])
                    }

                    // Make sure AAA VerifyModule runs *after* we produce a module map, headers and copy them over.
                    results.checkTaskFollows(AAAVerifierTask, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AAA.build/AAA-diagnostic-filename-map.json"]))
                    results.checkTaskFollows(AAAVerifierTask, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AAA.build/module.modulemap"]))
                    results.checkTaskFollows(AAAVerifierTask, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/AAA.framework/Versions/A/Headers/AAA.h", "\(SRCROOT)/Sources/AAA.h"]))
                    results.checkTaskFollows(AAAVerifierTask, .matchRule(["Copy", "\(SRCROOT)/build/Debug/AAA.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Debug/AAA.build/module.modulemap"]))

                    // But AAA shouldn't depend on any of BBB's tasks
                    results.checkTaskDoesNotFollow(AAAVerifierTask, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/BBB.build/BBB-diagnostic-filename-map.json"]))
                    results.checkTaskDoesNotFollow(AAAVerifierTask, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/BBB.build/module.modulemap"]))
                    results.checkTaskDoesNotFollow(AAAVerifierTask, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/BBB.framework/Versions/A/Headers/BBB.h", "\(SRCROOT)/Sources/BBB.h"]))
                    results.checkTaskDoesNotFollow(AAAVerifierTask, .matchRule(["Copy", "\(SRCROOT)/build/Debug/BBB.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Debug/BBB.build/module.modulemap"]))

                    results.checkTarget("BBB") { BBBTarget in
                        // Check that we have an modules verifier task.
                        results.checkTask(.matchTarget(BBBTarget), .matchRuleType(verifierRuleName)) { BBBVerifierTask in
                            if verifierKind == "external" {
                                BBBVerifierTask.checkRuleInfo([verifierRuleName, "\(SRCROOT)/build/Debug/BBB.framework"])
                            } else {
                                BBBVerifierTask.checkRuleInfo([verifierRuleName, "\(SRCROOT)/build/Debug/BBB.framework", "", "", "x86_64", "objective-c", "gnu17", "", "com.apple.compilers.llvm.clang.1_0.verify_module"])
                            }

                            // Make sure BBB VerifyModule runs *after* we produce a module map, headers and copy them over.
                            results.checkTaskFollows(BBBVerifierTask, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/BBB.build/BBB-diagnostic-filename-map.json"]))
                            results.checkTaskFollows(BBBVerifierTask, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/BBB.build/module.modulemap"]))
                            results.checkTaskFollows(BBBVerifierTask, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/BBB.framework/Versions/A/Headers/BBB.h", "\(SRCROOT)/Sources/BBB.h"]))
                            results.checkTaskFollows(BBBVerifierTask, .matchRule(["Copy", "\(SRCROOT)/build/Debug/BBB.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Debug/BBB.build/module.modulemap"]))

                            // BBB depends on AAA's module tasks, but it doesn't use AAA's filename map.
                            results.checkTaskDoesNotFollow(BBBVerifierTask, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AAA.build/AAA-diagnostic-filename-map.json"]))
                            results.checkTaskFollows(BBBVerifierTask, .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AAA.build/module.modulemap"]))
                            results.checkTaskFollows(BBBVerifierTask, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/AAA.framework/Versions/A/Headers/AAA.h", "\(SRCROOT)/Sources/AAA.h"]))
                            results.checkTaskFollows(BBBVerifierTask, .matchRule(["Copy", "\(SRCROOT)/build/Debug/AAA.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Debug/AAA.build/module.modulemap"]))

                            // Make sure there is no ordering relationship between the verifiers for AAA and BBB and other tasks in either target
                            for remainingTask in results.findMatchingTasks([.matchRuleType("CompileC")]) {
                                results.checkTaskDoesNotFollow(AAAVerifierTask, antecedent: remainingTask)
                                results.checkTaskDoesNotFollow(remainingTask, antecedent: AAAVerifierTask)
                                results.checkTaskDoesNotFollow(BBBVerifierTask, antecedent: remainingTask)
                                results.checkTaskDoesNotFollow(remainingTask, antecedent: BBBVerifierTask)
                            }
                        }
                    }
                }
            }
        }
    }

    func _copyFiles() async throws {
        let targetName  = "Framework"
        let clangCompilerPath = try await self.clangCompilerPath
        let testProject = TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("Framework.h"),
                    TestFile("Framework.m"),
                    TestFile("Framework.defs"),
                    TestFile("PublicHeader.h"),
                    TestFile("PrivateSubHeaderOne.h"),
                    TestFile("PrivateSubHeaderTwo.h"),
                    TestFile("PrivateSubHeaderThree.h"),
                    TestFile("DeploymentOnlyHeader.h"),
                    TestFile("BuiltProductsHeader.h"),
                    TestFile("module.private.modulemap"),
                    TestFile("ResourceFile.txt"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "DEFINES_MODULE": "YES",
                            "ENABLE_MODULE_VERIFIER": "YES",
                            "MODULE_VERIFIER_KIND": verifierKind,
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CC": clangCompilerPath.str,
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Framework.h", headerVisibility: .public)
                        ]),

                        // Copying to Headers should run the verifier, but only the header file
                        // should be an input file to the module verifier.
                        TestCopyFilesBuildPhase([
                            "Framework.defs",
                            "PublicHeader.h",
                        ], destinationSubfolder: .wrapper, destinationSubpath: "Versions/A/Headers", onlyForDeployment: false),

                        // Subfolders count too.
                        TestCopyFilesBuildPhase([
                            "PrivateSubHeaderOne.h",
                        ], destinationSubfolder: .wrapper, destinationSubpath: "Versions/A/PrivateHeaders/SubFolder", onlyForDeployment: false),

                        // Using the symlinks should work too.
                        TestCopyFilesBuildPhase([
                            "PrivateSubHeaderTwo.h",
                        ], destinationSubfolder: .wrapper, destinationSubpath: "Versions/Current/PrivateHeaders/SubFolder", onlyForDeployment: false),
                        TestCopyFilesBuildPhase([
                            "PrivateSubHeaderThree.h",
                        ], destinationSubfolder: .wrapper, destinationSubpath: "PrivateHeaders/SubFolder", onlyForDeployment: false),

                        // A deployment-only phase should only affect deployment builds.
                        TestCopyFilesBuildPhase([
                            "DeploymentOnlyHeader.h",
                        ], destinationSubfolder: .wrapper, destinationSubpath: "Versions/A/Headers"),

                        // Built products should work for both deployment and non-deployment builds.
                        TestCopyFilesBuildPhase([
                            "BuiltProductsHeader.h",
                        ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(PUBLIC_HEADERS_FOLDER_PATH)", onlyForDeployment: false),

                        // Module maps should run the verifier.
                        TestCopyFilesBuildPhase([
                            "module.private.modulemap",
                        ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(MODULES_FOLDER_PATH)", onlyForDeployment: false),

                        TestSourcesBuildPhase([
                            "Framework.m",
                        ]),

                        // Resources and other destinations shouldn't run the verifier.
                        TestCopyFilesBuildPhase([
                            "ResourceFile.txt",
                        ], destinationSubfolder: .resources, onlyForDeployment: false),
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS, targetName: targetName) { results in
            results.checkNoDiagnostics()
            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType(verifierInputRuleName)) { task in
                    // Make sure VerifyModule runs after all of the relevant Copy tasks.
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Headers/PublicHeader.h", "\(SRCROOT)/PublicHeader.h"]))
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/PrivateHeaders/SubFolder/PrivateSubHeaderOne.h", "\(SRCROOT)/PrivateSubHeaderOne.h"]))
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/Current/PrivateHeaders/SubFolder/PrivateSubHeaderTwo.h", "\(SRCROOT)/PrivateSubHeaderTwo.h"]))
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/\(targetName).framework/PrivateHeaders/SubFolder/PrivateSubHeaderThree.h", "\(SRCROOT)/PrivateSubHeaderThree.h"]))
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Headers/BuiltProductsHeader.h", "\(SRCROOT)/BuiltProductsHeader.h"]))
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Modules/module.private.modulemap", "\(SRCROOT)/module.private.modulemap"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Resources/ResourceFile.txt", "\(SRCROOT)/ResourceFile.txt"]))
                    results.checkTaskDoesNotFollow(task, .matchRuleType("CompileC"))

                    // Make sure VerifyModule has all of the relevant Copy outputs as inputs so that it will run
                    // again if any of them change.
                    #expect(!task.alwaysExecuteTask)
                    task.checkInputs(contain: [
                        .name("module.modulemap"),
                        .name("Framework.h"),
                        .name("PublicHeader.h"),
                        .name("PrivateSubHeaderOne.h"),
                        .name("PrivateSubHeaderTwo.h"),
                        .name("PrivateSubHeaderThree.h"),
                        .name("BuiltProductsHeader.h"),
                        .name("module.private.modulemap"),
                    ])
                    task.checkNoInputs(contain: [
                        // The deployment-only header should not show up when we aren't doing deployment.
                        .name("DeploymentOnlyHeader.h"),
                        .name("Framework.defs"),
                        .name("ResourceFile.txt"),
                    ])
                }
            }
        }

        // Make sure the right stuff happens for deployment postprocessing, i.e. an install build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: nil), runDestination: .macOS, targetName: targetName) { results in
            results.checkNoDiagnostics()
            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType(verifierInputRuleName)) { task in
                    results.checkTaskFollows(task, .matchRule(["Copy", "/tmp/Project.dst/Library/Frameworks/\(targetName).framework/Versions/A/Headers/DeploymentOnlyHeader.h", "\(SRCROOT)/DeploymentOnlyHeader.h"]))
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/Headers/BuiltProductsHeader.h", "\(SRCROOT)/BuiltProductsHeader.h"]))

                    task.checkInputs(contain: [
                        // The deployment-only header should show up when we're doing deployment.
                        .name("DeploymentOnlyHeader.h"),
                        // The built products header should still show up, even though the built products
                        // directory is a different one from the target build directory in deployment mode.
                            .name("BuiltProductsHeader.h"),
                    ])
                }
            }
        }
    }

    func _shellScript() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let testProject = TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("OutputFiles.h"),
                    TestFile("OutputFiles.m"),
                    TestFile("NoOutputFiles.h"),
                    TestFile("NoOutputFiles.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "DEFINES_MODULE": "YES",
                    // The module verification tasks use TaskOrderingOptions.compilation, and
                    // shell script tasks use .compilationRequirement by default. That means
                    // that module verification waits for all shell scripts, regardless of
                    // their output files. EAGER_COMPILATION_ALLOW_SCRIPTS changes shell scripts
                    // to .compilation, allowing the module verification tasks to be ordered
                    // independent of them. Make sure that module verification still waits for
                    // the relevant shell scripts in that environment.
                    "EAGER_COMPILATION_ALLOW_SCRIPTS": "YES",
                    "ENABLE_MODULE_VERIFIER": "YES",
                    "MODULE_VERIFIER_KIND": verifierKind,
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CC": clangCompilerPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "OutputFiles",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("OutputFiles.h", headerVisibility: .public)
                        ]),

                        // Outputting to Headers should run the verifier.
                        TestShellScriptBuildPhase(
                            name: "OutputToHeaders",
                            originalObjectID: "OutputToHeaders",
                            outputs: [
                                "$(TARGET_BUILD_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/PublicHeader.h",
                                "$(TARGET_BUILD_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/PublicHeader.defs",
                            ]),
                        // Subfolders count too. Even if the script always runs, the module
                        // verifier should still only run if the output file changes.
                        TestShellScriptBuildPhase(
                            name: "OutputToPrivateHeadersSubFolder",
                            originalObjectID: "OutputToPrivateHeadersSubFolder",
                            outputs: [
                                "$(TARGET_BUILD_DIR)/$(PRIVATE_HEADERS_FOLDER_PATH)/SubFolder/PrivateSubHeaderOne.h",
                            ], alwaysOutOfDate: true),

                        // Using the symlinks and file lists should work too.
                        TestShellScriptBuildPhase(
                            name: "OutputToPrivateHeadersSymlink",
                            originalObjectID: "OutputToPrivateHeadersSymlink",
                            outputFileLists: [
                                "$(PROJECT_DIR)/OutputToPrivateHeadersSymlink.xcfilelist",
                            ]),
                        TestShellScriptBuildPhase(
                            name: "OutputToCurrentSymlink",
                            originalObjectID: "OutputToCurrentSymlink",
                            outputFileLists: [
                                "$(SRCROOT)/OutputToCurrentSymlink.xcfilelist",
                            ]),

                        // A deployment-only phase should only affect deployment builds.
                        TestShellScriptBuildPhase(
                            name: "DeploymentOnly",
                            originalObjectID: "DeploymentOnly",
                            outputs: [
                                "$(TARGET_BUILD_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/DeploymentOnlyHeader.h",
                            ], onlyForDeployment: true),

                        // Built products should work for both deployment and non-deployment builds.
                        // As long as any output file affects the module, the phase should run the
                        // verifier.
                        TestShellScriptBuildPhase(
                            name: "BuiltProducts",
                            originalObjectID: "BuiltProducts",
                            outputs: [
                                "$(BUILT_PRODUCTS_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/BuiltProductsHeader.h",
                                "$(BUILT_PRODUCTS_DIR)/SharedHeader.h",
                            ]),

                        // Module maps should run the verifier.
                        TestShellScriptBuildPhase(
                            name: "ModuleMap",
                            originalObjectID: "ModuleMap",
                            outputs: [
                                "$(TARGET_BUILD_DIR)/$(MODULES_FOLDER_PATH)/module.private.modulemap",
                            ]),

                        TestSourcesBuildPhase([
                            "OutputFiles.m",
                        ]),

                        // Resources and other destinations shouldn't run the verifier.
                        TestShellScriptBuildPhase(
                            name: "Resources",
                            originalObjectID: "Resources",
                            outputs: [
                                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ResourceFile.txt",
                            ]),
                    ]),
                TestStandardTarget(
                    "NoOutputFiles",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("NoOutputFiles.h", headerVisibility: .public)
                        ]),

                        // With no output files, the module verifier needs to unconditionally run.
                        TestShellScriptBuildPhase(
                            name: "NoOutputFiles",
                            originalObjectID: "NoOutputFiles"
                        ),

                        // The module verifier still needs to wait for tasks that affect the module.
                        TestShellScriptBuildPhase(
                            name: "OutputToHeaders",
                            originalObjectID: "OutputToHeaders",
                            outputs: [
                                "$(TARGET_BUILD_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/PublicHeader.h",
                            ]),

                        TestSourcesBuildPhase([
                            "NoOutputFiles.m",
                        ]),

                        // Resources and other destinations shouldn't block the verifier.
                        TestShellScriptBuildPhase(
                            name: "Resources",
                            originalObjectID: "Resources",
                            outputs: [
                                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ResourceFile.txt",
                            ]),
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let sourceRoot = tester.workspace.projects[0].sourceRoot

        let fs = PseudoFS()
        try await fs.writeFileContents(sourceRoot.join("OutputToPrivateHeadersSymlink.xcfilelist")) { contents in
            contents <<< "$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)/PrivateHeaders/SubFolder/PrivateSubHeaderTwo.h"
        }
        try await fs.writeFileContents(sourceRoot.join("OutputToCurrentSymlink.xcfilelist")) { contents in
            contents <<< "$(TARGET_BUILD_DIR)/$(VERSIONS_FOLDER_PATH)/$(CURRENT_VERSION)/PrivateHeaders/SubFolder/PrivateSubHeaderThree.h"
        }

        let SRCROOT = sourceRoot.str

        await tester.checkBuild(runDestination: .macOS, targetName: "OutputFiles", fs: fs) { results in
            results.checkNote(.contains("'OutputToPrivateHeadersSubFolder' will be run during every build because it does not specify any outputs."), failIfNotFound: false)
            results.checkNoDiagnostics()
            results.checkTarget("OutputFiles") { target in
                results.checkTask(.matchTarget(target), .matchRuleType(verifierInputRuleName)) { task in
                    // Make sure VerifyModule runs after all of the relevant PhaseScriptExecution tasks.
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "OutputToHeaders", "\(SRCROOT)/build/Project.build/Debug/OutputFiles.build/Script-OutputToHeaders.sh"]))
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "OutputToPrivateHeadersSubFolder", "\(SRCROOT)/build/Project.build/Debug/OutputFiles.build/Script-OutputToPrivateHeadersSubFolder.sh"]))
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "OutputToPrivateHeadersSymlink", "\(SRCROOT)/build/Project.build/Debug/OutputFiles.build/Script-OutputToPrivateHeadersSymlink.sh"]))
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "OutputToCurrentSymlink", "\(SRCROOT)/build/Project.build/Debug/OutputFiles.build/Script-OutputToCurrentSymlink.sh"]))
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "BuiltProducts", "\(SRCROOT)/build/Project.build/Debug/OutputFiles.build/Script-BuiltProducts.sh"]))
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "ModuleMap", "\(SRCROOT)/build/Project.build/Debug/OutputFiles.build/Script-ModuleMap.sh"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["PhaseScriptExecution", "Resources", "\(SRCROOT)/build/Project.build/Debug/OutputFiles.build/Script-Resources.sh"]))
                    results.checkTaskDoesNotFollow(task, .matchRuleType("CompileC"))

                    // Make sure VerifyModule has all of the relevant PhaseScriptExecution outputs as inputs so that it will run
                    // again if any of them change.
                    #expect(!task.alwaysExecuteTask)
                    task.checkInputs(contain: [
                        .name("OutputFiles.h"),
                        .name("PublicHeader.h"),
                        .name("PrivateSubHeaderOne.h"),
                        .name("PrivateSubHeaderTwo.h"),
                        .name("PrivateSubHeaderThree.h"),
                        .name("BuiltProductsHeader.h"),
                        .name("module.private.modulemap"),
                    ])
                    task.checkNoInputs(contain: [
                        .name("PublicHeader.defs"),
                        // The deployment-only header should not show up when we aren't doing deployment.
                        .name("DeploymentOnlyHeader.h"),
                        .name("SharedHeader.h"),
                        .name("ResourceFile.txt"),
                    ])
                }
            }
        }

        // Make sure the right stuff happens for deployment postprocessing, i.e. an install build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: nil), runDestination: .macOS, targetName: "OutputFiles", fs: fs) { results in
            results.checkNote(.contains("'OutputToPrivateHeadersSubFolder' will be run during every build because it does not specify any outputs."), failIfNotFound: false)
            results.checkNoDiagnostics()
            results.checkTarget("OutputFiles") { target in
                results.checkTask(.matchTarget(target), .matchRuleType(verifierInputRuleName)) { task in
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "DeploymentOnly", "\(SRCROOT)/build/Project.build/Debug/OutputFiles.build/Script-DeploymentOnly.sh"]))
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "BuiltProducts", "\(SRCROOT)/build/Project.build/Debug/OutputFiles.build/Script-BuiltProducts.sh"]))

                    task.checkInputs(contain: [
                        // The deployment-only header should show up when we're doing deployment.
                        .name("DeploymentOnlyHeader.h"),
                        // The built products header should still show up, even though the built products
                        // directory is a different one from the target build directory in deployment mode.
                            .name("BuiltProductsHeader.h"),
                    ])
                }
            }
        }

        await tester.checkBuild(runDestination: .macOS, targetName: "NoOutputFiles", fs: fs) { results in
            results.checkWarning(.contains("'NoOutputFiles' will be run during every build because it does not specify any outputs."), failIfNotFound: false)
            results.checkNoDiagnostics()
            results.checkTarget("NoOutputFiles") { target in
                results.checkTask(.matchTarget(target), .matchRuleType(verifierInputRuleName)) { task in
                    // Make sure VerifyModule runs after all of the relevant PhaseScriptExecution tasks.
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "NoOutputFiles", "\(SRCROOT)/build/Project.build/Debug/NoOutputFiles.build/Script-NoOutputFiles.sh"]))
                    results.checkTaskFollows(task, .matchRule(["PhaseScriptExecution", "OutputToHeaders", "\(SRCROOT)/build/Project.build/Debug/NoOutputFiles.build/Script-OutputToHeaders.sh"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["PhaseScriptExecution", "Resources", "\(SRCROOT)/build/Project.build/Debug/NoOutputFiles.build/Script-Resources.sh"]))
                    results.checkTaskDoesNotFollow(task, .matchRuleType("CompileC"))

                    // Without output files from NoOutputFiles, the module verifier has to run every time.
                    #expect(task.alwaysExecuteTask)
                    task.checkInputs(contain: [
                        .name("NoOutputFiles.h"),
                        .name("PublicHeader.h"),
                    ])
                    task.checkNoInputs(contain: [
                        .name("ResourceFile.txt"),
                    ])
                }
            }
        }
    }

    func _swiftObjCAPI() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("ObjCAndSwift.h"),
                    TestFile("SwiftSource.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "DEFINES_MODULE": "YES",
                    "ENABLE_MODULE_VERIFIER": "YES",
                    "MODULE_VERIFIER_KIND": verifierKind,
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                    "CC": clangCompilerPath.str,
                ]),
            ],
            targets: [
                // Don't run the module verifier if the Objective-C compatibility header isn't generated.
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
                    ]),
                // Don't run the module verifier if the Objective-C compatibility header isn't installed.
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
                    ]),
                // Run the module verifier if the Objective-C compatibility header is the only header in the framework.
                TestStandardTarget(
                    "SwiftOnly",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SwiftSource.swift",
                        ]),
                    ]),
                // Run the module verifier if there are normal headers installed, but the Objective-C
                // compatibility header shouldn't block verification if it isn't installed.
                TestStandardTarget(
                    "ObjCAndSwift",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("ObjCAndSwift.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            "SwiftSource.swift",
                        ]),
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        for targetName in ["NoObjCCompatibilityHeader", "ObjCCompatibilityHeaderNotInstalled"] {
            await tester.checkBuild(runDestination: .macOS, targetName: targetName) { results in
                results.checkWarning(.prefix("[targetIntegrity] DEFINES_MODULE was set, but no umbrella header could be found to generate the module map"))
                results.checkNoDiagnostics()
                results.checkTarget(targetName) { target in
                    results.checkNoTask(.matchTarget(target), .matchRuleType(verifierRuleName))
                }
            }
        }

        await tester.checkBuild(runDestination: .macOS, targetName: "SwiftOnly") { results in
            results.checkNoDiagnostics()
            results.checkTarget("SwiftOnly") { target in
                results.checkTask(.matchTarget(target), .matchRuleType(verifierInputRuleName)) { task in
                    // Make sure VerifyModule runs after the relevant SwiftMergeGeneratedHeaders task.
                    results.checkTaskFollows(task, .matchRule(["SwiftMergeGeneratedHeaders", "\(SRCROOT)/build/Debug/SwiftOnly.framework/Versions/A/Headers/SwiftOnly-Swift.h", "\(SRCROOT)/build/Project.build/Debug/SwiftOnly.build/Objects-normal/x86_64/SwiftOnly-Swift.h"]))
                    results.checkTaskDoesNotFollow(task, .matchRuleType("SwiftDriver Compilation"))

                    // Make sure VerifyModule has all of the relevant SwiftMergeGeneratedHeaders outputs
                    // as inputs so that it will run again if any of them change.
                    #expect(!task.alwaysExecuteTask)
                    task.checkInputs(contain: [
                        .name("SwiftOnly-Swift.h"),
                    ])
                    task.checkNoInputs(contain: [
                        .name("SwiftSource.swift"),
                    ])
                }
            }
        }

        await tester.checkBuild(runDestination: .macOS, targetName: "ObjCAndSwift") { results in
            results.checkNoDiagnostics()
            results.checkTarget("ObjCAndSwift") { target in
                results.checkTask(.matchTarget(target), .matchRuleType(verifierInputRuleName)) { task in
                    results.checkTaskFollows(task, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/ObjCAndSwift.framework/Versions/A/Headers/ObjCAndSwift.h", "\(SRCROOT)/ObjCAndSwift.h"]))
                    results.checkTaskDoesNotFollow(task, .matchRuleType("SwiftDriver Compilation Requirements"))
                    results.checkTaskDoesNotFollow(task, .matchRuleType("SwiftMergeGeneratedHeaders"))
                    results.checkTaskDoesNotFollow(task, .matchRuleType("SwiftDriver Compilation"))

                    #expect(!task.alwaysExecuteTask)
                    task.checkInputs(contain: [
                        .name("ObjCAndSwift.h"),
                    ])
                    task.checkNoInputs(contain: [
                        .name("SwiftSource.swift"),
                        .name("SwiftOnly-Swift.h"),
                    ])
                }
            }
        }
    }

    func _generatedHeaders() async throws {
        let testProject = try await TestProject(
            "Project",
            groupTree: TestGroup(
                "Group",
                children: [
                    TestFile("Framework.h"),
                    TestFile("Framework.m"),
                    TestFile("PublicSource.iig"),
                    TestFile("PrivateSource.iig"),
                    TestFile("ProjectSource.iig"),
                    TestVariantGroup("PublicIntents.intentdefinition", children: [
                        TestFile("Base.lproj/PublicIntents.intentdefinition", regionVariantName: "Base"),
                    ]),
                    TestVariantGroup("PrivateIntents.intentdefinition", children: [
                        TestFile("Base.lproj/PrivateIntents.intentdefinition", regionVariantName: "Base"),
                    ]),
                    TestVariantGroup("ProjectIntents.intentdefinition", children: [
                        TestFile("Base.lproj/ProjectIntents.intentdefinition", regionVariantName: "Base"),
                    ]),
                    TestVariantGroup("NoCodegenIntents.intentdefinition", children: [
                        TestFile("Base.lproj/NoCodegenIntents.intentdefinition", regionVariantName: "Base"),
                    ]),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "DEFINES_MODULE": "YES",
                    "ENABLE_MODULE_VERIFIER": "YES",
                    "MODULE_VERIFIER_KIND": verifierKind,
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "INTENTS_CODEGEN_LANGUAGE": "Objective-C",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "IIG_EXEC": iigPath.str,
                    "CC": clangCompilerPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("Framework.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase([
                            TestBuildFile("PublicSource.iig", headerVisibility: .public),
                            TestBuildFile("PrivateSource.iig", headerVisibility: .private),
                            TestBuildFile("ProjectSource.iig"),
                            TestBuildFile("PublicIntents.intentdefinition", intentsCodegenVisibility: .public),
                            TestBuildFile("PrivateIntents.intentdefinition", intentsCodegenVisibility: .private),
                            TestBuildFile("ProjectIntents.intentdefinition", intentsCodegenVisibility: .project),
                            TestBuildFile("NoCodegenIntents.intentdefinition", intentsCodegenVisibility: .noCodegen),
                            TestBuildFile("Framework.m"),
                        ]),
                    ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS, targetName: "Framework", clientDelegate: TestIntentsCompilerTaskPlanningClientDelegate()) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Framework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType(verifierInputRuleName)) { task in
                    results.checkTaskFollows(task, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/Headers/Framework.h", "\(SRCROOT)/Framework.h"]))
                    // Make sure VerifyModule runs after the relevant Iig tasks.
                    results.checkTaskFollows(task, .matchRule(["Iig", "\(SRCROOT)/PublicSource.iig"]))
                    results.checkTaskFollows(task, .matchRule(["Iig", "\(SRCROOT)/PrivateSource.iig"]))
                    results.checkTaskFollows(task, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/Headers/PublicSource.h", "\(SRCROOT)/build/Project.build/Debug/Framework.build/DerivedSources/Framework/PublicSource.h"]))
                    results.checkTaskFollows(task, .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/PrivateHeaders/PrivateSource.h", "\(SRCROOT)/build/Project.build/Debug/Framework.build/DerivedSources/Framework/PrivateSource.h"]))
                    // Make sure VerifyModule runs after the relevant Intents tasks.
                    results.checkTaskFollows(task, .matchRule(["IntentDefinitionCodegen", "\(SRCROOT)/Base.lproj/PublicIntents.intentdefinition"]))
                    results.checkTaskFollows(task, .matchRule(["IntentDefinitionCodegen", "\(SRCROOT)/Base.lproj/PrivateIntents.intentdefinition"]))
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/Headers/PublicIntents.h", "\(SRCROOT)/build/Project.build/Debug/Framework.build/DerivedSources/IntentDefinitionGenerated/PublicIntents/PublicIntents.h"]))
                    results.checkTaskFollows(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/PrivateHeaders/PrivateIntents.h", "\(SRCROOT)/build/Project.build/Debug/Framework.build/DerivedSources/IntentDefinitionGenerated/PrivateIntents/PrivateIntents.h"]))
                    // VerifyModule shouldn't wait for the Iig files to be copied into the framework, for the
                    // project sources to be processed, or for any of their generated sources to be compiled.
                    results.checkTaskDoesNotFollow(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/Headers/PublicSource.iig", "\(SRCROOT)/PublicSource.iig"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["Copy", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/PrivateHeaders/PrivateSource.iig", "\(SRCROOT)/PrivateSource.iig"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["Iig", "\(SRCROOT)/ProjectSource.iig"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["IntentDefinitionCodegen", "\(SRCROOT)/Base.lproj/ProjectIntents.intentdefinition"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["CompileC", "\(SRCROOT)/build/Project.build/Debug/Framework.build/Objects-normal/x86_64/PublicSource.iig.o", "\(SRCROOT)/build/Project.build/Debug/Framework.build/DerivedSources/Framework/PublicSource.iig.cpp", "normal", "x86_64", "c++", "com.apple.compilers.llvm.clang.1_0.compiler"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["CompileC", "\(SRCROOT)/build/Project.build/Debug/Framework.build/Objects-normal/x86_64/PrivateSource.iig.o", "\(SRCROOT)/build/Project.build/Debug/Framework.build/DerivedSources/Framework/PrivateSource.iig.cpp", "normal", "x86_64", "c++", "com.apple.compilers.llvm.clang.1_0.compiler"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["CompileC", "\(SRCROOT)/build/Project.build/Debug/Framework.build/Objects-normal/x86_64/ProjectSource.iig.o", "\(SRCROOT)/build/Project.build/Debug/Framework.build/DerivedSources/Framework/ProjectSource.iig.cpp", "normal", "x86_64", "c++", "com.apple.compilers.llvm.clang.1_0.compiler"]))
                    results.checkTaskDoesNotFollow(task, .matchRule(["CompileC", "\(SRCROOT)/build/Project.build/Debug/Framework.build/Objects-normal/x86_64/Framework.o", "\(SRCROOT)/Framework.m", "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"]))

                    // Make sure VerifyModule has all of the relevant Iig and Intents outputs as inputs
                    // so that it will run again if any of them change.
                    #expect(!task.alwaysExecuteTask)
                    task.checkInputs(contain: [
                        .name("Framework.h"),
                        .name("PublicSource.h"),
                        .name("PrivateSource.h"),
                        .name("PublicIntents.h"),
                        .name("PrivateIntents.h"),
                    ])
                    task.checkNoInputs(contain: [
                        .name("PublicSource.iig"),
                        .name("PrivateSource.iig"),
                        .name("ProjectSource.iig"),
                        .name("ProjectSource.h"),
                        .name("PublicSource.iig.cpp"),
                        .name("PrivateSource.iig.cpp"),
                        .name("ProjectSource.iig.cpp"),
                        .name("PublicIntents.intentdefinition"),
                        .name("PrivateIntents.intentdefinition"),
                        .name("ProjectIntents.intentdefinition"),
                        .name("NoCodegenIntents.intentdefinition"),
                        .name("ProjectIntents.h"),
                        .name("PublicIntents.m"),
                        .name("PrivateIntents.m"),
                        .name("ProjectIntents.m"),
                        .name("Framework.m"),
                    ])
                }
            }
        }
    }
}

/// Tests that are common to both builtin and external verifier testing.
@Suite
fileprivate struct ClangModuleVerifierCommonTaskConstructionTests: ClangModuleVerifierTaskConstructionTestsProtocol {
    var verifierKind: String { "external" }
    var verifierRuleName: String { "VerifyModule" }
    var verifierInputRuleName: String { "VerifyModule" }

    @Test(.requireSDKs(.macOS))
    func noHeaders() async throws {
        try await _noHeaders()
    }

    @Test(.requireSDKs(.macOS))
    func modulesVerifierEagerCompilation() async throws {
        try await _modulesVerifierEagerCompilation()
    }

    @Test(.requireSDKs(.macOS))
    func noModulesVerifierUnlessBuild() async throws {
        try await _noModulesVerifierUnlessBuild()
    }

    @Test(.requireSDKs(.macOS))
    func modulesVerifierIndependence() async throws {
        try await _modulesVerifierIndependence()
    }

    @Test(.requireSDKs(.macOS))
    func copyFiles() async throws {
        try await _copyFiles()
    }

    @Test(.requireSDKs(.macOS))
    func shellScript() async throws {
        try await _shellScript()
    }

    @Test(.requireSDKs(.macOS))
    func swiftObjCAPI() async throws {
        try await _swiftObjCAPI()
    }

    @Test(.requireSDKs(.macOS))
    func generatedHeaders() async throws {
        try await _generatedHeaders()
    }
}

@Suite(.requireClangFeatures(.wSystemHeadersInModule))
fileprivate struct ClangModuleVerifierBuiltinTaskConstructionTests: ClangModuleVerifierTaskConstructionTestsProtocol {
    var verifierKind: String { "builtin" }
    var verifierRuleName: String { "VerifyModuleC" }
    var verifierInputRuleName: String { "GenerateVerifyModuleInput" }

    @Test(.requireSDKs(.macOS))
    func noHeaders() async throws {
        try await _noHeaders()
    }

    @Test(.requireSDKs(.macOS))
    func modulesVerifierEagerCompilation() async throws {
        try await _modulesVerifierEagerCompilation()
    }

    @Test(.requireSDKs(.macOS))
    func noModulesVerifierUnlessBuild() async throws {
        try await _noModulesVerifierUnlessBuild()
    }

    @Test(.requireSDKs(.macOS))
    func modulesVerifierIndependence() async throws {
        try await _modulesVerifierIndependence()
    }

    @Test(.requireSDKs(.macOS))
    func copyFiles() async throws {
        try await _copyFiles()
    }

    @Test(.requireSDKs(.macOS))
    func shellScript() async throws {
        try await _shellScript()
    }

    @Test(.requireSDKs(.macOS))
    func swiftObjCAPI() async throws {
        try await _swiftObjCAPI()
    }

    @Test(.requireSDKs(.macOS))
    func generatedHeaders() async throws {
        try await _generatedHeaders()
    }
}
