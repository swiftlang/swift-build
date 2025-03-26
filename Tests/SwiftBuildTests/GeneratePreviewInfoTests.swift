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
@_spi(Testing) import SwiftBuild
import SwiftBuildTestSupport
import SWBProtocol
import SWBTestSupport
import SWBUtil
import SWBBuildService

@Suite(.requireHostOS(.macOS))
fileprivate struct GeneratePreviewInfoTests: CoreBasedTests {
    func testGeneratePreviewInfo(overrides: [String: String]) async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let appTarget = TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "SWIFT_VERSION": "5.0",
                                "SWIFT_ENABLE_BARE_SLASH_REGEX": "YES",
                                "ONLY_ACTIVE_ARCH": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SDK_STAT_CACHE_ENABLE": "NO",
                                "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                                "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "NO",
                                // Test that we strip the flag
                                "SWIFT_EMIT_LOC_STRINGS": "YES",
                                "SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION": "NO",
                            ].merging(overrides, uniquingKeysWith: { _, new in new }))
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                            TestBuildFile("TestFile2.c"),
                            TestBuildFile("TestFile3.c"),
                            TestBuildFile("TestFile4.swift"),
                            TestBuildFile("Foo.xcdatamodeld"),
                            TestBuildFile("SmartStuff.mlmodel"),
                            TestBuildFile("Intents.intentdefinition", intentsCodegenVisibility: .public),
                        ]),
                        TestResourcesBuildPhase([
                            "Assets.xcassets",
                        ])
                    ]
                )

                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test", children: [
                            TestFile("TestFile1.c"),
                            TestFile("TestFile2.c"),
                            TestFile("TestFile3.c"),
                            TestFile("TestFile4.swift"),
                            TestVersionGroup("Foo.xcdatamodeld", children: [TestFile("Foo.xcdatamodeld")]),
                            TestFile("SmartStuff.mlmodel"),
                            TestFile("Intents.intentdefinition"),
                            TestFile("Assets.xcassets"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ENABLE_PREVIEWS": "YES",
                            ])
                        ],
                        targets: [
                            appTarget
                        ]
                    )
                ]))

                try await localFS.writeFileContents(tmpDir.join("Test/TestFile1.c")) { $0 <<< "" }
                try await localFS.writeFileContents(tmpDir.join("Test/TestFile2.c")) { $0 <<< "" }
                try await localFS.writeFileContents(tmpDir.join("Test/TestFile3.c")) { $0 <<< "" }
                try await localFS.writeFileContents(tmpDir.join("Test/TestFile4.swift")) { $0 <<< "@_cdecl(\"main\") func main() { }" }

                let activeRunDestination = SWBRunDestinationInfo.iOS
                let buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: appTarget.guid, parameters: buildParameters))

                let delegate = TestBuildOperationDelegate()

                let developerDir = try await testSession.session.evaluateMacroAsString("DEVELOPER_DIR", level: .target(appTarget.guid), buildParameters: buildParameters, overrides: nil)
                let sdkroot = try await testSession.session.evaluateMacroAsString("SDKROOT", level: .target(appTarget.guid), buildParameters: buildParameters, overrides: nil)
                let sdkVersion = try await testSession.session.evaluateMacroAsString("SDK_VERSION", level: .target(appTarget.guid), buildParameters: buildParameters, overrides: nil)
                let deploymentTarget = try await testSession.session.evaluateMacroAsString("IPHONEOS_DEPLOYMENT_TARGET", level: .target(appTarget.guid), buildParameters: buildParameters, overrides: nil)

                if overrides["ENABLE_XOJIT_PREVIEWS"] != "YES" {
                    // Checking dynamic replacement.
                    #expect(try await testSession.session.generatePreviewInfo(for: request, targetID: appTarget.guid, sourceFile: tmpDir.join("TestFile4.swift").str, thunkVariantSuffix: "canary", delegate: delegate) == [SWBPreviewInfo(sdkRoot: "iphoneos\(sdkVersion)", sdkVariant: "iphoneos", buildVariant: "normal", architecture: activeRunDestination.targetArchitecture, compileCommandLine: [
                        "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-enforce-exclusivity=checked", "-enable-bare-slash-regex", "-enable-experimental-feature", "DebugDescriptionMacro", "-sdk", sdkroot, "-target", "\(activeRunDestination.targetArchitecture)-apple-ios\(deploymentTarget)", "-Xfrontend", "-serialize-debugging-options", "-swift-version", "5", "-I", "\(tmpDir.str)/Test/build/Debug-iphoneos", "-F", "\(tmpDir.str)/Test/build/Debug-iphoneos", "-c", "-j\(compilerParallelismLevel)", "-no-color-diagnostics", "-serialize-diagnostics", "-Xcc", "-I\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/App-generated-files.hmap", "-Xcc", "-I\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/App-own-target-headers.hmap", "-Xcc", "-I\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/App-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/App-project-headers.hmap", "-Xcc", "-I\(tmpDir.str)/Test/build/Debug-iphoneos/include", "-Xcc", "-I\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources-normal/\(activeRunDestination.targetArchitecture)", "-Xcc", "-I\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/\(activeRunDestination.targetArchitecture)", "-Xcc", "-I\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources", "-working-directory", "\(tmpDir.str)/Test", "-experimental-emit-module-separately", "-disable-cmo", "-disable-bridging-pch", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.swift", "-o", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.o", "-module-name", "App_PreviewReplacement_TestFile4_canary", "-parse-as-library", "-Onone", "-Xfrontend", "-disable-modules-validate-system-headers"
                    ], linkCommandLine: [
                        "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "-Xlinker", "-reproducible", "-target", "\(activeRunDestination.targetArchitecture)-apple-ios\(deploymentTarget)", "-isysroot", sdkroot, "-Os", "-L\(tmpDir.str)/Test/build/EagerLinkingTBDs/Debug-iphoneos", "-L\(tmpDir.str)/Test/build/Debug-iphoneos", "-F\(tmpDir.str)/Test/build/EagerLinkingTBDs/Debug-iphoneos", "-F\(tmpDir.str)/Test/build/Debug-iphoneos", "-fobjc-link-runtime", "-L\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos", "-L/usr/lib/swift", "-bundle", "-bundle_loader", "\(tmpDir.str)/Test/build/Debug-iphoneos/App.app/App", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.o", "-o", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.dylib"
                    ], thunkSourceFile: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.swift", thunkObjectFile: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.o", thunkLibrary: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.dylib", pifGUID: appTarget.guid)])

                    await #expect(performing: {
                        try await testSession.session.generatePreviewInfo(for: request, targetID: "a", sourceFile: "/", thunkVariantSuffix: "", delegate: delegate)
                    }, throws: { error in
                        error.localizedDescription == "could not generate preview info: unableToFindTarget(targetID: \"a\")"
                    })
                } else {
                    // Checking XOJIT.
                    let previewInfo = try await testSession.session.generatePreviewInfo(for: request, targetID: appTarget.guid, sourceFile: tmpDir.join("Test/TestFile4.swift").str, thunkVariantSuffix: "canary", delegate: delegate).only
                    #expect(previewInfo?.sdkRoot == "iphoneos\(sdkVersion)")
                    #expect(previewInfo?.sdkVariant == "iphoneos")
                    #expect(previewInfo?.buildVariant == "normal")
                    #expect(previewInfo?.architecture == activeRunDestination.targetArchitecture)
                    // Ignore plugin paths when checking the compile command line, as these have changed often.
                    var compileCommandLine = previewInfo?.compileCommandLine ?? []

                    for idx in compileCommandLine.indices.reversed().dropFirst() {
                        if ["-external-plugin-path", "-plugin-path", "-in-process-plugin-server-path"].contains(compileCommandLine[idx]) {
                            // Remove the flag and argument
                            compileCommandLine.remove(at: idx)
                            compileCommandLine.remove(at: idx)
                        }
                        if ["-disable-clang-spi"].contains(compileCommandLine[idx]) {
                            // Remove the flag
                            compileCommandLine.remove(at: idx)
                        }
                    }

                    compileCommandLine = compileCommandLine.filter { $0 != "-disable-clang-spi" }

                    // Validate that the command line contains key arguments (we don't check the command line exactly because it will evolve over time in ways that don't affect XOJIT Previews, thus presenting a maintenance burden).
                    XCTAssertMatch(compileCommandLine, [
                        .start,
                        "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                        "-frontend", "-c",
                        "-primary-file", "\(tmpDir.str)/Test/TestFile4.swift", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.swift",
                        .anySequence,
                        "-sdk", "\(sdkroot)",
                        .anySequence,
                        "-vfsoverlay", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/vfsoverlay-TestFile4.canary.preview-thunk.swift.json",
                        .anySequence,
                        "-Onone",
                        .anySequence,
                        "-module-name", "App",
                        "-target-sdk-version", "\(deploymentTarget)",
                        "-target-sdk-name", "iphoneos\(deploymentTarget)",
                        "-o", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.o",
                        .end
                    ])
                    // Also spot-check that some options which were removed in SwiftCompilerSpec.generatePreviewInfo() for XOJIT are not present.
                    for option in [
                        "-incremental",
                        "-enable-batch-mode",
                        "-disable-batch-mode",
                        "-whole-module-optimization",
                        "-emit-dependencies",
                        "-emit-module",
                        "-emit-objc-header",
                        "-emit-localized-strings",
                        "-emit-localized-strings-path",
                        "-explicit-module-build",
                        "-output-file-map",
                        "-index-store-path",
                    ] {
                        #expect(!compileCommandLine.contains(option), "Unexpected argument: \(option)")
                    }
                    #expect(previewInfo?.linkCommandLine == [])
                    #expect(previewInfo?.thunkSourceFile == "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.swift")
                    #expect(previewInfo?.thunkObjectFile == "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.canary.preview-thunk.o")
                    #expect(previewInfo?.thunkLibrary == "")
                    #expect(previewInfo?.pifGUID == appTarget.guid)

                    await #expect(performing: {
                        try await testSession.session.generatePreviewInfo(for: request, targetID: "a", sourceFile: "/", thunkVariantSuffix: "", delegate: delegate)
                    }, throws: { error in
                        error.localizedDescription == "could not generate preview info: unableToFindTarget(targetID: \"a\")"
                    })

                    let info = try await testSession.session.generatePreviewTargetDependencyInfo(for: request, targetIDs: [appTarget.guid], delegate: delegate)
                    #expect(info == [
                        SWBPreviewTargetDependencyInfo(
                            sdkRoot: "iphoneos\(sdkVersion)",
                            sdkVariant: "iphoneos",
                            buildVariant: "normal",
                            architecture: activeRunDestination.targetArchitecture,
                            pifGUID: appTarget.guid,
                            objectFileInputMap: [
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.o": Set(["\(tmpDir.str)/Test/TestFile4.swift"]),
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/GeneratedAssetSymbols.o": Set(["\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.swift"])
                            ],
                            linkCommandLine: [
                                "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
                                "-Xlinker",
                                "-reproducible",
                                "-target",
                                "\(activeRunDestination.targetArchitecture)-apple-ios\(deploymentTarget)",
                                "-dynamiclib",
                                "-isysroot",
                                sdkroot,
                                "-Os",
                                "-L\(tmpDir.str)/Test/build/EagerLinkingTBDs/Debug-iphoneos",
                                "-L\(tmpDir.str)/Test/build/Debug-iphoneos",
                                "-F\(tmpDir.str)/Test/build/EagerLinkingTBDs/Debug-iphoneos",
                                "-F\(tmpDir.str)/Test/build/Debug-iphoneos",
                                "-filelist",
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/App.LinkFileList",
                                "-install_name",
                                "@rpath/App.debug.dylib",
                                "-dead_strip",
                                "-Xlinker",
                                "-object_path_lto",
                                "-Xlinker",
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/App_lto.o",
                                "-Xlinker",
                                "-dependency_info",
                                "-Xlinker",
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/App_dependency_info.dat",
                                "-fobjc-link-runtime",
                                "-L\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos",
                                "-L/usr/lib/swift",
                                "-Xlinker",
                                "-add_ast_path",
                                "-Xlinker",
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/App.swiftmodule",
                                "-Xlinker",
                                "-alias",
                                "-Xlinker",
                                "_main",
                                "-Xlinker",
                                "___debug_main_executable_dylib_entry_point",
                                "-o",
                                "\(tmpDir.str)/Test/build/Debug-iphoneos/App.app/App.debug.dylib"
                            ],
                            linkerWorkingDirectory: "\(tmpDir.str)/Test",
                            swiftEnableOpaqueTypeErasure: false,
                            swiftUseIntegratedDriver: true,
                            enableJITPreviews: true,
                            enableDebugDylib: true,
                            enableAddressSanitizer: false,
                            enableThreadSanitizer: false,
                            enableUndefinedBehaviorSanitizer: false
                        )
                    ])

                    await #expect(performing: {
                        try await testSession.session.generatePreviewTargetDependencyInfo(for: request, targetIDs: ["a"], delegate: delegate)
                    }, throws: { error in
                        error.localizedDescription == "could not generate preview info: unableToFindTarget(targetID: \"a\")"
                    })
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func generatePreviewInfo() async throws {
        try await testGeneratePreviewInfo(overrides: [:])
    }

    @Test(.requireSDKs(.iOS))
    func generatePreviewInfoXOJIT() async throws {
        try await testGeneratePreviewInfo(overrides: ["ENABLE_XOJIT_PREVIEWS": "YES", "ENABLE_PREVIEWS": "NO"])
    }

    @Test(.requireSDKs(.iOS))
    func generatePreviewInfoXOJITWithStaticLibrary() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let libTarget = TestStandardTarget(
                    "StaticLib",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "SWIFT_VERSION": "5.0",
                                "ONLY_ACTIVE_ARCH": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                "SDK_STAT_CACHE_ENABLE": "NO",
                                "SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION": "NO",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                            TestBuildFile("TestFile2.c"),
                            TestBuildFile("TestFile3.c"),
                            TestBuildFile("TestFile4.swift"),
                        ]),
                    ]
                )

                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test", children: [
                            TestFile("TestFile1.c"),
                            TestFile("TestFile2.c"),
                            TestFile("TestFile3.c"),
                            TestFile("TestFile4.swift"),
                            TestVersionGroup("Foo.xcdatamodeld", children: [TestFile("Foo.xcdatamodeld")]),
                            TestFile("SmartStuff.mlmodel"),
                            TestFile("Intents.intentdefinition"),
                            TestFile("Assets.xcassets"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ENABLE_PREVIEWS": "NO",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                            ])
                        ],
                        targets: [
                            libTarget
                        ]
                    )
                ]))

                try await localFS.writeFileContents(tmpDir.join("Test/TestFile1.c")) { $0 <<< "" }
                try await localFS.writeFileContents(tmpDir.join("Test/TestFile2.c")) { $0 <<< "" }
                try await localFS.writeFileContents(tmpDir.join("Test/TestFile3.c")) { $0 <<< "" }
                try await localFS.writeFileContents(tmpDir.join("Test/TestFile4.swift")) { $0 <<< "@_cdecl(\"main\") func main() { }" }

                let activeRunDestination = SWBRunDestinationInfo.iOS
                let buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: libTarget.guid, parameters: buildParameters))

                let delegate = TestBuildOperationDelegate()

                let developerDir = try await testSession.session.evaluateMacroAsString("DEVELOPER_DIR", level: .target(libTarget.guid), buildParameters: buildParameters, overrides: nil)
                let sdkroot = try await testSession.session.evaluateMacroAsString("SDKROOT", level: .target(libTarget.guid), buildParameters: buildParameters, overrides: nil)
                let sdkVersion = try await testSession.session.evaluateMacroAsString("SDK_VERSION", level: .target(libTarget.guid), buildParameters: buildParameters, overrides: nil)

                #expect(
                    try await testSession.session.generatePreviewTargetDependencyInfo(
                        for: request,
                        targetIDs: [libTarget.guid],
                        delegate: delegate
                    ) ==
                    [
                        SWBPreviewTargetDependencyInfo(
                            sdkRoot: "iphoneos\(sdkVersion)",
                            sdkVariant: "iphoneos",
                            buildVariant: "normal",
                            architecture: activeRunDestination.targetArchitecture,
                            pifGUID: libTarget.guid,
                            objectFileInputMap: [
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/StaticLib.build/Objects-normal/arm64/TestFile4.o": Set(["\(tmpDir.str)/Test/TestFile4.swift"])
                            ],
                            linkCommandLine: [
                                "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/libtool",
                                "-static",
                                "-arch_only",
                                activeRunDestination.targetArchitecture,
                                "-D",
                                "-syslibroot",
                                sdkroot,
                                "-L\(tmpDir.str)/Test/build/Debug-iphoneos",
                                "-filelist",
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/StaticLib.build/Objects-normal/arm64/StaticLib.LinkFileList",
                                "-dependency_info",
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/StaticLib.build/Objects-normal/arm64/StaticLib_libtool_dependency_info.dat",
                                "-o",
                                "\(tmpDir.str)/Test/build/Debug-iphoneos/libStaticLib.a"
                            ],
                            linkerWorkingDirectory: "\(tmpDir.str)/Test",
                            swiftEnableOpaqueTypeErasure: false,
                            swiftUseIntegratedDriver: true,
                            enableJITPreviews: true,
                            enableDebugDylib: false,
                            enableAddressSanitizer: false,
                            enableThreadSanitizer: false,
                            enableUndefinedBehaviorSanitizer: false
                        )
                    ]
                )
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func generatePreviewInfoTargetDependencyInfoXOJITWithCOnlyTarget() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let target = TestStandardTarget(
                    "CApplication",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "ONLY_ACTIVE_ARCH": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                                "SDK_STAT_CACHE_ENABLE": "NO",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                            TestBuildFile("TestFile2.c"),
                            TestBuildFile("TestFile3.c"),
                        ]),
                    ]
                )

                try await testSession.sendPIF(TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Test",
                        groupTree: TestGroup("Test", children: [
                            TestFile("TestFile1.c"),
                            TestFile("TestFile2.c"),
                            TestFile("TestFile3.c"),
                            TestVersionGroup("Foo.xcdatamodeld", children: [TestFile("Foo.xcdatamodeld")]),
                            TestFile("SmartStuff.mlmodel"),
                            TestFile("Intents.intentdefinition"),
                            TestFile("Assets.xcassets"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "ENABLE_PREVIEWS": "NO",
                                "ENABLE_XOJIT_PREVIEWS": "YES",
                            ])
                        ],
                        targets: [
                            target
                        ]
                    )
                ]))

                try await localFS.writeFileContents(tmpDir.join("Test/TestFile1.c")) { $0 <<< "int main(int argc, char **argv) { return 0; }" }
                try await localFS.writeFileContents(tmpDir.join("Test/TestFile2.c")) { $0 <<< "" }
                try await localFS.writeFileContents(tmpDir.join("Test/TestFile3.c")) { $0 <<< "" }

                let activeRunDestination = SWBRunDestinationInfo.iOS
                let buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParameters))

                let delegate = TestBuildOperationDelegate()

                let developerDir = try await testSession.session.evaluateMacroAsString("DEVELOPER_DIR", level: .target(target.guid), buildParameters: buildParameters, overrides: nil)
                let sdkroot = try await testSession.session.evaluateMacroAsString("SDKROOT", level: .target(target.guid), buildParameters: buildParameters, overrides: nil)
                let sdkVersion = try await testSession.session.evaluateMacroAsString("SDK_VERSION", level: .target(target.guid), buildParameters: buildParameters, overrides: nil)
                let deploymentTarget = try await testSession.session.evaluateMacroAsString("IPHONEOS_DEPLOYMENT_TARGET", level: .target(target.guid), buildParameters: buildParameters, overrides: nil)

                #expect(
                    try await testSession.session.generatePreviewTargetDependencyInfo(
                        for: request,
                        targetIDs: [target.guid],
                        delegate: delegate
                    ) ==
                    [
                        SWBPreviewTargetDependencyInfo(
                            sdkRoot: "iphoneos\(sdkVersion)",
                            sdkVariant: "iphoneos",
                            buildVariant: "normal",
                            architecture: activeRunDestination.targetArchitecture,
                            pifGUID: target.guid,
                            objectFileInputMap: [:],
                            linkCommandLine: [
                                "\(developerDir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
                                "-Xlinker", "-reproducible",
                                "-target", "\(activeRunDestination.targetArchitecture)-apple-ios\(deploymentTarget)",
                                "-isysroot",
                                sdkroot,
                                "-Os",
                                "-L\(tmpDir.str)/Test/build/EagerLinkingTBDs/Debug-iphoneos",
                                "-L\(tmpDir.str)/Test/build/Debug-iphoneos",
                                "-F\(tmpDir.str)/Test/build/EagerLinkingTBDs/Debug-iphoneos",
                                "-F\(tmpDir.str)/Test/build/Debug-iphoneos",
                                "-filelist",
                                "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/CApplication.build/Objects-normal/arm64/CApplication.LinkFileList",
                                "-dead_strip",
                                "-Xlinker", "-object_path_lto", "-Xlinker", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/CApplication.build/Objects-normal/arm64/CApplication_lto.o",
                                "-Xlinker", "-dependency_info",
                                "-Xlinker", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/CApplication.build/Objects-normal/arm64/CApplication_dependency_info.dat",
                                "-o",
                                "\(tmpDir.str)/Test/build/Debug-iphoneos/CApplication.app/CApplication"
                            ],
                            linkerWorkingDirectory: "\(tmpDir.str)/Test",
                            swiftEnableOpaqueTypeErasure: false,
                            swiftUseIntegratedDriver: true,
                            enableJITPreviews: false,
                            enableDebugDylib: false,
                            enableAddressSanitizer: false,
                            enableThreadSanitizer: false,
                            enableUndefinedBehaviorSanitizer: false
                        )
                    ]
                )
            }
        }
    }
}
