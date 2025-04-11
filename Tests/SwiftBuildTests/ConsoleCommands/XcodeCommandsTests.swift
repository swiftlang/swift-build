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

import SWBTestSupport
import Testing
import SWBUtil

@Suite
fileprivate struct XcodeCommandsTests {
    @Test(.skipHostOS(.windows), // PTY not supported on Windows
        .requireHostOS(.macOS)) // something with terminal echo is different on macOS vs Linux
    func XcodeCommands() async throws {
        try await withCLIConnection { cli in
            // Send the test commands.
            //
            // Some of these are really here just for test coverage.
            let commands = [
                "describeBuildSettings",
                "showPlatforms",
                "showSDKs",
                "showSpecs",
                "showToolchains",
                "quit"
            ]
            for command in commands {
                try cli.send(command: command)

                let reply = try await cli.getResponse()
                switch command {
                case "describeBuildSettings":
                    XCTAssertMatch(reply, .contains("\"DEVELOPER_DIR\""))
                case "showPlatforms":
                    XCTAssertMatch(reply, .contains("com.apple.platform.macosx"))
                case "showSDKs":
                    XCTAssertMatch(reply, .contains("MacOSX"))
                case "showSpecs":
                    XCTAssertMatch(reply, .contains("-- Domain: (default) --"))
                    XCTAssertMatch(reply, .contains("com.apple.compilers.mig"))
                case "showToolchains":
                    XCTAssertMatch(reply, .contains("com.apple.dt.toolchain.XcodeDefault"))
                default:
                    XCTAssertMatch(reply, .suffix("quit\r\n"))
                }
            }

            await #expect(try cli.exitStatus == .exit(0))
        }
    }
}
