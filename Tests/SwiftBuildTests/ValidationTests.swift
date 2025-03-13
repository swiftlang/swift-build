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
import SwiftBuild
import SWBUtil
import SWBTestSupport

@Suite
fileprivate struct ValidationTests: CoreBasedTests {
    /// Execute an `xcodebuild` invocation with the given arguments.
    func executeXcodebuild(_ args: [String], in workingDirectory: Path) async throws {
        let testPath = try await xcodebuildUnderTestPath()
        let url = URL(fileURLWithPath: testPath.str)

        // Propagate a standard environment.
        var environment: Environment = .current.filter(keys: ["HOME", "PATH", "SDKROOT", "TOOLCHAINS", "DEVELOPER_DIR", "LLVM_PROFILE_FILE", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "CI"])

        // If llbuild hasn't been build there are two scenarios:
        //     - in Debug it will link against the one in build products dir
        //     - in Release we need to add a fallback to the SharedFrameworks dir of the Xcode we test against
        let fallbackFrameworkPath = testPath.dirname.dirname.dirname.dirname.join("SharedFrameworks")
        environment["DYLD_FALLBACK_FRAMEWORK_PATH"] = fallbackFrameworkPath.str

        // Set the custom build service process path.
        if let path = swbServiceURL?.path {
            environment["XCBBUILDSERVICE_PATH"] = path
        }

        // Run the subprocess, check the result, and return the output if we succeeded.
        let executionResult = try await Process.getOutput(url: url, arguments: args, currentDirectoryURL: URL(fileURLWithPath: workingDirectory.str), environment: environment)
        if !executionResult.exitStatus.isSuccess {
            throw RunProcessNonZeroExitError(args: [url.path] + args, workingDirectory: workingDirectory.str, environment: environment, status: executionResult.exitStatus, stdout: ByteString(executionResult.stdout), stderr: ByteString(executionResult.stderr))
        }
    }

    /// Run a build of the project `\(name).xcodeproj` in `srcroot`.
    func buildProject(_ srcroot: Path, name: String, schemeName: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await withTemporaryDirectory { tmpDir in
            do {
                try await executeXcodebuild([
                    "-project", srcroot.join("\(name).xcodeproj").str,
                    "-scheme", schemeName ?? name,
                    "-derivedDataPath", tmpDir.str,
                ], in: tmpDir)
            } catch let error as RunProcessNonZeroExitError {
                switch error.output {
                case let .separate(stdout: stdout, stderr: stderr):
                    for stream in [stdout, stderr] {
                        let errors = stream.unsafeStringValue.split(separator: "\n").filter { $0.hasPrefix("error: ") }
                        if !errors.isEmpty {
                            for error in errors {
                                Issue.record(Comment(rawValue: String(error).withoutPrefix("error: ")), sourceLocation: sourceLocation)
                            }
                        }
                    }
                case .merged, .none:
                    preconditionFailure()
                }
                throw error
            }
        }
    }

    /// Tests that `xcodebuild` pointed at the built build service is still able to build projects. This can find incompatibilities introduced in the protocol between the older client framework and build service process.
    @Test(.requireSDKs(.macOS), .requireHostOS(.macOS), .requireXcode16())
    func selfBuild() async throws {
        let bundleResourceURL = try #require(Bundle.module.resourceURL)
        let projectPath = Path(bundleResourceURL.appendingPathComponent("TestData").appendingPathComponent("CommandLineTool").absoluteURL.path)
        try await buildProject(projectPath, name: "CommandLineTool")
    }
}
