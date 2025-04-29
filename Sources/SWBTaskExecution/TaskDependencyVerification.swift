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
public import SWBCore

import Foundation

// A harness for use in a task action implementation to perform trace-file-based dependency verification
public struct TaskDependencyVerification {

    public protocol Adapter<T> where T : Decodable {
        associatedtype T

        var outerTraceFileEnvVar: String? { get }

        func exec(
            ctx: TaskExecutionContext,
            env: [String: String]
        ) async throws -> CommandResult

        func verify(
            ctx: TaskExecutionContext,
            traceData: T,
            dependencySettings: DependencySettings
        ) throws -> Bool
    }

    public static func exec<T>(
        ctx: TaskExecutionContext,
        adapter: any TaskDependencyVerification.Adapter<T>
    ) async -> CommandResult where T : Decodable {
        do {
            if let taskDependencySettings = (ctx.task.payload as? (any TaskDependencySettingsPayload))?.taskDependencySettings {
                if (taskDependencySettings.dependencySettings.verification) {
                    return try await execWithDependencyVerification(
                        ctx: ctx,
                        taskDependencySettings: taskDependencySettings,
                        adapter: adapter
                    )
                }
            }

            return try await adapter.exec(
                ctx: ctx,
                env: ctx.task.environment.bindingsDictionary
            )
        } catch {
            ctx.outputDelegate.error(error.localizedDescription)
            return .failed
        }
    }

    private static func execWithDependencyVerification<T>(
        ctx: TaskExecutionContext,
        taskDependencySettings: TaskDependencySettings,
        adapter: any TaskDependencyVerification.Adapter<T>
    ) async throws -> CommandResult where T : Decodable {

        let traceFile = taskDependencySettings.traceFile
        if (ctx.executionDelegate.fs.exists(traceFile)) {
            try ctx.executionDelegate.fs.remove(traceFile)
        }

        var env = ctx.task.environment.bindingsDictionary
        let outerTraceFile = adapter.outerTraceFileEnvVar
            .flatMap { env.removeValue(forKey: $0) }
            .map(Path.init)

        let execResult = try await adapter.exec(ctx: ctx, env: env)

        if (execResult == .succeeded) {
            let traceData = try readAndMaybeMergeTraceFile(
                type: T.self,
                fs: ctx.executionDelegate.fs,
                traceFile: traceFile,
                outerTraceFile: outerTraceFile,
            )

            let verified = try adapter.verify(
                ctx: ctx,
                traceData: traceData,
                dependencySettings: taskDependencySettings.dependencySettings,
            )

            if (!verified) {
                return .failed
            }
        }

        return execResult
    }

    private static func readAndMaybeMergeTraceFile<T>(
        type: T.Type,
        fs: any FSProxy,
        traceFile: Path,
        outerTraceFile: Path?,
    ) throws -> T where T : Decodable {
        if let outerTraceFile = outerTraceFile {
            // TODO: Is this file appending concurrent-targets safe?
            let traceFileContent = try fs.read(traceFile)
            try fs.append(outerTraceFile, contents: traceFileContent)
            return try JSONDecoder().decode(type, from: Data(traceFileContent.bytes))
        } else {
            // Fast path
            return try JSONDecoder().decode(type, from: fs.readMemoryMapped(traceFile))
        }
    }
}

extension TaskDependencyVerification.Adapter {
    var outerTraceFileEnvVar: String? {
        return nil
    }

    func exec(ctx: TaskExecutionContext, env: [String: String]) async throws -> CommandResult {
        return try await spawn(ctx: ctx, env: env)
    }

    internal func spawn(ctx: TaskExecutionContext, env: [String: String]) async throws -> CommandResult {
        let processDelegate = TaskProcessDelegate(outputDelegate: ctx.outputDelegate)
        try await TaskAction.spawn(
            commandLine: Array(ctx.task.commandLineAsStrings),
            environment: env,
            workingDirectory: ctx.task.workingDirectory.str,
            dynamicExecutionDelegate: ctx.dynamicExecutionDelegate,
            clientDelegate: ctx.clientDelegate,
            processDelegate: processDelegate,
        )
        if let error = processDelegate.executionError {
            ctx.outputDelegate.error(error)
            return .failed
        }

        return processDelegate.commandResult ?? .failed
    }

    internal func verifyFiles(
        ctx: TaskExecutionContext,
        files: any Sequence<Path>,
        dependencySettings: DependencySettings,
    ) throws -> Bool {
        // Group used files by inferred logical dependency name
        var used = Dictionary(
            grouping: files,
            by: { $0.inferDependencyName() ?? "" }
        )
            .mapValues { OrderedSet($0)}

        // Remove declared dependencies
        dependencySettings.dependencies.forEach { used.removeValue(forKey: $0) }

        // Remove any where we could not infer the dependency
        let unmapped = used.removeValue(forKey: "") ?? []
        if !unmapped.isEmpty {
            ctx.outputDelegate.emitWarning("Could not infer logical dependency for: \(unmapped.map(\.str).joined(separator: ", "))")
        }

        // Any left are undeclared dependencies
        if (!used.isEmpty) {
            let undeclared = used.map {
                $0.key + "\n  " + $0.value.map { "  - " + $0.str }.joined(separator: "\n  ")
            }

            ctx.outputDelegate.error("Undeclared dependencies: \n  " + undeclared.joined(separator: "\n  "))

            return false
        }

        return true
    }
}

public extension Path {
    func inferDependencyName() -> String? {
        findFrameworkName() ?? findLibraryName()
    }

    func findFrameworkName() -> String? {
        if fileExtension == "framework" {
            return basenameWithoutSuffix
        }
        return dirname.isEmpty || dirname.isRoot ? nil : dirname.findFrameworkName()
    }

    func findLibraryName() -> String? {
        if fileExtension == "a" && basename.starts(with: "lib") {
            return String(basenameWithoutSuffix.suffix(from: str.index(str.startIndex, offsetBy: 3)))
        }
        return nil
    }
}
