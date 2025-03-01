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

public import SWBCore
public import SWBUtil
import SWBCAS
import SWBProtocol
import Foundation

public final class GenericCachingTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "generic-caching"
    }

    // We version this task action and include it in cache keys so that when the implementation changes, we have a mechanism to force invalidation.
    static let version = 1

    let enableCacheDebuggingRemarks: Bool
    let enableTaskSandboxEnforcement: Bool
    let sandboxDirectory: Path
    let extraSandboxSubdirectories: [Path]
    let developerDirectory: Path
    let casOptions: CASOptions

    public init(enableCacheDebuggingRemarks: Bool, enableTaskSandboxEnforcement: Bool, sandboxDirectory: Path, extraSandboxSubdirectories: [Path], developerDirectory: Path, casOptions: CASOptions) {
        self.enableCacheDebuggingRemarks = enableCacheDebuggingRemarks
        self.enableTaskSandboxEnforcement = enableTaskSandboxEnforcement
        self.sandboxDirectory = sandboxDirectory
        self.extraSandboxSubdirectories = extraSandboxSubdirectories
        self.developerDirectory = developerDirectory
        self.casOptions = casOptions
        super.init()
    }

    required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        self.enableCacheDebuggingRemarks = try deserializer.deserialize()
        self.enableTaskSandboxEnforcement = try deserializer.deserialize()
        self.sandboxDirectory = try deserializer.deserialize()
        self.extraSandboxSubdirectories = try deserializer.deserialize()
        self.developerDirectory = try deserializer.deserialize()
        self.casOptions = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    public override func serialize<T>(to serializer: T) where T : Serializer {
        serializer.beginAggregate(7)
        serializer.serialize(enableCacheDebuggingRemarks)
        serializer.serialize(enableTaskSandboxEnforcement)
        serializer.serialize(sandboxDirectory)
        serializer.serialize(extraSandboxSubdirectories)
        serializer.serialize(developerDirectory)
        serializer.serialize(casOptions)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    override public func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        func emitCacheDebuggingRemark(_ message: String) {
            if enableCacheDebuggingRemarks {
                outputDelegate.remark(message)
            }
        }
        guard let cas = dynamicExecutionDelegate.operationContext.cas else {
            outputDelegate.error("caching is enabled, but no CAS was provided")
            return .failed
        }

        defer {
            if cas.supportsPruning {
                dynamicExecutionDelegate.operationContext.compilationCachingDataPruner.pruneCAS(cas,
                                                                                                key: .init(path: casOptions.casPath, casOptions: casOptions),
                                                                                                activityReporter: dynamicExecutionDelegate,
                                                                                                fileSystem: executionDelegate.fs)
            }
        }

        // Ingest the inputs
        let cacheKey: CacheKey
        let keyObjectID: ToolchainDataID
        do {
            let inputIDs = try await task.inputPaths.concurrentMap(maximumParallelism: 10) {
                try await CASFSNode.import(path: $0, fs: executionDelegate.fs, cas: cas)
            }
            cacheKey = CacheKey(commandLine: task.commandLine, environmentBindings: task.environment, workingDirectory: task.workingDirectory, version: Self.version, inputIDs: inputIDs)
            keyObjectID = try await cacheKey.store(in: cas)
            emitCacheDebuggingRemark("cache key: \(keyObjectID)")

            // Replay a cached result if we have one.
            // TODO: replay diagnostics and other output
            if let cacheHitID = try await cas.lookupCachedObject(for: keyObjectID) {
                let cacheHit = try await CachedValue.load(from: cas, id: cacheHitID)
                guard task.outputPaths.count == cacheHit.outputRefs.count else {
                    throw StubError.error("Unexpectedly found cache hit with \(cacheHit.outputRefs.count) outputs for task with \(task.outputPaths.count) outputs")
                }
                outputDelegate.emitOutput(cacheHit.processOutput)
                for diagnostic in cacheHit.diagnostics {
                    outputDelegate.emit(diagnostic)
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (outputPath, outputID) in zip(task.outputPaths, cacheHit.outputRefs) {
                        group.addTask {
                            let node = try await CASFSNode.load(id: outputID, cas: cas)
                            try await node.export(at: outputPath, fs: executionDelegate.fs, cas: cas)
                        }
                    }
                    try await group.waitForAll()
                }
                emitCacheDebuggingRemark("replaying cache hit: \(cacheHitID)")
                outputDelegate.incrementTaskCounter(.cacheHits)
                return .succeeded
            }
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }

        // Execute the task in a sandbox
        emitCacheDebuggingRemark("executing underlying task")
        outputDelegate.incrementTaskCounter(.cacheMisses)
        let capturingOutputDelegate = CapturingTaskOutputDelegate(underlyingTaskOutputDelegate: outputDelegate)
        let processDelegate = TaskProcessDelegate(outputDelegate: capturingOutputDelegate)
        do {
            try executionDelegate.fs.createDirectory(sandboxDirectory, recursive: true)
            try await withTemporaryDirectory(dir: sandboxDirectory, removeTreeOnDeinit: false) { sandboxDirectory in
                var inputRemappings: [Path: Path] = [:]
                for (number, input) in task.inputPaths.enumerated() {
                    let remappedPath = sandboxDirectory.join("inputs/\(number)/").join(input.withoutTrailingSlash().basename)
                    try executionDelegate.fs.createDirectory(remappedPath.dirname, recursive: true)
                    inputRemappings[input.normalize()] = remappedPath
                }
                var outputRemappings: [Path: Path] = [:]
                var postExecutionCopies: [(Path, Path)] = []
                for (number, output) in task.outputPaths.enumerated() {
                    let remappedPath = sandboxDirectory.join("outputs/\(number)/").join(output.withoutTrailingSlash().basename)
                    try executionDelegate.fs.createDirectory(remappedPath.dirname, recursive: true)
                    postExecutionCopies.append((remappedPath, output))
                    outputRemappings[output.normalize()] = remappedPath
                }
                emitCacheDebuggingRemark("original command line: \(cacheKey.commandLine)")
                let remappedCommandLine = cacheKey.commandLine.map { arg in
                    switch arg {
                    case .literal(let byteString):
                        return byteString.asString
                    case .path(let path):
                        if let remapping = outputRemappings[path.normalize()] {
                            return remapping.str
                        }
                        if let remapping = inputRemappings[path.normalize()] {
                            return remapping.str
                        }
                        return path.str
                    case .parentPath(let path):
                        if let remapping = outputRemappings[path.normalize()] {
                            return remapping.dirname.str
                        }
                        if let remapping = inputRemappings[path.normalize()] {
                            return remapping.dirname.str
                        }
                        return path.dirname.str
                    }
                }
                emitCacheDebuggingRemark("remapped command line: \(remappedCommandLine.joined(separator: " "))")
                let remappedTempPath = sandboxDirectory.join("temp")
                try executionDelegate.fs.createDirectory(remappedTempPath)
                let remappedEnvironment = EnvironmentBindings(cacheKey.environmentBindings.bindings + [
                    ("TMPDIR", remappedTempPath.str),
                    ("TEMP", remappedTempPath.str),
                    ("TEMPDIR", remappedTempPath.str),
                    ("TMP", remappedTempPath.str)
                ])
                emitCacheDebuggingRemark("remapped environment: \(remappedEnvironment.bindingsDictionary)")

                let sandboxArgs = enableTaskSandboxEnforcement ? try Self.prepareSandboxEnforcementArgs(sandboxDirectory: sandboxDirectory, developerDirectory: developerDirectory, executionDelegate: executionDelegate) : []

                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (source, destination) in inputRemappings {
                        group.addTask {
                            try executionDelegate.fs.copy(source, to: destination)
                            emitCacheDebuggingRemark("copying input \(source) to \(destination)")
                        }
                    }
                    try await group.waitForAll()
                }

                for dir in self.extraSandboxSubdirectories {
                    try executionDelegate.fs.createDirectory(sandboxDirectory.join(dir))
                }

                emitCacheDebuggingRemark("running sandboxed command")
                try await spawn(commandLine: sandboxArgs + remappedCommandLine, environment: remappedEnvironment.bindingsDictionary, workingDirectory: cacheKey.workingDirectory.str, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: processDelegate)

                if processDelegate.commandResult == .succeeded {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for copy in postExecutionCopies {
                            group.addTask {
                                emitCacheDebuggingRemark("copying output \(copy.0.str) to \(copy.1.str)")
                                if executionDelegate.fs.isDirectory(copy.1) {
                                    try? executionDelegate.fs.removeDirectory(copy.1)
                                } else {
                                    try? executionDelegate.fs.remove(copy.1)
                                }
                                try executionDelegate.fs.copy(copy.0, to: copy.1)
                            }
                        }
                        try await group.waitForAll()
                    }
                }
            }
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }
        let executionResult = processDelegate.commandResult ?? .failed

        // Cache the outputs
        // TODO: cache diagnostics and other output
        if executionResult == .succeeded {
            do {
                let outputIDs = try await task.outputPaths.concurrentMap(maximumParallelism: 10) {
                    try await CASFSNode.import(path: $0, fs: executionDelegate.fs, cas: cas)
                }
                let cachedValueID = try await CachedValue(outputRefs: outputIDs, processOutput: capturingOutputDelegate.capturedOutput, diagnostics: capturingOutputDelegate.capturedDiagnostics).store(in: cas)
                try await cas.cache(objectID: cachedValueID, forKeyID: keyObjectID)
                emitCacheDebuggingRemark("caching result: \(cachedValueID)")
            } catch {
                outputDelegate.warning("failed to cache task outputs: \(error.localizedDescription)")
            }
        }

        return executionResult
    }

    static func prepareSandboxEnforcementArgs(sandboxDirectory: Path, developerDirectory: Path, executionDelegate: any TaskExecutionDelegate) throws -> [String] {
        // We only support enforcement of the task sandbox on a macOS host
        #if os(macOS)
        let sandboxPath = sandboxDirectory.join("sandbox.sb")
        let sandboxProfile: ByteString = """
        (version 1)
        (allow default)
        
        (deny network*)
        
        (deny file-write*)
        (allow file-write* (subpath "/dev/")) ; Allow writes to locations such as /dev/null
        
        (deny file-read* (subpath "/Users/")) ; Block access to most locations under user control, while allowing reads to parts of the system required by frameworks and tools
        (allow file-read* (subpath (param "XCODE"))) ; Allow reads into Xcode.app

        ; Allow reads and writes to cache and logs directories
        (allow file-read* file-write* (subpath (param "USER_CACHE_DIR")))
        (allow file-read* file-write* (subpath (param "DARWIN_USER_CACHE_DIR")))
        (allow file-read* file-write* (subpath (param "DARWIN_USER_TEMP_DIR")))
        (allow file-read* file-write* (subpath (param "USER_LOGS_DIR")))
        (allow file-read* file-write* (subpath (param "USER_DEVELOPER_DIR")))

        ; Allow reads and writes to the task sandbox location
        (allow file-read* file-write* (subpath (param "TASK_SANDBOX")))
        
        ; Allow reads and writes to specific files required by system frameworks and libraries
        (allow file-read-data file-write-data
          (regex
            #"/\\.CFUserTextEncoding$"
            #"^/usr/share/nls/"
            #"^/usr/share/zoneinfo /var/db/timezone/zoneinfo/"
          ))
        
        (allow file-read-metadata)
        """
        try executionDelegate.fs.write(sandboxPath, contents: sandboxProfile)

         return [
            "/usr/bin/sandbox-exec",
            "-D", "TASK_SANDBOX=\(sandboxDirectory.str)",
            "-D", "XCODE=\(developerDirectory.dirname.dirname.str)",
            "-D", "USER_CACHE_DIR=\(Path.homeDirectory.join("Library/Caches").str)",
            "-D", "DARWIN_USER_CACHE_DIR=\(userCacheDir().str)",
            "-D", "DARWIN_USER_TEMP_DIR=\(try executionDelegate.fs.realpath(Path.temporaryDirectory).str)",
            "-D", "USER_LOGS_DIR=\(Path.homeDirectory.join("Library/Logs").str)",
            "-D", "USER_DEVELOPER_DIR=\(Path.homeDirectory.join("Library/Developer").str)",
            "-f", sandboxPath.str
        ]
        #else
        return []
        #endif
    }
}

fileprivate struct CacheKey {
    let commandLine: [CommandLineArgument]
    let environmentBindings: EnvironmentBindings
    let workingDirectory: Path
    let version: Int
    let inputIDs: [ToolchainDataID]

    init(commandLine: [CommandLineArgument], environmentBindings: EnvironmentBindings, workingDirectory: Path, version: Int, inputIDs: [ToolchainDataID]) {
        self.commandLine = commandLine
        self.environmentBindings = environmentBindings
        self.workingDirectory = workingDirectory
        self.inputIDs = inputIDs
        self.version = version
    }

    func store(in cas: ToolchainCAS) async throws -> ToolchainDataID {
        let serializer = MsgPackSerializer()
        serializer.beginAggregate(4)
        serializer.serialize(commandLine)
        serializer.serialize(environmentBindings)
        serializer.serialize(workingDirectory)
        serializer.serialize(version)
        serializer.endAggregate()
        return try await cas.store(object: .init(data: serializer.byteString, refs: inputIDs))
    }

    static func load(from cas: ToolchainCAS, id: ToolchainDataID) async throws -> CacheKey {
        guard let casObject = try await cas.load(id: id) else {
            throw StubError.error("Could not load cached value")
        }
        let deserializer = MsgPackDeserializer(casObject.data)
        try deserializer.beginAggregate(4)
        let commandLine: [CommandLineArgument] = try deserializer.deserialize()
        let environmentBindings: EnvironmentBindings = try deserializer.deserialize()
        let workingDirectory: Path = try deserializer.deserialize()
        let version: Int = try deserializer.deserialize()
        return CacheKey(commandLine: commandLine, environmentBindings: environmentBindings, workingDirectory: workingDirectory, version: version, inputIDs: casObject.refs)
    }
}

fileprivate struct CachedValue {
    let outputRefs: [ToolchainDataID]
    let processOutput: ByteString
    let diagnostics: [Diagnostic]

    init(outputRefs: [ToolchainDataID], processOutput: ByteString, diagnostics: [Diagnostic]) {
        self.outputRefs = outputRefs
        self.processOutput = processOutput
        self.diagnostics = diagnostics
    }

    func store(in cas: ToolchainCAS) async throws -> ToolchainDataID {
        let serializer = MsgPackSerializer()
        serializer.serialize(processOutput)
        serializer.serialize(diagnostics)
        return try await cas.store(object: .init(data: serializer.byteString, refs: outputRefs))
    }

    static func load(from cas: ToolchainCAS, id: ToolchainDataID) async throws -> CachedValue {
        guard let casObject = try await cas.load(id: id) else {
            throw StubError.error("Could not load cached value")
        }
        let deserializer = MsgPackDeserializer(casObject.data)
        let processOutput: ByteString = try deserializer.deserialize()
        let diagnostics: [Diagnostic] = try deserializer.deserialize()
        return CachedValue(outputRefs: casObject.refs, processOutput: processOutput, diagnostics: diagnostics)
    }
}

fileprivate final class CapturingTaskOutputDelegate: TaskOutputDelegate {
    let underlyingTaskOutputDelegate: any TaskOutputDelegate
    let capturingDiagnosticsEngine: DiagnosticsEngine
    var capturedOutput: ByteString = .init()
    var capturedDiagnostics: [Diagnostic] = []

    init(underlyingTaskOutputDelegate: any TaskOutputDelegate) {
        self.underlyingTaskOutputDelegate = underlyingTaskOutputDelegate
        self.capturingDiagnosticsEngine = .init()
        self.capturingDiagnosticsEngine.addHandler { diagnostic in
            self.capturedDiagnostics.append(diagnostic)
            self.underlyingTaskOutputDelegate.diagnosticsEngine.emit(diagnostic)
        }
    }

    var diagnosticsEngine: SWBCore.DiagnosticProducingDelegateProtocolPrivate<SWBUtil.DiagnosticsEngine> {
        .init(self.capturingDiagnosticsEngine)
    }

    func emitOutput(_ data: ByteString) {
        capturedOutput += data
        underlyingTaskOutputDelegate.emitOutput(data)
    }

    var startTime: Date {
        underlyingTaskOutputDelegate.startTime
    }

    func updateResult(_ result: SWBCore.TaskResult) {
        underlyingTaskOutputDelegate.updateResult(result)
    }

    func subtaskUpToDate(_ subtask: any SWBCore.ExecutableTask) {
        underlyingTaskOutputDelegate.subtaskUpToDate(subtask)
    }

    func previouslyBatchedSubtaskUpToDate(signature: SWBUtil.ByteString, target: SWBCore.ConfiguredTarget) {
        underlyingTaskOutputDelegate.previouslyBatchedSubtaskUpToDate(signature: signature, target: target)
    }

    func incrementClangCacheHit() {
        underlyingTaskOutputDelegate.incrementClangCacheHit()
    }

    func incrementClangCacheMiss() {
        underlyingTaskOutputDelegate.incrementClangCacheMiss()
    }

    func incrementSwiftCacheHit() {
        underlyingTaskOutputDelegate.incrementSwiftCacheHit()
    }

    func incrementSwiftCacheMiss() {
        underlyingTaskOutputDelegate.incrementSwiftCacheMiss()
    }

    func incrementTaskCounter(_ counter: BuildOperationMetrics.TaskCounter) {
        underlyingTaskOutputDelegate.incrementTaskCounter(counter)
    }

    var counters: [BuildOperationMetrics.Counter : Int] {
        underlyingTaskOutputDelegate.counters
    }

    var taskCounters: [BuildOperationMetrics.TaskCounter : Int] {
        underlyingTaskOutputDelegate.taskCounters
    }

    var result: SWBCore.TaskResult? {
        underlyingTaskOutputDelegate.result
    }
}
