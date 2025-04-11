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
fileprivate struct SessionCommandsTests {
    @Test(.skipHostOS(.windows), // PTY not supported on Windows
        .requireHostOS(.macOS)) // something with terminal echo is different on macOS vs Linux
    func sessionCommands() async throws {
        try await withCLIConnection { cli in
            // Create a session and send a mock PIF.
            let commands = [
                "createSession x",
                "listSessions",
                "showSession",
                "sendMockPIF",
                "selectSession",
                "selectSession x",
                "selectSession S0",
                "deleteSession S0",
                "exit"
            ]
            for command in commands {
                try cli.send(command: command)

                let reply = try await cli.getResponse()
                switch command {
                case "createSession x":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nS0\r\nswbuild> "))
                case "deleteSession S0":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nunknownSession(handle: \"S0\")swbuild> "))
                case "listSessions":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nS0: x (0 active builds, 0 normal, 0 index)\r\nswbuild> "))
                case "showSession":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nactiveSession = 'S0'\r\nswbuild> "))
                case "selectSession":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nusage: selectSession <uid>\r\nswbuild> "))
                case "selectSession x":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nerror: no session for UID 'x'\r\nswbuild> "))
                case "selectSession S0":
                    XCTAssertMatch(reply, .suffix("selectSession S0\r\nok\r\nswbuild> "))
                case "sendMockPIF":
                    XCTAssertMatch(reply, .contains("the PIF was sent successfully"))
                default:
                    XCTAssertMatch(reply, .suffix("exit\r\n"))
                }
            }

            await #expect(try cli.exitStatus == .exit(0))
        }
    }
}
