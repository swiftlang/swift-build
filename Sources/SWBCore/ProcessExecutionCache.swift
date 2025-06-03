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

public import SWBUtil

public final class ProcessExecutionCache: Sendable {
    private let cache = AsyncCache<[String], Processes.ExecutionResult>()
    private let workingDirectory: Path?

    public init(workingDirectory: Path? = .root) {
        // FIXME: Work around lack of thread-safe working directory support in Foundation (Amazon Linux 2, OpenBSD). Executing processes in the current working directory is less deterministic, but all of the clients which use this class are generally not expected to be sensitive to the working directory anyways. This workaround can be removed once we drop support for Amazon Linux 2 and/or adopt swift-subprocess and/or Foundation.Process's working directory support is made thread safe.
        if try! Process.hasUnsafeWorkingDirectorySupport {
            self.workingDirectory = nil
            return
        }
        self.workingDirectory = workingDirectory
    }

    public func run(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ commandLine: [String], executionDescription: String?) async throws -> Processes.ExecutionResult {
        try await cache.value(forKey: commandLine) {
            try await delegate.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: [:], executionDescription: executionDescription)
        }
    }
}
