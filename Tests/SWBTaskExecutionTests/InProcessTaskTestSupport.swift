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

// Support for testing in-process tasks.

import struct Foundation.Date

public import SWBCore
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import enum SWBProtocol.ExternalToolResult
import struct SWBProtocol.BuildOperationMetrics
import SWBMacro
import Synchronization

struct MockExecutionDelegate: TaskExecutionDelegate {
    struct Lookup: PlatformInfoLookup {
        func lookupPlatformInfo(platform: SWBUtil.BuildVersion.Platform) -> (any SWBUtil.PlatformInfoProvider)? {
            nil
        }
    }

    let fs: any FSProxy
    let buildCommand: BuildCommand?
    let schemeCommand: SchemeCommand?
    let environment: [String: String]?
    let userPreferences: UserPreferences
    let infoLookup: any PlatformInfoLookup
    var sdkRegistry: SDKRegistry { core!.sdkRegistry }
    var specRegistry: SpecRegistry { core!.specRegistry }
    var platformRegistry: PlatformRegistry { core!.platformRegistry }
    var namespace: MacroNamespace
    var requestContext: SWBCore.BuildRequestContext { fatalError() }
    var emitFrontendCommandLines: Bool { false }
    private var core: Core?

    func taskDiscoveredRequiredTargetDependency(target: ConfiguredTarget, antecedent: ConfiguredTarget, reason: RequiredTargetDependencyReason, warningLevel: BooleanWarningLevel) {}

    init(fs: (any FSProxy)? = nil, buildCommand: BuildCommand? = nil, schemeCommand: SchemeCommand? = .launch, environment: [String: String]? = nil, userPreferences: UserPreferences = .defaultForTesting, infoLookup: (any PlatformInfoLookup)? = nil, core: Core? = nil) {
        self.fs = fs ?? PseudoFS()
        self.buildCommand = buildCommand
        self.schemeCommand = schemeCommand
        self.environment = environment
        self.userPreferences = userPreferences
        self.infoLookup = infoLookup ?? Lookup()
        self.core = core
        self.namespace = MacroNamespace(parent: BuiltinMacros.namespace)
    }
}

struct MockTaskExecutionClientDelegate: TaskExecutionClientDelegate {
    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
        .deferred
    }
}

final class MockTaskOutputDelegate: TaskOutputDelegate {
    var result: SWBCore.TaskResult?

    let startTime = Date()

    private let _diagnosticsEngine = DiagnosticsEngine()

    func incrementClangCacheHit() {
        state.state.withLock { state in
            state.counters[.clangCacheHits, default: 0] += 1
        }
    }

    func incrementClangCacheMiss() {
        state.state.withLock { state in
            state.counters[.clangCacheMisses, default: 0] += 1
        }
    }

    func incrementSwiftCacheHit() {
        state.state.withLock { state in
            state.counters[.swiftCacheHits, default: 0] += 1
        }
    }

    func incrementSwiftCacheMiss() {
        state.state.withLock { state in
            state.counters[.swiftCacheMisses, default: 0] += 1
        }
    }

    func incrementTaskCounter(_ counter: BuildOperationMetrics.TaskCounter) {
        state.state.withLock { state in
            state.taskCounters[counter, default: 0] += 1
        }
    }

    var counters: [SWBProtocol.BuildOperationMetrics.Counter : Int] {
        state.state.withLock { $0.counters }
    }

    var taskCounters: [SWBProtocol.BuildOperationMetrics.TaskCounter : Int] {
        state.state.withLock { $0.taskCounters }
    }

    struct State {
        var counters: [BuildOperationMetrics.Counter : Int] = [:]
        var taskCounters: [BuildOperationMetrics.TaskCounter : Int] = [:]
        var messages: [String] = []
        var errors: [String] = []
        var warnings: [String] = []
        var notes: [String] = []
        var remarks: [String] = []
        let text = OutputByteStream()
        fileprivate(set) var upToDateSubtasks: [any ExecutableTask] = []
        fileprivate(set) var result: TaskResult? = nil

        mutating func emitError(_ message: String) {
            errors.append("error: \(message)")
            messages.append("error: \(message)")
        }
        mutating func emitWarning(_ message: String) {
            warnings.append("warning: \(message)")
            messages.append("warning: \(message)")
        }
        mutating func emitNote(_ message: String) {
            notes.append("note: \(message)")
            messages.append("note: \(message)")
        }
        mutating func emitRemark(_ message: String) {
            remarks.append("remark: \(message)")
            messages.append("remark: \(message)")
        }
        mutating func appendText(_ bytes: ByteString) {
            text <<< bytes
        }
    }

    var messages: [String] {
        state.state.withLock { $0.messages }
    }

    var errors: [String] {
        state.state.withLock { $0.errors }
    }

    var warnings: [String] {
        state.state.withLock { $0.warnings }
    }

    var notes: [String] {
        state.state.withLock { $0.notes }
    }

    var remarks: [String] {
        state.state.withLock { $0.remarks }
    }

    var textBytes: ByteString {
        state.state.withLock { $0.text.bytes }
    }

    final class StateHolder: Sendable {
        let state = SWBMutex<State>(.init())
    }

    let state: StateHolder

    init() {
        let state = StateHolder()
        self.state = state
        _diagnosticsEngine.addHandler { diag in
            state.state.withLock { state in
                switch diag.behavior {
                case .error:
                    state.emitError(diag.formatLocalizedDescription(.debugWithoutBehavior))
                case .warning:
                    state.emitWarning(diag.formatLocalizedDescription(.debugWithoutBehavior))
                case .note:
                    state.emitNote(diag.formatLocalizedDescription(.debugWithoutBehavior))
                case .remark:
                    state.emitRemark(diag.formatLocalizedDescription(.debugWithoutBehavior))
                case .ignored:
                    break
                }
            }
        }
    }

    var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return .init(_diagnosticsEngine)
    }

    var diagnostics: [Diagnostic] {
        return _diagnosticsEngine.diagnostics
    }

    func emitError(_ message: String) {
        state.state.withLock { state in
            state.emitError(message)
        }
    }
    func emitWarning(_ message: String) {
        state.state.withLock { state in
            state.emitWarning(message)
        }
    }
    func emitNote(_ message: String) {
        state.state.withLock { state in
            state.emitNote(message)
        }
    }
    func emitRemark(_ message: String) {
        state.state.withLock { state in
            state.emitRemark(message)
        }
    }
    func emitOutput(_ data: ByteString) {
        state.state.withLock { state in
            state.appendText(data)
        }
    }
    func subtaskUpToDate(_ subtask: any SWBCore.ExecutableTask) {
        state.state.withLock { state in
            state.upToDateSubtasks.append(subtask)
        }
    }
    func previouslyBatchedSubtaskUpToDate(signature: SWBUtil.ByteString, target: SWBCore.ConfiguredTarget) {}
    func updateResult(_ result: TaskResult) {
        state.state.withLock { state in
            state.result = result
        }
    }
}

final class MockTaskTypeDescription: TaskTypeDescription {
    let isUnsafeToInterrupt: Bool = false

    init() { }

    let payloadType: (any TaskPayload.Type)? = nil
    var toolBasenameAliases: [String] { return [] }
    func commandLineForSignature(for task: any ExecutableTask) -> [ByteString]? { return nil }
    func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] { return [] }
    func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] { return [] }
    func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] { return [] }
    func generateDocumentationInfo(for task: any ExecutableTask, input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput] { return [] }
    func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] { return [] }
    func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? { return nil }
    func interestingPath(for task: any ExecutableTask) -> Path? { return nil }
}
public let mockTaskType: any TaskTypeDescription = MockTaskTypeDescription()
