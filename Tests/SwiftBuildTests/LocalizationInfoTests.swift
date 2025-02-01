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
import SWBTestSupport
import SwiftBuildTestSupport

import SWBUtil
import SwiftBuild

@Suite(.requireHostOS(.macOS), .requireLocalizedStringExtraction)
fileprivate struct LocalizationInfoTests {
    @Test(.requireSDKs(.macOS))
    func singleTargetMacOSAllArchs() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "NO"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 6)
                // Each Swift file should get 1 stringsdata file for x86_64 and 1 for arm64
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 2)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 2)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "x86_64")]?.filter({ $0.hasSuffix("x86_64/MyApp.stringsdata") }).count == 1)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "x86_64")]?.filter({ $0.hasSuffix("arm64/MyApp.stringsdata") }).count == 0)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "arm64")]?.filter({ $0.hasSuffix("arm64/MyApp.stringsdata") }).count == 1)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "arm64")]?.filter({ $0.hasSuffix("x86_64/MyApp.stringsdata") }).count == 0)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 2)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "x86_64")]?.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 1)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "arm64")]?.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 2)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "x86_64")]?.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "arm64")]?.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func compilerExtractionOff() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "NO",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "NO"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                // Regardless of compiler extraction being off, ExtractedAppShortcutsMetadata.stringsdata produced
                #expect(targetInfo.producedStringsdataPaths.count == 2)
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 2) // 2 archs
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 2)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "x86_64")]?.filter({ $0.hasSuffix("x86_64/ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "x86_64")]?.filter({ $0.hasSuffix("arm64/ExtractedAppShortcutsMetadata.stringsdata") }).count == 0)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "arm64")]?.filter({ $0.hasSuffix("arm64/ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
                #expect(targetInfo.stringsdataPathsByBuildPortion[.init(effectivePlatformName: "macosx", variant: "normal", architecture: "arm64")]?.filter({ $0.hasSuffix("x86_64/ExtractedAppShortcutsMetadata.stringsdata") }).count == 0)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func XCStringsNotNeedingBuilt() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "NO"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                // Return empty paths from xcstringstool compile --dryrun, which means we won't actually generate any tasks for it.
                // But we still need to detect its presence as part of the build inputs.
                let delegate = BuildOperationDelegate(returnEmpty: true)

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 6)
                // Each Swift file should get 1 stringsdata file for x86_64 and 1 for arm64
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 2)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 2)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 2)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func XCStringsInCopyFiles() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "NO",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "NO"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestCopyFilesBuildPhase([
                            "Localizable.xcstrings"
                        ], destinationSubfolder: .absolute)
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                // no xcstrings are actually going to get compiled because it's in Copy Files
                #expect(targetInfo.compilableXCStringsPaths.count == 0)

                // Regardless of compiler extraction being off, ExtractedAppShortcutsMetadata.stringsdata produced
                #expect(targetInfo.producedStringsdataPaths.count == 2)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 2)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func XCStringsNotNeedingBuiltInCopyFiles() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "NO",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "NO"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestCopyFilesBuildPhase([
                            "Localizable.xcstrings"
                        ], destinationSubfolder: .absolute)
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                // Return empty paths from xcstringstool compile --dryrun if asked, which means we won't actually generate any tasks for it.
                // But in practice we shouldn't be asked anyway because it's in Copy Files not Resources.
                let delegate = BuildOperationDelegate(returnEmpty: true)

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                // no xcstrings are actually going to get compiled because it's in Copy Files
                #expect(targetInfo.compilableXCStringsPaths.count == 0)

                // Regardless of compiler extraction being off, ExtractedAppShortcutsMetadata.stringsdata produced
                #expect(targetInfo.producedStringsdataPaths.count == 2)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 2)
            }
        }
    }

    // Let's do some correctness testing to ensure our paths properly differ based on platform, architecture, etc.

    @Test(.requireSDKs(.macOS))
    func singleTargetMacOSOnlyActiveArch() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 3)
                // Each Swift file should get 1 stringsdata for the active arch
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata")}).count == 1)
                #expect(targetInfo.producedStringsdataPaths.allSatisfy({ $0.contains("Debug/") }))
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func singleTargetIOSOnlyActiveArch() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                            "ONLY_ACTIVE_ARCH": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.iOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 3)
                // Each Swift file should get 1 stringsdata for the active arch
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.allSatisfy({ $0.contains("Debug-iphoneos/") }))
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func singleTargetIOSSimOnlyActiveArch() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                            "ONLY_ACTIVE_ARCH": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.iOSSimulator
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 3)
                // Each Swift file should get 1 stringsdata for the active arch
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.allSatisfy({ $0.contains("Debug-iphonesimulator/") }))
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func singleTargetMacCatalyst() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                            "SUPPORTS_MACCATALYST": "YES",
                            "ONLY_ACTIVE_ARCH" : "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macCatalyst
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.parameters = buildParams
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 3)
                // Each Swift file should get 1 stringsdata for the active arch
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata")}).count == 1)
                #expect(targetInfo.producedStringsdataPaths.allSatisfy({ $0.contains("Debug-maccatalyst/") }))
                #expect(targetInfo.stringsdataPathsByBuildPortion.keys.allSatisfy({ $0.effectivePlatformName == "maccatalyst" }))
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func singleTargetMultiPlatformOnlyActiveArch() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                            "ONLY_ACTIVE_ARCH": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                var runDestination = SWBRunDestinationInfo.macOS
                var buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                var delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                var info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                var targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 3)
                // Each Swift file should get 1 stringsdata for the active arch
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(targetInfo.stringsdataPathsByBuildPortion.keys.first?.effectivePlatformName == "macosx")
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.allSatisfy({ $0.contains("Debug/") }))

                runDestination = .iOS
                buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                delegate = BuildOperationDelegate()
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 3)
                // Each Swift file should get 1 stringsdata for the active arch
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(targetInfo.stringsdataPathsByBuildPortion.keys.first?.effectivePlatformName == "iphoneos")
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
                #expect(targetInfo.producedStringsdataPaths.allSatisfy({ $0.contains("Debug-iphoneos/") }))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func withSanitizer() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "NO",
                            "ENABLE_THREAD_SANITIZER": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                            "Supporting.swift"
                        ]),
                        TestResourcesBuildPhase([
                            "Localizable.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestFile("Supporting.swift"),
                                TestFile("Localizable.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("Localizable.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 6)
                // Each Swift file should get 1 stringsdata file for x86_64 and 1 for arm64
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 2)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 2)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("Supporting.stringsdata") }).count == 2)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 2)
                #expect(targetInfo.producedStringsdataPaths.allSatisfy({ $0.contains("-tsan/") }))
            }
        }
    }

    // Now ensure multi-target and target filtering workflows work.

    @Test(.requireSDKs(.macOS))
    func multiTargetMacOS() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let target1 = TestStandardTarget(
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "App.swift",
                        ]),
                        TestResourcesBuildPhase([
                            "LocalizableApp.xcstrings",
                            "Other.xcstrings"
                        ])
                    ],
                    dependencies: [
                        "MyFramework"
                    ]
                )

                let target2 = TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Framework.swift",
                        ]),
                        TestResourcesBuildPhase([
                            "LocalizableFramework.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("App.swift"),
                                TestFile("LocalizableApp.xcstrings"),
                                TestFile("Other.xcstrings"),

                                TestFile("Framework.swift"),
                                TestFile("LocalizableFramework.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target1,
                            target2
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target1.guid, parameters: buildParams))
                request.add(target: SWBConfiguredTarget(guid: target2.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 2) // 2 targets

                let target1Info = try #require(info.infoByTarget[target1.guid])
                let target2Info = try #require(info.infoByTarget[target2.guid])

                #expect(target1Info.compilableXCStringsPaths.count == 2)
                #expect(target1Info.compilableXCStringsPaths.contains(where: { $0.hasSuffix("LocalizableApp.xcstrings") }))
                #expect(target1Info.compilableXCStringsPaths.contains(where: { $0.hasSuffix("Other.xcstrings") }))

                #expect(target2Info.compilableXCStringsPaths.count == 1)
                #expect(target2Info.compilableXCStringsPaths.contains(where: { $0.hasSuffix("LocalizableFramework.xcstrings") }))

                #expect(target1Info.producedStringsdataPaths.count == 2)
                #expect(target1Info.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(target1Info.producedStringsdataPaths.filter({ $0.hasSuffix("App.stringsdata") }).count == 1)
                #expect(target1Info.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)

                #expect(target2Info.producedStringsdataPaths.count == 2)
                #expect(target2Info.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(target2Info.producedStringsdataPaths.filter({ $0.hasSuffix("Framework.stringsdata") }).count == 1)
                #expect(target2Info.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func targetFiltering() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let target1 = TestStandardTarget(
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "App.swift",
                        ]),
                        TestResourcesBuildPhase([
                            "LocalizableApp.xcstrings",
                            "Other.xcstrings"
                        ])
                    ],
                    dependencies: [
                        "MyFramework"
                    ]
                )

                let target2 = TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Framework.swift",
                        ]),
                        TestResourcesBuildPhase([
                            "LocalizableFramework.xcstrings"
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("App.swift"),
                                TestFile("LocalizableApp.xcstrings"),
                                TestFile("Other.xcstrings"),

                                TestFile("Framework.swift"),
                                TestFile("LocalizableFramework.xcstrings"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target1,
                            target2
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target1.guid, parameters: buildParams))
                request.add(target: SWBConfiguredTarget(guid: target2.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                var info = try await testSession.session.generateLocalizationInfo(for: request, targetIdentifiers: [target2.guid], delegate: delegate)

                // Only MyFramework should be included in output.
                #expect(info.infoByTarget.count == 1)

                let target2Info = try #require(info.infoByTarget[target2.guid])

                #expect(target2Info.compilableXCStringsPaths.count == 1)
                #expect(target2Info.compilableXCStringsPaths.contains(where: { $0.hasSuffix("LocalizableFramework.xcstrings") }))

                #expect(target2Info.producedStringsdataPaths.count == 2)
                #expect(target2Info.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(target2Info.producedStringsdataPaths.filter({ $0.hasSuffix("Framework.stringsdata") }).count == 1)
                #expect(target2Info.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)

                // Now ask for MyApp only.
                // This filters irrespective of dependencies, so MyFramework will not be included in the results.
                info = try await testSession.session.generateLocalizationInfo(for: request, targetIdentifiers: [target1.guid], delegate: delegate)

                // Only MyApp should be included in output.
                #expect(info.infoByTarget.count == 1)

                let target1Info = try #require(info.infoByTarget[target1.guid])

                #expect(target1Info.compilableXCStringsPaths.count == 2)
                #expect(target1Info.compilableXCStringsPaths.contains(where: { $0.hasSuffix("LocalizableApp.xcstrings") }))
                #expect(target1Info.compilableXCStringsPaths.contains(where: { $0.hasSuffix("Other.xcstrings") }))

                #expect(target1Info.producedStringsdataPaths.count == 2)
                #expect(target1Info.stringsdataPathsByBuildPortion.count == 1) // 1 arch
                #expect(target1Info.producedStringsdataPaths.filter({ $0.hasSuffix("App.stringsdata") }).count == 1)
                #expect(target1Info.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 1)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func XCStringsInVariantGroup() async throws {
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
                    "MyApp",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SKIP_INSTALL": "YES",
                            "SWIFT_VERSION": "5.5",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EMIT_LOC_STRINGS": "YES",
                            "SDKROOT": "auto",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "ONLY_ACTIVE_ARCH": "NO"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "MyApp.swift",
                        ]),
                        TestResourcesBuildPhase([
                            "MyView.xib",
                        ])
                    ]
                )

                let testWorkspace = TestWorkspace("MyWorkspace", sourceRoot: tmpDir, projects: [
                    TestProject(
                        "Project",
                        groupTree: TestGroup(
                            "ProjectSources",
                            path: "Sources",
                            children: [
                                TestFile("MyApp.swift"),
                                TestVariantGroup("MyView.xib", children: [
                                    TestFile("Base.lproj/MyView.xib", regionVariantName: "Base"),
                                    TestFile("mul.lproj/MyView.xcstrings", regionVariantName: "mul"), // mul is the ISO code for multi-lingual
                                ]),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])
                        ],
                        targets: [
                            target
                        ],
                        developmentRegion: "en"
                    )
                ])

                // Describe the workspace to the build system.
                try await testSession.sendPIF(testWorkspace)

                let runDestination = SWBRunDestinationInfo.macOS
                let buildParams = SWBBuildParameters(configuration: "Debug", activeRunDestination: runDestination)
                var request = SWBBuildRequest()
                request.add(target: SWBConfiguredTarget(guid: target.guid, parameters: buildParams))

                let delegate = BuildOperationDelegate()

                // Now run a build (plan only)
                request.buildDescriptionID = try await testSession.runBuildDescriptionCreationOperation(request: request, delegate: delegate).buildDescriptionID

                let info = try await testSession.session.generateLocalizationInfo(for: request, delegate: delegate)

                #expect(info.infoByTarget.count == 1) // 1 target

                let targetInfo = try #require(info.infoByTarget[target.guid])

                #expect(targetInfo.compilableXCStringsPaths.count == 1)
                #expect(targetInfo.compilableXCStringsPaths.first?.hasSuffix("mul.lproj/MyView.xcstrings") ?? false)

                #expect(targetInfo.producedStringsdataPaths.count == 4)
                // Swift file should get 1 stringsdata file for x86_64 and 1 for arm64
                #expect(targetInfo.stringsdataPathsByBuildPortion.count == 2) // 2 archs
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("MyApp.stringsdata") }).count == 2)
                #expect(targetInfo.producedStringsdataPaths.filter({ $0.hasSuffix("ExtractedAppShortcutsMetadata.stringsdata") }).count == 2)
            }
        }
    }
}

private final class BuildOperationDelegate: SWBLocalizationDelegate {
    private let delegate = TestBuildOperationDelegate()
    private let returnEmpty: Bool

    init(returnEmpty: Bool = false) {
        self.returnEmpty = returnEmpty
    }

    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
        return await delegate.provisioningTaskInputs(targetGUID: targetGUID, provisioningSourceData: provisioningSourceData)
    }

    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> SWBExternalToolResult {
        guard let command = commandLine.first, command.hasSuffix("xcstringstool") else {
            return .deferred
        }

        guard !returnEmpty else {
            // We were asked to return empty, simulating an xcstrings file that does not need to build at all.
            return .result(status: .exit(0), stdout: Data(), stderr: Data())
        }

        // We need to intercept and handle xcstringstool compile --dry-run commands.
        // These tests are not testing the XCStringsCompiler, we just need to produce something so the build plan doesn't fail.
        // So we'll just produce a single same-named .strings file.

        // Last arg is input.
        guard let inputPath = commandLine.last.map(Path.init) else {
            return .result(status: .exit(1), stdout: Data(), stderr: "Couldn't find input file in command line.".data(using: .utf8)!)
        }

        // Second to last arg is output directory.
        guard let outputDir = commandLine[safe: commandLine.endIndex - 2].map(Path.init) else {
            return .result(status: .exit(1), stdout: Data(), stderr: "Couldn't find output directory in command line.".data(using: .utf8)!)
        }

        let output = outputDir.join("en.lproj/\(inputPath.basenameWithoutSuffix).strings")

        return .result(status: .exit(0), stdout: Data(output.str.utf8), stderr: Data())
    }
}
