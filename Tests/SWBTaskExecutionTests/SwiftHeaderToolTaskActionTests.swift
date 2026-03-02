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
import SWBUtil
import SWBTestSupport
import SWBTaskExecution

struct SwiftHeaderToolTaskActionTests: CoreBasedTests {

    /// Utility function to create and run a `SwiftHeaderToolTaskAction` and call a block to check the results.
    @discardableResult
    private func runSwiftHeaderToolTaskAction(fs: PseudoFS, archs: [String]) async throws -> Path {
        guard !archs.isEmpty else {
            Issue.record("Must pass at least one architecture.")
            return Path("/")
        }

        let inputDir = Path.root.join("Volumes/Inputs")
        let outputDir = Path.root.join("Volumes/Outputs")

        // Build the command line and write the input files.
        try fs.createDirectory(inputDir, recursive: true)
        try fs.createDirectory(outputDir, recursive: true)
        var commandLine = ["builtin-swiftHeaderTool"]
        if archs.count == 1 {
            commandLine.append("-single")
        }
        for arch in archs {
            let inputPath = inputDir.join("\(arch)/GeneratedHeader-Swift.h")
            try await fs.writeFileContents(inputPath) { stream in
                stream <<< "Contents of file for \(arch)\n"
            }
            commandLine.append(contentsOf: [
                "-arch", arch,
                inputPath.str,
            ])
        }
        let outputPath = outputDir.join("GeneratedHeader-Swift.h")
        commandLine.append(contentsOf: [
            "-o", outputPath.str
        ])

        // Construct and run the task action.
        let executionDelegate = MockExecutionDelegate(fs: fs)
        let outputDelegate = MockTaskOutputDelegate()
        let action = SwiftHeaderToolTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "")
        guard let result = await task.action?.performTaskAction(task, dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(), executionDelegate: executionDelegate, clientDelegate: MockTaskExecutionClientDelegate(), outputDelegate: outputDelegate) else {
            Issue.record("No result was returned.")
            return outputPath
        }

        // Check the command succeeded with no errors.
        #expect(result == .succeeded)
        #expect(outputDelegate.messages == [])

        return outputPath
    }

    /// Convenience wrapper that creates its own filesystem and validates the output contents.
    private func testSwiftHeaderToolTaskAction(archs: [String], validate: (ByteString) -> Void) async throws {
        let fs = PseudoFS()
        let outputPath = try await runSwiftHeaderToolTaskAction(fs: fs, archs: archs)
        validate(try fs.read(outputPath))
    }

    /// Test that running the tool for a single arch just copies the file and doesn't add any `#if` blocks.
    @Test
    func testSingleArch() async throws {
        let archs = ["arm64"]
        try await testSwiftHeaderToolTaskAction(archs: archs) { outputFileContents in
            let expectedFileContents =
                "Contents of file for arm64\n"
            #expect(outputFileContents == expectedFileContents)
        }
    }

    /// Basic test for two architectures.
    @Test
    func testTwoArchs() async throws {
        let archs = ["arm64", "x86_64"]
        try await testSwiftHeaderToolTaskAction(archs: archs) { outputFileContents in
            let expectedFileContents =
                "#if 0\n" +
                "#elif defined(__arm64__) && __arm64__\n" +
                "Contents of file for arm64\n\n" +
                "#elif defined(__x86_64__) && __x86_64__\n" +
                "Contents of file for x86_64\n\n" +
                "#else\n" +
                "#error unsupported Swift architecture\n" +
                "#endif\n"
            #expect(outputFileContents == expectedFileContents)
        }
    }

    /// Test that when building for `arm64e` but not `arm64` that we guard the `arm64e` file contents by the fallback `arm64` macro.
    @Test
    func testFallbackArch() async throws {
        let archs = ["arm64e", "x86_64"]
        try await testSwiftHeaderToolTaskAction(archs: archs) { outputFileContents in
            let expectedFileContents =
                "#if 0\n" +
                "#elif defined(__arm64__) && __arm64__\n" +
                "Contents of file for arm64e\n\n" +
                "#elif defined(__x86_64__) && __x86_64__\n" +
                "Contents of file for x86_64\n\n" +
                "#else\n" +
                "#error unsupported Swift architecture\n" +
                "#endif\n"
            #expect(outputFileContents == expectedFileContents)
        }
    }

    /// Test that when building for both `arm64e` and `arm64` that we end up with the content for both archs using both macros.
    @Test
    func testNoFallbackArch() async throws {
        let archs = ["arm64", "arm64e"]
        try await testSwiftHeaderToolTaskAction(archs: archs) { outputFileContents in
            let expectedFileContents =
                "#if 0\n" +
                "#elif defined(__arm64e__) && __arm64e__\n" +
                "Contents of file for arm64e\n\n" +
                "#elif defined(__arm64__) && __arm64__\n" +
                "Contents of file for arm64\n\n" +
                "#else\n" +
                "#error unsupported Swift architecture\n" +
                "#endif\n"
            #expect(outputFileContents == expectedFileContents)
        }
    }

    // MARK: - writeIfChanged tests

    /// Test that running the single-arch tool twice with identical input does not rewrite the output.
    @Test
    func testSingleArchDoesNotRewriteIdenticalOutput() async throws {
        let fs = PseudoFS()

        let outputPath = try await runSwiftHeaderToolTaskAction(fs: fs, archs: ["arm64"])
        let timestampAfterFirstRun = try fs.getFileTimestamp(outputPath)

        try await runSwiftHeaderToolTaskAction(fs: fs, archs: ["arm64"])
        let timestampAfterSecondRun = try fs.getFileTimestamp(outputPath)

        #expect(timestampAfterFirstRun == timestampAfterSecondRun, "Output header was rewritten despite identical content; expected writeIfChanged to skip the write")
    }

    /// Test that running the multi-arch tool twice with identical inputs does not rewrite the output.
    @Test
    func testMultiArchDoesNotRewriteIdenticalOutput() async throws {
        let fs = PseudoFS()

        let outputPath = try await runSwiftHeaderToolTaskAction(fs: fs, archs: ["arm64", "x86_64"])
        let timestampAfterFirstRun = try fs.getFileTimestamp(outputPath)

        try await runSwiftHeaderToolTaskAction(fs: fs, archs: ["arm64", "x86_64"])
        let timestampAfterSecondRun = try fs.getFileTimestamp(outputPath)

        #expect(timestampAfterFirstRun == timestampAfterSecondRun, "Output header was rewritten despite identical content; expected writeIfChanged to skip the write")
    }

}
