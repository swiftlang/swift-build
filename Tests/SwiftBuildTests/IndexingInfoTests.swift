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
import SwiftBuild
import SwiftBuildTestSupport
import SWBTestSupport
@_spi(Testing) import SWBUtil
import SWBProtocol
import SWBCore

// These tests use the old model, ie. the index build arena is disabled.
@Suite(.requireHostOS(.macOS))
fileprivate struct IndexingInfoTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS), .userDefaults(["EnablePluginManagerLogging": "0"]))
    func indexingInfo() async throws {
        try await withTemporaryDirectory { tmpDir in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = tmpDir.str

                // Establish a connection to the build service.
                let service = try await SWBBuildService()
                await deferrable.addBlock {
                    await service.close()
                }

                // Check there are no sessions.
                #expect(try await service.listSessions() == [:])

                // Create a session.
                let (result, diagnostics) = await service.createSession(name: "FOO", cachePath: nil)
                #expect(diagnostics.isEmpty)
                let session = try result.get()
                #expect(try await service.listSessions() == ["S0": "FOO"])
                #expect(session.name == "FOO")
                #expect(session.uid == "S0")

                // Send a PIF (required to establish a workspace context).
                //
                // FIXME: Move this test data elsewhere.
                let projectDir = "\(tmpDirPath)/SomeProject"
                let projectFilesDir = "\(projectDir)/SomeFiles"

                let workspacePIF: SWBPropertyListItem = [
                    "guid":      "some-workspace-guid",
                    "name":      "aWorkspace",
                    "path":      .plString("\(tmpDirPath)/aWorkspace.xcworkspace/contents.xcworkspacedata"),
                    "projects":  ["P1"]
                ]
                let projectPIF: SWBPropertyListItem = [
                    "guid": "P1",
                    "path": .plString("\(projectDir)/aProject.xcodeproj"),
                    "groupTree": [
                        "guid": "G1",
                        "type": "group",
                        "name": "SomeFiles",
                        "sourceTree": "PROJECT_DIR",
                        "path": .plString(projectFilesDir),
                        "children": [
                            [
                                "guid": "source-file-fileReference-guid",
                                "type": "file",
                                "sourceTree": "<group>",
                                "path": "Source.c",
                                "fileType": "sourcecode.c.c"
                            ],
                            [
                                "guid": "source-file-fileReference-guid2",
                                "type": "file",
                                "sourceTree": "<group>",
                                "path": "Source2.c",
                                "fileType": "sourcecode.c.c"
                            ]
                        ]
                    ],
                    "buildConfigurations": [
                        [
                            "guid": "BC1",
                            "name": "Config1",
                            "buildSettings": [:]
                        ]
                    ],
                    "defaultConfigurationName": "Config1",
                    "developmentRegion": "English",
                    "targets": ["T1"]
                ]
                let targetPIF: SWBPropertyListItem = [
                    "guid": "T1",
                    "name": "Target1",
                    "type": "standard",
                    "productTypeIdentifier": "com.apple.product-type.tool",
                    "productReference": [
                        "guid": "PR1",
                        "name": "Target1",
                    ],
                    "buildPhases": [
                        [
                            "guid": "BP1",
                            "type": "com.apple.buildphase.sources",
                            "buildFiles": [
                                [
                                    "guid": "BF2",
                                    "name": "Source.c",
                                    "fileReference": "source-file-fileReference-guid"
                                ],
                                [
                                    "guid": "BF3",
                                    "name": "Source2.c",
                                    "fileReference": "source-file-fileReference-guid2"
                                ]
                            ]
                        ]
                    ],
                    "buildConfigurations": [
                        [
                            "guid": "C2",
                            "name": "Config1",
                            "buildSettings": [:]
                        ]
                    ],
                    "dependencies": [],
                    "buildRules": []
                ]
                let topLevelPIF: SWBPropertyListItem = [
                    [
                        "type": "workspace",
                        "signature": "W1",
                        "contents": workspacePIF
                    ],
                    [
                        "type": "project",
                        "signature": "P1",
                        "contents": projectPIF
                    ],
                    [
                        "type": "target",
                        "signature": "T1",
                        "contents": targetPIF
                    ]
                ]

                try await session.sendPIF(topLevelPIF)

                // Verify we can send the system and user info.
                try await session.setSystemInfo(.defaultForTesting)
                try await session.setUserInfo(.defaultForTesting)

                // Create a build request for which to ask for indexing information.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.parameters.activeRunDestination = .macOS
                let target = SWBConfiguredTarget(guid: "T1")
                request.add(target: target)

                // Collect indexing information, and wait for it.
                do {
                    let results = try await session.generateLegacyInfo(for: request, targetID: target.guid)

                    do {
                        let expectedPath = Path("\(projectFilesDir)/Source.c")
                        await results.checkIndexingInfo(.matchSourceFilePath(expectedPath)) { info in
                            info.checkSourceFilePath(expectedPath)
                            info.checkLanguageDialect("c")
                            info.clang.checkCommandLineContainsUninterrupted(["-x", "c"])
                        }
                    }

                    do {
                        let expectedPath = Path("\(projectFilesDir)/Source2.c")
                        await results.checkIndexingInfo(.matchSourceFilePath(expectedPath)) { info in
                            info.checkSourceFilePath(expectedPath)
                            info.checkLanguageDialect("c")
                            info.clang.checkCommandLineContainsUninterrupted(["-x", "c"])
                        }
                    }

                    results.checkNoIndexingInfo()
                }

                // Test with specific file.
                do {
                    let results = try await session.generateLegacyInfo(for: request, targetID: target.guid, filePath: "\(projectFilesDir)/Source.c")

                    do {
                        let expectedPath = Path("\(projectFilesDir)/Source.c")
                        await results.checkIndexingInfo(.matchSourceFilePath(expectedPath)) { info in
                            info.checkSourceFilePath(expectedPath)
                            info.checkLanguageDialect("c")
                            info.clang.checkCommandLineContainsUninterrupted(["-x", "c"])
                        }
                    }

                    results.checkNoIndexingInfo()
                }

                // Test with specific file, output path only.
                do {
                    let results = try await session.generateLegacyInfo(for: request, targetID: target.guid, filePath: "\(projectFilesDir)/Source.c", outputPathOnly: true)

                    do {
                        let expectedPath = Path("\(projectFilesDir)/Source.c")
                        await results.checkIndexingInfo(.matchSourceFilePath(expectedPath)) { info in
                            info.checkSourceFilePath(expectedPath)
                            info.checkOutputFilePath(Path("\(projectDir)/build/aProject.build/Config1/Target1.build/Objects-normal/x86_64/Source.o"))

                            // We should _only_ have the output (and source) file paths due to the `outputPathOnly` flag, no other keys.
                            info.checkNoUnmatchedKeys()
                        }
                    }

                    results.checkNoIndexingInfo()
                }

                // Test all files, output path only.
                do {
                    let results = try await session.generateLegacyInfo(for: request, targetID: target.guid, filePath: nil, outputPathOnly: true)

                    do {
                        let expectedPath = Path("\(projectFilesDir)/Source.c")
                        await results.checkIndexingInfo(.matchSourceFilePath(expectedPath)) { info in
                            info.checkSourceFilePath(expectedPath)
                            info.checkOutputFilePath(Path("\(projectDir)/build/aProject.build/Config1/Target1.build/Objects-normal/x86_64/Source.o"))

                            // We should _only_ have the output (and source) file paths due to the `outputPathOnly` flag, no other keys.
                            info.checkNoUnmatchedKeys()
                        }
                    }

                    do {
                        let expectedPath = Path("\(projectFilesDir)/Source2.c")
                        await results.checkIndexingInfo(.matchSourceFilePath(expectedPath)) { info in
                            info.checkSourceFilePath(expectedPath)
                            info.checkOutputFilePath(Path("\(projectDir)/build/aProject.build/Config1/Target1.build/Objects-normal/x86_64/Source2.o"))

                            // We should _only_ have the output (and source) file paths due to the `outputPathOnly` flag, no other keys.
                            info.checkNoUnmatchedKeys()
                        }
                    }

                    results.checkNoIndexingInfo()
                }

                // We’re done with the session.
                try await session.close()

                // Verify there are no sessions remaining.
                #expect(try await service.listSessions() == [:])
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func indexingInfoDetailed() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
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
                                "ONLY_ACTIVE_ARCH": "YES",
                                "SWIFT_VERSION": "5.0",
                                "CLANG_ENABLE_MODULES": "YES",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
                            TestBuildFile("TestFile4.swift"),
                            TestBuildFile("Titanium.metal"),
                            TestBuildFile("Foo.xcdatamodeld"),
                            TestBuildFile("SmartStuff.mlmodel", intentsCodegenVisibility: .project),
                            TestBuildFile("Intents.intentdefinition", intentsCodegenVisibility: .public),

                            // Error cases
                            TestBuildFile("mlmissing.mlmodel", intentsCodegenVisibility: .project),
                            TestBuildFile("intentsmissing.intentdefinition", intentsCodegenVisibility: .public),
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
                            TestFile("TestFile4.swift"),
                            TestFile("Titanium.metal"),
                            TestVersionGroup("Foo.xcdatamodeld", children: [TestFile("Foo.xcdatamodeld")]),
                            TestFile("SmartStuff.mlmodel"),
                            TestFile("Intents.intentdefinition"),
                            TestFile("Assets.xcassets"),
                            TestFile("mlmissing.mlmodel"),
                            TestFile("intentsmissing.intentdefinition"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        targets: [
                            appTarget
                        ]
                    )
                ]))

                try localFS.createDirectory(tmpDir.join("Test"), recursive: true)

                let modelSourcePath = try #require(Bundle.module.path(forResource: "WordTagger", ofType: "mlmodel", inDirectory: "TestData"))
                try localFS.copy(Path(modelSourcePath), to: tmpDir.join("Test/SmartStuff.mlmodel"))

                try await localFS.writeIntentDefinition(tmpDir.join("Test/Intents.intentdefinition"))

                let activeRunDestination = SWBRunDestinationInfo.iOS
                let buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: appTarget.guid, parameters: buildParameters))

                let results = try await testSession.session.generateLegacyInfo(for: request, targetID: appTarget.guid)

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.m"))) { info in
                    info.checkOutputFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/SmartStuff.o"))
                    info.checkSourceFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.m"))
                    info.checkLanguageDialect("objective-c")
                    info.checkToolchains(["com.apple.dt.toolchain.XcodeDefault"])
                    info.checkClangBuiltProductsDir(Path("\(tmpDir.str)/Test/build/Debug-iphoneos"))
                    info.checkAssetSymbolIndexPath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols-Index.plist"))
                    checkClangCommandLine(info.clang, input: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.m", output: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/SmartStuff.o")
                    info.checkNoUnmatchedKeys()
                }

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/TestFile1.c"))) { info in
                    info.checkOutputFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile1.o"))
                    info.checkSourceFilePath(Path("\(tmpDir.str)/Test/TestFile1.c"))
                    info.checkLanguageDialect("c")
                    info.checkToolchains(["com.apple.dt.toolchain.XcodeDefault"])
                    info.checkClangBuiltProductsDir(Path("\(tmpDir.str)/Test/build/Debug-iphoneos"))
                    info.checkAssetSymbolIndexPath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols-Index.plist"))
                    checkClangCommandLine(info.clang, input: "\(tmpDir.str)/Test/TestFile1.c", output: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile1.o")
                    info.checkNoUnmatchedKeys()
                }

                let swiftFeatures = try await self.swiftFeatures

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/TestFile4.swift"))) { info in
                    if swiftFeatures.has(.indexUnitOutputPathWithoutWarning) {
                        info.checkOutputFilePath(Path("/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.o"))
                    } else {
                        info.checkOutputFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/TestFile4.o"))
                    }

                    info.checkSourceFilePath(Path("\(tmpDir.str)/Test/TestFile4.swift"))
                    info.checkLanguageDialect("swift")
                    info.checkToolchains(["com.apple.dt.toolchain.XcodeDefault"])
                    info.checkSwiftModuleName("App")
                    info.checkSwiftBuiltProductsDir(Path("\(tmpDir.str)/Test/build/Debug-iphoneos"))
                    info.checkAssetSymbolIndexPath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols-Index.plist"))
                    checkSwiftCommandLine(info, inputs: ["\(tmpDir.str)/Test/TestFile4.swift"])
                    info.checkNoUnmatchedKeys()
                }

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.swift"))) { info in
                    // This is expected to be a relative path with a "fake" leading slash (see `generateIndexOutputPath`).
                    info.checkOutputFilePath(Path("/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/GeneratedAssetSymbols.o"))
                    info.checkSourceFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.swift"))
                    info.checkLanguageDialect("swift")
                    info.checkToolchains(["com.apple.dt.toolchain.XcodeDefault"])
                    info.checkSwiftModuleName("App")
                    info.checkSwiftBuiltProductsDir(Path("\(tmpDir.str)/Test/build/Debug-iphoneos"))
                    info.checkAssetSymbolIndexPath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols-Index.plist"))
                    checkSwiftCommandLine(info, inputs: ["\(tmpDir.str)/Test/TestFile4.swift", "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.swift"])
                    info.checkNoUnmatchedKeys()
                }

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/Titanium.metal"))) { info in
                    info.checkOutputFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Metal/Titanium.air"))
                    info.checkSourceFilePath(Path("\(tmpDir.str)/Test/Titanium.metal"))
                    info.checkToolchains(["com.apple.dt.toolchain.XcodeDefault"])
                    info.checkLanguageDialect("metal")
                    info.checkMetalBuiltProductsDir(Path("\(tmpDir.str)/Test/build/Debug-iphoneos"))
                    checkClangCommandLine(info.metal, input: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Metal/Titanium.dia", output: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Metal/Titanium.air")
                    info.checkNoUnmatchedKeys()
                }

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/SmartStuff.mlmodel"))) { info in
                    info.checkSourceFilePath(Path("\(tmpDir.str)/Test/SmartStuff.mlmodel"))
                    info.checkCoreMLGeneratedFilePaths([
                        Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.h"),
                        Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/CoreMLGenerated/SmartStuff/SmartStuff.m"),
                    ])
                    info.checkCoreMLGeneratedLanguage("Objective-C")
                    info.checkNoUnmatchedKeys()
                }

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/IntentDefinitionGenerated/Intents/IntentIntent.m"))) { info in
                    info.checkOutputFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/IntentIntent.o"))
                    info.checkSourceFilePath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/IntentDefinitionGenerated/Intents/IntentIntent.m"))
                    info.checkLanguageDialect("objective-c")
                    info.checkToolchains(["com.apple.dt.toolchain.XcodeDefault"])
                    info.checkClangBuiltProductsDir(Path("\(tmpDir.str)/Test/build/Debug-iphoneos"))
                    info.checkAssetSymbolIndexPath(Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols-Index.plist"))
                    checkClangCommandLine(info.clang, input: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/IntentDefinitionGenerated/Intents/IntentIntent.m", output: "\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/Objects-normal/\(activeRunDestination.targetArchitecture)/IntentIntent.o")
                    info.checkNoUnmatchedKeys()
                }

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/Intents.intentdefinition"))) { info in
                    info.checkSourceFilePath(Path("\(tmpDir.str)/Test/Intents.intentdefinition"))
                    info.checkIntentsGeneratedFilePaths([
                        Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/IntentDefinitionGenerated/Intents/IntentIntent.h"),
                        Path("\(tmpDir.str)/Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/IntentDefinitionGenerated/Intents/IntentIntent.m"),
                    ])
                    info.checkNoUnmatchedKeys()
                }

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/mlmissing.mlmodel"))) { info in
                    info.checkSourceFilePath(Path("\(tmpDir.str)/Test/mlmissing.mlmodel"))
                    info.checkCoreMLGeneratedError(.and(.prefix("Error preparing CoreML model \"mlmissing.mlmodel\" for code generation"), .contains("exited with status")))
                    info.checkNoUnmatchedKeys()
                }

                // NOTE: No check for intentsmissing.intentdefinition because Intents code generation currently never reports failure (it should!)

                results.checkNoIndexingInfo()

                await #expect(performing: {
                    try await testSession.session.generateLegacyInfo(for: request, targetID: "missing")
                }, throws: { error in
                    error.localizedDescription.contains("could not find target with GUID: 'missing'")
                })

                // Basic checks that the command line makes sense for indexing. Doesn't check everything, just a few to make sure we've made the calls to add/remove args.
                func checkClangCommandLine(_ checkable: any CommandLineCheckable, input: String, output: String, sourceLocation: SourceLocation = #_sourceLocation) {
                    // Check we have the right file
                    checkable.checkCommandLineContains([input], sourceLocation: sourceLocation)
                    checkable.checkCommandLineContainsUninterrupted(["-o", output], sourceLocation: sourceLocation)
                    // Check for some indexing args
                    checkable.checkCommandLineContains(["-fsyntax-only"], sourceLocation: sourceLocation)
                    checkable.checkCommandLineContains(["-fretain-comments-from-system-headers"], sourceLocation: sourceLocation)
                    // Check we removed some unnecessary args
                    checkable.checkCommandLineDoesNotContain("-MD", sourceLocation: sourceLocation)
                    checkable.checkCommandLineDoesNotContain("--serialize-diagnostics", sourceLocation: sourceLocation)
                }
                func checkSwiftCommandLine(_ info: IndexingInfo, inputs: [String], sourceLocation: SourceLocation = #_sourceLocation) {
                    // Check we have the right file
                    info.swift.checkCommandLineContains(inputs, sourceLocation: sourceLocation)

                    // Indexing never emits modules
                    info.swift.checkCommandLineNoMatch(["-emit-module"], sourceLocation: sourceLocation)
                    info.swift.checkCommandLineNoMatch(["-emit-module-path"], sourceLocation: sourceLocation)
                    info.swift.checkCommandLineNoMatch(["-emit-module-interface"], sourceLocation: sourceLocation)
                    info.swift.checkCommandLineNoMatch(["-emit-module-interface-path"], sourceLocation: sourceLocation)
                    info.swift.checkCommandLineNoMatch(["-emit-private-module-interface-path"], sourceLocation: sourceLocation)

                    // Check for some indexing args
                    info.swift.checkCommandLineContainsUninterrupted(["-Xcc", "-fretain-comments-from-system-headers"], sourceLocation: sourceLocation)
                    // Check we removed some unnecessary args
                    info.swift.checkCommandLineDoesNotContain("--serialize-diagnostics", sourceLocation: sourceLocation)
                    info.swift.checkCommandLineDoesNotContain("-experimental-skip-all-function-bodies", sourceLocation: sourceLocation)
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func absoluteAssetSymbolIndexPath() async throws {
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
                                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "iphoneos",
                                "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_INDEX_PATH": "foo.plist",
                                "ONLY_ACTIVE_ARCH": "YES",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("test.c"),
                            TestBuildFile("test.swift"),
                        ]),
                        TestResourcesBuildPhase([
                            "Assets.xcassets",
                        ])
                    ]
                )

                try await testSession.sendPIF(
                    TestWorkspace(
                        "Test", sourceRoot: tmpDir, projects: [
                            TestProject(
                                "Test",
                                groupTree: TestGroup("Test", children: [
                                    TestFile("test.c"),
                                    TestFile("test.swift"),
                                    TestFile("Assets.xcassets"),
                                ]),
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug")
                                ],
                                targets: [
                                    appTarget
                                ]
                            )
                        ])
                )

                try localFS.createDirectory(tmpDir.join("Test"), recursive: true)

                let activeRunDestination = SWBRunDestinationInfo.iOS
                let buildParameters = SWBBuildParameters(
                    configuration: "Debug", activeRunDestination: activeRunDestination
                )
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(
                    guid: appTarget.guid, parameters: buildParameters
                ))

                let results = try await testSession.session.generateLegacyInfo(
                    for: request, targetID: appTarget.guid
                )

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/test.c"))) { info in
                    info.checkAssetSymbolIndexPath(Path("\(tmpDir.str)/Test/foo.plist"))
                }

                await results.checkIndexingInfo(.matchSourceFilePath(Path("\(tmpDir.str)/Test/test.swift"))) { info in
                    info.checkAssetSymbolIndexPath(Path("\(tmpDir.str)/Test/foo.plist"))
                }
            }
        }
    }

    /// Test that we compute right indexing argument when there is
    /// a PCH file.
    @Test(.requireSDKs(.macOS))
    func indexingPCH() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: srcroot,
                    projects: [
                        TestProject(
                            "aProject", defaultConfigurationName: "Debug",
                            groupTree: TestGroup(
                                "Foo",
                                children: [
                                    TestFile("foo.c"),
                                    TestFile("PrefixHeader.pch"),
                                ]
                            ),
                            targets: [
                                TestStandardTarget(
                                    "Foo", guid: "Foo", type: .staticLibrary,
                                    buildConfigurations: [
                                        TestBuildConfiguration(
                                            "Debug",
                                            buildSettings: [
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "USE_HEADERMAP": "NO",
                                                "GCC_PREFIX_HEADER": "Foo/PrefixHeader.pch"
                                            ])],
                                    buildPhases: [
                                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                                    ]
                                )
                            ]
                        )
                    ]
                )

                try await testSession.sendPIF(testWorkspace)

                // Write the test file.
                try localFS.createDirectory(testWorkspace.sourceRoot.join("aProject"), recursive: true)
                try localFS.write(testWorkspace.sourceRoot.join("aProject/foo.c"), contents: "")

                do {
                    var request = SWBBuildRequest()
                    request.parameters = SWBBuildParameters()
                    request.parameters.action = "build"
                    request.parameters.configurationName = "Debug"
                    request.add(target: SWBConfiguredTarget(guid: "Foo", parameters: nil))

                    let results = try await testSession.session.generateLegacyInfo(for: request, targetID: "Foo")
                    for arch in ["arm64", "x86_64"] {
                        await results.checkIndexingInfo(.matchSourceFilePath(srcroot.join("aProject/foo.c")), .matchOutputFilePath(srcroot.join("aProject/build/aProject.build/Debug/Foo.build/Objects-normal/\(arch)/foo.o"))) { info in
                            // Check that there is input pch path in the indexing args.
                            let pchInput = srcroot.join("aProject/Foo/PrefixHeader.pch").str
                            info.clang.checkCommandLineMatches([.contains("-include"), .contains(pchInput)])

                            info.checkPrefixHeaderPath(.equal(srcroot.join("aProject/Foo/PrefixHeader.pch").str))
                            info.checkPrecompiledHeaderPath(nil)
                            info.checkPrecompiledHeaderHashCriteria(nil)
                            info.clangPrecompiledHeader.checkCommandLine([])
                        }
                    }
                    results.checkNoIndexingInfo()
                }

                do {
                    var request = SWBBuildRequest()
                    request.parameters = SWBBuildParameters()
                    request.parameters.action = "build"
                    request.parameters.configurationName = "Debug"
                    var synthesized = SWBSettingsTable()
                    synthesized.set(value: "YES", for: "GCC_PRECOMPILE_PREFIX_HEADER")
                    request.parameters.overrides.synthesized = synthesized
                    request.add(target: SWBConfiguredTarget(guid: "Foo", parameters: nil))

                    let results = try await testSession.session.generateLegacyInfo(for: request, targetID: "Foo")
                    for arch in ["arm64", "x86_64"] {
                        await results.checkIndexingInfo(.matchSourceFilePath(srcroot.join("aProject/foo.c")), .matchOutputFilePath(srcroot.join("aProject/build/aProject.build/Debug/Foo.build/Objects-normal/\(arch)/foo.o"))) { info in
                            // PCH should be remapped to the original prefix header and we should have
                            // the input/output PCH info

                            info.clang.checkCommandLineMatches([.equal("-include"), .suffix("PrefixHeader.pch")])
                            info.clang.checkCommandLineNoMatch([.contains("SharedPrecompiledHeaders")])
                            info.checkPrefixHeaderPath(.suffix("PrefixHeader.pch"))
                            info.checkPrecompiledHeaderPath(.suffix("PrefixHeader.pch.gch"))

                            info.checkPrecompiledHeaderHashCriteria(nil) // rdar://problem/24469921
                            info.clangPrecompiledHeader.checkCommandLineDoesNotContain("--serialize-diagnostics")
                            info.clangPrecompiledHeader.checkCommandLineDoesNotContain("-fsyntax-only")
                            info.clangPrecompiledHeader.checkCommandLineMatches([.suffix("PrefixHeader.pch.gch")])
                            info.clangPrecompiledHeader.checkCommandLineMatches([.equal("-fretain-comments-from-system-headers")])
                        }
                    }
                    results.checkNoIndexingInfo()
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func indexingInfoWithMultipleArchs() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let srcroot = tmpDir.join("Test")
                let testWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: srcroot,
                    projects: [
                        TestProject(
                            "aProject", defaultConfigurationName: "Debug",
                            groupTree: TestGroup(
                                "Foo",
                                children: [
                                    TestFile("foo.c"),
                                ]
                            ),
                            targets: [
                                TestStandardTarget(
                                    "Foo", guid: "Foo", type: .staticLibrary,
                                    buildConfigurations: [
                                        TestBuildConfiguration(
                                            "Debug",
                                            buildSettings: [
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "ARCHS": "arm64 x86_64 i386",
                                            ])],
                                    buildPhases: [
                                        TestSourcesBuildPhase([TestBuildFile("foo.c")]),
                                    ]
                                )
                            ]
                        )
                    ]
                )

                try await testSession.sendPIF(testWorkspace)

                // Write the test file.
                try localFS.createDirectory(testWorkspace.sourceRoot.join("aProject"), recursive: true)
                try localFS.write(testWorkspace.sourceRoot.join("aProject/foo.c"), contents: "")

                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.parameters.activeRunDestination = .macOS
                request.add(target: SWBConfiguredTarget(guid: "Foo", parameters: nil))

                let results = try await testSession.session.generateLegacyInfo(for: request, targetID: "Foo")

                // Assert that there is only one compile task for indexing and it is for the run destination's target architecture.
                let arch = request.parameters.activeRunDestination?.targetArchitecture ?? "unknown_arch"
                await results.checkIndexingInfo(.matchSourceFilePath(srcroot.join("aProject/foo.c")), .matchOutputFilePath(srcroot.join("aProject/build/aProject.build/Debug/Foo.build/Objects-normal/\(arch)/foo.o"))) { info in
                    info.clang.checkCommandLineMatches(["-target", .prefix("\(arch)-apple-macos")])
                }

                results.checkNoIndexingInfo()
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func indexInfoWithExplicitBuildDescriptionID() async throws {
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
                                "CLANG_ENABLE_MODULES": "YES",
                                "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("TestFile1.c"),
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
                            TestFile("TestFile4.swift"),
                            TestVersionGroup("Foo.xcdatamodeld", children: [TestFile("Foo.xcdatamodeld")]),
                            TestFile("SmartStuff.mlmodel"),
                            TestFile("Intents.intentdefinition"),
                            TestFile("Assets.xcassets"),
                        ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        targets: [
                            appTarget
                        ]
                    )
                ]))

                let activeRunDestination = SWBRunDestinationInfo.iOS
                let buildParameters = SWBBuildParameters(configuration: "Debug", activeRunDestination: activeRunDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: appTarget.guid, parameters: buildParameters))

                final class IndexingBuildOperationDelegate: SWBIndexingDelegate {
                    private(set) var numExecuteExternalToolRequests = 0
                    private let delegate = TestBuildOperationDelegate()

                    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> SWBExternalToolResult {
                        numExecuteExternalToolRequests += 1
                        return try await delegate.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
                    }

                    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
                        return await delegate.provisioningTaskInputs(targetGUID: targetGUID, provisioningSourceData: provisioningSourceData)
                    }
                }

                // Check index request without explicit build description ID.
                do {
                    let delegate = IndexingBuildOperationDelegate()
                    let results = try await testSession.session.generateLegacyInfo(for: request, targetID: appTarget.guid, delegate: delegate)
                    await results.checkIndexingInfo(.matchSourceFilePath(tmpDir.join("Test/TestFile1.c"))) { _ in }
                    await results.checkIndexingInfo(.matchSourceFilePath(tmpDir.join("Test/TestFile4.swift"))) { _ in }
                    await results.checkIndexingInfo(.matchSourceFilePath(tmpDir.join("Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.swift"))) { _ in }
                    results.checkNoIndexingInfo()
                    #expect(delegate.numExecuteExternalToolRequests != 0)
                }

                // Get a build description ID.
                let buildDescriptionID: String
                do {
                    buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: TestBuildOperationDelegate()).buildDescriptionID
                }

                // Check index request with explicit build description ID.
                do {
                    // The `generateIndexingInfo` API has very little back communication with the client, it doesn't send any notification messages other than client task construction messages.
                    // This means we cannot check whether planning occurred or not by checking notification messages. Instead we use a rather hacky way in that we change the build parameters
                    // in a way that it would force a new build description to get created, triggering client task construction messages. But when we pass an explicit build description ID then it will not
                    // create a build description and it will not send the client task construction messages, thus we verify that the explicit build description got used.
                    //
                    // Given that we intend for this API to become a very lean request with not much processing occurring, beyond querying for information of an existing build description, it doesn't seem
                    // worthy to extend it so that more notification messages are sent to the client, just for testing purposes.

                    let buildParameters = SWBBuildParameters(configuration: "Release", activeRunDestination: activeRunDestination)
                    var request = SWBBuildRequest()
                    request.add(target: SWBConfiguredTarget(guid: appTarget.guid, parameters: buildParameters))
                    request.buildDescriptionID = buildDescriptionID
                    let delegate = IndexingBuildOperationDelegate()
                    let results = try await testSession.session.generateLegacyInfo(for: request, targetID: appTarget.guid, delegate: delegate)
                    await results.checkIndexingInfo(.matchSourceFilePath(tmpDir.join("Test/TestFile1.c"))) { _ in }
                    await results.checkIndexingInfo(.matchSourceFilePath(tmpDir.join("Test/TestFile4.swift"))) { _ in }
                    await results.checkIndexingInfo(.matchSourceFilePath(tmpDir.join("Test/build/Test.build/Debug-iphoneos/App.build/DerivedSources/GeneratedAssetSymbols.swift"))) { _ in }
                    results.checkNoIndexingInfo()
                    #expect(delegate.numExecuteExternalToolRequests == 0, "client requests occurred even with explicit build request")
                }
            }
        }
    }
}

extension SWBBuildServiceSession {
    fileprivate func generateLegacyInfo(for request: SWBBuildRequest, targetID: String, filePath: String? = nil, outputPathOnly: Bool = false, delegate: (any SWBIndexingDelegate)? = nil) async throws -> IndexingInfoResults {
        let delegate = delegate ?? EmptyBuildOperationDelegate()
        let plists = try await self.generateIndexingFileSettings(for: request, targetID: targetID, filePath: filePath, outputPathOnly: outputPathOnly, delegate: delegate).sourceFileBuildInfos
        return IndexingInfoResults(plists.map { plist in
            plist.mapValues { $0.propertyListItem }
        })
    }
}
