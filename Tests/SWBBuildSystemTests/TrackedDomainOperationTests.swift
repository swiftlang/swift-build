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

import SwiftBuild
import SwiftBuildTestSupport
import func SWBBuildService.commandLineDisplayString
import SWBBuildSystem
import SWBCore
import struct SWBProtocol.RunDestinationInfo
import struct SWBProtocol.TargetDescription
import struct SWBProtocol.TargetDependencyRelationship
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SWBTestSupport

@Suite(.requireXcode16())
fileprivate struct TrackedDomainOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func basicTrackedDomainAggregation() async throws {

        // Create a temporary test workspace, consisting of:
        // - an application
        // - a framework embedded directly inside the application
        // - a framework embedded inside that framework
        let core = try await getCore()
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "TestProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Info.plist"),
                                TestFile("PrivacyInfo.xcprivacy"),
                                TestFile("AppMain.c"),
                                TestFile("FrameworkSource.swift"),
                                TestFile("SubFrameworkSource.swift"),
                                TestFile("SysExMain.swift"),
                                TestFile("Test.swift"),
                                TestFile("Fmk/PrivacyInfo.xcprivacy"),
                                TestFile("SubFmk/PrivacyInfo.xcprivacy"),
                                TestFile("SubFmkEmpty/PrivacyInfo.xcprivacy"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "macosx",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "INFOPLIST_FILE": "Info.plist",
                                    "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
                                ]
                            )
                        ],
                        targets: [
                            TestAggregateTarget(
                                "All",
                                dependencies: [
                                    "App",
                                ]
                            ),
                            TestStandardTarget(
                                "App",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                                            "AGGREGATE_TRACKED_DOMAINS": "YES",
                                        ]
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "AppMain.c"
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "Framework.framework"
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "PrivacyInfo.xcprivacy",
                                        "Framework.framework",
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                ],
                                dependencies: [
                                    "Framework",
                                ]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "FrameworkSource.swift"
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "SubFramework.framework",
                                        "SubFrameworkEmpty.framework",
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "SubFramework.framework",
                                        "SubFrameworkEmpty.framework",
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase([
                                        "Fmk/PrivacyInfo.xcprivacy"
                                    ], destinationSubfolder: .resources, onlyForDeployment: false)
                                ],
                                dependencies: [
                                    "SubFramework",
                                    "SubFrameworkEmpty",
                                ]
                            ),
                            TestStandardTarget(
                                "SubFramework",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "SubFrameworkSource.swift"
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "SubFmk/PrivacyInfo.xcprivacy"
                                    ], destinationSubfolder: .resources, onlyForDeployment: false)
                                ]
                            ),
                            TestStandardTarget(
                                "SubFrameworkEmpty",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "SubFrameworkSource.swift"
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "SubFmkEmpty/PrivacyInfo.xcprivacy"
                                    ], destinationSubfolder: .resources, onlyForDeployment: false)
                                ]
                            )
                        ]
                    )
                ])

            // Create a tester for driving the build.
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            // Write the source files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/AppMain.c")) { contents in
                contents <<< "int main(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/FrameworkSource.swift")) { contents in
                contents <<< """
                    public import Foundation
                    public func foo() -> NSString { return "Foo" }
                    @available(macOS 10.15, *)
                    public actor A { }
                    """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/SysExMain.swift")) { contents in
                contents <<< """
                    public import Foundation
                    public func foo() -> NSString { return "Foo" }
                    @available(macOS 10.15, *)
                    public actor A { }
                    @main struct Main { public static func main() { } }
                    """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/SubFrameworkSource.swift")) { contents in
                contents <<< "public import Foundation\npublic func Bar() -> NSString { return \"Bar\" }"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/Test.swift")) { contents in
                contents <<< """
                    import XCTest
                    class Tester: XCTestCase {
                    func testMe() { XCTAssert(true) }
                    @available(macOS 10.15, *)
                    public actor A { }
                    }
                    """
            }

            // Write a barebones Info.plist file.
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)"),
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    "www.apple.com",
                ]
            ]))

            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/PrivacyInfo.xcprivacy"), .plDict([
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    "www.best.com",
                ]
            ]))

            try tester.fs.createDirectory(testWorkspace.sourceRoot.join("TestProject/Fwk"), recursive: true)
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/Fmk/PrivacyInfo.xcprivacy"), .plDict([
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    "www.frameworka.com",
                    "internal.frameworka.com",
                    "www.allframeworks.com",
                ]
            ]))

            try tester.fs.createDirectory(testWorkspace.sourceRoot.join("TestProject/SubFwk"), recursive: true)
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/SubFmk/PrivacyInfo.xcprivacy"), .plDict([
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    "www.frameworkb.com",
                    "internal.frameworkb.com",
                    "www.allframeworks.com",
                ]
            ]))

            try tester.fs.createDirectory(testWorkspace.sourceRoot.join("TestProject/SubFwkEmpty"), recursive: true)
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/SubFmkEmpty/PrivacyInfo.xcprivacy"), .plDict([
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    // empty
                ]
            ]))

            // Do an initial build. It's a clean build, so we expect all the tasks to run.
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                let buildDir = tmpDirPath.join(Path("Test/TestProject/build/\(parameters.configuration!)"))

               try results.checkTask(.matchRuleType("ProcessInfoPlistFile"), .matchTargetName("App"), body: { task in
                   task.checkCommandLineContains([
                       "-scanforprivacyfile",
                       "\(buildDir.str)/App.app/Contents/Frameworks/Framework.framework"
                   ])

                   let contentsData = try tester.fs.read(buildDir.join("App.app/Contents/Info.plist"))
                   let (privacyPlist, _) = try PropertyList.fromBytesWithFormat(contentsData.bytes)
                   let plistDict = try #require(privacyPlist.dictValue)
                   let trackedDomains = try #require(plistDict["NSPrivacyTrackingDomains"]?.arrayValue).compactMap { $0.stringValue }

                   // Nested frameworks are not currently supported. rdar://105200261
//                   XCTAssertEqualSequences(trackedDomains, [
//                        "internal.frameworka.com",
//                        "internal.frameworkb.com",
//                        // There should be no duplicates
//                        "www.allframeworks.com",
//                        "www.apple.com",
//                        "www.frameworka.com",
//                        "www.frameworkb.com",
//                   ])

                   XCTAssertEqualSequences(trackedDomains, [
                        "internal.frameworka.com",
                        // There should be no duplicates
                        "www.allframeworks.com",
                        "www.apple.com",
                        "www.best.com",
                        "www.frameworka.com",
                   ])
                })
            }

            // Update the frameworks's tracked domains and check that this causes a re-scan.
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/Fmk/PrivacyInfo.xcprivacy"), .plDict([
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    "www.additional.com",
                ]
            ]))

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                let buildDir = tmpDirPath.join(Path("Test/TestProject/build/\(parameters.configuration!)"))

               try results.checkTask(.matchRuleType("ProcessInfoPlistFile"), .matchTargetName("App"), body: { task in
                   task.checkCommandLineContains([
                       "-scanforprivacyfile",
                       "\(buildDir.str)/App.app/Contents/Frameworks/Framework.framework"
                   ])

                   let contentsData = try tester.fs.read(buildDir.join("App.app/Contents/Info.plist"))
                   let (privacyPlist, _) = try PropertyList.fromBytesWithFormat(contentsData.bytes)
                   let plistDict = try #require(privacyPlist.dictValue)
                   let trackedDomains = try #require(plistDict["NSPrivacyTrackingDomains"]?.arrayValue).compactMap { $0.stringValue }

                   XCTAssertEqualSequences(trackedDomains, [
                        "www.additional.com",
                        "www.apple.com",
                        "www.best.com",
                   ])
                })
            }
        }
    }

    // regression test for: rdar://106836789 (Xcode build fails if all Info.privacy files in all dependencies resolves to an empty list of NSPrivacyTrackingDomains)
    @Test(.requireSDKs(.macOS))
    func basicTrackedDomainAggregationEmptyDomains() async throws {

        // Create a temporary test workspace, consisting of:
        // - an application
        // - a framework embedded directly inside the application
        // - a framework embedded inside that framework
        let core = try await getCore()
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "TestProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Info.plist"),
                                TestFile("AppMain.c"),
                                TestFile("FrameworkSource.swift"),
                                TestFile("SubFrameworkSource.swift"),
                                TestFile("SysExMain.swift"),
                                TestFile("Test.swift"),
                                TestFile("Fmk/PrivacyInfo.xcprivacy"),
                                TestFile("SubFmk/PrivacyInfo.xcprivacy"),
                                TestFile("SubFmkEmpty/PrivacyInfo.xcprivacy"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "macosx",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "INFOPLIST_FILE": "Info.plist",
                                    "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
                                ]
                            )
                        ],
                        targets: [
                            TestAggregateTarget(
                                "All",
                                dependencies: [
                                    "App",
                                ]
                            ),
                            TestStandardTarget(
                                "App",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                                            "AGGREGATE_TRACKED_DOMAINS": "YES",
                                        ]
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "AppMain.c"
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "Framework.framework"
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "Framework.framework",
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false)
                                ],
                                dependencies: [
                                    "Framework",
                                ]
                            ),
                            TestStandardTarget(
                                "Framework",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "FrameworkSource.swift"
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "SubFramework.framework",
                                        "SubFrameworkEmpty.framework",
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "SubFramework.framework",
                                        "SubFrameworkEmpty.framework",
                                    ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                                    TestCopyFilesBuildPhase([
                                        "Fmk/PrivacyInfo.xcprivacy"
                                    ], destinationSubfolder: .resources, onlyForDeployment: false)
                                ],
                                dependencies: [
                                    "SubFramework",
                                    "SubFrameworkEmpty",
                                ]
                            ),
                            TestStandardTarget(
                                "SubFramework",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "SubFrameworkSource.swift"
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "SubFmk/PrivacyInfo.xcprivacy"
                                    ], destinationSubfolder: .resources, onlyForDeployment: false)
                                ]
                            ),
                            TestStandardTarget(
                                "SubFrameworkEmpty",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug"
                                    ),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "SubFrameworkSource.swift"
                                    ]),
                                    TestCopyFilesBuildPhase([
                                        "SubFmkEmpty/PrivacyInfo.xcprivacy"
                                    ], destinationSubfolder: .resources, onlyForDeployment: false)
                                ]
                            )
                        ]
                    )
                ])

            // Create a tester for driving the build.
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            // Write the source files.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/AppMain.c")) { contents in
                contents <<< "int main(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/FrameworkSource.swift")) { contents in
                contents <<< """
                    public import Foundation
                    public func foo() -> NSString { return "Foo" }
                    @available(macOS 10.15, *)
                    public actor A { }
                    """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/SysExMain.swift")) { contents in
                contents <<< """
                    public import Foundation
                    public func foo() -> NSString { return "Foo" }
                    @available(macOS 10.15, *)
                    public actor A { }
                    @main struct Main { public static func main() { } }
                    """
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/SubFrameworkSource.swift")) { contents in
                contents <<< "public import Foundation\npublic func Bar() -> NSString { return \"Bar\" }"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("TestProject/Test.swift")) { contents in
                contents <<< """
                    import XCTest
                    class Tester: XCTestCase {
                    func testMe() { XCTAssert(true) }
                    @available(macOS 10.15, *)
                    public actor A { }
                    }
                    """
            }

            // Write a barebones Info.plist file.
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)"),
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    // empty
                ]
            ]))

            try tester.fs.createDirectory(testWorkspace.sourceRoot.join("TestProject/Fwk"), recursive: true)
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/Fmk/PrivacyInfo.xcprivacy"), .plDict([
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    // empty
                ]
            ]))

            try tester.fs.createDirectory(testWorkspace.sourceRoot.join("TestProject/SubFwk"), recursive: true)
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/SubFmk/PrivacyInfo.xcprivacy"), .plDict([
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    // empty
                ]
            ]))

            try tester.fs.createDirectory(testWorkspace.sourceRoot.join("TestProject/SubFwkEmpty"), recursive: true)
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/SubFmkEmpty/PrivacyInfo.xcprivacy"), .plDict([
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    // empty
                ]
            ]))

            // Do an initial build. It's a clean build, so we expect all the tasks to run.
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                let buildDir = tmpDirPath.join(Path("Test/TestProject/build/\(parameters.configuration!)"))

               try results.checkTask(.matchRuleType("ProcessInfoPlistFile"), .matchTargetName("App"), body: { task in
                   task.checkCommandLineContains([
                       "-scanforprivacyfile",
                       "\(buildDir.str)/App.app/Contents/Frameworks/Framework.framework"
                   ])

                   let contentsData = try tester.fs.read(buildDir.join("App.app/Contents/Info.plist"))
                   let (privacyPlist, _) = try PropertyList.fromBytesWithFormat(contentsData.bytes)
                   let plistDict = try #require(privacyPlist.dictValue)
                   let trackedDomains = try #require(plistDict["NSPrivacyTrackingDomains"]?.arrayValue).compactMap { $0.stringValue }

                   XCTAssertEqualSequences(trackedDomains, [
                    // empty
                   ])
                })
            }

            // Update the frameworks's tracked domains and check that this causes a re-scan.
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("TestProject/Fmk/PrivacyInfo.xcprivacy"), .plDict([
                "NSPrivacyTracking": "YES",
                "NSPrivacyTrackingDomains": [
                    "www.additional.com",
                ]
            ]))

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true) { results in
                let buildDir = tmpDirPath.join(Path("Test/TestProject/build/\(parameters.configuration!)"))

               try results.checkTask(.matchRuleType("ProcessInfoPlistFile"), .matchTargetName("App"), body: { task in
                   task.checkCommandLineContains([
                       "-scanforprivacyfile",
                       "\(buildDir.str)/App.app/Contents/Frameworks/Framework.framework"
                   ])

                   let contentsData = try tester.fs.read(buildDir.join("App.app/Contents/Info.plist"))
                   let (privacyPlist, _) = try PropertyList.fromBytesWithFormat(contentsData.bytes)
                   let plistDict = try #require(privacyPlist.dictValue)
                   let trackedDomains = try #require(plistDict["NSPrivacyTrackingDomains"]?.arrayValue).compactMap { $0.stringValue }

                   XCTAssertEqualSequences(trackedDomains, [
                        "www.additional.com",
                   ])
                })
            }
        }
    }

}
