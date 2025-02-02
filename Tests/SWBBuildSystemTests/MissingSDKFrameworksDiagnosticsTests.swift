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

import SWBBuildSystem
import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct MissingSDKFrameworksDiagnosticsTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .watchOS, .iOS))
    func missingFrameworkLinkerDiagnostic() async throws {
        try await testMissingFrameworkLinkerDiagnostic(frameworkName: "WatchKit")
        try await testMissingFrameworkLinkerDiagnostic(frameworkName: "MobileCoreServices")
        try await testMissingFrameworkLinkerDiagnostic(frameworkName: "OpenGLES")
    }

    func testMissingFrameworkLinkerDiagnostic(frameworkName: String) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("Source.m"),
                                TestFile("\(frameworkName).framework", sourceTree: .buildSetting("SDKROOT"))
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Foo",
                                buildPhases: [
                                    TestSourcesBuildPhase(["Source.m"]),
                                    TestFrameworksBuildPhase([TestBuildFile("\(frameworkName).framework")])
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Source.m")) { $0 <<< "int main() { return 0; }" }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["DISABLE_SDK_METADATA_PARSING": "NO"])) { results in
                results.checkNoWarnings()
                switch frameworkName {
                case "WatchKit":
                    results.checkError(.equal("WatchKit is not available when building for Mac Catalyst. (for task: [\"Ld\", \"\(tmpDirPath.str)/Test/aProject/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.app/Contents/MacOS/Foo\", \"normal\"])"))
                    results.checkError(.prefix("Linker command failed with exit code 1 (use -v to see invocation)"))
                    results.checkError(.prefix("Command Ld failed."))
                case "OpenGLES":
                    results.checkError(.equal("OpenGLES is deprecated and is not available when building for Mac Catalyst. (for task: [\"Ld\", \"\(tmpDirPath.str)/Test/aProject/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.app/Contents/MacOS/Foo\", \"normal\"])"))
                    results.checkError(.prefix("Linker command failed with exit code 1 (use -v to see invocation)"))
                    results.checkError(.prefix("Command Ld failed."))
                default:
                    // No error for MobileCoreServices because it still exists for macCatalyst
                    break
                }

                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .watchOS))
    func missingFrameworkLinkerDiagnosticViaLinkerFlags() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("Source.m"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "OTHER_LDFLAGS": "-framework WatchKit",
                                "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Foo",
                                buildPhases: [
                                    TestSourcesBuildPhase(["Source.m"]),
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Source.m")) { $0 <<< "int main() { return 0; }" }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["DISABLE_SDK_METADATA_PARSING": "NO"])) { results in
                results.checkNoWarnings()
                results.checkError(.equal("WatchKit is not available when building for Mac Catalyst. (for task: [\"Ld\", \"\(tmpDirPath.str)/Test/aProject/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.app/Contents/MacOS/Foo\", \"normal\"])"))
                results.checkError(.prefix("Linker command failed with exit code 1 (use -v to see invocation)"))
                results.checkError(.prefix("Command Ld failed."))
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .watchOS))
    func missingFrameworkLinkerDiagnosticNoConditionalizationBlurb() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("Source.m"),
                                TestFile("WatchKit.framework", sourceTree: .buildSetting("SDKROOT"))
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Foo",
                                buildPhases: [
                                    TestSourcesBuildPhase(["Source.m"]),
                                    TestFrameworksBuildPhase([TestBuildFile("WatchKit.framework")])
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Source.m")) { $0 <<< "int main() { return 0; }" }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["DISABLE_SDK_METADATA_PARSING": "NO"])) { results in
                results.checkNoWarnings()
                results.checkError(.equal("WatchKit is not available when building for macOS. (for task: [\"Ld\", \"\(tmpDirPath.str)/Test/aProject/build/Debug/Foo.app/Contents/MacOS/Foo\", \"normal\"])"))
                results.checkError(.prefix("Linker command failed with exit code 1 (use -v to see invocation)"))
                results.checkError(.prefix("Command Ld failed."))
                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .watchOS, .iOS))
    func missingFrameworkSwiftCompilerDiagnostic() async throws {
        try await testMissingFrameworkSwiftCompilerDiagnostic(frameworkName: "AppKit", activeRunDestination: .iOS)
        try await testMissingFrameworkSwiftCompilerDiagnostic(frameworkName: "WatchKit")
        try await testMissingFrameworkSwiftCompilerDiagnostic(frameworkName: "MobileCoreServices")
        try await testMissingFrameworkSwiftCompilerDiagnostic(frameworkName: "OpenGLES")
        try await testMissingFrameworkSwiftCompilerDiagnostic(frameworkName: "UIKit", sdk: "macosx", activeRunDestination: .macOS, supportsMacCatalyst: false)
    }

    func testMissingFrameworkSwiftCompilerDiagnostic(frameworkName: String, sdk: String = "iphoneos", activeRunDestination: RunDestinationInfo = .macCatalyst, supportsMacCatalyst: Bool = true) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("Source.swift"),
                                TestFile("\(frameworkName).framework", sourceTree: .buildSetting("SDKROOT")),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS[sdk=iphoneos*]": "arm64",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": sdk,
                                "SUPPORTS_MACCATALYST": supportsMacCatalyst ? "YES" : "NO",
                                "SWIFT_VERSION": swiftVersion,

                                "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Foo",
                                buildPhases: [
                                    TestSourcesBuildPhase(["Source.swift"]),
                                    TestFrameworksBuildPhase([TestBuildFile("\(frameworkName).framework")])
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Source.swift")) {
                $0 <<< "import \(frameworkName)\n@_cdecl(\"main\") func main() { }"
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination, overrides: ["DISABLE_SDK_METADATA_PARSING": "NO"])) { results in
                results.checkNoWarnings()
                switch frameworkName {
                case "AppKit":
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: no such module \'AppKit\' (for task: [\"SwiftCompile\", \"normal\", \"arm64\", \"Compiling Source.swift\", \"\(tmpDirPath.str)/Test/aProject/Source.swift\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: no such module \'AppKit\' (for task: [\"SwiftEmitModule\", \"normal\", \"arm64\", \"Emitting module for Foo\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: [Swift Compiler Error] AppKit is not available when building for iOS. Consider using `#if canImport(AppKit)` to conditionally import this framework. (for task: [\"SwiftCompile\", \"normal\", \"arm64\", \"Compiling Source.swift\", \"\(tmpDirPath.str)/Test/aProject/Source.swift\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: [Swift Compiler Error] AppKit is not available when building for iOS. Consider using `#if canImport(AppKit)` to conditionally import this framework. (for task: [\"SwiftEmitModule\", \"normal\", \"arm64\", \"Emitting module for Foo\"])"))

                    results.checkError(.prefix("Command SwiftEmitModule failed."))
                    results.checkError(.prefix("Command SwiftCompile failed."))
                    if !SWBFeatureFlag.performOwnershipAnalysis.value {
                        for _ in 0..<4 { results.checkError(.contains("No such file or directory (2) (for task: [\"Copy\"")) }
                    }
                case "WatchKit":
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: no such module \'WatchKit\' (for task: [\"SwiftCompile\", \"normal\", \"x86_64\", \"Compiling Source.swift\", \"\(tmpDirPath.str)/Test/aProject/Source.swift\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: no such module \'WatchKit\' (for task: [\"SwiftEmitModule\", \"normal\", \"x86_64\", \"Emitting module for Foo\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: [Swift Compiler Error] WatchKit is not available when building for Mac Catalyst. Consider using `#if canImport(WatchKit)` to conditionally import this framework. (for task: [\"SwiftCompile\", \"normal\", \"x86_64\", \"Compiling Source.swift\", \"\(tmpDirPath.str)/Test/aProject/Source.swift\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: [Swift Compiler Error] WatchKit is not available when building for Mac Catalyst. Consider using `#if canImport(WatchKit)` to conditionally import this framework. (for task: [\"SwiftEmitModule\", \"normal\", \"x86_64\", \"Emitting module for Foo\"])"))
                    results.checkError(.prefix("Command SwiftEmitModule failed."))
                    results.checkError(.prefix("Command SwiftCompile failed."))
                    if !SWBFeatureFlag.performOwnershipAnalysis.value {
                        for _ in 0..<4 { results.checkError(.contains("No such file or directory (2) (for task: [\"Copy\"")) }
                    }
                case "OpenGLES":
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: no such module \'OpenGLES\' (for task: [\"SwiftCompile\", \"normal\", \"x86_64\", \"Compiling Source.swift\", \"\(tmpDirPath.str)/Test/aProject/Source.swift\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: no such module \'OpenGLES\' (for task: [\"SwiftEmitModule\", \"normal\", \"x86_64\", \"Emitting module for Foo\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: [Swift Compiler Error] OpenGLES is deprecated and is not available when building for Mac Catalyst. Consider migrating to Metal instead, or use `#if canImport(OpenGLES)` to conditionally import this framework. (for task: [\"SwiftCompile\", \"normal\", \"x86_64\", \"Compiling Source.swift\", \"\(tmpDirPath.str)/Test/aProject/Source.swift\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: [Swift Compiler Error] OpenGLES is deprecated and is not available when building for Mac Catalyst. Consider migrating to Metal instead, or use `#if canImport(OpenGLES)` to conditionally import this framework. (for task: [\"SwiftEmitModule\", \"normal\", \"x86_64\", \"Emitting module for Foo\"])"))
                    results.checkError(.prefix("Command SwiftEmitModule failed."))
                    results.checkError(.prefix("Command SwiftCompile failed."))
                    if !SWBFeatureFlag.performOwnershipAnalysis.value {
                        for _ in 0..<4 { results.checkError(.contains("No such file or directory (2) (for task: [\"Copy\"")) }
                    }
                case "UIKit":
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: no such module \'UIKit\' (for task: [\"SwiftCompile\", \"normal\", \"x86_64\", \"Compiling Source.swift\", \"\(tmpDirPath.str)/Test/aProject/Source.swift\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: no such module \'UIKit\' (for task: [\"SwiftEmitModule\", \"normal\", \"x86_64\", \"Emitting module for Foo\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: [Swift Compiler Error] UIKit is not available when building for macOS. Consider using `#if canImport(UIKit)` to conditionally import this framework. (for task: [\"SwiftCompile\", \"normal\", \"x86_64\", \"Compiling Source.swift\", \"\(tmpDirPath.str)/Test/aProject/Source.swift\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.swift:1:8: [Swift Compiler Error] UIKit is not available when building for macOS. Consider using `#if canImport(UIKit)` to conditionally import this framework. (for task: [\"SwiftEmitModule\", \"normal\", \"x86_64\", \"Emitting module for Foo\"])"))
                    results.checkError(.prefix("Command SwiftEmitModule failed."))
                    results.checkError(.prefix("Command SwiftCompile failed."))
                    if !SWBFeatureFlag.performOwnershipAnalysis.value {
                        for _ in 0..<4 { results.checkError(.contains("No such file or directory (2) (for task: [\"Copy\"")) }
                    }
                default:
                    // No error for MobileCoreServices because it still exists for macCatalyst
                    break
                }

                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .watchOS, .iOS))
    func missingFrameworkClangCompilerHeaderDiagnostic() async throws {
        try await testMissingFrameworkClangCompilerHeaderDiagnostic(frameworkName: "AppKit", activeRunDestination: .iOS)
        try await testMissingFrameworkClangCompilerHeaderDiagnostic(frameworkName: "WatchKit")
        try await testMissingFrameworkClangCompilerHeaderDiagnostic(frameworkName: "MobileCoreServices")
        try await testMissingFrameworkClangCompilerHeaderDiagnostic(frameworkName: "OpenGLES")
        try await testMissingFrameworkClangCompilerHeaderDiagnostic(frameworkName: "UIKit", sdk: "macosx", activeRunDestination: .macOS, supportsMacCatalyst: false)
    }

    func testMissingFrameworkClangCompilerHeaderDiagnostic(frameworkName: String, sdk: String = "iphoneos", activeRunDestination: RunDestinationInfo = .macCatalyst, supportsMacCatalyst: Bool = true) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("Source.m"),
                                TestFile("\(frameworkName).framework", sourceTree: .buildSetting("SDKROOT"))
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS[sdk=iphoneos*]": "arm64",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": sdk,
                                "SUPPORTS_MACCATALYST": supportsMacCatalyst ? "YES" : "NO",
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Foo",
                                buildPhases: [
                                    TestSourcesBuildPhase(["Source.m"]),
                                    TestFrameworksBuildPhase([TestBuildFile("\(frameworkName).framework")])
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Source.m")) {
                $0 <<< "#import <\(frameworkName)/\(frameworkName).h>\nint main() { return 0; }"
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination, overrides: ["DISABLE_SDK_METADATA_PARSING": "NO"])) { results in
                results.checkNoWarnings()
                switch frameworkName {
                case "AppKit":
                    results.checkError(.prefix("Command CompileC failed."))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Lexical or Preprocessor Issue] \'AppKit/AppKit.h\' file not found (for task: [\"CompileC\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-iphoneos/Foo.build/Objects-normal/arm64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"arm64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Lexical or Preprocessor Issue] AppKit is not available when building for iOS. Consider using `#if __has_include(<AppKit/AppKit.h>)` to conditionally import this framework. (for task: [\"CompileC\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-iphoneos/Foo.build/Objects-normal/arm64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"arm64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                case "WatchKit":
                    results.checkError(.prefix("Command CompileC failed."))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Lexical or Preprocessor Issue] \'WatchKit/WatchKit.h\' file not found (for task: [\"CompileC\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Lexical or Preprocessor Issue] WatchKit is not available when building for Mac Catalyst. Consider using `#if __has_include(<WatchKit/WatchKit.h>)` to conditionally import this framework. (for task: [\"CompileC\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                case "OpenGLES":
                    results.checkError(.prefix("Command CompileC failed."))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Lexical or Preprocessor Issue] \'OpenGLES/OpenGLES.h\' file not found (for task: [\"CompileC\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Lexical or Preprocessor Issue] OpenGLES is deprecated and is not available when building for Mac Catalyst. Consider migrating to Metal instead, or use `#if __has_include(<OpenGLES/OpenGLES.h>)` to conditionally import this framework. (for task: [\"CompileC\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                case "UIKit":
                    results.checkError(.prefix("Command CompileC failed."))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Lexical or Preprocessor Issue] \'UIKit/UIKit.h\' file not found (for task: [\"CompileC\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Lexical or Preprocessor Issue] UIKit is not available when building for macOS. Consider using `#if __has_include(<UIKit/UIKit.h>)` to conditionally import this framework. (for task: [\"CompileC\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                default:
                    // No error for MobileCoreServices because it still exists for macCatalyst
                    break
                }

                results.checkNoErrors()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .watchOS, .iOS), .requireStructuredDiagnostics)
    func missingFrameworkClangCompilerModularImportDiagnostic() async throws {
        try await testMissingFrameworkClangCompilerModularImportDiagnostic(frameworkName: "AppKit", activeRunDestination: .iOS)
        try await testMissingFrameworkClangCompilerModularImportDiagnostic(frameworkName: "WatchKit")
        try await testMissingFrameworkClangCompilerModularImportDiagnostic(frameworkName: "MobileCoreServices")
        try await testMissingFrameworkClangCompilerModularImportDiagnostic(frameworkName: "OpenGLES")
        try await testMissingFrameworkClangCompilerModularImportDiagnostic(frameworkName: "UIKit", sdk: "macosx", activeRunDestination: .macOS, supportsMacCatalyst: false)
    }

    func testMissingFrameworkClangCompilerModularImportDiagnostic(frameworkName: String, sdk: String = "iphoneos", activeRunDestination: RunDestinationInfo = .macCatalyst, supportsMacCatalyst: Bool = true) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [
                                TestFile("Source.m"),
                                TestFile("\(frameworkName).framework", sourceTree: .buildSetting("SDKROOT"))
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ARCHS[sdk=iphoneos*]": "arm64",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": sdk,
                                "SUPPORTS_MACCATALYST": supportsMacCatalyst ? "YES" : "NO",
                                "_EXPERIMENTAL_CLANG_EXPLICIT_MODULES": "YES",
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Foo",
                                buildPhases: [
                                    TestSourcesBuildPhase(["Source.m"]),
                                    TestFrameworksBuildPhase([TestBuildFile("\(frameworkName).framework")])
                                ]),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/Source.m")) {
                $0 <<< "@import \(frameworkName);\nint main() { return 0; }"
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination, overrides: ["DISABLE_SDK_METADATA_PARSING": "NO"])) { results in
                results.checkNoWarnings()
                switch frameworkName {
                case "AppKit":
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Parse Issue] module \'AppKit\' not found (for task: [\"ScanDependencies\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-iphoneos/Foo.build/Objects-normal/arm64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"arm64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Parse Issue] AppKit is not available when building for iOS. Consider using `#if __has_include(<AppKit/AppKit.h>)` to conditionally import this framework. (for task: [\"ScanDependencies\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-iphoneos/Foo.build/Objects-normal/arm64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"arm64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                case "WatchKit":
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Parse Issue] module \'WatchKit\' not found (for task: [\"ScanDependencies\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-maccatalyst/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Parse Issue] WatchKit is not available when building for Mac Catalyst. Consider using `#if __has_include(<WatchKit/WatchKit.h>)` to conditionally import this framework. (for task: [\"ScanDependencies\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                case "OpenGLES":
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Parse Issue] module \'OpenGLES\' not found (for task: [\"ScanDependencies\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-maccatalyst/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Parse Issue] OpenGLES is deprecated and is not available when building for Mac Catalyst. Consider migrating to Metal instead, or use `#if __has_include(<OpenGLES/OpenGLES.h>)` to conditionally import this framework. (for task: [\"ScanDependencies\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                case "UIKit":
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Parse Issue] module \'UIKit\' not found (for task: [\"ScanDependencies\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                    results.checkError(.equal("\(tmpDirPath.str)/Test/aProject/Source.m:1:9: [Parse Issue] UIKit is not available when building for macOS. Consider using `#if __has_include(<UIKit/UIKit.h>)` to conditionally import this framework. (for task: [\"ScanDependencies\", \"\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/Foo.build/Objects-normal/x86_64/Source.o\", \"\(tmpDirPath.str)/Test/aProject/Source.m\", \"normal\", \"x86_64\", \"objective-c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])"))
                default:
                    // No error for MobileCoreServices because it still exists for macCatalyst
                    break
                }

                results.checkNoErrors()
            }
        }
    }
}
