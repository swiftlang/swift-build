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
import SWBCore
import SWBTestSupport
import SWBUtil
import SWBTaskExecution

@Suite(.requireHostOS(.macOS)) // Core isn't working on Linux yet
fileprivate struct ProcessXCFrameworkLibraryTaskActionTests: CoreBasedTests {
    let infoLookup: any PlatformInfoLookup

    init() async throws {
        infoLookup = try await Self.makeCore()
    }

    @Test
    func basicCopy() async throws {
        let fs = localFS
        let executionDelegate = MockExecutionDelegate(fs: fs)
        let outputDelegate = MockTaskOutputDelegate()

        try await withTemporaryDirectory { tmpDir in
            let SRCROOT = tmpDir.join("src").str
            let DSTROOT = tmpDir.join("dst").str

            try fs.createDirectory(Path(SRCROOT), recursive: true)

            let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil, debugSymbolsPath: Path("debugSymbols")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework"), headersPath: nil, debugSymbolsPath: Path("debugSymbols")),
            ])
            let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
            try fs.createDirectory(supportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

            try fs.createDirectory(Path("\(DSTROOT)"), recursive: true)

            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["<arg_skipp>", "--xcframework", supportXCFrameworkPath.str, "--platform", "macos", "--target-path", DSTROOT], workingDirectory: Path(DSTROOT), action: ProcessXCFrameworkTaskAction())
            guard let result = await task.action?.performTaskAction(task, dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(), executionDelegate: executionDelegate, clientDelegate: MockTaskExecutionClientDelegate(), outputDelegate: outputDelegate) else {
                Issue.record("No result was returned.")
                return
            }

            // Check the command succeeded with no errors.
            #expect(result == .succeeded)
            #expect(outputDelegate.messages == [])

            // Check the file was copied, and is the same as the source contents.
            let plistContent = try fs.read(supportXCFrameworkPath.join("x86_64-apple-macos10.15/Support.framework/Info.plist"))
            #expect(plistContent.count > 0)

            let inputData = PropertyListItem.plDict([:])
            let outputData = try PropertyList.fromBytes(plistContent.bytes)
            #expect(inputData == outputData)

            // Verify that the debug symbols are in place.
            #expect(try fs.read(Path(DSTROOT).join("Support.framework.dSYM")) == "fake dsym!")
        }
    }

    @Test
    func copyForLibraryWithHeaders() async throws {
        let fs = localFS
        let executionDelegate = MockExecutionDelegate(fs: fs)
        let outputDelegate = MockTaskOutputDelegate()

        try await withTemporaryDirectory { tmpDir in
            let SRCROOT = tmpDir.join("src").str
            let DSTROOT = tmpDir.join("dst").str

            try fs.createDirectory(Path(SRCROOT), recursive: true)

            let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
            ])
            let supportXCFrameworkPath = Path(SRCROOT).join("libsample.xcframework")
            try fs.createDirectory(supportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

            try fs.createDirectory(Path("\(DSTROOT)"), recursive: true)

            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["<arg_skipp>", "--xcframework", supportXCFrameworkPath.str, "--platform", "macos", "--target-path", DSTROOT], workingDirectory: Path(DSTROOT), action: ProcessXCFrameworkTaskAction())
            guard let result = await task.action?.performTaskAction(task, dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(), executionDelegate: executionDelegate, clientDelegate: MockTaskExecutionClientDelegate(), outputDelegate: outputDelegate) else {
                Issue.record("No result was returned.")
                return
            }

            // Check the command succeeded with no errors.
            #expect(result == .succeeded)
            #expect(outputDelegate.messages == [])

            // Check the file was copied, and is the same as the source contents.
            let archive = try MachO(reader: BinaryReader(data: #require(FileHandle(forReadingAtPath: supportXCFrameworkPath.join("x86_64-apple-macos10.15/libsample.a").str))))
            #expect(try archive.slices().isEmpty == false)

            // Verify that the debug symbols are in place.
            #expect(try fs.read(Path(DSTROOT).join("libsample.a.dSYM")) == "fake dsym!")

            // Verify that the headers are in place.
            #expect(try fs.read(Path(DSTROOT).join("include").join("header1.h")) == "// header 1")
            #expect(try fs.read(Path(DSTROOT).join("include").join("header2.h")) == "// header 2")
        }
    }

    @Test
    func errorMessageForMissingFramework() async throws {
        let fs = localFS
        let executionDelegate = MockExecutionDelegate(fs: fs)
        let outputDelegate = MockTaskOutputDelegate()

        try await withTemporaryDirectory { tmpDir in
            let SRCROOT = tmpDir.join("src").str
            let DSTROOT = tmpDir.join("dst").str

            try fs.createDirectory(Path(SRCROOT), recursive: true)

            let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Versions/A/Support"), headersPath: nil, debugSymbolsPath: nil),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil, debugSymbolsPath: nil),
            ])
            let supportXCFrameworkPath = Path(SRCROOT).join("Support.xcframework")
            try fs.createDirectory(supportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

            try fs.createDirectory(Path("\(DSTROOT)"), recursive: true)

            // Remove macOS's framework for testing the diagnostic.
            let expectedLibraryPath = supportXCFrameworkPath.join("x86_64-apple-macos10.15/Support.framework")
            try fs.removeDirectory(expectedLibraryPath)

            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["<arg_skipp>", "--xcframework", supportXCFrameworkPath.str, "--platform", "macos", "--target-path", DSTROOT], workingDirectory: Path(DSTROOT), action: ProcessXCFrameworkTaskAction())
            guard let result = await task.action?.performTaskAction(task, dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(), executionDelegate: executionDelegate, clientDelegate: MockTaskExecutionClientDelegate(), outputDelegate: outputDelegate) else {
                Issue.record("No result was returned.")
                return
            }

            // Check the command succeeded with no errors.
            #expect(result == .failed)
            #expect(outputDelegate.messages == [
                "error: When building for macOS, the expected library \(expectedLibraryPath.str) was not found in \(supportXCFrameworkPath.str)"
            ])

            // Check the file was NOT copied, and is the same as the source contents.
            #expect(!fs.exists(Path("\(DSTROOT)/Support.framework")))
        }
    }
}
