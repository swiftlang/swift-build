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
public import enum SWBProtocol.ExternalToolResult
public import struct SWBProtocol.BuildOperationTaskEnded
public import SWBTaskConstruction
import SWBTaskExecution
package import SWBUtil
import Testing
package import SWBMacro
import Foundation
import Synchronization

extension PlannedTask {
    package var dependencyData: DependencyDataStyle? {
        execTask.dependencyData
    }

    package var commandLine: [ByteString] {
        execTask.commandLine.map(\.asByteString)
    }

    package var commandLineAsStrings: AnySequence<String> {
        execTask.commandLineAsStrings
    }

    package var environment: EnvironmentBindings {
        execTask.environment
    }

    package var workingDirectory: Path {
        execTask.workingDirectory
    }

    package var preparesForIndexing: Bool {
        execTask.preparesForIndexing
    }

    package var execDescription: String? {
        execTask.execDescription
    }

    package func generateIndexingInfo(input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        execTask.generateIndexingInfo(input: input)
    }

    /// Convenience method to report on a task when emitting a test failure.
    package var testIssueDescription: String {
        var result = ""
        if let targetName = forTarget?.target.name {
            result = result + "\(targetName):"
        }
        result = result + ruleInfo.quotedDescription
        return result
    }
}

/// Conditions which can describe possible task matches in test results.
package enum TaskCondition: CustomStringConvertible, Sendable {
    /// Match against the specific target.
    case matchTarget(ConfiguredTarget)
    /// Match against any target with the given name.
    case matchTargetName(String)
    /// Match against any task with the given rule info.
    case matchRule([String])
    /// Match against any task matching the given rule info.
    case matchRulePattern([StringPattern])
    /// Match against any task with the given rule type.
    case matchRuleType(String)
    /// Match against any task with the given string in the rule info.
    case matchRuleItem(String)
    /// Match against any task whose rule info contains an item with the given basename.
    case matchRuleItemBasename(String)
    /// Match against any task whose rule info contains an item with the given pattern.
    case matchRuleItemPattern(StringPattern)
    /// Match against any task whose command line contains the given argument.
    case matchCommandLineArgument(String)
    /// Match against any task whose command line contains an argument with the given pattern.
    case matchCommandLineArgumentPattern(StringPattern)

    package var description: String {
        switch self {
        case .matchTarget(let target):
            return "Target == \(target)"

        case .matchTargetName(let name):
            return "Target == \(name)"

        case .matchRule(let rule):
            return "Rule == \(rule)"

        case .matchRulePattern(let rulePattern):
            return "Rule matches \(rulePattern)"

        case .matchRuleType(let name):
            return "RuleType == \(name)"

        case .matchRuleItem(let name):
            return "RuleItems contains \(name)"

        case .matchRuleItemBasename(let name):
            return "RuleItem.basename == \(name)"

        case .matchRuleItemPattern(let pattern):
            return "RuleItem matches \(pattern)"

        case .matchCommandLineArgument(let argument):
            return "CommandLineArguments contains \(argument)"

        case .matchCommandLineArgumentPattern(let pattern):
            return "CommandLineArguments match \(pattern)"
        }
    }

    package func match(_ task: any PlannedTask) -> Bool {
        return match(task.execTask)
    }

    package func match(_ task: any ExecutableTask) -> Bool {
        return match(target: task.forTarget, ruleInfo: task.ruleInfo, commandLine: task.commandLine.map(\.asByteString))
    }

    package func match(target forTarget: ConfiguredTarget?, ruleInfo: [String], commandLine: [ByteString]) -> Bool {
        switch self {
        case .matchTarget(let target):
            return forTarget == target

        case .matchTargetName(let name):
            return forTarget?.target.name == name

        case .matchRule(let rule):
            return ruleInfo == rule

        case .matchRulePattern(let rulePattern):
            return rulePattern ~= ruleInfo

        case .matchRuleType(let name):
            return ruleInfo.first == name

        case .matchRuleItem(let name):
            return ruleInfo.firstIndex(where: { $0 == name }) != nil

        case .matchRuleItemBasename(let name):
            return ruleInfo.firstIndex(where: { Path($0).basename == name }) != nil

        case .matchRuleItemPattern(let pattern):
            return ruleInfo.firstIndex(where: { pattern ~= $0 }) != nil

        case .matchCommandLineArgument(let argument):
            return commandLine.firstIndex(where: { $0 == argument }) != nil

        case .matchCommandLineArgumentPattern(let pattern):
            return commandLine.firstIndex(where: { item in
                guard let itemStr = item.stringValue else {
                    return false
                }

                return pattern ~= itemStr
            }) != nil
        }
    }
}

package extension Array where Element == TaskCondition {
    static func gateTask(_ targetName: String, suffix: String) -> [TaskCondition] {
        return [.matchTargetName(targetName), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("-\(suffix)"))]
    }

    static func compileC(_ targetName: String, fileName: String) -> [TaskCondition] {
        return [.matchTargetName(targetName), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix(fileName))]
    }

    static func compileSwift(_ targetName: String) -> [TaskCondition] {
        return [.matchTargetName(targetName), .matchRuleType("SwiftDriver Compilation")]
    }

    static func emitSwiftCompilationRequirements(_ targetName: String) -> [TaskCondition] {
        return [.matchTargetName(targetName), .matchRuleType("SwiftDriver Compilation Requirements")]
    }
}

open class MockTestTaskPlanningClientDelegate: TaskPlanningClientDelegate, @unchecked Sendable {
    package init() {}

    open func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> ExternalToolResult {
        let args = commandLine.dropFirst()
        switch commandLine.first.map(Path.init)?.basenameWithoutSuffix {
        case "actool" where args == ["--version", "--output-format", "xml1"]:
            return .deferred
        case "cat": // docc
            return .deferred
        case "clang" where args.first == "-v":
            return .deferred
        case "distill" where args == ["--version"]:
            return .deferred
        case "distill" where args == ["--version", "--output-format", "xml1"]:
            return .deferred
        case "ibtool" where args == ["--version", "--output-format", "xml1"]:
            return .deferred
        case "iig" where args == ["--version"]:
            return .deferred
        case "ld" where args == ["-version_details"]:
            return .deferred
        case "libtool" where args == ["-V"] || args == ["--version"]:
            return .deferred
        case "mig" where args == ["-version"]:
            return .deferred
        case "swiftc" where args == ["--version"]:
            return .deferred
        case "tapi" where args == ["--version"]:
            return .deferred
        case "what":
            return .deferred
        default:
            break
        }
        throw StubError.error("Unit test should implement its own instance of TaskPlanningClientDelegate.")
    }
}

package class TestTaskPlanningDelegate: TaskPlanningDelegate, @unchecked Sendable {
    private let _diagnosticsEngines = LockedValue<[ConfiguredTarget?: DiagnosticsEngine]>(.init())

    private let queue = SWBQueue(label: "SWBTestSupport.TestTaskPlanningDelegate.queue", qos: UserDefaults.defaultRequestQoS)

    let allPlannedBuildDirectoryNodes = SWBMutex<[Path: PlannedPathNode]>([:])
    let fs: any FSProxy
    let tmpDir: NamedTemporaryDirectory?

    package init(clientDelegate: any TaskPlanningClientDelegate, workspace: Workspace? = nil, fs: any FSProxy) {
        self.clientDelegate = clientDelegate
        self.diagnosticContext = DiagnosticContextData(target: nil)
        self.fs = fs
        self.tmpDir = try? NamedTemporaryDirectory(fs: fs)
    }

    package let diagnosticContext: DiagnosticContextData

    package func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngines.withLock { diagnosticsEngines in
            diagnosticsEngines.getOrInsert(target, { DiagnosticsEngine() })
        })
    }

    var diagnostics: [ConfiguredTarget?: [Diagnostic]] {
        _diagnosticsEngines.withLock { $0.mapValues { $0.diagnostics } }
    }

    package func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        .init(rawValue: -1)
    }

    package func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {

    }

    package func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {

    }

    package func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {

    }

    package var hadErrors: Bool {
        false
    }

    package var cancelled: Bool { return false }
    package func updateProgress(statusMessage: String, showInLog: Bool) { }

    package func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        return MakePlannedVirtualNode(name)
    }

    package func createNode(absolutePath path: Path) -> PlannedPathNode {
        assert(path.isAbsolute)
        return MakePlannedPathNode(path)
    }

    package func createDirectoryTreeNode(absolutePath path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        return MakePlannedDirectoryTreeNode(path, excluding: excluding)
    }

    package func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode {
        assert(path.isAbsolute)
        return allPlannedBuildDirectoryNodes.withLock { allPlannedBuildDirectoryNodes in
            if let node = allPlannedBuildDirectoryNodes[path] {
                return node
            } else {
                let node = createNode(absolutePath: path)
                allPlannedBuildDirectoryNodes[path] = node
                return node
            }
        }
    }

    package func createTask(_ builder: inout PlannedTaskBuilder) -> any PlannedTask {
        return ConstructedTask(&builder, execTask: Task(&builder))
    }

    package func createGateTask(_ inputs: [any PlannedNode], output: any PlannedNode, name: String, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) -> any PlannedTask {
        var builder = PlannedTaskBuilder(type: GateTask.type, ruleInfo: ["Gate", name], commandLine: [], environment: EnvironmentBindings(), inputs: inputs, outputs: [output], mustPrecede: mustPrecede, repairViaOwnershipAnalysis: false)
        builder.preparesForIndexing = true
        builder.makeGate()
        taskConfiguration(&builder)
        return GateTask(&builder, execTask: Task(&builder))
    }

    package func recordAttachment(contents: SWBUtil.ByteString) -> SWBUtil.Path {
        let digester = InsecureHashContext()
        digester.add(bytes: contents)
        if let path = tmpDir?.path.join(digester.signature.asString) {
            do {
                try fs.write(path, contents: contents)
            } catch {
                Issue.record("Failed to write attachment at \(path): \(error.localizedDescription)")
                return Path("")
            }
            return path
        } else {
            Issue.record("Failed to create temporary directory")
            return Path("")
        }
    }

    package var taskActionCreationDelegate: any TaskActionCreationDelegate { return self }

    package let clientDelegate: any TaskPlanningClientDelegate
}

extension TestTaskPlanningDelegate: TaskActionCreationDelegate {
    package func createAuxiliaryFileTaskAction(_ context: AuxiliaryFileTaskActionContext) -> any PlannedTaskAction {
        return AuxiliaryFileTaskAction(context)
    }

    package func createCodeSignTaskAction() -> any PlannedTaskAction {
        return CodeSignTaskAction()
    }

    package func createConcatenateTaskAction() -> any PlannedTaskAction {
        return ConcatenateTaskAction()
    }

    package func createCopyPlistTaskAction() -> any PlannedTaskAction {
        return CopyPlistTaskAction()
    }

    package func createCopyStringsFileTaskAction() -> any PlannedTaskAction {
        return CopyStringsFileTaskAction()
    }

    package func createCopyTiffTaskAction() -> any PlannedTaskAction {
        return CopyTiffTaskAction()
    }

    package func createDeferredExecutionTaskAction() -> any PlannedTaskAction {
        return DeferredExecutionTaskAction()
    }

    package func createBuildDirectoryTaskAction() -> any PlannedTaskAction {
        return CreateBuildDirectoryTaskAction()
    }

    package func createSwiftHeaderToolTaskAction() -> any PlannedTaskAction {
        return SwiftHeaderToolTaskAction()
    }

    package func createEmbedSwiftStdLibTaskAction() -> any PlannedTaskAction {
        return EmbedSwiftStdLibTaskAction()
    }

    package func createFileCopyTaskAction(_ context: FileCopyTaskActionContext) -> any PlannedTaskAction {
        return FileCopyTaskAction(context)
    }

    package func createGenericCachingTaskAction(enableCacheDebuggingRemarks: Bool, enableTaskSandboxEnforcement: Bool, sandboxDirectory: Path, extraSandboxSubdirectories: [Path], developerDirectory: Path, casOptions: CASOptions) -> any PlannedTaskAction {
        return GenericCachingTaskAction(enableCacheDebuggingRemarks: enableCacheDebuggingRemarks, enableTaskSandboxEnforcement: enableTaskSandboxEnforcement, sandboxDirectory: sandboxDirectory, extraSandboxSubdirectories: extraSandboxSubdirectories, developerDirectory: developerDirectory, casOptions: casOptions)
    }

    package func createInfoPlistProcessorTaskAction(_ contextPath: Path) -> any PlannedTaskAction {
        return InfoPlistProcessorTaskAction(contextPath)
    }

    package func createMergeInfoPlistTaskAction() -> any PlannedTaskAction {
        return MergeInfoPlistTaskAction()
    }

    package func createLinkAssetCatalogTaskAction() -> any PlannedTaskAction {
        return LinkAssetCatalogTaskAction()
    }

    package func createLSRegisterURLTaskAction() -> any PlannedTaskAction {
        return LSRegisterURLTaskAction()
    }

    package func createProcessProductEntitlementsTaskAction(scope: MacroEvaluationScope, mergedEntitlements: PropertyListItem, entitlementsVariant: EntitlementsVariant, destinationPlatformName: String, entitlementsFilePath: Path?, fs: any FSProxy) -> any PlannedTaskAction {
        return ProcessProductEntitlementsTaskAction(scope: scope, fs: fs, entitlements: mergedEntitlements, entitlementsVariant: entitlementsVariant, destinationPlatformName: destinationPlatformName, entitlementsFilePath: entitlementsFilePath)
    }

    package func createProcessProductProvisioningProfileTaskAction() -> any PlannedTaskAction {
        return ProcessProductProvisioningProfileTaskAction()
    }

    package func createRegisterExecutionPolicyExceptionTaskAction() -> any PlannedTaskAction {
        return RegisterExecutionPolicyExceptionTaskAction()
    }

    package func createValidateProductTaskAction() -> any PlannedTaskAction {
        return ValidateProductTaskAction()
    }

    package func createConstructStubExecutorInputFileListTaskAction() -> any PlannedTaskAction {
        return ConstructStubExecutorInputFileListTaskAction()
    }

    package func createODRAssetPackManifestTaskAction() -> any PlannedTaskAction {
        return ODRAssetPackManifestTaskAction()
    }

    package func createClangCompileTaskAction() -> any PlannedTaskAction {
        return ClangCompileTaskAction()
    }

    package func createClangScanTaskAction() -> any PlannedTaskAction {
        return ClangScanTaskAction()
    }

    package func createSwiftDriverTaskAction() -> any PlannedTaskAction {
        return SwiftDriverTaskAction()
    }

    package func createSwiftCompilationRequirementTaskAction() -> any PlannedTaskAction {
        return SwiftDriverCompilationRequirementTaskAction()
    }

    package func createSwiftCompilationTaskAction() -> any PlannedTaskAction {
        return SwiftCompilationTaskAction()
    }

    package func createProcessXCFrameworkTask() -> any PlannedTaskAction {
        return ProcessXCFrameworkTaskAction()
    }

    package func createValidateDevelopmentAssetsTaskAction() -> any PlannedTaskAction {
        return ValidateDevelopmentAssetsTaskAction()
    }

    package func createSignatureCollectionTaskAction() -> any PlannedTaskAction {
        return SignatureCollectionTaskAction()
    }

    package func createClangModuleVerifierInputGeneratorTaskAction() -> any PlannedTaskAction {
        return ClangModuleVerifierInputGeneratorTaskAction()
    }

    package func createProcessSDKImportsTaskAction() -> any PlannedTaskAction {
        return ProcessSDKImportsTaskAction()
    }
}

package final class CancellingTaskPlanningDelegate: TestTaskPlanningDelegate, @unchecked Sendable {
    let afterNodes: Int
    let afterTasks: Int
    var numNodesSeen: Int = 0
    var numTasksSeen: Int = 0

    private let queue = SWBQueue(label: "SWBTestSupport.CancellingTaskPlanningDelegate.queue", qos: UserDefaults.defaultRequestQoS)

    package init(afterNodes: Int = Int.max, afterTasks: Int = Int.max, clientDelegate: any TaskPlanningClientDelegate, workspace: Workspace, fs: any FSProxy) {
        self.afterNodes = afterNodes
        self.afterTasks = afterTasks
        super.init(clientDelegate: clientDelegate, workspace: workspace, fs: fs)
    }

    package override var cancelled: Bool {
        return (queue.blocking_sync{ numNodesSeen }) > afterNodes || (queue.blocking_sync{ numTasksSeen }) > afterTasks
    }

    package override func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        queue.blocking_sync{ numNodesSeen += 1 }
        return super.createVirtualNode(name)
    }

    package override func createDirectoryTreeNode(absolutePath path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        queue.blocking_sync{ numNodesSeen += 1 }
        return super.createDirectoryTreeNode(absolutePath: path, excluding: excluding)
    }

    package override func createNode(absolutePath path: Path) -> PlannedPathNode {
        queue.blocking_sync{ numNodesSeen += 1 }
        return super.createNode(absolutePath: path)
    }

    package override func createTask(_ builder: inout PlannedTaskBuilder) -> any PlannedTask {
        queue.blocking_sync{ numTasksSeen += 1 }
        return super.createTask(&builder)
    }
}
