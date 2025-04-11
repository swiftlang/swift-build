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
import SWBTestSupport

import SWBCore
import SWBUtil
import SWBProtocol

@Suite
fileprivate struct AppClipTaskConstructionTests: CoreBasedTests {
    /// Tests the normal build of an App Clip project on iOS and Mac Catalyst.
    @Test(.requireSDKs(.macOS, .iOS))
    func appClip() async throws {
        try await withTemporaryDirectory { tmpDir in
            let fs = PseudoFS()
            let tester = try await TaskConstructionTester(getCore(), TestProject.appClip(sourceRoot: tmpDir, fs: fs))

            await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOS, fs: fs) { results in
                results.checkNoDiagnostics()
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTargetName("Foo"), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineDoesNotContain("--write-standalone-icons")
                    }
                    results.checkTask(.matchTargetName("BarClip"), .matchRuleType("CompileAssetCatalogVariant"), .matchRuleItem(variant)) { task in
                        task.checkCommandLineContains(["--standalone-icon-behavior", "none"])
                    }
                }
                results.checkTask(.matchTargetName("Foo"), .matchRuleType("ValidateEmbeddedBinary")) { task in
                    task.checkCommandLine(["embeddedBinaryValidationUtility", "\(tmpDir.str)/build/Debug-iphoneos/Foo.app/AppClips/BarClip.app", "-info-plist-path", "\(tmpDir.str)/build/Debug-iphoneos/Foo.app/Info.plist"])
                }
            }

            await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOSSimulator, fs: fs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("Foo"), .matchRuleType("ValidateEmbeddedBinary")) { task in
                    task.checkCommandLine(["embeddedBinaryValidationUtility", "\(tmpDir.str)/build/Debug-iphonesimulator/Foo.app/AppClips/BarClip.app", "-info-plist-path", "\(tmpDir.str)/build/Debug-iphonesimulator/Foo.app/Info.plist"])
                }
            }

            await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macCatalyst, fs: fs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("Foo"), .matchRuleType("Ld")) { task in
                    task.checkCommandLineLastArgumentEqual("\(tmpDir.str)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Foo.app/Contents/MacOS/Foo")
                }
                results.checkNoTask(.matchTargetName("BarClip"), .matchRuleType("Ld"))
                results.checkNoTask(.matchTargetName("Foo"), .matchRuleType("ValidateEmbeddedBinary"))
            }
        }
    }
}
