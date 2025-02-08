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

package import SWBCore
package import SWBUtil
import Testing

extension CoreBasedTests {
    /// Create a context for test project data.
    ///
    /// - Parameter files: A mapping of file paths to test data to use for those file paths. This is useful for supplying the contents of external files (e.g., xcconfig files) which will be used by the settings construction.
    package func contextForTestData(_ workspace: SWBCore.Workspace, core: Core? = nil, fs: (any FSProxy)? = nil, systemInfo: SystemInfo? = nil, environment: [String: String] = [:], files: [Path: String] = [:], symlinks: [Path: String] = [:]) async throws -> WorkspaceContext {
        let fs = fs ?? PseudoFS()
        for (file, contents) in files {
            try fs.createDirectory(file.dirname, recursive: true)
            try fs.write(file, contents: ByteString(encodingAsUTF8: contents))
        }
        for (file, contents) in symlinks {
            try fs.createDirectory(file.dirname, recursive: true)
            try fs.symlink(file, target: Path(contents))
        }

        let context = try await WorkspaceContext(core: core.or(await getCore()), workspace: workspace, fs: fs, processExecutionCache: .sharedForTesting)

        // Configure fake user and system info.
        context.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid:12345, home: Path.root.join("Users").join("exampleUser"), environment: environment))
        context.updateSystemInfo(systemInfo ?? SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: "x86_64"))

        return context
    }

    /// Create a context for test project data.
    ///
    /// - Parameter files: A mapping of file paths to test data to use for those file paths. This is useful for supplying the contents of external files (e.g., xcconfig files) which will be used by the settings construction.
    package func contextForTestData(_ workspace: TestWorkspace, core: Core? = nil, systemInfo: SystemInfo? = nil, environment: [String: String] = [:], files: [Path: String] = [:]) async throws -> WorkspaceContext {
        let effectiveCore = try await core.or(await getCore())
        return try await contextForTestData(workspace.load(effectiveCore), core: effectiveCore, systemInfo: systemInfo, environment: environment, files: files)
    }
}
