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

package import SWBUtil
private import SWBProtocol

extension TestProject {
    package static func appClip(sourceRoot: Path, fs: (any FSProxy)? = nil, appClipPlatformFilters: Set<PlatformFilter> = PlatformFilter.iOSFilters, appClipSupportsMacCatalyst: Bool = false, appDeploymentTarget: String? = nil) async throws -> TestProject {
        var appBuildSettings = [
            "CODE_SIGN_ENTITLEMENTS": "Entitlements.entitlements",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.app",
            "SUPPORTS_MACCATALYST": "YES",
        ]

        if let appDeploymentTarget {
            appBuildSettings["IPHONEOS_DEPLOYMENT_TARGET"] = appDeploymentTarget
        }

        let testProject = TestProject(
            "aProject",
            sourceRoot: sourceRoot,
            groupTree: TestGroup(
                "Sources", children: [
                    TestFile("Source.c"),
                    TestFile("Assets.xcassets"),
                    TestFile("Bar.app", sourceTree: .buildSetting("BUILT_PRODUCTS_DIR")),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ASSETCATALOG_EXEC": "$(DEVELOPER_DIR)/usr/bin/actool",
                    "ALWAYS_SEARCH_USER_PATHS": "NO",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "Foo",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "COPY_PHASE_STRIP": "NO",
                    "CURRENT_PROJECT_VERSION": "1",
                    "ENABLE_ON_DEMAND_RESOURCES": "NO",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "INFOPLIST_FILE": "Info.plist",
                    "MARKETING_VERSION": "1.0",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "iphoneos",
                ])
            ],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: appBuildSettings)
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.c"]),
                        TestResourcesBuildPhase(["Assets.xcassets"]),
                        TestCopyFilesBuildPhase([TestBuildFile(.target("BarClip"), platformFilters: appClipPlatformFilters)], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/AppClips", onlyForDeployment: false),
                    ],
                    dependencies: [TestTargetDependency("BarClip", platformFilters: appClipPlatformFilters)],
                    provisioningSourceData: [.init(configurationName: "Debug", provisioningStyle: .automatic, bundleIdentifierFromInfoPlist: "com.foo.app")]),
                TestStandardTarget(
                    "BarClip",
                    type: .appClip,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "CODE_SIGN_ENTITLEMENTS": "ClipEntitlements.entitlements",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.app.clip",
                            "SUPPORTS_MACCATALYST": appClipSupportsMacCatalyst ? "YES" : "NO",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.c"]),
                        TestResourcesBuildPhase(["Assets.xcassets"]),
                    ],
                    provisioningSourceData: [.init(configurationName: "Debug", provisioningStyle: .automatic, bundleIdentifierFromInfoPlist: "com.foo.app.clip")]),
            ])

        if let fs {
            let SRCROOT = sourceRoot.str

            try fs.createDirectory(Path(SRCROOT), recursive: true)
            try fs.write(Path(SRCROOT).join("Source.c"), contents: "int main() { return 0; }")
            try await fs.writePlist(Path(SRCROOT).join("Entitlements.entitlements"), .plDict([:]))
            try await fs.writePlist(Path(SRCROOT).join("ClipEntitlements.entitlements"), .plDict(["com.apple.developer.parent-application-identifiers": .plArray([.plString("com.foo.app")])]))
            try await fs.writePlist(Path(SRCROOT).join("Info.plist"), .plDict([
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)"),
                "CFBundleName": .plString("$(PRODUCT_NAME)"),
                "CFBundleVersion": .plString("$(CURRENT_PROJECT_VERSION)"),
                "LSApplicationCategory": .plString("Business"),
            ]))
            try await fs.writeAssetCatalog(Path(SRCROOT).join("Assets.xcassets"), .root, .appIcon("Foo"))
        }

        return testProject
    }
}
