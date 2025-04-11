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

import SWBCore
import Testing
import SWBTestSupport
import SWBUtil
import SWBTaskConstruction
import SWBProtocol
import Foundation

@Suite
fileprivate struct XCFrameworkTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func basicXCFrameworkUsage() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Support.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "x86_64",
                    "INFOPLIST_FILE": "Info.plist",
                    "CLANG_USE_RESPONSE_FILE": "NO",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                        TestCopyFilesBuildPhase(["Support.xcframework"], destinationSubfolder: .frameworks),
                    ],
                    dependencies: []
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            var processSupportXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRuleType("ProcessXCFramework")) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                task.checkInputs([
                    .path("\(SRCROOT)/Support.xcframework"),
                    .path("\(SRCROOT)/build/Debug")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug/Support.framework"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Info.plist"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Support")
                ])
                processSupportXCFrameworkTask = task
            }

            try results.checkTarget("App") { target in
                results.checkNoDiagnostics()
                // Validate that the compile tas has the include path, which is simply the default of "-I\(SRCROOT)/build/Debug/include". Also ensure there are no unexpected items.
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-x", "c", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-float-conversion", "-Wno-non-literal-null-conversion", "-Wno-objc-literal-conversion", "-Wshorten-64-to-32", "-Wpointer-sign", "-Wno-newline-eof", "-Wno-implicit-fallthrough", "-isysroot", core.loadSDK(.macOS).path.str, "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-g", "-fvisibility=hidden", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-comma", "-Wno-block-capture-autoreleasing", "-Wno-strict-prototypes", "-Wno-semicolon-before-method-body", "-iquote", "\(SRCROOT)/build/aProject.build/Debug/App.build/App-generated-files.hmap", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/App-own-target-headers.hmap", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/App-all-target-headers.hmap", "-iquote", "\(SRCROOT)/build/aProject.build/Debug/App.build/App-project-headers.hmap", "-I\(SRCROOT)/build/Debug/include", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources-normal/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources", "-F\(SRCROOT)/build/Debug", "-MMD", "-MT", "dependencies", "-MF", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/file.d", "--serialize-diagnostics", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/file.dia", "-c", "\(SRCROOT)/file.c", "-o", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/file.o"])
                }

                // Validate that we are getting the "-framework Support" flag added an no unexpected parameters.
                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App.LinkFileList", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_dependency_info.dat", "-framework", "Support", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/MacOS/App"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .driverKit))
    func basicXCFrameworkUsageWithDriver() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Support.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
                    "DEAD_CODE_STRIPPING": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ARCHS": "x86_64",
                    "INFOPLIST_FILE": "Info.plist",
                    "CLANG_USE_RESPONSE_FILE": "NO",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                        TestCopyFilesBuildPhase(["Support.xcframework", "Driver.dext"], destinationSubfolder: .frameworks),
                    ],
                    dependencies: ["Driver"]
                ),
                TestStandardTarget(
                    "Driver",
                    type: .driverExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "CODE_SIGN_IDENTITY": "Apple Development",
                            "SDKROOT": "driverkit"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                        TestCopyFilesBuildPhase(["Support.xcframework"], destinationSubfolder: .frameworks),
                    ]
                )
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")
        try fs.writeSimulatedProvisioningProfile(uuid: "8db0e92c-592c-4f06-bfed-9d945841b78d")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "x86_64-apple-driverkit\(core.loadSDK(.driverKit).defaultDeploymentTarget)", supportedPlatform: "driverkit", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            try results.checkTarget("App") { target in
                results.checkNoDiagnostics()

                var processSupportXCFrameworkTask: (any PlannedTask)?
                results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Support.xcframework", "\(SRCROOT)/build/Debug/Support.framework", "macos"])) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Support.xcframework"),
                        .path("\(SRCROOT)/build/Debug")
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/Support.framework"),
                        .path("\(SRCROOT)/build/Debug/Support.framework/Info.plist"),
                        .path("\(SRCROOT)/build/Debug/Support.framework/Support")
                    ])
                    processSupportXCFrameworkTask = task
                }

                // Validate that the compile tas has the include path, which is simply the default of "-I\(SRCROOT)/build/Debug/include". Also ensure there are no unexpected items.
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-x", "c", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-float-conversion", "-Wno-non-literal-null-conversion", "-Wno-objc-literal-conversion", "-Wshorten-64-to-32", "-Wpointer-sign", "-Wno-newline-eof", "-Wno-implicit-fallthrough", "-isysroot", core.loadSDK(.macOS).path.str, "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-g", "-fvisibility=hidden", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-comma", "-Wno-block-capture-autoreleasing", "-Wno-strict-prototypes", "-Wno-semicolon-before-method-body", "-iquote", "\(SRCROOT)/build/aProject.build/Debug/App.build/App-generated-files.hmap", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/App-own-target-headers.hmap", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/App-all-target-headers.hmap", "-iquote", "\(SRCROOT)/build/aProject.build/Debug/App.build/App-project-headers.hmap", "-I\(SRCROOT)/build/Debug/include", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources-normal/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources", "-F\(SRCROOT)/build/Debug", "-MMD", "-MT", "dependencies", "-MF", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/file.d", "--serialize-diagnostics", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/file.dia", "-c", "\(SRCROOT)/file.c", "-o", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/file.o"])
                }

                // Validate that we are getting the "-framework Support" flag added an no unexpected parameters.
                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App.LinkFileList", "-dead_strip", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_dependency_info.dat", "-framework", "Support", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/MacOS/App"])
                }
            }

            try results.checkTarget("Driver") { target in
                results.checkNoDiagnostics()

                var processSupportXCFrameworkTask: (any PlannedTask)?
                results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Support.xcframework", "\(SRCROOT)/build/Debug-driverkit/Support.framework", "driverkit"])) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "driverkit", "--target-path", "\(SRCROOT)/build/Debug-driverkit"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Support.xcframework"),
                        .path("\(SRCROOT)/build/Debug-driverkit")
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug-driverkit/Support.framework"),
                        .path("\(SRCROOT)/build/Debug-driverkit/Support.framework/Info.plist"),
                        .path("\(SRCROOT)/build/Debug-driverkit/Support.framework/Support")
                    ])
                    processSupportXCFrameworkTask = task
                }

                // Validate that the compile tas has the include path, which is simply the default of "-I\(SRCROOT)/build/Debug/include". Also ensure there are no unexpected items.
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-x", "c", "-target", "x86_64-apple-driverkit\(core.loadSDK(.driverKit).defaultDeploymentTarget)", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-float-conversion", "-Wno-non-literal-null-conversion", "-Wno-objc-literal-conversion", "-Wshorten-64-to-32", "-Wpointer-sign", "-Wno-newline-eof", "-Wno-implicit-fallthrough", "-isysroot", core.loadSDK(.driverKit).path.str, "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-g", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-comma", "-Wno-block-capture-autoreleasing", "-Wno-strict-prototypes", "-Wno-semicolon-before-method-body", "-iquote", "\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Driver-generated-files.hmap", "-I\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Driver-own-target-headers.hmap", "-I\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Driver-all-target-headers.hmap", "-iquote", "\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Driver-project-headers.hmap",
                                           "-I\(SRCROOT)/build/Debug-driverkit/include",
                                           "-I\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/DerivedSources-normal/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/DerivedSources/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/DerivedSources", "-F\(SRCROOT)/build/Debug-driverkit", "-MMD", "-MT", "dependencies", "-MF", "\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Objects-normal/x86_64/file.d", "--serialize-diagnostics", "\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Objects-normal/x86_64/file.dia", "-c", "\(SRCROOT)/file.c", "-o", "\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Objects-normal/x86_64/file.o"])
                }

                // Validate that we are getting the "-framework Support" flag added an no unexpected parameters.
                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-driverkit\(core.loadSDK(.driverKit).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.driverKit).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug-driverkit", "-L\(SRCROOT)/build/Debug-driverkit", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug-driverkit", "-F\(SRCROOT)/build/Debug-driverkit", "-filelist", "\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Objects-normal/x86_64/Driver.LinkFileList", "-dead_strip", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Objects-normal/x86_64/Driver_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug-driverkit/Driver.build/Objects-normal/x86_64/Driver_dependency_info.dat", "-framework", "Support", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug-driverkit/Driver.dext/Driver"])
                }
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func basicXCFrameworkUsageWithArchive() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Support.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "x86_64",
                    "INFOPLIST_FILE": "Info.plist",
                    "CLANG_USE_RESPONSE_FILE": "NO",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                        TestCopyFilesBuildPhase(["Support.xcframework"], destinationSubfolder: .frameworks),
                    ],
                    dependencies: []
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        try await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS, fs: fs) { results in
            var processSupportXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRuleType("ProcessXCFramework")) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Release"])
                task.checkInputs([
                    .path("\(SRCROOT)/Support.xcframework"),
                    .path("\(SRCROOT)/build/Release")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Release/Support.framework"),
                    .path("\(SRCROOT)/build/Release/Support.framework/Info.plist"),
                    .path("\(SRCROOT)/build/Release/Support.framework/Support")
                ])
                processSupportXCFrameworkTask = task
            }

            try results.checkTarget("App") { target in
                results.checkNoDiagnostics()

                // Validate that the compile tas has the include path, which is simply the default of "-I\(SRCROOT)/build/Debug/include". Also ensure there are no unexpected items.
                try results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-x", "c", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-float-conversion", "-Wno-non-literal-null-conversion", "-Wno-objc-literal-conversion", "-Wshorten-64-to-32", "-Wpointer-sign", "-Wno-newline-eof", "-Wno-implicit-fallthrough", "-isysroot", core.loadSDK(.macOS).path.str, "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-g", "-fvisibility=hidden", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-comma", "-Wno-block-capture-autoreleasing", "-Wno-strict-prototypes", "-Wno-semicolon-before-method-body", "-iquote", "\(SRCROOT)/build/aProject.build/Release/App.build/App-generated-files.hmap", "-I\(SRCROOT)/build/aProject.build/Release/App.build/App-own-target-headers.hmap", "-I\(SRCROOT)/build/aProject.build/Release/App.build/App-all-target-headers.hmap", "-iquote", "\(SRCROOT)/build/aProject.build/Release/App.build/App-project-headers.hmap", "-I\(SRCROOT)/build/Release/include", "-I\(SRCROOT)/build/aProject.build/Release/App.build/DerivedSources-normal/x86_64", "-I\(SRCROOT)/build/aProject.build/Release/App.build/DerivedSources/x86_64", "-I\(SRCROOT)/build/aProject.build/Release/App.build/DerivedSources", "-F\(SRCROOT)/build/Release", "-MMD", "-MT", "dependencies", "-MF", "\(SRCROOT)/build/aProject.build/Release/App.build/Objects-normal/x86_64/file.d", "--serialize-diagnostics", "\(SRCROOT)/build/aProject.build/Release/App.build/Objects-normal/x86_64/file.dia", "-c", "\(SRCROOT)/file.c", "-o", "\(SRCROOT)/build/aProject.build/Release/App.build/Objects-normal/x86_64/file.o"])
                }

                // Validate that we are getting the "-framework Support" flag added an no unexpected parameters.
                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L/tmp/Test/aProject/build/EagerLinkingTBDs/Release", "-L/tmp/Test/aProject/build/Release", "-F/tmp/Test/aProject/build/EagerLinkingTBDs/Release", "-F/tmp/Test/aProject/build/Release", "-filelist", "/tmp/Test/aProject/build/aProject.build/Release/App.build/Objects-normal/x86_64/App.LinkFileList", "-Xlinker", "-object_path_lto", "-Xlinker", "/tmp/Test/aProject/build/aProject.build/Release/App.build/Objects-normal/x86_64/App_lto.o", "-Xlinker", "-final_output", "-Xlinker", "/Applications/App.app/Contents/MacOS/App", "-Xlinker", "-dependency_info", "-Xlinker", "/tmp/Test/aProject/build/aProject.build/Release/App.build/Objects-normal/x86_64/App_dependency_info.dat", "-framework", "Support", "-Xlinker", "-no_adhoc_codesign", "-o", "/tmp/aProject.dst/Applications/App.app/Contents/MacOS/App"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func basicXCFrameworkUsageWithSwift() async throws {
        let core = try await getCore()
        let swiftCompilerPath = try await self.swiftCompilerPath
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("Support.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "x86_64",
                    "INFOPLIST_FILE": "Info.plist",
                    "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                    "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "NO",
                    "SWIFT_VERSION": "5",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                    ],
                    dependencies: []
                ),
            ])

        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("main.swift"), contents: "func f() -> Int { return 0 }")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            var processSupportXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRuleType("ProcessXCFramework")) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                task.checkInputs([
                    .path("\(SRCROOT)/Support.xcframework"),
                    .path("\(SRCROOT)/build/Debug")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug/Support.framework"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Info.plist"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Support")
                ])
                processSupportXCFrameworkTask = task
            }

            try results.checkTarget("App") { target in
                results.checkNoDiagnostics()

                try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    // Validate that we are looking into the build location with -F.
                    task.checkCommandLineContains([swiftCompilerPath.str, "-module-name", "App", "-O", "-enforce-exclusivity=checked", "@\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App.SwiftFileList", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-g", "-Xfrontend", "-serialize-debugging-options", "-swift-version", "5", "-I", "\(SRCROOT)/build/Debug", "-F", "\(SRCROOT)/build/Debug", "-c", "-j\(compilerParallelismLevel)", "-enable-batch-mode", "-incremental", "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App.swiftmodule", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/App.build/App-generated-files.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/App-own-target-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/App-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/App.build/App-project-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/Debug/include", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources-normal/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App-Swift.h", "-working-directory", "\(SRCROOT)"])
                }

                try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App.SwiftFileList"])) { _, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == ["\(SRCROOT)/main.swift", ""])
                }

                // Validate that the framework is properly being linked.
                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App.LinkFileList", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App.swiftmodule", "-framework", "Support", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/MacOS/App"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func basicXCFrameworkUsageWithTestsUsingHostBundle() async throws {
        let core = try await getCore()
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Support.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
                    "DEAD_CODE_STRIPPING": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "x86_64",
                    "INFOPLIST_FILE": "Info.plist",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestAggregateTarget(
                    "All",
                    dependencies: ["App", "AppTests", "AppUITests"]
                ),
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                        TestCopyFilesBuildPhase(["Support.xcframework"], destinationSubfolder: .frameworks),
                    ]
                ),
                TestStandardTarget(
                    "AppTests",
                    type: .unitTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "BUNDLE_LOADER": "$(TEST_HOST)",
                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/App.app/Contents/MacOS/App",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                        TestCopyFilesBuildPhase(["Support.xcframework"], destinationSubfolder: .frameworks),
                    ],
                    dependencies: ["App"]
                ),
                TestStandardTarget(
                    "AppUITests",
                    type: .uiTest,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "BUNDLE_LOADER": "$(TEST_HOST)",
                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/App.app/Contents/MacOS/App",
                            "USES_XCTRUNNER": "YES", // default
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                        TestCopyFilesBuildPhase(["Support.xcframework"], destinationSubfolder: .frameworks),
                    ],
                    dependencies: ["App"]
                )
            ])

        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let xctrunnerPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCTRunner.app")
        try await fs.writeXCTRunnerApp(xctrunnerPath, archs: ["arm64", "arm64e", "x86_64"], platform: .macOS, infoLookup: core)

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Support.xcframework", "\(SRCROOT)/build/Debug/Support.framework", "macos"])) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                task.checkInputs([
                    .path("\(SRCROOT)/Support.xcframework"),
                    .path("\(SRCROOT)/build/Debug")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug/Support.framework"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Info.plist"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Support")
                ])
            }

            // We shouldn't have any duplicate tasks errors
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func copyXCFramework() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Support.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "x86_64",
                    "INFOPLIST_FILE": "Info.plist",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestCopyFilesBuildPhase(["Support.xcframework"], destinationSubfolder: .builtProductsDir, destinationSubpath: "MyFrameworks/more/subpaths", onlyForDeployment: false),
                    ],
                    dependencies: []
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            var processSupportXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRuleType("ProcessXCFramework")) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                task.checkInputs([
                    .path("\(SRCROOT)/Support.xcframework"),
                    .path("\(SRCROOT)/build/Debug")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug/Support.framework"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Info.plist"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Support")
                ])
                processSupportXCFrameworkTask = task
            }

            try results.checkTarget("App") { target in
                results.checkNoDiagnostics()

                try results.checkTask(.matchTarget(target), .matchRuleType("Copy")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "-remove-static-executable", "\(SRCROOT)/Support.xcframework/x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)/Support.framework", "\(SRCROOT)/build/Debug/MyFrameworks/more/subpaths"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func basicXCFrameworkWithHeaders() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Support.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "x86_64",
                    "INFOPLIST_FILE": "Info.plist",
                    "HEADER_SEARCH_PATHS": "hp1 hp2",
                    "CLANG_USE_RESPONSE_FILE": "NO",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                    ],
                    dependencies: []
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libsupport.a"), binaryPath: Path("libsupport.a"), headersPath: Path("Headers")),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libsupport.a"), binaryPath: Path("libsupport.a"), headersPath: Path("Headers")),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        // Create some headers to work with.
        for library in supportXCFramework.libraries {
            if let headersPath = library.headersPath {
                let libraryHeadersPath = supportXCFrameworkPath.join(library.libraryIdentifier).join(headersPath)
                try fs.createDirectory(libraryHeadersPath, recursive: true)
                try fs.write(libraryHeadersPath.join("Header1.h"), contents: "int f();")
                try fs.write(libraryHeadersPath.join("Header2.h"), contents: "int g();")

                let subLibraryHeadersPath = libraryHeadersPath.join("more")
                try fs.createDirectory(subLibraryHeadersPath, recursive: true)
                try fs.write(subLibraryHeadersPath.join("Header3.h"), contents: "int h();")

                // Write some content that should be skipped.
                try fs.write(libraryHeadersPath.join(".DS_Store"), contents: "thanks macOS for the cool files")
            }
        }

        try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            var processSupportXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRuleType("ProcessXCFramework")) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                task.checkInputs([
                    .path("\(SRCROOT)/Support.xcframework"),
                    .path("\(SRCROOT)/build/Debug")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug/include/Header1.h"),
                    .path("\(SRCROOT)/build/Debug/include/Header2.h"),
                    .path("\(SRCROOT)/build/Debug/include/header1.h"),
                    .path("\(SRCROOT)/build/Debug/include/header2.h"),
                    .path("\(SRCROOT)/build/Debug/include/more/Header3.h"),
                    .path("\(SRCROOT)/build/Debug/libsupport.a"),
                ])
                processSupportXCFrameworkTask = task
            }

            try results.checkTarget("App") { target in
                results.checkNoDiagnostics()

                try results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-x", "c", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-float-conversion", "-Wno-non-literal-null-conversion", "-Wno-objc-literal-conversion", "-Wshorten-64-to-32", "-Wpointer-sign", "-Wno-newline-eof", "-Wno-implicit-fallthrough", "-isysroot", core.loadSDK(.macOS).path.str, "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-g", "-fvisibility=hidden", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-comma", "-Wno-block-capture-autoreleasing", "-Wno-strict-prototypes", "-Wno-semicolon-before-method-body", "-iquote", "\(SRCROOT)/build/aProject.build/Debug/App.build/App-generated-files.hmap", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/App-own-target-headers.hmap", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/App-all-target-headers.hmap", "-iquote", "\(SRCROOT)/build/aProject.build/Debug/App.build/App-project-headers.hmap", "-I\(SRCROOT)/build/Debug/include", "-Ihp1", "-Ihp2", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources-normal/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources", "-F\(SRCROOT)/build/Debug", "-MMD", "-MT", "dependencies", "-MF", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/file.d", "--serialize-diagnostics", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/file.dia", "-c", "\(SRCROOT)/file.c", "-o", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/file.o"])
                }

                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App.LinkFileList", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_dependency_info.dat", "-lsupport", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/MacOS/App"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func basicXCFrameworkWithSwift() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.swift"),
                    TestFile("Support.xcframework"),
                    TestFile("Other.xcframework"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "x86_64",
                    "INFOPLIST_FILE": "Info.plist",
                    "HEADER_SEARCH_PATHS": "hp1 hp2",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5.0",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.swift"]),
                        TestFrameworksBuildPhase(["Support.xcframework", "Other.xcframework"]),
                    ],
                    dependencies: []
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("support.framework"), binaryPath: Path("support.framework/Versions/A/support"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("support.framework"), binaryPath: Path("support.framework/support"), headersPath: nil),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        let otherXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("other.dylib"), binaryPath: Path("other.dylib"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("other.dylib"), binaryPath: Path("other.dylib"), headersPath: nil),
        ])
        let otherXCFrameworkPath = Path(SRCROOT).join("Other.xcframework")
        try fs.createDirectory(otherXCFrameworkPath, recursive: true)
        try await XCFrameworkTestSupport.writeXCFramework(otherXCFramework, fs: fs, path: otherXCFrameworkPath, infoLookup: infoLookup)

        // Write out the swiftmodule, swiftinterface, and swiftdoc files to ensure we also copy those over.
        for library in otherXCFramework.libraries {
            let libraryIdentifierPath = otherXCFrameworkPath.join(library.libraryIdentifier)
            try fs.write(libraryIdentifierPath.join("other.swiftmodule"), contents: "empty module")
            try fs.write(libraryIdentifierPath.join("other.swiftinterface"), contents: "empty interface")
            try fs.write(libraryIdentifierPath.join("other.swiftdoc"), contents: "empty docs")
        }

        try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            var processSupportXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Support.xcframework", "\(SRCROOT)/build/Debug/support.framework", "macos"])) { task in
                task.checkInputs([
                    .path("\(SRCROOT)/Support.xcframework"),
                    .path("\(SRCROOT)/build/Debug")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug/support.framework"),
                    .path("\(SRCROOT)/build/Debug/support.framework/Info.plist"),
                    .path("\(SRCROOT)/build/Debug/support.framework/support")
                ])
                processSupportXCFrameworkTask = task
            }

            var processOtherXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Other.xcframework", "\(SRCROOT)/build/Debug/other.dylib", "macos"])) { task in
                task.checkInputs([
                    .path("\(SRCROOT)/Other.xcframework"),
                    .path("\(SRCROOT)/build/Debug")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug/other.dylib"),
                    .path("\(SRCROOT)/build/Debug/other.swiftdoc"),
                    .path("\(SRCROOT)/build/Debug/other.swiftinterface"),
                    .path("\(SRCROOT)/build/Debug/other.swiftmodule"),
                ])
                processOtherXCFrameworkTask = task
            }

            try results.checkTarget("App") { target in
                results.checkNoDiagnostics()

                try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))
                    results.checkTaskFollows(task, antecedent: try #require(processOtherXCFrameworkTask))

                    // Ensure that the standard search paths are correctly
                    task.checkCommandLineContains(["-F", "\(SRCROOT)/build/Debug"])
                    task.checkCommandLineContains(["-I", "\(SRCROOT)/build/Debug"])
                }

                try results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))
                    results.checkTaskFollows(task, antecedent: try #require(processOtherXCFrameworkTask))
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // Ensure that we are getting the framework added properly.
                    task.checkCommandLineContains(["-framework", "support"])
                }

            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func multipleXCFrameworkUsage_ios() async throws {
        let core = try await getCore()
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Support.xcframework"),
                    TestFile("Extras.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS[sdk=iphoneos*]": "arm64",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
                    "SDKROOT": "iphoneos",
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "CODE_SIGN_ENTITLEMENTS": "codesign.entitlements",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework", "Extras.xcframework"]),
                    ],
                    dependencies: []
                ),
            ])

        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        let extrasXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Extras.framework"), binaryPath: Path("Extras.framework/Versions/A/Extras"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Extras.framework"), binaryPath: Path("Extras.framework/Extras"), headersPath: nil),
        ])
        let extrasXCFrameworkPath = Path(SRCROOT).join("Extras.xcframework")
        try fs.createDirectory(extrasXCFrameworkPath, recursive: true)
        try await XCFrameworkTestSupport.writeXCFramework(extrasXCFramework, fs: fs, path: extrasXCFrameworkPath, infoLookup: infoLookup)

        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
        try await fs.writePlist(Path("/tmp/Test/aProject/codesign.entitlements"), .plDict([:]))

        try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            var processExtrasXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Extras.xcframework", "\(SRCROOT)/build/Debug-iphoneos/Extras.framework", "ios"])) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Extras.xcframework", "--platform", "ios", "--target-path", "\(SRCROOT)/build/Debug-iphoneos"])
                task.checkInputs([
                    .path("\(SRCROOT)/Extras.xcframework"),
                    .path("\(SRCROOT)/build/Debug-iphoneos")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug-iphoneos/Extras.framework"),
                    .path("\(SRCROOT)/build/Debug-iphoneos/Extras.framework/Extras"),
                    .path("\(SRCROOT)/build/Debug-iphoneos/Extras.framework/Info.plist")
                ])
                processExtrasXCFrameworkTask = task
            }

            var processSupportXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Support.xcframework", "\(SRCROOT)/build/Debug-iphoneos/Support.framework", "ios"])) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "ios", "--target-path", "\(SRCROOT)/build/Debug-iphoneos"])
                task.checkInputs([
                    .path("\(SRCROOT)/Support.xcframework"),
                    .path("\(SRCROOT)/build/Debug-iphoneos")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug-iphoneos/Support.framework"),
                    .path("\(SRCROOT)/build/Debug-iphoneos/Support.framework/Info.plist"),
                    .path("\(SRCROOT)/build/Debug-iphoneos/Support.framework/Support")
                ])
                processSupportXCFrameworkTask = task
            }

            try results.checkTarget("App") { target in
                results.checkNoDiagnostics()

                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))
                    results.checkTaskFollows(task, antecedent: try #require(processExtrasXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "arm64-apple-ios\(core.loadSDK(.iOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.iOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug-iphoneos", "-L\(SRCROOT)/build/Debug-iphoneos", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug-iphoneos", "-F\(SRCROOT)/build/Debug-iphoneos", "-filelist", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/Objects-normal/arm64/App.LinkFileList", "-dead_strip", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/Objects-normal/arm64/App_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/App.build/Objects-normal/arm64/App_dependency_info.dat", "-framework", "Support", "-framework", "Extras", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug-iphoneos/App.app/App"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .tvOS, .iOS))
    func multipleXCFrameworkAcrossMultipleTargetsUsage() async throws {

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("lib1.c"),
                    TestFile("Support.xcframework"),
                    TestFile("Extras.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "INFOPLIST_FILE": "Info.plist",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework", "Extras.xcframework"]),
                        TestCopyFilesBuildPhase(["Support.xcframework", "Extras.xcframework"], destinationSubfolder: .frameworks),
                    ],
                    dependencies: ["lib1"]
                ),
                TestStandardTarget(
                    "lib1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["lib1.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework", "Extras.xcframework"]),
                    ],
                    dependencies: []
                ),
                TestStandardTarget(
                    "lib2",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SDKROOT": "appletvos"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["lib1.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework", "Extras.xcframework"]),
                    ],
                    dependencies: []
                ),
                TestStandardTarget(
                    "App2",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ARCHS": "x86_64h",
                            "VALID_ARCHS": "$(inherited) x86_64h",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["lib1.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework", "Extras.xcframework"]),
                    ],
                    dependencies: []
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")
        try fs.write(Path(SRCROOT).join("lib1.c"), contents: "int l() { return 0; }")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
        ])
        let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        let extrasXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Extras.framework"), binaryPath: Path("Extras.framework/Versions/A/Extras"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Extras.framework"), binaryPath: Path("Extras.framework/Extras"), headersPath: nil),
        ])
        let extrasXCFrameworkPath = Path(SRCROOT).join("Extras.xcframework")
        try fs.createDirectory(extrasXCFrameworkPath, recursive: true)
        try await XCFrameworkTestSupport.writeXCFramework(extrasXCFramework, fs: fs, path: extrasXCFrameworkPath, infoLookup: infoLookup)

        try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            var processSupportXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Support.xcframework", "\(SRCROOT)/build/Debug/Support.framework", "macos"])) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                task.checkInputs([
                    .path("\(SRCROOT)/Support.xcframework"),
                    .path("\(SRCROOT)/build/Debug")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug/Support.framework"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Info.plist"),
                    .path("\(SRCROOT)/build/Debug/Support.framework/Support")
                ])
                processSupportXCFrameworkTask = task
            }

            var processExtrasXCFrameworkTask: (any PlannedTask)?
            results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Extras.xcframework", "\(SRCROOT)/build/Debug/Extras.framework", "macos"])) { task in
                task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Extras.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                task.checkInputs([
                    .path("\(SRCROOT)/Extras.xcframework"),
                    .path("\(SRCROOT)/build/Debug")
                ])
                task.checkOutputs([
                    .path("\(SRCROOT)/build/Debug/Extras.framework"),
                    .path("\(SRCROOT)/build/Debug/Extras.framework/Extras"),
                    .path("\(SRCROOT)/build/Debug/Extras.framework/Info.plist")
                ])
                processExtrasXCFrameworkTask = task
            }

            try results.checkTarget("lib1") { target in
                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))
                    results.checkTaskFollows(task, antecedent: try #require(processExtrasXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-dynamiclib", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/lib1.build/Objects-normal/x86_64/lib1.LinkFileList", "-install_name", "/Library/Frameworks/lib1.framework/Versions/A/lib1", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/lib1.build/Objects-normal/x86_64/lib1_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/lib1.build/Objects-normal/x86_64/lib1_dependency_info.dat", "-framework", "Support", "-framework", "Extras", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/lib1.framework/Versions/A/lib1"])
                }
            }

            try results.checkTarget("App") { target in
                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))
                    results.checkTaskFollows(task, antecedent: try #require(processExtrasXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App.LinkFileList", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App.build/Objects-normal/x86_64/App_dependency_info.dat", "-framework", "Support", "-framework", "Extras", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/App.app/Contents/MacOS/App"])
                }
            }

            results.checkNoDiagnostics()
        }

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, targetName: "lib2", fs: fs) { results in
            results.checkTarget("lib2") { target in
                results.checkError("\(SRCROOT)/Extras.xcframework: While building for tvOS, no library for this platform was found in '\(SRCROOT)/Extras.xcframework'. (in target 'lib2' from project 'aProject')")
                results.checkError("\(SRCROOT)/Support.xcframework: While building for tvOS, no library for this platform was found in '\(SRCROOT)/Support.xcframework'. (in target 'lib2' from project 'aProject')")
            }

            results.checkNoDiagnostics()
        }

        try await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, targetName: "App2", fs: fs) { results in
            try results.checkTarget("App2") { target in
                var processSupportXCFrameworkTask: (any PlannedTask)?
                results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Support.xcframework", "\(SRCROOT)/build/Debug/Support.framework", "macos"])) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Support.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Support.xcframework"),
                        .path("\(SRCROOT)/build/Debug")
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/Support.framework"),
                        .path("\(SRCROOT)/build/Debug/Support.framework/Info.plist"),
                        .path("\(SRCROOT)/build/Debug/Support.framework/Support")
                    ])
                    processSupportXCFrameworkTask = task
                }

                var processExtrasXCFrameworkTask: (any PlannedTask)?
                results.checkTask(.matchRule(["ProcessXCFramework", "\(SRCROOT)/Extras.xcframework", "\(SRCROOT)/build/Debug/Extras.framework", "macos"])) { task in
                    task.checkCommandLine(["builtin-process-xcframework", "--xcframework", "\(SRCROOT)/Extras.xcframework", "--platform", "macos", "--target-path", "\(SRCROOT)/build/Debug"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Extras.xcframework"),
                        .path("\(SRCROOT)/build/Debug")
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug/Extras.framework"),
                        .path("\(SRCROOT)/build/Debug/Extras.framework/Extras"),
                        .path("\(SRCROOT)/build/Debug/Extras.framework/Info.plist")
                    ])
                    processExtrasXCFrameworkTask = task
                }

                try results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // There needs to be a strong dependency on the XCFramework processing.
                    results.checkTaskFollows(task, antecedent: try #require(processSupportXCFrameworkTask))
                    results.checkTaskFollows(task, antecedent: try #require(processExtrasXCFrameworkTask))

                    task.checkCommandLine(["clang", "-Xlinker", "-reproducible", "-target", "x86_64h-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/App2.build/Objects-normal/x86_64h/App2.LinkFileList", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App2.build/Objects-normal/x86_64h/App2_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/App2.build/Objects-normal/x86_64h/App2_dependency_info.dat", "-framework", "Support", "-framework", "Extras", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/App2.app/Contents/MacOS/App2"])
                }

                results.checkNote(.equal("'\(SRCROOT)/Extras.xcframework' is missing architecture(s) required by this target (x86_64h), but may still be link-compatible. (in target 'App2' from project 'aProject')"))
                results.checkNote(.equal("'\(SRCROOT)/Support.xcframework' is missing architecture(s) required by this target (x86_64h), but may still be link-compatible. (in target 'App2' from project 'aProject')"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func missingXCFramework() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("file.c"),
                    TestFile("Support.xcframework"),
                    TestFile("Info.plist")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "x86_64",
                    "INFOPLIST_FILE": "Info.plist",
                ]),
            ],
            targets: [
                // Test building an app which links and embeds an xcframework.
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["file.c"]),
                        TestFrameworksBuildPhase(["Support.xcframework"]),
                        TestCopyFilesBuildPhase(["Support.xcframework"], destinationSubfolder: .frameworks),
                    ],
                    dependencies: []
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
        ])

        // Purposefully write this out to the wrong path.
        let supportXCFrameworkPath = Path(SRCROOT).join("Support_wrongpath.xcframework")
        try fs.createDirectory(supportXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkError(.equal("There is no XCFramework found at '\(SRCROOT)/Support.xcframework'. (in target 'App' from project 'aProject')"))
            results.checkError(.equal("There is no XCFramework found at '\(SRCROOT)/Support.xcframework'. (in target 'App' from project 'aProject')"))
            results.checkNoDiagnostics()
        }
    }
}
