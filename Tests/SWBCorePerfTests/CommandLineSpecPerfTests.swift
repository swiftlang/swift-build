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

import Testing

import SWBTestSupport
import SWBCore
import SWBUtil
import enum SWBProtocol.ExternalToolResult
import struct SWBProtocol.BuildOperationTaskEnded
import SWBTaskExecution
import SWBMacro

private final class CapturingTaskGenerationDelegate: TaskGenerationDelegate {
    private let _diagnosticsEngine = DiagnosticsEngine()
    let producer: any CommandProducer
    let userPreferences: UserPreferences
    let diagnosticContext: DiagnosticContextData
    let sharedIntermediateNodes = Registry<String, (any PlannedNode, any Sendable)>()

    init(producer: any CommandProducer, userPreferences: UserPreferences) throws {
        self.producer = producer
        self.userPreferences = userPreferences
        self.diagnosticContext = DiagnosticContextData(target: nil)
    }

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    var shellTasks: [PlannedTaskBuilder] = []

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        .init(rawValue: -1)
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
    }

    var hadErrors: Bool {
        _diagnosticsEngine.hasErrors
    }

    // TaskGenerationDelegate

    func warning(_ message: String) {}
    func error(_ message: String) {}
    func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        return MakePlannedVirtualNode(name)
    }
    func createNode(_ path: Path) -> PlannedPathNode {
        let absolutePath = Path.root.join("tmp").join(path)
        return MakePlannedPathNode(absolutePath)
    }
    func createDirectoryTreeNode(_ path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        let absolutePath = Path.root.join("tmp").join(path)
        return MakePlannedDirectoryTreeNode(absolutePath, excluding: excluding)
    }
    func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode {
        return createNode(path)
    }
    func declareOutput(_ file: FileToBuild) {}
    func declareGeneratedSourceFile(_ path: Path) {}
    func declareGeneratedInfoPlistContent(_ path: Path) {}
    func declareGeneratedPrivacyPlistContent(_ path: Path) {}
    func declareGeneratedTBDFile(_ path: Path, forVariant variant: String) {}
    func declareGeneratedSwiftObjectiveCHeaderFile(_ path: Path, architecture: String) {}
    func declareGeneratedSwiftConstMetadataFile(_ path: Path, architecture: String) {}
    var additionalCodeSignInputs: OrderedSet<Path> { return [] }
    var buildDirectories: Set<Path> { return [] }

    func createTask(_ builder: inout PlannedTaskBuilder)
    {
        shellTasks.append((builder))
    }
    func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, name: String?, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) {
        // Store somewhere if a test needs it.
    }
    func createOrReuseSharedNodeWithIdentifier(_ ident: String, creator: () -> (any PlannedNode, any Sendable)) -> (any PlannedNode, any Sendable)
    {
        return sharedIntermediateNodes.getOrInsert(ident, creator)
    }
    func access(path: Path) {}
    func readFileContents(_ path: Path) throws -> ByteString { return ByteString() }
    func recordAttachment(contents: SWBUtil.ByteString) -> SWBUtil.Path {
        Path("")
    }
    func fileExists(at path: Path) -> Bool { return true }
    public var taskActionCreationDelegate: any TaskActionCreationDelegate { return self }
    public var clientDelegate: any CoreClientDelegate { return self }
}

extension CapturingTaskGenerationDelegate: TaskActionCreationDelegate {
    public func createAuxiliaryFileTaskAction(_ context: AuxiliaryFileTaskActionContext) -> any PlannedTaskAction {
        return AuxiliaryFileTaskAction(context)
    }

    public func createCodeSignTaskAction() -> any PlannedTaskAction {
        return CodeSignTaskAction()
    }

    public func createConcatenateTaskAction() -> any PlannedTaskAction {
        return ConcatenateTaskAction()
    }

    public func createCopyPlistTaskAction() -> any PlannedTaskAction {
        return CopyPlistTaskAction()
    }

    public func createCopyStringsFileTaskAction() -> any PlannedTaskAction {
        return CopyStringsFileTaskAction()
    }

    public func createCopyTiffTaskAction() -> any PlannedTaskAction {
        return CopyTiffTaskAction()
    }

    public func createDeferredExecutionTaskAction() -> any PlannedTaskAction {
        return DeferredExecutionTaskAction()
    }

    public func createBuildDirectoryTaskAction() -> any PlannedTaskAction {
        return CreateBuildDirectoryTaskAction()
    }

    public func createSwiftHeaderToolTaskAction() -> any PlannedTaskAction {
        return SwiftHeaderToolTaskAction()
    }

    public func createEmbedSwiftStdLibTaskAction() -> any PlannedTaskAction {
        return EmbedSwiftStdLibTaskAction()
    }

    public func createFileCopyTaskAction(_ context: FileCopyTaskActionContext) -> any PlannedTaskAction {
        return FileCopyTaskAction(context)
    }

    public func createGenericCachingTaskAction(enableCacheDebuggingRemarks: Bool, enableTaskSandboxEnforcement: Bool, sandboxDirectory: Path, extraSandboxSubdirectories: [Path], developerDirectory: Path, casOptions: CASOptions) -> any PlannedTaskAction {
        return GenericCachingTaskAction(enableCacheDebuggingRemarks: enableCacheDebuggingRemarks, enableTaskSandboxEnforcement: enableTaskSandboxEnforcement, sandboxDirectory: sandboxDirectory, extraSandboxSubdirectories: extraSandboxSubdirectories, developerDirectory: developerDirectory, casOptions: casOptions)
    }

    public func createInfoPlistProcessorTaskAction(_ contextPath: Path) -> any PlannedTaskAction {
        return InfoPlistProcessorTaskAction(contextPath)
    }

    public func createMergeInfoPlistTaskAction() -> any PlannedTaskAction {
        return MergeInfoPlistTaskAction()
    }

    public func createLinkAssetCatalogTaskAction() -> any PlannedTaskAction {
        return LinkAssetCatalogTaskAction()
    }

    public func createLSRegisterURLTaskAction() -> any PlannedTaskAction {
        return LSRegisterURLTaskAction()
    }

    public func createProcessProductEntitlementsTaskAction(scope: MacroEvaluationScope, mergedEntitlements: PropertyListItem, entitlementsVariant: EntitlementsVariant, destinationPlatformName: String, entitlementsFilePath: Path?, fs: any FSProxy) -> any PlannedTaskAction {
        return ProcessProductEntitlementsTaskAction(scope: scope, fs: fs, entitlements: mergedEntitlements, entitlementsVariant: entitlementsVariant, destinationPlatformName: destinationPlatformName, entitlementsFilePath: entitlementsFilePath)
    }

    public func createProcessProductProvisioningProfileTaskAction() -> any PlannedTaskAction {
        return ProcessProductProvisioningProfileTaskAction()
    }

    public func createRegisterExecutionPolicyExceptionTaskAction() -> any PlannedTaskAction {
        return RegisterExecutionPolicyExceptionTaskAction()
    }

    public func createValidateProductTaskAction() -> any PlannedTaskAction {
        return ValidateProductTaskAction()
    }

    public func createConstructStubExecutorInputFileListTaskAction() -> any PlannedTaskAction {
        return ConstructStubExecutorInputFileListTaskAction()
    }

    public func createODRAssetPackManifestTaskAction() -> any PlannedTaskAction {
        return ODRAssetPackManifestTaskAction()
    }

    public func createClangCompileTaskAction() -> any PlannedTaskAction {
        return ClangCompileTaskAction()
    }

    public func createClangScanTaskAction() -> any PlannedTaskAction {
        return ClangScanTaskAction()
    }

    public func createSwiftDriverTaskAction() -> any PlannedTaskAction {
        return SwiftDriverTaskAction()
    }

    func createSwiftCompilationRequirementTaskAction() -> any PlannedTaskAction {
        return SwiftDriverCompilationRequirementTaskAction()
    }

    func createSwiftCompilationTaskAction() -> any PlannedTaskAction {
        return SwiftCompilationTaskAction()
    }

    public func createProcessXCFrameworkTask() -> any PlannedTaskAction {
        return ProcessXCFrameworkTaskAction()
    }

    func createValidateDevelopmentAssetsTaskAction() -> any PlannedTaskAction {
        return ValidateDevelopmentAssetsTaskAction()
    }

    func createSignatureCollectionTaskAction() -> any PlannedTaskAction {
        return SignatureCollectionTaskAction()
    }

    func createClangModuleVerifierInputGeneratorTaskAction() -> any PlannedTaskAction {
        return ClangModuleVerifierInputGeneratorTaskAction()
    }

    func createProcessSDKImportsTaskAction() -> any PlannedTaskAction {
        return ProcessSDKImportsTaskAction()
    }
}

extension CapturingTaskGenerationDelegate: CoreClientDelegate {
    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> ExternalToolResult {
        return .emptyResult
    }
}

@Suite(.performance)
fileprivate struct CommandLineSpecPerfTests: CoreBasedTests, PerfTests {
    let specDataCaches = Registry<Spec, any SpecDataCache>()

    @Test
    func clangCompileTaskConstruction_X1000() async throws {
        let core = try await getCore()

        let clangSpec: CommandLineToolSpec = try core.specRegistry.getSpec() as ClangCompilerSpec

        // Create the mock table.  We include all the defaults for the tool specification.
        var (table, namespace) = clangSpec.macroTableForBuildOptionDefaults(core)

        // We also add some other settings that are more contextual in nature.
        table.push(try #require(namespace.lookupMacroDeclaration("CURRENT_ARCH") as? StringMacroDeclaration), literal: "x86_64")
        table.push(try #require(namespace.lookupMacroDeclaration("arch") as? StringMacroDeclaration), literal: "x86_64")
        table.push(try #require(namespace.lookupMacroDeclaration("CURRENT_VARIANT") as? StringMacroDeclaration), literal: "normal")
        table.push(try #require(namespace.lookupMacroDeclaration("PRODUCT_NAME") as? StringMacroDeclaration), literal: "Product")
        table.push(try #require(namespace.lookupMacroDeclaration("TEMP_DIR") as? PathMacroDeclaration), literal: "/tmp")
        table.push(try #require(namespace.lookupMacroDeclaration("PROJECT_TEMP_DIR") as? PathMacroDeclaration), literal: "/tmp/ptmp")
        table.push(try #require(namespace.lookupMacroDeclaration("OBJECT_FILE_DIR") as? PathMacroDeclaration), literal: "/tmp/output/obj")
        table.push(try #require(namespace.lookupMacroDeclaration("BUILT_PRODUCTS_DIR") as? PathMacroDeclaration), literal: "/tmp/output/sym")
        table.push(try #require(namespace.lookupMacroDeclaration("GCC_PREFIX_HEADER") as? PathMacroDeclaration), literal: "/tmp/prefix.h")
        table.push(try #require(namespace.lookupMacroDeclaration("DERIVED_FILE_DIR") as? PathMacroDeclaration), literal: "/tmp/derived")
        table.push(try namespace.declareUserDefinedMacro("PER_ARCH_CFLAGS_i386"), namespace.parseLiteralStringList(["-DX86.32"]))
        table.push(try namespace.declareUserDefinedMacro("PER_ARCH_CFLAGS_x86_64"), namespace.parseLiteralStringList(["-DX86.64"]))
        table.push(try #require(namespace.lookupMacroDeclaration("PER_ARCH_CFLAGS") as? StringListMacroDeclaration), BuiltinMacros.namespace.parseStringList("$(PER_ARCH_CFLAGS_$(CURRENT_ARCH)"))
        table.push(try namespace.declareUserDefinedMacro("OTHER_CFLAGS_normal"), namespace.parseLiteralStringList(["-DFrom_OTHER_CFLAGS_normal"]))
        table.push(try namespace.declareUserDefinedMacro("OTHER_CFLAGS_profile"), namespace.parseLiteralStringList(["-DFrom_OTHER_CFLAGS_profile"]))
        table.push(try #require(namespace.lookupMacroDeclaration("PER_VARIANT_CFLAGS") as? StringListMacroDeclaration), BuiltinMacros.namespace.parseStringList("$(OTHER_CFLAGS_$(CURRENT_VARIANT)"))
        table.push(try #require(namespace.lookupMacroDeclaration("USE_HEADERMAP") as? BooleanMacroDeclaration), literal: true)
        table.push(try #require(namespace.lookupMacroDeclaration("HEADERMAP_USES_VFS") as? BooleanMacroDeclaration), literal: true)
        table.push(try #require(namespace.lookupMacroDeclaration("CLANG_ENABLE_MODULES") as? BooleanMacroDeclaration), literal: true)
        table.push(try namespace.declareStringListMacro("GLOBAL_CFLAGS"), literal: ["-DFrom_GLOBAL_CFLAGS"])
        table.push(try #require(namespace.lookupMacroDeclaration("GCC_GENERATE_PROFILING_CODE") as? BooleanMacroDeclaration), literal: true)
        table.push(try #require(namespace.lookupMacroDeclaration("GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS") as? StringListMacroDeclaration), literal: ["defn1", "defn2"])
        table.push(try #require(namespace.lookupMacroDeclaration("GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS") as? StringListMacroDeclaration), literal: ["-DFrom_GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS"])

        // Override CLANG_DEBUG_MODULES, to be independent of recent changes to the Clang.xcspec.
        table.push(try #require(namespace.lookupMacroDeclaration("CLANG_DEBUG_MODULES") as? BooleanMacroDeclaration), literal: false)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: nil, fs: PseudoFS())

        // Create the delegate, scope, file type, etc.
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec

        // Create the build context for the command.
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path("/tmp/input.c"), fileType: mockFileType)], output: nil)

        // Ask the specification to construct the tasks.
        //
        // NOTE: As currently implemented, the performance of this test makes heavy use of the "constant flags" cache. That accurately matches what happens during a real build, but skews the pure results away from "how long does it take to do an individual compiler task construction job".
        let count = 1000
        await measure {
            // We do each iteration many times in order to samples that are more likely to be statistically significant.
            for _ in 1...count {
                await clangSpec.constructTasks(cbc, delegate)
            }
        }

        // There should be 10x as many shell tasks as we had iterations, since performance testing runs the measureBlock 10 times.
        #expect(delegate.shellTasks.count == count * (getEnvironmentVariable("CI")?.boolValue == true ? 1 : 10))
    }
}
