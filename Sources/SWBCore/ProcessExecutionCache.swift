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

    public init() { }

    public func run(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ commandLine: [String], executionDescription: String?) async throws -> Processes.ExecutionResult {
        try await cache.value(forKey: commandLine) {
            try await delegate.executeExternalTool(commandLine: commandLine, workingDirectory: "/", environment: [:], executionDescription: executionDescription)
        }
    }
}
