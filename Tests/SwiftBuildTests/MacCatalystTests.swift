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
import SWBTestSupport
import SwiftBuild
import SwiftBuildTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct MacCatalystTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func macIdiom() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("Source.c"),
                        TestFile("Assets.xcassets"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SUPPORTS_MACCATALYST": "YES",
                        "TARGETED_DEVICE_FAMILY": "2,6",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "Foo",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SUPPORTS_MACCATALYST": "YES",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["Source.c"]),
                            TestResourcesBuildPhase(["Assets.xcassets"]),
                        ]),
                ])

            let SRCROOT = tmpDirPath.str
            let testImagePath = Path(SRCROOT).join("Assets.xcassets/foo.imageset/test.png")

            let fs: any FSProxy = localFS
            try fs.write(Path(SRCROOT).join("Source.c"), contents: "int main() { return 0; }")
            try await fs.writeAssetCatalog(Path(SRCROOT).join("Assets.xcassets"), .root, .imageSet("foo", [
                .init(filename: testImagePath.basename, scale: 2, idiom: .universal),
                .init(filename: testImagePath.basename, scale: 2, idiom: .ipad),
                .init(filename: testImagePath.basename, scale: 2, idiom: .mac),
            ]))
            try fs.writeImage(testImagePath, width: 24, height: 24)

            try await withTester(testProject, fs: fs) { tester in
                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .macCatalyst, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-"])) { results in
                    results.checkNoFailedTasks()
                    results.checkNoDiagnostics()

                    results.checkFileExists(tmpDirPath.join("build/Debug-maccatalyst/Foo.app/Contents/MacOS/Foo"))
                    results.checkFileExists(tmpDirPath.join("build/Debug-maccatalyst/Foo.app/Contents/PkgInfo"))

                    try results.checkPropertyListContents(tmpDirPath.join("build/Debug-maccatalyst/Foo.app/Contents/Info.plist")) { plist in
                        #expect(plist.dictValue?["UIDeviceFamily"]?.intArrayValue == [6])
                    }

                    let assetInfo = try await PropertyList.fromJSONData(Array(runProcess(["/usr/bin/assetutil", "--info", tmpDirPath.join("build/Debug-maccatalyst/Foo.app/Contents/Resources/Assets.car").str]).utf8))

                    #expect((assetInfo.arrayValue?.contains(where: { $0.dictValue?["AssetType"]?.stringValue == "Image" && $0.dictValue?["Idiom"]?.stringValue == "mac" })) == true)
                    #expect((assetInfo.arrayValue?.contains(where: { $0.dictValue?["AssetType"]?.stringValue == "Image" && $0.dictValue?["Idiom"]?.stringValue == "pad" })) == false)
                }

                // Check that back-deployment keeps both asset types
                try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .macCatalyst, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-", "IPHONEOS_DEPLOYMENT_TARGET": "13.1"])) { results in
                    results.checkNoFailedTasks()

                    results.checkNoDiagnostics()

                    results.checkFileExists(tmpDirPath.join("build/Debug-maccatalyst/Foo.app/Contents/MacOS/Foo"))
                    results.checkFileExists(tmpDirPath.join("build/Debug-maccatalyst/Foo.app/Contents/PkgInfo"))

                    try results.checkPropertyListContents(tmpDirPath.join("build/Debug-maccatalyst/Foo.app/Contents/Info.plist")) { plist in
                        #expect(plist.dictValue?["UIDeviceFamily"]?.intArrayValue == [2, 6])
                    }

                    let assetInfo = try await PropertyList.fromJSONData(Array(runProcess(["/usr/bin/assetutil", "--info", tmpDirPath.join("build/Debug-maccatalyst/Foo.app/Contents/Resources/Assets.car").str]).utf8))

                    #expect((assetInfo.arrayValue?.contains(where: { $0.dictValue?["AssetType"]?.stringValue == "Image" && $0.dictValue?["Idiom"]?.stringValue == "mac" })) == true)
                    #expect((assetInfo.arrayValue?.contains(where: { $0.dictValue?["AssetType"]?.stringValue == "Image" && $0.dictValue?["Idiom"]?.stringValue == "pad" })) == true)
                }
            }
        }
    }
}
