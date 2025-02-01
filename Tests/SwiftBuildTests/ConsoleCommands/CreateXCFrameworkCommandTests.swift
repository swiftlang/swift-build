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
import SWBUtil
import Testing
import SWBTestSupport

// Note: The functionality of this class is heavily unit tested in `XCFrameworkTests.swift`. These tests are only to ensure that the command is indeed hooked up and registered properly.

@Suite
fileprivate struct CreateXCFrameworkCommandTests {
    @Test
    func commandInvocation() async throws {
        let swiftbuildURL = try CLIConnection.swiftbuildToolURL
        let executionResult = try await Process.getOutput(url: swiftbuildURL, arguments: ["createXCFramework", "-help"], environment: CLIConnection.environment)
        #expect(executionResult.exitStatus == .exit(0))
        XCTAssertMatch(String(decoding: executionResult.stdout, as: UTF8.self), .prefix("OVERVIEW: Utility for packaging multiple build configurations of a given library or framework into a single xcframework."))
    }

    @Test
    func failingCommandInvocation() async throws {
        let swiftbuildURL = try CLIConnection.swiftbuildToolURL
        let executionResult = try await Process.getOutput(url: swiftbuildURL, arguments: ["createXCFramework"], environment: CLIConnection.environment)
        #expect(executionResult.exitStatus == .exit(1))
        #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "error: at least one framework or library must be specified." + String.newline + String.newline)
    }

    @Test(.skipHostOS(.windows)) // PTY not supported on Windows
    func commandInvocationInProcess() async throws {
        try await withCLIConnection { cli in
            try cli.send(command: "createXCFramework -help")

            let reply = try await cli.getResponse()
            #expect(reply.contains("OVERVIEW: Utility for packaging multiple build configurations of a given library or framework into a single xcframework."))

            await #expect(try cli.exitStatus == .exit(0))
        }
    }
}
