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
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct GeneralCommandsTests {
    @Test(.skipHostOS(.windows), // PTY not supported on Windows
        .requireHostOS(.macOS)) // something with terminal echo is different on macOS vs Linux
    func generalCommands() async throws {
        // Test the basic functioning of the swbuild command line tool.
        try await withCLIConnection { cli in
            // Send the test commands.
            //
            // Some of these are really here just for test coverage.
            let commands = [
                "",
                "clearAllCaches",
                "dumpDependencyInfo",
                "dumpMsgPack",
                "dumpPID",
                "headermap",
                "help",
                "isAlive",
                "isAlive",
                "sendMockPIF",
                "serializedDiagnostics",
                "setConfig",
                "setConfig a b",
                "showStatistics",
                "version",
                "quit"
            ]
            for command in commands {
                try cli.send(command: command)

                let reply = try await cli.getResponse()
                switch command {
                case "":
                    XCTAssertMatch(reply, .suffix("\r\nswbuild> "))
                case "clearAllCaches", "setConfig a b":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nok\r\nswbuild> "))
                case "dumpDependencyInfo":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nusage: dumpDependencyInfo <dependency-info-file>\r\nswbuild> "))
                case "dumpMsgPack":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nerror: no path given, --path is required\r\nswbuild> "))
                case "dumpPID":
                    XCTAssertMatch(reply, .contains("service pid = "))

                    // The service PID is NOT the swbuild PID
                    XCTAssertNoMatch(reply, .contains("service pid = \(cli.processIdentifier)"))
                case "headermap", "serializedDiagnostics":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nerror: no path specified\r\n\r\nusage: \(command) --dump path\r\nswbuild> "))
                case "help":
                    XCTAssertMatch(reply, .suffix("""
                    help\r
                    build\r
                    clang-scan\r
                    clearAllCaches\r
                    createSession\r
                    createXCFramework\r
                    deleteSession\r
                    describeBuildSettings\r
                    dumpDependencyInfo\r
                    dumpMsgPack\r
                    dumpPID\r
                    exit\r
                    headermap\r
                    help\r
                    isAlive\r
                    listSessions\r
                    openIDEConsole\r
                    prepareForIndex\r
                    quit\r
                    selectSession\r
                    sendMockPIF\r
                    serializedDiagnostics\r
                    setConfig\r
                    showPlatforms\r
                    showSDKs\r
                    showSession\r
                    showSpecs\r
                    showStatistics\r
                    showToolchains\r
                    version\r
                    swbuild>
                    """ + " "))
                case "isAlive":
                    XCTAssertMatch(reply, .contains("is alive? yes"))
                case "sendMockPIF":
                    XCTAssertMatch(reply, .contains("the PIF was sent successfully"))
                case "setConfig":
                    XCTAssertMatch(reply, .suffix("\(command)\r\nusage: setConfig <key> <value>\r\nswbuild> "))
                case "showStatistics":
                    XCTAssertMatch(reply, .contains("swift-build.MsgPackDeserializer.bytesDecoded:"))
                    XCTAssertMatch(reply, .contains("swift-build.Service.messagesReceived:"))
                case "version":
                    #if SWIFT_PACKAGE
                    break
                    #else
                    let version = try SwiftBuildGetVersion()
                    XCTAssertMatch(reply, .contains(version))
                    #endif
                default:
                    XCTAssertMatch(reply, .suffix("quit\r\n"))
                }
            }

            await #expect(try cli.exitStatus == .exit(0))
        }
    }

    @Test
    func helpCommandLineInvocation() async throws {
        let swiftbuildPath = try CLIConnection.swiftbuildToolURL.filePath
        let output = try await runProcess([swiftbuildPath.str, "--help"], environment: CLIConnection.environment)

        let allCommands = [
            "build",
            "clang-scan",
            "clearAllCaches",
            "createSession",
            "createXCFramework",
            "deleteSession",
            "describeBuildSettings",
            "dumpDependencyInfo",
            "dumpMsgPack",
            "dumpPID",
            "exit",
            "headermap",
            "help",
            "isAlive",
            "listSessions",
            "openIDEConsole",
            "prepareForIndex",
            "quit",
            "selectSession",
            "sendMockPIF",
            "serializedDiagnostics",
            "setConfig",
            "showPlatforms",
            "showSDKs",
            "showSession",
            "showSpecs",
            "showStatistics",
            "showToolchains",
            "version"
        ].sorted()

        let commands = output.split(separator: String.newline).filter({ !$0.isEmpty }).map({ String($0)}).sorted()

        if commands != allCommands.sorted() {
            Issue.record("""
                    The list of commands is incorrect.
                    actual:
                    \(commands.joined(separator: String.newline))
                    expected:
                    \(allCommands.joined(separator: String.newline))"
                    """)
        }
    }

    @Test
    func versionCommandLineInvocation() async throws {
        let swiftbuildPath = try CLIConnection.swiftbuildToolURL.filePath
        let output = try await runProcess([swiftbuildPath.str, "--version"], environment: CLIConnection.environment)
        #expect(try output == SwiftBuildGetVersion() + String.newline)
    }
}
