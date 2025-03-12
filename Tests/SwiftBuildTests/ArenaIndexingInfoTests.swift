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
import SWBUtil

// These tests use the new model of enabling `enableIndexBuildArena` in the build request, along with passing a build description ID.
@Suite
struct ArenaIndexingInfoTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func indexInfoForMultiPlatformTargets() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

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

                let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
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
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                                ])],
                        targets: [
                            macApp,
                            fwkTarget_mac,
                            fwkTarget_ios,
                        ])
                ])

                let infoProducer = try await IndexInfoProducer(testWorkspace, testSession: testSession)
                do {
                    let info = try await IndexingInfoResults(infoProducer.generateIndexingInfo(fwkTarget_mac, .macOS))
                    await info.checkIndexingInfo { info in
                        info.clang.checkCommandLineMatches(["-target", .prefix("x86_64-apple-macos")])
                    }
                    info.checkNoIndexingInfo()
                }
                do {
                    let info = try await IndexingInfoResults(infoProducer.generateIndexingInfo(fwkTarget_mac, .iOS))
                    await info.checkIndexingInfo { info in
                        info.clang.checkCommandLineMatches(["-target", .prefix("x86_64-apple-macos")])
                    }
                    info.checkNoIndexingInfo()
                }
                do {
                    let info = try await IndexingInfoResults(infoProducer.generateIndexingInfo(fwkTarget_ios, .iOS))
                    await info.checkIndexingInfo { info in
                        info.clang.checkCommandLineMatches(["-target", .prefix("arm64-apple-ios")])
                    }
                    info.checkNoIndexingInfo()
                }
                do {
                    let info = try await IndexingInfoResults(infoProducer.generateIndexingInfo(fwkTarget_ios, .iOSSimulator))
                    await info.checkIndexingInfo { info in
                        info.clang.checkCommandLineMatches(["-target", .prefix("x86_64-apple-ios")])
                    }
                    info.checkNoIndexingInfo()
                }
                do {
                    let info = try await IndexingInfoResults(infoProducer.generateIndexingInfo(fwkTarget_ios, .macOS))
                    await info.checkIndexingInfo { info in
                        info.clang.checkCommandLineMatches(["-target", .prefix("x86_64-apple-ios")])
                    }
                    info.checkNoIndexingInfo()
                }
                do {
                    let info = try await IndexingInfoResults(infoProducer.generateIndexingInfo(fwkTarget_ios, .macCatalyst))
                    await info.checkIndexingInfo { info in
                        info.clang.checkCommandLineMatches(["-target", .suffix("-macabi")])
                    }
                    info.checkNoIndexingInfo()
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func buildDescriptionTargetInfo() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

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

                let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
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
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                                ])],
                        targets: [
                            macApp,
                            fwkTarget_mac,
                            fwkTarget_ios,
                        ])
                ])

                let infoProducer = try await IndexInfoProducer(testWorkspace, testSession: testSession, targets: [macApp])
                let buildDescInfo = try await infoProducer.generateBuildDescriptionTargetInfo(.macOS)
                #expect(buildDescInfo.targetGUIDs.sorted() == [fwkTarget_mac.guid, macApp.guid])
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func useBuildDescriptionAfterPIFChange() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let appTarget1 = TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "iphoneos",
                                                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
                                               ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])
                    ])
                let testWorkspace1 = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [ TestFile("main.c") ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                                ])],
                        targets: [
                            appTarget1,
                        ])
                ])

                let SRCROOT = testWorkspace1.sourceRoot.join("aProject")
                try await localFS.writeFileContents(SRCROOT.join("main.c")) { contents in
                    contents <<< "int main(){}\n"
                }

                // Get index info settings and prepare result.

                let infoProducer = try await IndexInfoProducer(testWorkspace1, testSession: testSession)
                let indexInfo1 = try await infoProducer.generateIndexingInfo(appTarget1, .macOS)

                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters(action: "indexbuild", configuration: "Debug")
                request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: [appTarget1.guid], enableIndexBuildArena: true)
                request.buildDescriptionID = infoProducer.indexBuildDescriptionID

                let prepareResult1: SwiftBuildMessage.PreparedForIndexInfo
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let events = try await operation.start()
                    var preparedForIndexInfos: [SwiftBuildMessage.PreparedForIndexInfo] = []
                    for await event in events {
                        if case let .preparedForIndex(message) = event {
                            preparedForIndexInfos.append(message)
                        }
                    }
                    prepareResult1 = try #require(preparedForIndexInfos.only)
                    #expect(prepareResult1.targetGUID == appTarget1.guid)
                    await operation.waitForCompletion()
                }

                // Simulate adding a file to the existing target and send new PIF data.

                let appTarget2 = TestStandardTarget(
                    "AppTarget",
                    guid: appTarget1.guid,
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug")
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c", "second.c"])
                    ])
                let testWorkspace2 = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [ TestFile("main.c"), TestFile("second.c") ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                                ])],
                        targets: [
                            appTarget2,
                        ])
                ])

                try await localFS.writeFileContents(SRCROOT.join("second.c")) { contents in
                    contents <<< ""
                }
                try await testSession.sendPIF(testWorkspace2)

                // Get index info settings and prepare result from the same build description.

                let indexInfo2 = try await infoProducer.generateIndexingInfo(appTarget1, .macOS)
                let prepareResult2: SwiftBuildMessage.PreparedForIndexInfo
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let events = try await operation.start()
                    var preparedForIndexInfos: [SwiftBuildMessage.PreparedForIndexInfo] = []
                    for await event in events {
                        if case let .preparedForIndex(message) = event {
                            preparedForIndexInfos.append(message)
                        }
                    }
                    prepareResult2 = try #require(preparedForIndexInfos.only)
                    #expect(prepareResult2.targetGUID == appTarget1.guid)
                    await operation.waitForCompletion()
                }

                // Check that we still got the same results from the same build description.

                let indexInfoStr1 = try PropertyListItem.plArray(indexInfo1.map { .plDict($0) }).asJSONFragment().stringValue
                let indexInfoStr2 = try PropertyListItem.plArray(indexInfo2.map { .plDict($0) }).asJSONFragment().stringValue
                #expect(indexInfoStr1 == indexInfoStr2)
                #expect(prepareResult1.targetGUID == prepareResult2.targetGUID)
                #expect(prepareResult1.targetGUID == prepareResult2.targetGUID)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func fixFor23297285DisabledForIndexBuild() async throws {
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
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug")
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([ "main.swift" ])
                    ])

                let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [ TestFile("main.swift") ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                                    "SWIFT_INCLUDE_PATHS": "/tmp/some-dir",
                                ])],
                        targets: [
                            appTarget,
                        ])
                ])

                let infoProducer = try await IndexInfoProducer(testWorkspace, testSession: testSession)
                let info = try await IndexingInfoResults(infoProducer.generateIndexingInfo(appTarget, .macOS))
                await info.checkIndexingInfo { info in
                    info.checkLanguageDialect("swift")
                    info.swift.checkCommandLineNoMatch(["-Xcc", "-I"])
                }
                info.checkNoIndexingInfo()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func indexOutputUnitPathModifiesOutputInfo() async throws {
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
                    "AppTarget",
                    guid: "Foo",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug")
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "f1.swift",
                            "f2.m"
                        ])
                    ])

                let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("f1.swift"),
                                TestFile("f2.m"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "COMPILER_INDEX_STORE_ENABLE": "YES",
                                ])],
                        targets: [
                            appTarget,
                        ])
                ])

                let projectDir = tmpDir.join("aProject")
                let infoProducer = try await IndexInfoProducer(testWorkspace, testSession: testSession)

                let swiftInfo = try await IndexingInfoResults(infoProducer.generateIndexingInfo(appTarget, .macOS, filePath: projectDir.join("f1.swift").str))
                await swiftInfo.checkIndexingInfo { info in
                    info.checkOutputFilePath(Path("/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/f1.o"))
                }

                let clangInfo = try await IndexingInfoResults(infoProducer.generateIndexingInfo(appTarget, .macOS, filePath: projectDir.join("f2.m").str))
                await clangInfo.checkIndexingInfo { info in
                    info.checkOutputFilePath(Path("/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/f2.o"))
                }
            }
        }
    }

    /// Check that we remove unwanted Swift/Clang args for indexing and that any supplementary args are also added.
    @Test(.requireSDKs(.macOS))
    func argsCleaned() async throws {
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
                    "Foo", guid: "Foo", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
                                "SWIFT_INSTALL_OBJC_HEADER": "YES",
                            ]
                        )
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "foo.m",
                            "bar.swift",
                        ])
                    ])

                let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Files",
                            children: [
                                TestFile("foo.m"),
                                TestFile("bar.swift"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])
                        ],
                        targets: [
                            target
                        ])
                ])

                let projectDir = tmpDir.join("aProject")
                let infoProducer = try await IndexInfoProducer(testWorkspace, testSession: testSession)

                let fooInfo = try await IndexingInfoResults(infoProducer.generateIndexingInfo(target, .macOS, filePath: projectDir.join("foo.m").str))
                await fooInfo.checkIndexingInfo { info in
                    info.clang.checkCommandLineMatches(["-fretain-comments-from-system-headers"])
                    info.clang.checkCommandLineNoMatch(["--serialize-diagnostics"])
                }

                let barInfo = try await IndexingInfoResults(infoProducer.generateIndexingInfo(target, .macOS, filePath: projectDir.join("bar.swift").str))
                await barInfo.checkIndexingInfo { info in
                    info.swift.checkCommandLineMatches(["-Xcc", "-fretain-comments-from-system-headers"])
                    info.swift.checkCommandLineNoMatch(["-experimental-skip-all-function-bodies"])
                    info.swift.checkCommandLineNoMatch(["-num-threads"])
                    info.swift.checkCommandLineNoMatch(["-emit-module"])
                    info.swift.checkCommandLineNoMatch(["-emit-module-path"])
                    info.swift.checkCommandLineNoMatch(["-emit-module-interface"])
                    info.swift.checkCommandLineNoMatch(["-emit-module-interface-path"])
                    info.swift.checkCommandLineNoMatch(["-emit-private-module-interface-path"])
                    info.swift.checkCommandLineNoMatch(["-emit-objc-header"])
                    info.swift.checkCommandLineNoMatch(["-emit-objc-header-path"])
                }
            }
        }
    }

    /// The arena precompiles the PCH as part of the prepare, check we don't generate the extra `prefixInfo`.
    @Test(.requireSDKs(.macOS))
    func precompiledPCH() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let precompiledPCHTarget = TestStandardTarget(
                    "Foo", guid: "Foo", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GCC_PREFIX_HEADER": "prefix.h",
                                "GCC_PRECOMPILE_PREFIX_HEADER": "YES"
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "foo.c",
                        ])
                    ])

                let regularTarget = TestStandardTarget(
                    "Bar", guid: "Bar", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GCC_PREFIX_HEADER": "prefix.h"
                            ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "foo.c",
                        ])
                    ])

                let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Files",
                            children: [
                                TestFile("foo.c"),
                                TestFile("prefix.h"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])
                        ],
                        targets: [
                            precompiledPCHTarget, regularTarget
                        ])
                ])

                let projectDir = tmpDir.join("aProject")
                let infoProducer = try await IndexInfoProducer(testWorkspace, testSession: testSession)

                let precompiledInfo = try await IndexingInfoResults(infoProducer.generateIndexingInfo(precompiledPCHTarget, .macOS, filePath: projectDir.join("foo.c").str))
                await precompiledInfo.checkIndexingInfo { info in
                    // PCH should be remapped to the original prefix header and we should have
                    // the input/output PCH info
                    info.clang.checkCommandLineMatches([.equal("-include"), .suffix("prefix.h")])
                    info.clang.checkCommandLineNoMatch([.contains("SharedPrecompiledHeaders")])
                    info.checkPrefixHeaderPath(.suffix("prefix.h"))
                    info.checkPrecompiledHeaderPath(.suffix("prefix.h.gch"))

                    info.clangPrecompiledHeader.checkCommandLineDoesNotContain("-fsyntax-only")
                    info.clangPrecompiledHeader.checkCommandLineDoesNotContain("--serialize-diagnostics")
                    info.clangPrecompiledHeader.checkCommandLineMatches([.suffix("prefix.h.gch")])
                    info.clangPrecompiledHeader.checkCommandLineMatches([.equal("-fretain-comments-from-system-headers")])
                }

                let regularInfo = try await IndexingInfoResults(infoProducer.generateIndexingInfo(regularTarget, .macOS, filePath: projectDir.join("foo.c").str))
                await regularInfo.checkIndexingInfo { info in
                    // Should be no precompiled header info
                    info.clang.checkCommandLineMatches([.equal("-include"), .suffix("prefix.h")])
                    info.clang.checkCommandLineNoMatch([.contains("SharedPrecompiledHeaders")])
                    info.checkPrecompiledHeaderPath(nil)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func quotedPreprocessor() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                            try await testSession.close()
                        }
                }

                let quotedTarget = TestStandardTarget(
                    "quotedTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GCC_PREPROCESSOR_DEFINITIONS": #"SOME_DEFINE=\"Some:\ Super\ \\\ Name\'s\""#,
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"]),
                    ])

                let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
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
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])
                        ],
                        targets: [
                            quotedTarget,
                        ])
                ])

                let projectDir = tmpDir.join("aProject")
                let infoProducer = try await IndexInfoProducer(testWorkspace, testSession: testSession)

                let quotedInfo = try await IndexingInfoResults(infoProducer.generateIndexingInfo(quotedTarget, .macOS, filePath: projectDir.join("main.c").str))
                await quotedInfo.checkIndexingInfo { info in
                    info.clang.checkCommandLineContains([#"-DSOME_DEFINE="Some: Super \ Name's""#])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func indexingInfoInvokeClangCommandLine() async throws {
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
                    "quotedTarget",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"]),
                    ])

                let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
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
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])
                        ],
                        targets: [
                            target
                        ])
                ])

                let projectDir = tmpDir.join("aProject")

                try await localFS.writeFileContents(projectDir.join("main.c")) { contents in
                    contents <<< "int foo(void) { return 42; }"
                }

                let infoProducer = try await IndexInfoProducer(testWorkspace, testSession: testSession)

                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters(action: "indexbuild", configuration: "Debug")
                request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: [target.guid], enableIndexBuildArena: true)
                request.buildDescriptionID = infoProducer.indexBuildDescriptionID

                let prepareResult: SwiftBuildMessage.PreparedForIndexInfo
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let events = try await operation.start()
                    var preparedForIndexInfos: [SwiftBuildMessage.PreparedForIndexInfo] = []
                    for await event in events {
                        if case let .preparedForIndex(message) = event {
                            preparedForIndexInfos.append(message)
                        }
                    }
                    prepareResult = try #require(preparedForIndexInfos.only)
                    #expect(prepareResult.targetGUID == target.guid)
                    await operation.waitForCompletion()
                }

                let info = try await IndexingInfoResults(infoProducer.generateIndexingInfo(target, .macOS, filePath: projectDir.join("main.c").str))
                await info.checkIndexingInfo { info in
                    do {
                        // We should be able to successfully run the resulting command line from indexing info
                        let success = try await Process.run(url: URL(fileURLWithPath: clangCompilerPath.str), arguments: info.clang.commandLineAsByteStrings.map { $0.asString }).isSuccess
                        #expect(success)
                    } catch {
                        Issue.record("failed to run command returned as clang indexing info")
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func indexingInfoInvokeSwiftCommandLine() async throws {
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
                    "quotedTarget",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                    ])

                let testWorkspace = try await TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Files",
                            children: [
                                TestFile("main.swift"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion
                                ])
                        ],
                        targets: [
                            target
                        ])
                ])

                let projectDir = tmpDir.join("aProject")

                try await localFS.writeFileContents(projectDir.join("main.swift")) { contents in
                    contents <<< "func foo() -> Int { 42 }"
                }

                let infoProducer = try await IndexInfoProducer(testWorkspace, testSession: testSession)

                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters(action: "indexbuild", configuration: "Debug")
                request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: [target.guid], enableIndexBuildArena: true)
                request.buildDescriptionID = infoProducer.indexBuildDescriptionID

                let prepareResult: SwiftBuildMessage.PreparedForIndexInfo
                do {
                    let operation = try await testSession.session.createBuildOperation(request: request, delegate: TestBuildOperationDelegate())
                    let events = try await operation.start()
                    var preparedForIndexInfos: [SwiftBuildMessage.PreparedForIndexInfo] = []
                    for await event in events {
                        if case let .preparedForIndex(message) = event {
                            preparedForIndexInfos.append(message)
                        }
                    }
                    prepareResult = try #require(preparedForIndexInfos.only)
                    #expect(prepareResult.targetGUID == target.guid)
                    await operation.waitForCompletion()
                }

                let info = try await IndexingInfoResults(infoProducer.generateIndexingInfo(target, .macOS, filePath: projectDir.join("main.swift").str))
                await info.checkIndexingInfo { info in
                    do {
                        // We should be able to successfully run the resulting command line from indexing info
                        let success = try await Process.run(url: URL(fileURLWithPath: swiftCompilerPath.str), arguments: info.swift.commandLineAsByteStrings.map { $0.asString }).isSuccess
                        #expect(success)
                    } catch {
                        Issue.record("failed to run command returned as clang indexing info")
                    }
                }
            }
        }
    }
}

/// Get a build description ID.
func createIndexBuildDescription(_ workspace: TestWorkspace, session: TestSWBSession, targets: [any TestTarget]? = nil) async throws -> String {
    let buildParameters = SWBBuildParameters(action: "indexbuild", configuration: "Debug", overrides: ["ONLY_ACTIVE_ARCH": "YES"])
    var request = SWBBuildRequest()
    if let targets {
        request.configuredTargets = targets.map{ SWBConfiguredTarget(guid: $0.guid, parameters: buildParameters) }
    } else {
        request.configuredTargets = workspace.projects.flatMap{ $0.targets.map{ SWBConfiguredTarget(guid: $0.guid, parameters: buildParameters) } }
    }
    request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: true)
    request.parameters = buildParameters
    request.useParallelTargets = true
    request.useImplicitDependencies = true
    return try await session.runBuildDescriptionCreationOperation(request: request, delegate: TestBuildOperationDelegate()).buildDescriptionID
}

fileprivate struct IndexInfoProducer {
    private let testSession: TestSWBSession
    let indexBuildDescriptionID: String

    init(_ workspace: TestWorkspace, testSession: TestSWBSession, targets: [any TestTarget]? = nil) async throws {
        try await testSession.sendPIF(workspace)
        self.testSession = testSession
        self.indexBuildDescriptionID = try await createIndexBuildDescription(workspace, session: testSession, targets: targets)
    }

    func generateIndexingInfo(_ target: any TestTarget, _ runDestination: SWBRunDestinationInfo, filePath: String? = nil, outputPathOnly: Bool = false) async throws -> [[String: PropertyListItem]] {
        let request = createIndexPrepareRequest(runDestination)
        let delegate = EmptyBuildOperationDelegate()

        let plists = try await testSession.session.generateIndexingFileSettings(for: request, targetID: target.guid, filePath: filePath, outputPathOnly: outputPathOnly, delegate: delegate).sourceFileBuildInfos
        return plists.map { plist in
            plist.mapValues { $0.propertyListItem }
        }
    }

    func generateBuildDescriptionTargetInfo(_ runDestination: SWBRunDestinationInfo) async throws -> SWBBuildDescriptionTargetInfo {
        return try await testSession.session.generateBuildDescriptionTargetInfo(for: createIndexPrepareRequest(runDestination))
    }

    private func createIndexPrepareRequest(_ runDestination: SWBRunDestinationInfo) -> SWBBuildRequest {
        var request = SWBBuildRequest()
        request.buildCommand = .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: true)
        request.parameters = SWBBuildParameters(action: "indexbuild", configuration: "Debug", activeRunDestination: runDestination)
        request.buildDescriptionID = indexBuildDescriptionID
        return request
    }
}
