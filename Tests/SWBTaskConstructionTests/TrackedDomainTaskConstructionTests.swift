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

import SWBCore

import SWBTestSupport
import SWBUtil

import SWBTaskConstruction
import SWBProtocol

@Suite(.requireXcode16())
fileprivate struct TrackedDomainTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func basicDomainAggregation() async throws {

        // Test the basics of task construction for a framework.
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("MyInfo.plist"),
                    TestFile("PrivacyInfo.xcprivacy"),
                    TestFile("FrameworkA/PrivacyInfo.xcprivacy"),
                    TestFile("FrameworkB/PrivacyInfo.xcprivacy"),
                    TestFile("FrameworkC/PrivacyInfo.xcprivacy"),
                    TestFile("Support.xcframework"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "DEFINES_MODULE": "YES",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "CODE_SIGN_IDENTITY": "-",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": "5",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "LIBTOOL": libtoolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "MyInfo.plist",
                            // This should be enabled by default, so do not explicitly set this.
                            // "AGGREGATE_TRACKED_DOMAINS": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                            "PrivacyInfo.xcprivacy",
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("FrameworkTargetA")),
                            TestBuildFile(.target("FrameworkTargetB")),
                            TestBuildFile("Support.xcframework"),
                            TestBuildFile(.target("SomePackageProduct")),
                            TestBuildFile(.target("OtherPackageProduct")),
                            TestBuildFile(.target("PackageProductWithTransitiveRefs")),
                        ]),
                        TestCopyFilesBuildPhase([
                            TestBuildFile(.target("FrameworkTargetB")),
                            TestBuildFile(.target("FrameworkTargetC")),
                            TestBuildFile("Support.xcframework"),
                        ], destinationSubfolder: TestCopyFilesBuildPhase.TestDestinationSubfolder.frameworks, onlyForDeployment: false)
                    ],
                    dependencies: [
                        "FrameworkTargetA",
                        "FrameworkTargetB",
                        "FrameworkTargetC",
                        "SomePackageProduct",
                        "SwiftyJSON",
                        "PackageProductWithTransitiveRefs",
                    ]
                ),
                TestStandardTarget(
                    "FrameworkTargetA",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                            "FrameworkA/PrivacyInfo.xcprivacy",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "FrameworkTargetB",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                            "FrameworkB/PrivacyInfo.xcprivacy",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "FrameworkTargetC",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.swift",
                            "FrameworkC/PrivacyInfo.xcprivacy",
                        ]),
                    ]
                ),

            ])

        let testPackage = try await TestPackageProject(
            "Package",
            groupTree: TestGroup(
                "OtherFiles",
                children: [
                    TestFile("foo.c"),
                    TestFile("Package/PrivacyInfo.xcprivacy"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "LIBTOOL": libtoolPath.str,
                ]),
            ],
            targets: [
                TestPackageProductTarget(
                    "SomePackageProduct",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("A"))]),
                    dependencies: ["A"]),
                TestPackageProductTarget(
                    "OtherPackageProduct",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("A"))]),
                    dependencies: ["A"]),
                TestPackageProductTarget(
                    "NestedPackagedProduct",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("B"))]),
                    dependencies: ["B"]),
                TestPackageProductTarget(
                    "PackageProductWithTransitiveRefs",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("SomePackageProduct")),
                        TestBuildFile(.target("NestedPackagedProduct")),
                        TestBuildFile(.target("C")),
                        TestBuildFile(.target("E"))]),
                    dependencies: ["SomePackageProduct", "NestedPackageProduct", "C", "E"]),
                TestStandardTarget(
                    "A", type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", impartedBuildProperties: TestImpartedBuildProperties(buildSettings: [
                            "EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES": "FOO",
                        ])),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"]),
                        TestCopyFilesBuildPhase(["Package/PrivacyInfo.xcprivacy"], destinationSubfolder: .resources)
                    ], dependencies: [
                        "FOO",
                    ]),

                TestStandardTarget(
                    "B", type: .framework,
                    buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
                TestStandardTarget(
                    "C", type: .dynamicLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("C_Impl"))])],
                    dependencies: ["C_Impl"]),
                TestStandardTarget(
                    "C_Impl", type: .staticLibrary,
                    buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
                TestPackageProductTarget(
                    "SwiftyJSON",
                    frameworksBuildPhase: TestFrameworksBuildPhase([]),
                    buildConfigurations: [],
                    dependencies: ["D"]),
                TestStandardTarget(
                    "E", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("F"))])
                    ], dependencies: ["F"]),
                TestStandardTarget(
                    "F", type: .objectFile,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"])
                    ]),
                TestStandardTarget(
                    "FOO", type: .bundle
                )
            ])

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject, testPackage])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testWorkspace)
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

        // Check an install release build.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkTarget("AppTarget") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkCommandLineContains([
                        // Prefer the copy that ends up in the app bundle
                        // "-scanforprivacyfile",
                        // "/tmp/aWorkspace/Package/build/Debug/B.framework",
                        // Linked items don't get scanned, only embedded.
                        // "-scanforprivacyfile",
                        // "/tmp/aWorkspace/Package/build/Debug/libC.dylib",
                        "-scanforprivacyfile",
                        "/tmp/aWorkspace/aProject/build/Debug/AppTarget.app/Contents/Frameworks/B.framework",
                        "-scanforprivacyfile",
                        "/tmp/aWorkspace/aProject/build/Debug/AppTarget.app/Contents/Frameworks/FrameworkTargetB.framework",
                        "-scanforprivacyfile",
                        "/tmp/aWorkspace/aProject/build/Debug/AppTarget.app/Contents/Frameworks/FrameworkTargetC.framework",
                        "-scanforprivacyfile",
                        "/tmp/aWorkspace/aProject/build/Debug/AppTarget.app/Contents/Frameworks/Support.framework",
                        "-scanforprivacyfile",
                        "/tmp/aWorkspace/aProject/build/Debug/AppTarget.app/Contents/Resources/FOO.bundle",
                        // Linked items don't get scanned, only embedded.
                        // "-scanforprivacyfile",
                        // "/tmp/aWorkspace/aProject/build/Debug/FrameworkTargetA.framework",
                        // "-scanforprivacyfile",
                        // "/tmp/aWorkspace/aProject/build/Debug/FrameworkTargetB.framework",
                    ])
                }
            }
        }
    }
}
