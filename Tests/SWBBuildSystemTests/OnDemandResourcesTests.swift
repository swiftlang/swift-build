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

import struct Foundation.Date

import Testing

import SWBLibc
import SWBBuildSystem
import SWBCore
import SWBTestSupport
import SWBTaskConstruction
import SWBTaskExecution
import SWBUtil
import SWBMacro

private extension AssetPackManifestPlist.Resource.PrimaryContentHash {
    var modtimeValue: Date {
        switch self {
        case .modtime(let d): return d
        }
    }
}

/// Just enough of an asset catalog model to support ODR tests
private struct TestAssetCatalog {
    struct Entry {
        var bytes: ByteString
        var assetTags: ODRTagSet

        func write(_ fs: any FSProxy, _ path: Path) async throws {
            if fs.exists(path) { try fs.removeDirectory(path) }
            try fs.createDirectory(path)

            try await fs.writeJSON(path.join("Contents.json"), [
                "info": ["version": 1, "author": "xcode"] as PropertyListItem,
                "data": [
                    [
                        "idiom": "universal",
                        "filename": "x",
                        "universal-type-identifier": "public.data",
                    ],
                ],
                "properties": [
                    "on-demand-resource-tags": assetTags.sorted(),
                ],
            ])

            try fs.write(path.join("x"), contents: bytes)
        }
    }

    var entries: [String: Entry]

    func write(_ fs: any FSProxy, _ path: Path) async throws {
        if fs.exists(path) { try fs.removeDirectory(path) }
        try fs.createDirectory(path)
        try await fs.writeJSON(path.join("Contents.json"), ["info": ["version": 1, "author": "xcode"] as PropertyListItem])

        for (name, entry) in entries {
            let entryPath = path.join(name + ".dataset")
            try await entry.write(fs, entryPath)
        }
    }
}

private extension AssetPackManifestPlist {
    init(_ plist: PropertyListItem) throws {
        guard let array = plist.dictValue?["resources"]?.arrayValue else {
            throw StubError.error("expected {\"resources\": [...]} in \(plist)")
        }

        try self.init(resources: Set(array.map { itemPlist in
            guard let item = itemPlist.dictValue else { throw StubError.error("expected dictionary in \(itemPlist)") }

            guard let identifier = item["bundleKey"]?.stringValue else { throw StubError.error("expected bundleKey String in \(item)") }
            guard let isStreamable = item["isStreamable"]?.boolValue else { throw StubError.error("expected isStreamable Bool in \(item)") }
            guard let url = item["URL"]?.stringValue else { throw StubError.error("expected URL String in \(item)") }

            let priority: Double?
            if let priorityItem = item["downloadPriority"] {
                guard let p = priorityItem.floatValue else { throw StubError.error("expected downloadPriority Double in \(item)") }
                priority = p
            }
            else {
                priority = nil
            }

            guard let uncompressedSize = item["uncompressedSize"]?.intValue else { throw StubError.error("expected uncompressedSize Int in \(item)") }

            guard let contentHash = item["primaryContentHash"]?.dictValue else { throw StubError.error("expected primaryContentHash Dictionary in \(item)") }
            guard let contentHashStrategy = contentHash["strategy"]?.stringValue else { throw StubError.error("expected strategy String in \(contentHash)") }
            guard contentHashStrategy == "modtime" else { throw StubError.error("expected modtime in \(contentHashStrategy)") }

            guard let modDateString = contentHash["hash"]?.stringValue else { throw StubError.error("expected hash String in \(contentHash)") }
            guard let parsedDate = try? AssetPackManifestPlist.Resource.PrimaryContentHash.modtimeFormatStyle.parse(modDateString) else { throw StubError.error("failed to parse date from \(modDateString)") }

            return AssetPackManifestPlist.Resource(assetPackBundleIdentifier: identifier, isStreamable: isStreamable, primaryContentHash: AssetPackManifestPlist.Resource.PrimaryContentHash.modtime(parsedDate), uncompressedSize: uncompressedSize, url: url, downloadPriority: priority)
        }))
    }
}

// Some of these tests could live in in lower-layered test targets, but on the other hand there's value in having all the tests for the feature in one place. TODO discuss.
@Suite
fileprivate struct OnDemandResourcesTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func oDRAssetPackInfo() async throws {
        // Want to exceed the filename limit
        let tags = Set([
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa2",
        ])

        let emptyScope = MacroEvaluationScope(table: MacroValueAssignmentTable(namespace: BuiltinMacros.namespace))
        let info = ODRAssetPackInfo(tags: tags, priority: nil, productBundleIdentifier: "Bundle", emptyScope)
        #expect(info.identifier == "Bundle.asset-pack-3ed1a57b39f299b9e527b6a274381186")
        #expect(info.path.basename == "Bundle.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0+aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1+aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-3ed1a57b39f299b9e527b6a274381186.assetpack")
    }

    /// Checks that we're correctly formatting plists which external tools need to consume
    @Test(.requireSDKs(.macOS))
    func onDemandResourcesPlist() async throws {
        let assetPacks = [
            ODRAssetPackInfo(identifier: "a0i", tags: Set(["t0", "t1"]), path: Path("/tmp/a0.assetpack"), priority: nil),
            ODRAssetPackInfo(identifier: "a1i", tags: Set(["t1"]), path: Path("/tmp/a1.assetpack"), priority: 3),
        ]

        let subPaths = [
            "a0i": Set(["x", "y"]),
            "a1i": Set([]),
        ]

        let model = OnDemandResourcesPlist(assetPacks, subPaths: subPaths)

        let expected: PropertyListItem = [
            "NSBundleResourceRequestTags": [
                "t0": [ "NSAssetPacks": ["a0i"] ],
                "t1": [ "NSAssetPacks": ["a0i", "a1i"] ],
            ],
            "NSBundleResourceRequestAssetPacks": [
                "a0i": ["x", "y"],
            ],
        ]

        #expect(model.propertyListItem == expected)
    }

    /// Checks that we're correctly formatting plists which external tools need to consume
    @Test(.requireSDKs(.macOS))
    func assetPackManifestPlist() async throws {
        let date0 = Date(timeIntervalSince1970: 0)
        let date1 = Date(timeIntervalSince1970: 60*60)

        let resources = [
            AssetPackManifestPlist.Resource(assetPackBundleIdentifier: "a0i", isStreamable: true, primaryContentHash: .modtime(date0), uncompressedSize: 1, url: "http://test=a0i", downloadPriority: nil),
            AssetPackManifestPlist.Resource(assetPackBundleIdentifier: "a1i", isStreamable: false, primaryContentHash: .modtime(date1), uncompressedSize: 2, url: "http://test=a1i", downloadPriority: 0.5),
        ]

        let model = AssetPackManifestPlist(resources: Set(resources))

        let expected: PropertyListItem = [
            "resources": [
                [
                    "URL": "http://test=a0i",
                    "bundleKey": "a0i",
                    "isStreamable": true,
                    "primaryContentHash": [
                        "hash": "1970-01-01T00:00:00.000Z",
                        "strategy": "modtime",
                    ],
                    "uncompressedSize": 1,
                ] as [String: PropertyListItem],
                [
                    "URL": "http://test=a1i",
                    "bundleKey": "a1i",
                    "isStreamable": false,
                    "primaryContentHash": [
                        "hash": "1970-01-01T01:00:00.000Z",
                        "strategy": "modtime",
                    ],
                    "uncompressedSize": 2,
                    "downloadPriority": 0.5,
                ] as [String: PropertyListItem],
            ],
        ]

        #expect(model.propertyListItem == expected)

        let modelParsed = try AssetPackManifestPlist(expected)
        #expect(model == modelParsed)
    }

    /// Checks that we're correctly formatting plists which external tools need to consume
    @Test(.requireSDKs(.macOS))
    func assetPackOutputSpecificationsPlist() async throws {
        let assetPacks = [
            ODRAssetPackInfo(identifier: "a0i", tags: Set(["t0", "t1"]), path: Path("/tmp/a0.assetpack"), priority: nil),
            ODRAssetPackInfo(identifier: "a1i", tags: Set(["t1"]), path: Path("/tmp/a1.assetpack"), priority: 3),
        ]

        let model = AssetPackOutputSpecificationsPlist(assetPacks: assetPacks)

        let expected: PropertyListItem = [
            [
                "bundle-id": "a0i",
                "bundle-path": "/tmp/a0.assetpack",
                "tags": [ "t0", "t1" ],
            ] as [String: PropertyListItem],
            [
                "bundle-id": "a1i",
                "bundle-path": "/tmp/a1.assetpack",
                "tags": [ "t1" ],
            ] as [String: PropertyListItem],
        ]

        #expect(model.propertyListItem == expected)
    }

    @Test(.requireSDKs(.iOS))
    func onDemandResourcesErrors() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("A.dat"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                            "PRODUCT_BUNDLE_IDENTIFIER": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "WRAP_ASSET_PACKS_IN_SEPARATE_DIRECTORIES": "YES",
                            "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("A.dat", assetTags: Set(["foo"])),
                            ]),
                        ],
                        dependencies: ["Framework"]),
                    TestStandardTarget("Framework", type: .framework),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false, continueBuildingAfterErrors: false)
            let provisioningInputs = [
                "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]

            // ODR is by default enabled on the app product type. If we enable it universally, we expect to see an error because the framework target should not support ODR.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["ENABLE_ON_DEMAND_RESOURCES": "YES"]), runDestination: .iOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkError(.equal("On-Demand Resources is enabled (ENABLE_ON_DEMAND_RESOURCES = YES), but the PRODUCT_BUNDLE_IDENTIFIER build setting is empty (in target \'App\' from project 'aProject')"))
                results.checkError(.equal("WRAP_ASSET_PACKS_IN_SEPARATE_DIRECTORIES=YES is not supported (in target \'App\' from project 'aProject')"))
                results.checkError(.equal("On-Demand Resources is enabled (ENABLE_ON_DEMAND_RESOURCES = YES), but is not supported for framework targets (in target \'Framework\' from project 'aProject')"))
                results.checkNoDiagnostics()
            }
        }
    }

    /// If ODR is disabled, we should ignore tags on assets
    @Test(.requireSDKs(.iOS))
    func onDemandResourcesDisabled() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("A.dat"),
                        TestFile("Assets.xcassets"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.company.$(TARGET_NAME)",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
                            "CODESIGN": "/usr/bin/true", // we use "Apple Development" identity, so this test will never succeed with the real codesign
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("A.dat", assetTags: Set(["foo"])),
                                "Assets.xcassets",
                            ]),
                        ]),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs

            try fs.createDirectory(srcRoot.join("Sources"), recursive: true)
            try fs.write(srcRoot.join("Sources/A.dat"), contents: ByteString([0]))
            try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
            try fs.write(srcRoot.join("App.entitlements"), contents: "")

            let assetCatalogPath = srcRoot.join("Sources/Assets.xcassets")
            let assetCatalog0 = TestAssetCatalog(entries: [
                "acA": TestAssetCatalog.Entry(bytes: ByteString([0]), assetTags: Set(["foo"])),
            ])
            try await assetCatalog0.write(fs, assetCatalogPath)

            let provisioningInputs = [
                "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["ENABLE_ON_DEMAND_RESOURCES": "NO"]), runDestination: .iOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchRule(["CpResource", srcRoot.join("build/Debug-iphoneos/App.app/A.dat").str, srcRoot.join("Sources/A.dat").str])) { _ in }
                results.checkTask(.matchRule(["CompileAssetCatalogVariant", "thinned", srcRoot.join("build/Debug-iphoneos/App.app").str, srcRoot.join("Sources/Assets.xcassets").str])) { task in
                    // should not contain outputs plist arg
                    task.checkCommandLineMatches([.anySequence, .equal("--enable-on-demand-resources"), .equal("NO"), .anySequence])
                    #expect(!task.commandLineAsStrings.contains("--asset-pack-output-specifications"))
                }

                #expect(!fs.exists(srcRoot.join("build/Debug-iphoneos/OnDemandResources")))
            }
        }
    }

    // MARK: Utility methods for testing ODR functionality


    /// Create a test project and return a tester for that project.
    private func createODRProjectAndTester(_ srcRoot: Path) async throws -> BuildOperationTester {
        let testProject = TestProject(
            "aProject",
            sourceRoot: srcRoot,
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("A.dat"),
                    TestFile("B.dat"),
                    TestFile("de.lproj/C.dat", regionVariantName: "de"),
                    TestFile("Assets.xcassets"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "INFOPLIST_FILE": "Info.plist",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.company.$(TARGET_NAME)",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "ON_DEMAND_RESOURCES_INITIAL_INSTALL_TAGS": "foo",
                        "ON_DEMAND_RESOURCES_PREFETCH_ORDER": "baz",
                        "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
                        "CODESIGN": "/usr/bin/true", // we use "Apple Development" identity, so this test will never succeed with the real codesign
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestResourcesBuildPhase([
                            TestBuildFile("A.dat", assetTags: Set(["foo"])),
                            TestBuildFile("B.dat", assetTags: Set(["foo"])),
                            TestBuildFile("de.lproj/C.dat", assetTags: Set(["foo", "bar"])),
                            "Assets.xcassets",
                        ]),
                    ]),
            ])

        let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
        let fs = tester.fs

        try fs.createDirectory(srcRoot.join("Sources"), recursive: true)
        try fs.write(srcRoot.join("Sources/A.dat"), contents: ByteString([0]))
        try fs.write(srcRoot.join("Sources/B.dat"), contents: ByteString([0]))
        try fs.createDirectory(srcRoot.join("Sources/de.lproj"), recursive: true)
        try fs.write(srcRoot.join("Sources/de.lproj/C.dat"), contents: ByteString([0]))

        try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
        try fs.write(srcRoot.join("App.entitlements"), contents: "")

        let assetCatalogPath = srcRoot.join("Sources/Assets.xcassets")
        let assetCatalog0 = TestAssetCatalog(entries: [
            "acA": TestAssetCatalog.Entry(bytes: ByteString([0]), assetTags: Set(["foo"])),
            "acB": TestAssetCatalog.Entry(bytes: ByteString([0]), assetTags: Set(["foo", "bar"])),
            "acC": TestAssetCatalog.Entry(bytes: ByteString([0]), assetTags: Set(["baz"])),
        ])
        try await assetCatalog0.write(fs, assetCatalogPath)

        return tester
    }

    // MARK: ODR functionality tests

    /// Test the basic ODR functionality when building for an iOS device.
    @Test(.requireSDKs(.iOS))
    func onDemandResourcesBasics() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            // Create the project and tester to use.
            let tester = try await createODRProjectAndTester(srcRoot)
            let fs = tester.fs

            func auxFileTaskContents(_ task: Task) throws -> ByteString {
                precondition(task.ruleInfo.first == "WriteAuxiliaryFile")
                precondition(task.ruleInfo.count == 2)
                let path = Path(task.ruleInfo[1])
                return try fs.read(path)
            }

            let assetPackFoo = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-acbd18db4cc2f85cedef654fccc4a4d8", tags: Set(["foo"]), path: srcRoot.join("build/Debug-iphoneos/OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack"), priority: 1)
            let assetPackBarFoo = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-8856328b99ee7881e9bf7205296e056d", tags: Set(["foo", "bar"]), path: srcRoot.join("build/Debug-iphoneos/OnDemandResources/com.company.App.bar+foo-8856328b99ee7881e9bf7205296e056d.assetpack"), priority: 1)
            let assetPackBaz = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-73feffa4b7f6bb68e44cf984c85f6e88", tags: Set(["baz"]), path: srcRoot.join("build/Debug-iphoneos/OnDemandResources/com.company.App.baz-73feffa4b7f6bb68e44cf984c85f6e88.assetpack"), priority: 0.5)
            let allAssetPacks0 = [assetPackFoo, assetPackBarFoo, assetPackBaz]

            let expectedSubPaths: [String: Set<String>] = [
                assetPackFoo.identifier: Set(["A.dat", "B.dat"]),
                assetPackBarFoo.identifier: Set(["de.lproj/C.dat"]),
                assetPackBaz.identifier: Set(),
            ]

            // Utility methods for checking the asset packs and related artifacts.

            func checkAssetPackInfoPlist(_ results: BuildOperationTester.BuildResults, _ assetPack: ODRAssetPackInfo) throws {
                try results.checkTask(.matchRule(["WriteAuxiliaryFile", assetPack.path.join("Info.plist").str])) { task in
                    let data = try PropertyList.fromBytes(auxFileTaskContents(task).bytes)

                    var expectedDict: [String: any PropertyListItemConvertible] = [
                        "CFBundleIdentifier": assetPack.identifier,
                        "Tags": assetPack.tags.sorted(),
                    ]

                    if let p = assetPack.priority {
                        expectedDict["Priority"] = p
                    }

                    let expected = PropertyListItem(expectedDict)
                    #expect(expected == data)
                }
            }

            func checkOnDemandResourcesPlist(_ results: BuildOperationTester.BuildResults, _ assetPacks: [ODRAssetPackInfo]) throws {
                try results.checkTask(.matchRule(["WriteAuxiliaryFile", srcRoot.join("build/Debug-iphoneos/App.app/OnDemandResources.plist").str])) { task in
                    let data = try PropertyList.fromBytes(auxFileTaskContents(task).bytes)

                    let infos = assetPacks.map { ODRAssetPackInfo(identifier: $0.identifier, tags: $0.tags, path: $0.path, priority: nil) }
                    let assetPacksToSubPaths = Dictionary(uniqueKeysWithValues: assetPacks.map { ($0.identifier, expectedSubPaths[$0.identifier]!) })
                    let odrpl = OnDemandResourcesPlist(infos, subPaths: assetPacksToSubPaths)
                    let expected = odrpl.propertyListItem

                    #expect(expected == data)
                }
            }

            func checkAssetPackManifestPlist(_ results: BuildOperationTester.BuildResults, _ assetPacks: [ODRAssetPackInfo], minModDate: Date, precedingTasks: [Task]) throws {
                let assetPackManifestPlistPath = srcRoot.join("build/Debug-iphoneos/App.app/AssetPackManifestTemplate.plist")
                try results.checkTask(.matchRule(["CreateAssetPackManifest", assetPackManifestPlistPath.str])) { createAssetPackManifestTask in
                    /// All tasks which contribute to asset packs should have finished before createAssetPackManifestTask started
                    for precedingTask in precedingTasks {
                        results.check(event:    .taskHadEvent(precedingTask,                event: .completed),
                                      precedes: .taskHadEvent(createAssetPackManifestTask,  event: .started))
                    }

                    // Content
                    let manifest = try AssetPackManifestPlist(PropertyList.fromBytes(fs.read(assetPackManifestPlistPath).bytes))
                    #expect(assetPacks.count == manifest.resources.count)

                    for assetPack in assetPacks {
                        guard let item = (manifest.resources.first { $0.assetPackBundleIdentifier == assetPack.identifier }) else { Issue.record(); return }
                        #expect(item.isStreamable)

                        let suffixStr = assetPack.path.str
                        #expect(item.url == "http://127.0.0.1\(suffixStr)")

                        var expectedSize: Int = 0
                        try fs.traverse(assetPack.path) { try expectedSize += Int(fs.getFileInfo($0).statBuf.st_size) }
                        #expect(item.uncompressedSize == expectedSize)

                        switch item.primaryContentHash {
                        case .modtime(let date):
                            // Need to round down and up since we may not have subsecond granularity in the file system
                            #expect(date.timeIntervalSince1970 >= floor(minModDate.timeIntervalSince1970))
                            #expect(date.timeIntervalSince1970 <= ceil(Date().timeIntervalSince1970))
                        }
                    }
                }
            }

            // Perform a build and check the results.
            let provisioningInputs = [
                "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]

            let buildStartDate0 = Date()
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                // Assets copied into correct asset packs

                let resourceA = try results.checkTask(.matchRule(["CpResource", assetPackFoo.path.join("A.dat").str, srcRoot.join("Sources/A.dat").str])) { task throws in task }
                #expect(fs.exists(assetPackFoo.path.join("A.dat")))
                #expect(!fs.exists(srcRoot.join("build/Debug-iphoneos/App.app/A.dat")))

                let resourceB = try results.checkTask(.matchRule(["CpResource", assetPackFoo.path.join("B.dat").str, srcRoot.join("Sources/B.dat").str])) { task throws in task }
                #expect(fs.exists(assetPackFoo.path.join("B.dat")))
                #expect(!fs.exists(srcRoot.join("build/Debug-iphoneos/App.app/B.dat")))

                let resourceC = try results.checkTask(.matchRule(["CpResource", assetPackBarFoo.path.join("de.lproj/C.dat").str, srcRoot.join("Sources/de.lproj/C.dat").str])) { task throws in task }
                #expect(fs.exists(assetPackBarFoo.path.join("de.lproj/C.dat")))
                #expect(!fs.exists(srcRoot.join("build/Debug-iphoneos/App.app/de.lproj/C.dat")))

                // Asset pack bundle Info.plist files

                for assetPack in allAssetPacks0 {
                    try checkAssetPackInfoPlist(results, assetPack)
                }

                // AssetPackOutputSpecifications.plist actool asset pack configuration

                let assetPackInfoPlistPath = srcRoot.join("build/aProject.build/Debug-iphoneos/App.build/AssetPackOutputSpecifications.plist")
                try results.checkTask(.matchRule(["WriteAuxiliaryFile", assetPackInfoPlistPath.str])) { task in
                    let data = try PropertyList.fromBytes(auxFileTaskContents(task).bytes)

                    let expected: PropertyListItem = .init(allAssetPacks0
                        .sorted { $0.identifier < $1.identifier }
                        .map { assetPack in
                            PropertyListItem([
                                "bundle-id": .plString(assetPack.identifier),
                                "tags": PropertyListItem(assetPack.tags.sorted()),
                                "bundle-path": .plString(assetPack.path.str),
                            ])
                        })

                    #expect(expected == data)
                }

                let assetCatalog = try results.checkTask(.matchRule(["CompileAssetCatalogVariant", "thinned", srcRoot.join("build/Debug-iphoneos/App.app").str, srcRoot.join("Sources/Assets.xcassets").str])) { task throws -> Task in
                    task.checkCommandLineMatches([.anySequence, .equal("--enable-on-demand-resources"), .equal("YES"), .anySequence])
                    task.checkCommandLineMatches([
                        StringPattern.anySequence,
                        StringPattern.equal("--asset-pack-output-specifications"),
                        StringPattern.equal(assetPackInfoPlistPath.str),
                        StringPattern.anySequence])
                    return task
                }

                // OnDemandResources.plist

                try checkOnDemandResourcesPlist(results, allAssetPacks0)

                // AssetPackManifest.plist

                try checkAssetPackManifestPlist(results, allAssetPacks0, minModDate: buildStartDate0, precedingTasks: [resourceA, resourceB, resourceC, assetCatalog])
            }
        }
    }

    /// Test that ODR is forcibly and silently disabled when building for macCatalyst.  This builds the same project as `testOnDemandResourcesBasics()` above.
    @Test(.requireSDKs(.macOS))
    func onDemandResourcesDisabledForMacCatalyst() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            // Create the project and tester to use.
            let tester = try await createODRProjectAndTester(srcRoot)
            let fs = tester.fs

            // Perform a build for macCatalyst and check the results.
            let provisioningInputs = [
                "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]
            let overrides = [
                "SDKROOT": "macosx",
                "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                "TARGETED_DEVICE_FAMILY": "2",
            ]
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: overrides), runDestination: .macOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                // Check that there are no tasks putting any content into a .assetpack bundle.
                results.checkNoTask(.matchRuleItemPattern(.contains(".assetpack/")))

                // Check that assets are copied into the bundle and not into asset packs.
                results.checkTask(.matchRule(["CpResource", srcRoot.join("build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/App.app/Contents/Resources/A.dat").str, srcRoot.join("Sources/A.dat").str])) { _ in }
                #expect(fs.exists(srcRoot.join("build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/App.app/Contents/Resources/A.dat")))

                results.checkTask(.matchRule(["CpResource", srcRoot.join("build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/App.app/Contents/Resources/B.dat").str, srcRoot.join("Sources/B.dat").str])) { _ in }
                #expect(fs.exists(srcRoot.join("build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/App.app/Contents/Resources/B.dat")))

                results.checkTask(.matchRule(["CpResource", srcRoot.join("build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/App.app/Contents/Resources/de.lproj/C.dat").str, srcRoot.join("Sources/de.lproj/C.dat").str])) { _ in }
                #expect(fs.exists(srcRoot.join("build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/App.app/Contents/Resources/de.lproj/C.dat")))

                // Check that there is no AssetPackOutputSpecifications.plist actool asset pack configuration.
                results.checkNoTask(.matchRuleItemBasename("AssetPackOutputSpecifications.plist"))

                // Check that the actool invocation does not include ODR options.
                results.checkTask(.matchRule(["CompileAssetCatalogVariant", "thinned", srcRoot.join("build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/App.app/Contents/Resources").str, srcRoot.join("Sources/Assets.xcassets").str])) { task in
                    task.checkCommandLineContainsUninterrupted(["--enable-on-demand-resources", "NO"])
                    task.checkCommandLineDoesNotContain("--asset-pack-output-specifications")
                }

                // Check that there is no OnDemandResources.plist task.
                results.checkNoTask(.matchRuleItemBasename("OnDemandResources.plist"))

                // Check that there is no AssetPackManifest.plist task.
                results.checkNoTask(.matchRuleType("CreateAssetPackManifest"))
            }
        }
    }

    /// This is essentially the archiving configuration
    @Test(.requireSDKs(.iOS))
    func assetPackFolderPath() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")
            let odrRoot = tmpDirPath.join("odr")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("A.dat"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.company.$(TARGET_NAME)",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "ASSET_PACK_FOLDER_PATH": odrRoot.str,
                            "EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE": "NO",
                            "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
                            "CODESIGN": "/usr/bin/true", // we use "Apple Development" identity, so this test will never succeed with the real codesign
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("A.dat", assetTags: Set(["foo"])),
                            ]),
                        ]),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs

            try fs.createDirectory(srcRoot.join("Sources"), recursive: true)
            try fs.write(srcRoot.join("Sources/A.dat"), contents: ByteString([0]))

            try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
            try fs.write(srcRoot.join("App.entitlements"), contents: "")

            let assetPackFoo = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-acbd18db4cc2f85cedef654fccc4a4d8", tags: Set(["foo"]), path: odrRoot.join("com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack"), priority: 1)
            let assetPacks = [assetPackFoo]

            let provisioningInputs = [
                "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                let assetPackManifestPlistPath = srcRoot.join("build/Debug-iphoneos/App.app/AssetPackManifestTemplate.plist")
                try results.checkTask(.matchRule(["CreateAssetPackManifest", assetPackManifestPlistPath.str])) { createAssetPackManifestTask in
                    let manifest = try AssetPackManifestPlist(PropertyList.fromBytes(fs.read(assetPackManifestPlistPath).bytes))
                    #expect(assetPacks.count == manifest.resources.count)

                    for assetPack in assetPacks {
                        guard let item = (manifest.resources.first { $0.assetPackBundleIdentifier == assetPack.identifier }) else { Issue.record(); return }
                        let suffixStr = assetPack.path.str
                        #expect(item.url == "http://127.0.0.1\(suffixStr)")
                    }
                }
            }
        }
    }

    // rdar://108165577 (Swift-frontend crashes due to heap corruption when compiling Swift Build)
    /*
     /// Allow users to point at a custom asset pack server using ASSET_PACK_MANIFEST_URL_PREFIX
     func testAssetPackManifestURLPrefix() async throws {
     try await XCTSkipUnlessSDKs(.iOS)
     try await withTemporaryDirectory { tmpDirPath in
     let srcRoot = tmpDirPath.join("srcroot")

     let expectedURLPrefix = "https://example.com/packs"

     let testProject = TestProject(
     "aProject",
     sourceRoot: srcRoot,
     groupTree: TestGroup(
     "SomeFiles", path: "Sources",
     children: [
     TestFile("A.dat"),
     ]),
     buildConfigurations: [
     TestBuildConfiguration(
     "Debug",
     buildSettings: [
     "INFOPLIST_FILE": "Info.plist",
     "PRODUCT_BUNDLE_IDENTIFIER": "com.company.$(TARGET_NAME)",
     "PRODUCT_NAME": "$(TARGET_NAME)",
     "SDKROOT": "iphoneos",
     "ASSET_PACK_MANIFEST_URL_PREFIX": expectedURLPrefix,
     "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
     "CODESIGN": "/usr/bin/true", // we use "Apple Development" identity, so this test will never succeed with the real codesign
     ]),
     ],
     targets: [
     TestStandardTarget(
     "App",
     buildPhases: [
     TestResourcesBuildPhase([
     TestBuildFile("A.dat", assetTags: Set(["foo"])),
     ]),
     ]),
     ])

     let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
     let fs = tester.fs

     try fs.createDirectory(srcRoot.join("Sources"), recursive: true)
     try fs.write(srcRoot.join("Sources/A.dat"), contents: ByteString([0]))

     try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
     try fs.write(srcRoot.join("App.entitlements"), contents: "")

     let assetPackFoo = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-acbd18db4cc2f85cedef654fccc4a4d8", tags: Set(["foo"]), path: srcRoot.join("build/Debug-iphoneos/OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack"), priority: 1)
     let assetPacks = [assetPackFoo]

     let provisioningInputs = [
     "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
     ]

     try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", activeRunDestination: .iOS), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
     results.checkNoDiagnostics()

     let assetPackManifestPlistPath = srcRoot.join("build/Debug-iphoneos/App.app/AssetPackManifest.plist")
     try results.checkTask(.matchRule(["CreateAssetPackManifest", assetPackManifestPlistPath.str])) { createAssetPackManifestTask in
     let manifest = try AssetPackManifestPlist(PropertyList.fromBytes(fs.read(assetPackManifestPlistPath).bytes))
     XCTAssertEqual(assetPacks.count, manifest.resources.count)

     for assetPack in assetPacks {
     guard let item = (manifest.resources.first { $0.assetPackBundleIdentifier == assetPack.identifier }) else { XCTFail(); return }
     let suffixStr = assetPack.path.basename
     XCTAssertEqual(item.url, "\(expectedURLPrefix)\(suffixStr)")
     }
     }
     }
     }
     }
     */
    @Test(.requireSDKs(.iOS))
    func assetPackManifestEmbedding() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("A.dat"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.company.$(TARGET_NAME)",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE": "YES",
                            "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
                            "CODESIGN": "/usr/bin/true", // we use "Apple Development" identity, so this test will never succeed with the real codesign
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("A.dat", assetTags: Set(["foo"])),
                            ]),
                        ]),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs

            try fs.createDirectory(srcRoot.join("Sources"), recursive: true)
            try fs.write(srcRoot.join("Sources/A.dat"), contents: ByteString([0]))

            try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
            try fs.write(srcRoot.join("App.entitlements"), contents: "")

            let provisioningInputs = [
                "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                let assetPackManifestPlistPath = srcRoot.join("build/Debug-iphoneos/App.app/AssetPackManifest.plist")
                try results.checkTask(.matchRule(["CreateAssetPackManifest", assetPackManifestPlistPath.str])) { createAssetPackManifestTask in
                    let manifest = try AssetPackManifestPlist(PropertyList.fromBytes(fs.read(assetPackManifestPlistPath).bytes))
                    #expect(1 == manifest.resources.count)
                    let item = manifest.resources.only!

                    // it should be relative to the app's resources directory
                    #expect(item.url == "OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack")
                }
            }
        }
    }

    /// Some tests supply a custom AssetPackManifest.plist. If we see it, we shouldn't emit ours per <rdar://problem/19679943>.
    @Test(.requireSDKs(.iOS))
    func userAssetPackManifest() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("A.dat"),
                        TestFile("AssetPackManifest.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.company.$(TARGET_NAME)",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
                            "CODESIGN": "/usr/bin/true", // we use "Apple Development" identity, so this test will never succeed with the real codesign
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("AssetPackManifest.plist"),
                                TestBuildFile("A.dat", assetTags: Set(["foo"])),
                            ]),
                        ]),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs

            try fs.createDirectory(srcRoot.join("Sources"), recursive: true)
            try fs.write(srcRoot.join("Sources/A.dat"), contents: ByteString([0]))
            try fs.write(srcRoot.join("Sources/AssetPackManifest.plist"), contents: ByteString(PropertyListItem(["a": "3"]).asBytes(.binary)))

            try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
            try fs.write(srcRoot.join("App.entitlements"), contents: "")

            let provisioningInputs = [
                "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]

            let assetPackFoo = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-acbd18db4cc2f85cedef654fccc4a4d8", tags: Set(["foo"]), path: srcRoot.join("build/Debug-iphoneos/OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack"), priority: nil)

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                // We emitted an asset pack, so we would normally emit a manifest as well
                results.checkTask(.matchRule(["WriteAuxiliaryFile", assetPackFoo.path.join("Info.plist").str])) { _ in }

                // But because we saw a custom manifest, we shouldn't emit ours
                results.checkNoTask(.matchRuleType("CreateAssetPackManifest"))
                results.checkTask(.matchRule(["CopyPlistFile", "\(srcRoot.str)/build/Debug-iphoneos/App.app/AssetPackManifest.plist", "\(srcRoot.str)/Sources/AssetPackManifest.plist"])) { _ in }
            }
        }
    }

    /// If the tags on a loose or catalogued asset are modified, we need to redo task construction. We get the loose case for free via the PIF signature, but we don't store catalogued asset tags in the PIF (because we don't have enough context to resolve the asset catalog file path at PIF-time).
    @Test(.requireSDKs(.iOS))
    func buildDescriptionInvalidation() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("Assets.xcassets"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "INFOPLIST_FILE": "Info.plist",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.company.$(TARGET_NAME)",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
                            "CODESIGN": "/usr/bin/true", // we use "Apple Development" identity, so this test will never succeed with the real codesign
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                "Assets.xcassets",
                            ]),
                        ]),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs

            try fs.createDirectory(srcRoot.join("Sources"), recursive: true)

            let assetCatalogPath = srcRoot.join("Sources/Assets.xcassets")
            let assetCatalog0 = TestAssetCatalog(entries: [
                "acA": TestAssetCatalog.Entry(bytes: ByteString([0]), assetTags: Set(["foo"])),
            ])
            try await assetCatalog0.write(fs, assetCatalogPath)

            let assetPackFoo = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-acbd18db4cc2f85cedef654fccc4a4d8", tags: Set(["foo"]), path: srcRoot.join("build/Debug-iphoneos/OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack"), priority: nil)

            try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
            try fs.write(srcRoot.join("App.entitlements"), contents: "")

            let provisioningInputs = [
                "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]

            // Base build

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRule(["WriteAuxiliaryFile", assetPackFoo.path.join("Info.plist").str])) { _ in }
            }

            // Update the asset catalog

            let assetCatalog1 = TestAssetCatalog(entries: [
                "acA": TestAssetCatalog.Entry(bytes: ByteString([0]), assetTags: Set(["foo", "bar"])),
            ])
            try await assetCatalog1.write(fs, assetCatalogPath)

            let assetPackBarFoo = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-8856328b99ee7881e9bf7205296e056d", tags: Set(["foo", "bar"]), path: srcRoot.join("build/Debug-iphoneos/OnDemandResources/com.company.App.bar+foo-8856328b99ee7881e9bf7205296e056d.assetpack"), priority: nil)

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRule(["WriteAuxiliaryFile", assetPackBarFoo.path.join("Info.plist").str])) { _ in }
            }
        }
    }

    /// When an asset is updated, only affected asset packs should have their modtimes updated to prevent all asset packs from redownloading on local incremental debug builds.
    @Test(.requireSDKs(.iOS))
    func incrementalAssetPackUpdates() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("A.dat"),
                        TestFile("B.dat"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.company.$(TARGET_NAME)",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "CODE_SIGN_ENTITLEMENTS": "App.entitlements",
                            "CODESIGN": "/usr/bin/true", // we use "Apple Development" identity, so this test will never succeed with the real codesign

                            // NOTE: THIS IS THE IMPORTANT SETTING! Ensure that opt-in is on, regardless of the default value.
                            "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING": "YES",
                            "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS": "YES",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildPhases: [
                            TestResourcesBuildPhase([
                                TestBuildFile("A.dat", assetTags: Set(["foo"])),
                                TestBuildFile("B.dat", assetTags: Set(["bar"])),
                            ]),
                        ]),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs

            try fs.createDirectory(srcRoot.join("Sources"), recursive: true)
            try fs.write(srcRoot.join("Sources/A.dat"), contents: ByteString([0]))
            try fs.write(srcRoot.join("Sources/B.dat"), contents: ByteString([0]))

            let assetPackFoo = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-acbd18db4cc2f85cedef654fccc4a4d8", tags: Set(["foo"]), path: srcRoot.join("build/Debug-iphoneos/OnDemandResources/com.company.App.foo-acbd18db4cc2f85cedef654fccc4a4d8.assetpack"), priority: nil)
            let assetPackBar = ODRAssetPackInfo(identifier: "com.company.App.asset-pack-MzdiNTFkMTk0YTc1MTNlNDViNTZmNjUyNGYyZDUxZjI=", tags: Set(["bar"]), path: srcRoot.join("build/Debug-iphoneos/OnDemandResources/com.company.App.bar-MzdiNTFkMTk0YTc1MTNlNDViNTZmNjUyNGYyZDUxZjI=.assetpack"), priority: nil)
            let assetPacks = [assetPackFoo, assetPackBar]

            let assetPackManifestPlistPath = srcRoot.join("build/Debug-iphoneos/App.app/AssetPackManifestTemplate.plist")

            try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
            try fs.write(srcRoot.join("App.entitlements"), contents: "")

            let provisioningInputs = [
                "App": ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing"),
            ]

            // Base build

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()
            }

            let assetPackManifest0 = try AssetPackManifestPlist(PropertyList.fromPath(assetPackManifestPlistPath, fs: tester.fs))
            #expect(assetPacks.count == assetPackManifest0.resources.count)
            let modTimes0 = Dictionary(uniqueKeysWithValues: assetPackManifest0.resources.map { ($0.assetPackBundleIdentifier, $0.primaryContentHash.modtimeValue) })

            // Update an asset and check that the next build only updates the AssetPackManifest on the asset's associated asset pack
            try fs.write(srcRoot.join("Sources/A.dat"), contents: ByteString([42]))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .iOS, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                let copyTask: Task = try results.checkTask(.matchRule(["CpResource", "\(assetPackFoo.path.str)/A.dat", "\(srcRoot.str)/Sources/A.dat"])) { task in task }

                let manifestTask: Task = try results.checkTask(.matchRule(["CreateAssetPackManifest", assetPackManifestPlistPath.str])) { task in task }
                results.checkTask(.matchRule(["CodeSign", "\(srcRoot.str)/build/Debug-iphoneos/App.app"])) { _ in }
                results.checkTask(.matchRule(["Validate", "\(srcRoot.str)/build/Debug-iphoneos/App.app"])) { _ in }

                results.check(event: .taskHadEvent(copyTask, event: .completed), precedes: .taskHadEvent(manifestTask, event: .started))

                results.consumeTasksMatchingRuleTypes()
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            let assetPackManifest1 = try AssetPackManifestPlist(PropertyList.fromPath(assetPackManifestPlistPath, fs: tester.fs))
            let modTimes1 = Dictionary(uniqueKeysWithValues: assetPackManifest1.resources.map { ($0.assetPackBundleIdentifier, $0.primaryContentHash.modtimeValue) })

            for (identifier, t1) in modTimes1 {
                let t0 = modTimes0[identifier]!
                switch identifier {
                case assetPackFoo.identifier:
                    #expect(t0 < t1)
                default:
                    #expect(t0 == t1)
                }
            }

            // We could test asset catalogs here as well, but incremental asset catalog updates are not supported. I.e. if you modify a single asset, actool will update all the asset catalogs in all the asset packs.
        }
    }
}
