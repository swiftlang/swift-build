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
import SWBTaskExecution
import SWBCore

@Suite
fileprivate struct FileCopyTaskTests {
    @Test
    func singleFileCopy() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testDataDirPath = try Path(#require(Bundle.module.resourceURL).appendingPathComponent("TestData").appendingPathComponent("FileCopyTask").path)

            // Many filesystems on other platforms (e.g. various non-ext4 temporary filesystems on Linux) don't support xattrs and will return ENOTSUP.
            // In particular, tmpfs doesn't support xattrs on Linux unless `CONFIG_TMPFS_XATTR` is enabled in the kernel config.
            if try ProcessInfo.processInfo.hostOperatingSystem() == .linux {
                do {
                    _ = try localFS.getExtendedAttribute(testDataDirPath, key: "user.test")
                } catch let error as SWBUtil.POSIXError where error.code == ENOTSUP {
                    return
                }
            }

            // Set up the copy task and run it.
            let action = FileCopyTaskAction(.init(skipAppStoreDeployment: false, stubPartialCompilerCommandLine: [], stubPartialLinkerCommandLine: [], stubPartialLipoCommandLine: [], partialTargetValues: [], llvmTargetTripleOSVersion: "", llvmTargetTripleSuffix: "", platformName: "", swiftPlatformTargetPrefix: "", isMacCatalyst: false))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copy", testDataDirPath.join("LoneFile.txt").str, tmpDir.str], workingDirectory: testDataDirPath, outputs: [], action: action, execDescription: "Copy File")

            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: MockExecutionDelegate(),
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])

            // Make sure it completed successfully.
            #expect(result == .succeeded)

            // Examine the copied contents.
            #expect(localFS.exists(tmpDir.join("LoneFile.txt")))
        }
    }

    @Test
    func simpleDirectoryCopy() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testDataDirPath = try Path(#require(Bundle.module.resourceURL).appendingPathComponent("TestData").appendingPathComponent("FileCopyTask").path)

            // Many filesystems on other platforms (e.g. various non-ext4 temporary filesystems on Linux) don't support xattrs and will return ENOTSUP.
            // In particular, tmpfs doesn't support xattrs on Linux unless `CONFIG_TMPFS_XATTR` is enabled in the kernel config.
            if try ProcessInfo.processInfo.hostOperatingSystem() == .linux {
                do {
                    _ = try localFS.getExtendedAttribute(testDataDirPath, key: "user.test")
                } catch let error as SWBUtil.POSIXError where error.code == ENOTSUP {
                    return
                }
            }

            // Set up the copy task and run it.
            let action = FileCopyTaskAction(.init(skipAppStoreDeployment: false, stubPartialCompilerCommandLine: [], stubPartialLinkerCommandLine: [], stubPartialLipoCommandLine: [], partialTargetValues: [], llvmTargetTripleOSVersion: "", llvmTargetTripleSuffix: "", platformName: "", swiftPlatformTargetPrefix: "", isMacCatalyst: false))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copy", testDataDirPath.join("SimpleDir").str, tmpDir.str], workingDirectory: testDataDirPath, outputs: [], action: action, execDescription: "Copy Directory")

            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: MockExecutionDelegate(),
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            #expect(outputDelegate.errors == [])
            #expect(outputDelegate.warnings == [])

            // Make sure it completed successfully.
            #expect(result == .succeeded)

            // Examine the copied contents.
            #expect(localFS.isDirectory(tmpDir.join("SimpleDir")))
            #expect(localFS.exists(tmpDir.join("SimpleDir").join("FileOne.txt")))
            #expect(localFS.isDirectory(tmpDir.join("SimpleDir").join("More")))
            #expect(localFS.exists(tmpDir.join("SimpleDir").join("More").join("FileTwo.txt")))
        }
    }

    @Test
    func missingFileCopy() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testDataDirPath = try Path(#require(Bundle.module.resourceURL).appendingPathComponent("TestData").appendingPathComponent("FileCopyTask").path)

            // Set up the copy task and run it.
            let action = FileCopyTaskAction(.init(skipAppStoreDeployment: false, stubPartialCompilerCommandLine: [], stubPartialLinkerCommandLine: [], stubPartialLipoCommandLine: [], partialTargetValues: [], llvmTargetTripleOSVersion: "", llvmTargetTripleSuffix: "", platformName: "", swiftPlatformTargetPrefix: "", isMacCatalyst: false))
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["builtin-copy", testDataDirPath.join("MissingFile.bogus").str, tmpDir.str], workingDirectory: testDataDirPath, outputs: [], action: action, execDescription: "Copy File")

            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: MockExecutionDelegate(),
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )

            // Make sure it completed successfully.
            #expect(result == .failed)

            // Examine the error messages.
            XCTAssertMatch(outputDelegate.errors, [.suffix("MissingFile.bogus): No such file or directory (2)")])
        }
    }
}
