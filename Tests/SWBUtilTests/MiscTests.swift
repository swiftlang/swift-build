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
import SWBUtil

@Suite fileprivate struct MiscTests {
    @Test
    func userCacheDir() throws {
        switch try ProcessInfo.processInfo.hostOperatingSystem() {
        case .windows:
            #expect(SWBUtil.userCacheDir().str.hasSuffix("\\AppData\\Local\\Temp"))
        case .macOS, .iOS, .tvOS, .watchOS, .visionOS:
            #expect(SWBUtil.userCacheDir().str.hasPrefix("/var/folders"))
        case .android:
            #expect(SWBUtil.userCacheDir().str.hasPrefix("/data/local/tmp"))
        case .linux, .unknown:
            #expect(SWBUtil.userCacheDir().str.hasPrefix("/tmp"))
        }
    }

    @Test
    func parsingUmbrellaHeaderFromModuleMap() {
        let contentWithUmbrellaHeader = """
        framework module FrameworkName [extern_c] {
          umbrella header "TheUmbrellaHeader.h"
          export *
        }
        """
        #expect(parseUmbrellaHeaderName(contentWithUmbrellaHeader) == "TheUmbrellaHeader.h")

        let contentWithoutUmbrellaHeader = """
        framework module FrameworkName [extern_c] {
          header "NonUmbrellaHeader.h"
          export *
        }
        """
        #expect(parseUmbrellaHeaderName(contentWithoutUmbrellaHeader) == nil)
    }

    /// Tests that a linker-signed binary is not detected as code-signed by PbxCp.
    @Test(.requireHostOS(.macOS))
    func linkerSignedBinaryDetection() async throws {
        try await withTemporaryDirectory { tmpDir -> Void in
            struct Lookup: PlatformInfoLookup {
                func lookupPlatformInfo(platform: BuildVersion.Platform) -> (any PlatformInfoProvider)? {
                    nil
                }
            }
            let xcode = try await InstalledXcode.currentlySelected()
            let path = try await xcode.compileFramework(path: tmpDir, platform: .iOS, infoLookup: Lookup(), archs: ["arm64"], useSwift: false)
            #expect(!pbxcp_path_is_code_signed(path), "binary was unexpectedly code signed")

            _ = try await runProcess(["/usr/bin/codesign", "-s", "-", path.str])
            #expect(pbxcp_path_is_code_signed(path), "binary was unexpectedly NOT code signed")
        }
    }
}
