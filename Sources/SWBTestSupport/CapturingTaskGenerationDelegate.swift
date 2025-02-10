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
package import SWBProtocol
import SWBTaskExecution
package import SWBUtil
package import SWBMacro

package class CapturingTaskGenerationDelegate: TaskGenerationDelegate, CoreClientDelegate {
    package func recordAttachment(contents: SWBUtil.ByteString) -> SWBUtil.Path {
        Path("")
    }

    private var _generatedSwiftObjectiveCHeaderFiles: [String: Path] = [:]
    let _diagnosticsEngine = DiagnosticsEngine()
    let producer: any CommandProducer
    package let userPreferences: UserPreferences
    let sharedIntermediateNodes = Registry<String, (any PlannedNode, any Sendable)>()

    public init(producer: any CommandProducer, userPreferences: UserPreferences) throws {
        self.producer = producer
        self.userPreferences = userPreferences
        self.diagnosticContext = DiagnosticContextData(target: nil)
    }

    package var shellTasks: [PlannedTaskBuilder] = []

    package let diagnosticContext: DiagnosticContextData

    package func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return .init(_diagnosticsEngine)
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
        _diagnosticsEngine.hasErrors
    }

    // TaskGenerationDelegate

    func warning(_ message: String) {}
    func error(_ message: String) {}
    package func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        return MakePlannedVirtualNode(name)
    }
    package func createNode(_ path: Path) -> PlannedPathNode {
        let absolutePath = Path("/tmp").join(path)
        return MakePlannedPathNode(absolutePath)
    }
    package func createDirectoryTreeNode(_ path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        let absolutePath = Path("/tmp").join(path)
        return MakePlannedDirectoryTreeNode(absolutePath, excluding: excluding)
    }
    package func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode {
        return createNode(path)
    }
    package func declareOutput(_ file: FileToBuild) {}
    package func declareGeneratedSourceFile(_ path: Path) {}
    package func declareGeneratedInfoPlistContent(_ path: Path) {}
    package func declareGeneratedPrivacyPlistContent(_ path: Path) {}
    package func declareGeneratedTBDFile(_ path: Path, forVariant variant: String) {}
    package func declareGeneratedSwiftObjectiveCHeaderFile(_ path: Path, architecture: String) {
        assert(_generatedSwiftObjectiveCHeaderFiles[architecture] == nil)
        _generatedSwiftObjectiveCHeaderFiles[architecture] = path
    }
    package func declareGeneratedSwiftConstMetadataFile(_ path: Path, architecture: String) {}
    package func generatedSwiftObjectiveCHeaderFiles() -> [String: Path] {
        _generatedSwiftObjectiveCHeaderFiles
    }
    package var additionalCodeSignInputs: OrderedSet<Path> { return [] }
    package var buildDirectories: Set<Path> { return [] }

    package func createTask(_ builder: inout PlannedTaskBuilder) {
        shellTasks.append(builder)
    }
    package func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, name: String?, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) {
        // Store somewhere if a test needs it.
    }
    package func createOrReuseSharedNodeWithIdentifier(_ ident: String, creator: () -> (any PlannedNode, any Sendable)) -> (any PlannedNode, any Sendable) {
        return sharedIntermediateNodes.getOrInsert(ident, creator)
    }
    package func access(path: Path) {}
    package func readFileContents(_ path: Path) throws -> ByteString { return ByteString() }
    package func fileExists(at path: Path) -> Bool { return true }
    package var taskActionCreationDelegate: any TaskActionCreationDelegate { return self }
    package var clientDelegate: any CoreClientDelegate { return self }
    package func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> ExternalToolResult {
        return .deferred
    }
}

extension CapturingTaskGenerationDelegate: TaskActionCreationDelegate {
    package func createAuxiliaryFileTaskAction(_ context: AuxiliaryFileTaskActionContext) -> any PlannedTaskAction {
        return AuxiliaryFileTaskAction(context)
    }

    package func createCodeSignTaskAction() -> any PlannedTaskAction {
        return CodeSignTaskAction()
    }

    package func createConcatenateTaskAction() -> any SWBCore.PlannedTaskAction {
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
