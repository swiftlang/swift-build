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

package import Testing

import SWBUtil
import SWBCore
package import SWBProtocol

extension CoreBasedTests {
    package func deviceFamilyBuildOperationTester(destination: RunDestinationInfo, targetedDeviceFamily: String?, expectedIdentifiers: [Int]? = nil, expectedIdioms: [String], unexpectedIdioms: [String] = [], expectedWarnings: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let idiomIntMap = [
            "iphone": 1,
            "ipad": 2,
            "tv": 3,
            "watch": 4,
            "mac": 6,
            "vision": 7,
        ]

        let core = try await getCore()

        let platform = destination.platform
        let sdkVariant = destination.sdkVariant

        try await withTemporaryDirectory { (tmpDirPath: Path) async throws -> Void in
            let sdkVariantSettings = sdkVariant.flatMap { ["SDK_VARIANT": $0] } ?? [:]
            let deviceFamilySettings = targetedDeviceFamily.flatMap { ["TARGETED_DEVICE_FAMILY": $0] } ?? [:]

            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "Sources",
                    path: "",
                    children: [
                        TestFile("Assets.xcassets"),
                        TestFile("Info.plist")
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGN_IDENTITY": "",
                            "SDKROOT": "\(destination.sdk)",
                            "VERSIONING_SYSTEM": "apple-generic"
                        ]
                        .merging(sdkVariantSettings, uniquingKeysWith: { (_, new) in new })
                        .merging(deviceFamilySettings, uniquingKeysWith: { (_, new) in new })
                    )
                ],
                targets: [
                    TestStandardTarget(
                        "Framework",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "INFOPLIST_FILE": "$(SRCROOT)/Info.plist",
                                ]
                            )
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase(["Assets.xcassets"])
                        ]
                    )
                ]
            )

            let tester = try await BuildOperationTester(core, testProject, simulated: false)
            let SRCROOT = tmpDirPath

            try await tester.fs.writePlist(SRCROOT.join("Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            try await tester.fs.writeAssetCatalog(SRCROOT.join("Assets.xcassets"), .root, .appIcon("AppIcon"))

            try await tester.checkBuild(runDestination: destination, persistent: true) { results in
                for expectedWarning in expectedWarnings {
                    results.checkWarning(.contains(expectedWarning), sourceLocation: sourceLocation)
                }

                results.checkNoDiagnostics(sourceLocation: sourceLocation)

                results.checkTask(.matchRuleType("CompileAssetCatalogVariant")) { task in
                    task.checkCommandLineContainsUninterrupted(["--platform", platform], sourceLocation: sourceLocation)
                    task.checkCommandLineContainsUninterrupted(Array(expectedIdioms.map { ["--target-device", $0] }.joined()), sourceLocation: sourceLocation)
                    for idiom in unexpectedIdioms {
                        task.checkCommandLineDoesNotContain(idiom, sourceLocation: sourceLocation)
                    }
                }

                let infoPlist = try PropertyList.fromPath(tmpDirPath.join("build/Debug\(platform == "macosx" ? (sdkVariant == MacCatalystInfo.sdkVariantName ? MacCatalystInfo.publicSDKBuiltProductsDirSuffix : "") : "-\(platform)")/Framework.framework/\(platform == "macosx" ? "Resources" : "")/Info.plist"), fs: tester.fs)
                if platform == "macosx" && sdkVariant != MacCatalystInfo.sdkVariantName {
                    #expect(infoPlist.dictValue?["UIDeviceFamily"] == nil, "expected no UIDeviceFamily on \(platform) but found value", sourceLocation: sourceLocation)
                } else {
                    #expect(infoPlist.dictValue?["UIDeviceFamily"]?.intArrayValue == expectedIdentifiers ?? expectedIdioms.compactMap { idiomIntMap[$0] }, "unexpected UIDeviceFamily value", sourceLocation: sourceLocation)
                }
            }
        }
    }
}
