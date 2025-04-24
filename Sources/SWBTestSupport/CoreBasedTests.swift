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

package import Testing

@_spi(Testing) package import SWBCore
import enum SWBProtocol.ExternalToolResult
import struct SWBProtocol.BuildOperationTaskEnded
package import SWBUtil
import SWBMacro

package protocol CoreBasedTests {
    func simulatedInferiorProductsPath() async throws -> Path?
}

extension CoreBasedTests {
    package static func makeCore(skipLoadingPluginsNamed: Set<String> = [], registerExtraPlugins: @PluginExtensionSystemActor (PluginManager) -> Void = { _ in }, simulatedInferiorProductsPath: Path? = nil, environment: [String: String] = [:], _ delegate: TestingCoreDelegate? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Core {
        let core: Result<Core, any Error>
        do {
            let theCore = try await Core.createInitializedTestingCore(skipLoadingPluginsNamed: skipLoadingPluginsNamed, registerExtraPlugins: registerExtraPlugins, simulatedInferiorProductsPath: simulatedInferiorProductsPath, environment: environment, delegate: delegate)
            core = .success(theCore)
        } catch {
            core = .failure(error)
        }
        return try _getCore(core: core, sourceLocation: sourceLocation)
    }

    /// This will create and cache a `Core` object using the value of `simulatedInferiorProductsPath()` from the test class.  Individual test methods can use this cached `Core` object for their own tests, although they can also create their own if they need custom behavior.
    package func getCore(sourceLocation: SourceLocation = #_sourceLocation) async throws -> Core {
        let core: Result<Core, any Error>
        do {
            let path = try await simulatedInferiorProductsPath()
            core = try await .success(testingCoreRegistry.value(forKey: path) {
                try await Self.makeCore(simulatedInferiorProductsPath: path)
            })
        } catch {
            core = .failure(error)
        }
        return try Self._getCore(core: core, sourceLocation: sourceLocation)
    }

    private static func _getCore(core: Result<Core, any Error>, sourceLocation: SourceLocation = #_sourceLocation) throws -> Core {
        do {
            return try core.get()
        } catch let error as CoreInitializationError {
            // Emit one failure per error, which will be significantly easier to read.
            for diagnostic in error.diagnostics {
                Issue.record(Comment(rawValue: diagnostic.formatLocalizedDescription(.debug)), sourceLocation: sourceLocation)
            }

            // Re-throw the CoreInitializationError, whose string representation does NOT include the above diagnostics,
            // to avoid duplicating the error information.
            throw error
        } catch {
            throw error
        }
    }

    /// A concrete test suite can set this to a specific path containing content to be loaded into the core, as if it were the build products path of the inferior.
    package func simulatedInferiorProductsPath() async throws -> Path? {
        return nil
    }
}

extension CoreBasedTests {
    fileprivate func coreAndToolchain() async throws -> (Core, Toolchain) {
        let core = try await getCore()
        let defaultToolchain = try #require(core.toolchainRegistry.lookup("default"), "couldn't lookup default toolchain")
        return (core, defaultToolchain)
    }

    private var swiftInfo: (DiscoveredSwiftCompilerToolSpecInfo, Version) {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            let swiftc = try #require(defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "swiftc"), "couldn't find swiftc in default toolchain")

            // Get the Swift version from the compiler and validate it against the spec in our cached Core object.  This will give us a version suitable for checking against the Swift compiler command line.
            // FIXME: We could probably collapse all of this logic into a single method inside the spec, with some refactoring in several places.
            let swiftSpecInfo = try await discoveredSwiftCompilerInfo(at: swiftc)
            let provisionalSwiftVersion = swiftSpecInfo.swiftVersion
            let swiftSpec = try core.specRegistry.getSpec() as SwiftCompilerSpec
            let swiftVersion: Version
            switch swiftSpec.validateSwiftVersion(provisionalSwiftVersion) {
            case .invalid:
                throw StubError.error("Swift version '\(provisionalSwiftVersion)' from compiler is not valid according to SwiftCompiler.xcspec")
            case .validMajor:
                swiftVersion = provisionalSwiftVersion.normalized(toNumberOfComponents: 1)
            case .valid:
                swiftVersion = provisionalSwiftVersion
            }

            return (swiftSpecInfo, swiftVersion)
        }
    }

    /// The path to the Swift compiler in the default toolchain.
    package var swiftCompilerPath: Path {
        get async throws {
            try await swiftInfo.0.toolPath
        }
    }

    /// The version of Swift supported by the compiler in the default toolchain.
    package var swiftVersion: String {
        get async throws {
            // Truncate to the first two components.
            try await swiftInfo.1.zeroTrimmed.description
        }
    }

    /// The 'features' declared in accompanying 'features.json' file for swift.
    package var swiftFeatures: ToolFeatures<DiscoveredSwiftCompilerToolSpecInfo.FeatureFlag> {
        get async throws {
            try await swiftInfo.0.toolFeatures
        }
    }

    private var clangInfo: DiscoveredClangToolSpecInfo {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            let clang = try #require(defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "clang"), "couldn't find clang in default toolchain")
            return try await discoveredClangToolInfo(toolPath: clang, arch: "undefined_arch", sysroot: nil)
        }
    }

    /// The path to the Clang compiler in the default toolchain.
    package var clangCompilerPath: Path {
        get async throws {
            try await clangInfo.toolPath
        }
    }

    /// The 'features' declared in accompanying 'features.json' file for clang.
    package var clangFeatures: ToolFeatures<DiscoveredClangToolSpecInfo.FeatureFlag> {
        get async throws {
            let clangInfo = try await clangInfo
            var realToolFeatures = clangInfo.toolFeatures.flags
            if clangInfo.clangVersion > Version(17) {
                realToolFeatures.insert(.extractAPISupportsCPlusPlus)
            }
            return ToolFeatures(realToolFeatures)
        }
    }

    /// The path to the libClang.dylib compiler in the default toolchain.
    package var libClangPath: Path {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            return try #require(defaultToolchain.librarySearchPaths.findLibrary(operatingSystem: core.hostOperatingSystem, basename: "clang") ?? defaultToolchain.fallbackLibrarySearchPaths.findLibrary(operatingSystem: core.hostOperatingSystem, basename: "clang"), "couldn't find libclang in default toolchain")
        }
    }

    /// The path to the TAPI tool in the default toolchain.
    package var tapiToolPath: Path {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            return try #require(defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "tapi"), "couldn't find tapi in default toolchain")
        }
    }

    package var migPath: Path {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            return try #require(defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "mig"), "couldn't find mig in default toolchain")
        }
    }

    package var iigPath: Path {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            return try #require(defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "iig"), "couldn't find iig in default toolchain")
        }
    }

    package var actoolPath: Path {
        get async throws {
            try await getCore().developerPath.path.join("usr/bin/actool")
        }
    }

    package var ibtoolPath: Path {
        get async throws {
            try await getCore().developerPath.path.join("usr/bin/ibtool")
        }
    }

    private var doccToolInfo: DocumentationCompilerToolSpecInfo {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            let doccToolPath = try #require(defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "docc"), "couldn't find docc in default toolchain")
            return try await discoveredDocumentationCompilerInfo(at: doccToolPath)
        }
    }

    package var doccToolPath: Path {
        get async throws {
            try await doccToolInfo.toolPath
        }
    }

    package var doccFeatures: ToolFeatures<DocumentationCompilerToolSpecInfo.FeatureFlag> {
        get async throws {
            // Note: Windows Swift installer is missing docc's features.json
            // https://github.com/swiftlang/swift/issues/74634
            try await doccToolInfo.toolFeatures
        }
    }

    /// The path to the libtool tool in the default toolchain.
    package var libtoolPath: Path {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            let fallbacklibtool = Path("/usr/bin/libtool")
            return try #require(defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "libtool")
                                ?? defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "llvm-ar")
                                ?? (localFS.exists(fallbacklibtool) ? fallbacklibtool : nil), "couldn't find libtool in default toolchain")
        }
    }

    // The path to llvm-lib in default toolchain
    package var llvmlibPath: Path {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            let fallbacklibtool = Path("/usr/bin/llvm-lib")
            return try #require(defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "llvm-lib") ?? (localFS.exists(fallbacklibtool) ? fallbacklibtool : nil), "couldn't find llvm-lib in default toolchain")
        }
    }

    /// If compilation caching is supported.
    package var supportsCompilationCaching: Bool {
        get async throws {
            let core = try await getCore()
            return Settings.supportsCompilationCaching(core)
        }
    }

    package var supportsSDKImports: Bool {
        get async throws {
            #if os(macOS)
            let (core, defaultToolchain) = try await coreAndToolchain()
            let toolPath = try #require(defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "ld"), "couldn't find ld in default toolchain")
            let mockProducer = try await MockCommandProducer(core: getCore(), productTypeIdentifier: "com.apple.product-type.framework", platform: nil, useStandardExecutableSearchPaths: true, toolchain: nil, fs: PseudoFS())
            let toolsInfo = await SWBCore.discoveredLinkerToolsInfo(mockProducer, AlwaysDeferredCoreClientDelegate(), at: toolPath)
            return (try? toolsInfo?.toolVersion >= .init("1164")) == true
            #else
            return false
            #endif
        }
    }

    // Linkers
    package var ldPath: Path? {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            if let executable = defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "ld") {
                return executable
            }
            for platform in core.platformRegistry.platforms {
                if let executable = platform.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "ld") {
                    return executable
                }
            }
            return nil
        }
    }
    package var lldPath: Path? {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            if let executable = defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "ld.lld") {
                return executable
            }
            for platform in core.platformRegistry.platforms {
                if let executable = platform.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "ld.lld") {
                    return executable
                }
            }
            return nil
        }
    }
    package var goldPath: Path? {
        get async throws {
            let (core, defaultToolchain) = try await coreAndToolchain()
            if let executable = defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "ld.gold") {
                return executable
            }
            for platform in core.platformRegistry.platforms {
                if let executable = platform.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "ld.gold") {
                    return executable
                }
            }
            return nil
        }
    }
    package func linkPath(_ targetArchitecture: String) async throws -> Path? {
        let (core, defaultToolchain) = try await self.coreAndToolchain()
        let prefixMapping =  ["aarch64" : "arm64", "arm64ec" : "arm64", "armv7" : "arm", "x86_64": "x64", "i686": "x86"]

        guard let prefix = prefixMapping[targetArchitecture] else {
            return nil
        }
        let linkerPath = Path(prefix).join("link").str
        if core.hostOperatingSystem != .windows {
            // Most unixes have a link executable, but that is not a linker
            return nil
        }
        if let executable = defaultToolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: linkerPath) {
            return executable
        }
        for platform in core.platformRegistry.platforms {
            if let executable = platform.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: linkerPath) {
                return executable
            }
        }
        return nil
    }
}

/// Process-wide registry of inferior products paths to Core instances.
private let testingCoreRegistry = AsyncCache<Path?, Core>()

private final class AlwaysDeferredCoreClientDelegate: CoreClientDelegate, CoreClientTargetDiagnosticProducingDelegate {
    var coreClientDelegate: any SWBCore.CoreClientDelegate {
        self
    }

    private let _diagnosticsEngine = DiagnosticsEngine()

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    let diagnosticContext: DiagnosticContextData = .init(target: nil)

    func beginActivity(ruleInfo: String, executionDescription: String, signature: SWBUtil.ByteString, target: SWBCore.ConfiguredTarget?, parentActivity: SWBCore.ActivityID?) -> SWBCore.ActivityID {
        .init(rawValue: -1)
    }

    func endActivity(id: SWBCore.ActivityID, signature: SWBUtil.ByteString, status: BuildOperationTaskEnded.Status) {
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
    }

    var hadErrors: Bool {
        _diagnosticsEngine.hasErrors
    }

    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
        .deferred
    }
}

extension CoreBasedTests {
    package func discoveredClangToolInfo(toolPath: Path, arch: String, sysroot: Path?, language: String = "c") async throws -> DiscoveredClangToolSpecInfo {
        try await SWBCore.discoveredClangToolInfo(MockCommandProducer(core: getCore(), productTypeIdentifier: "com.apple.product-type.framework", platform: nil, useStandardExecutableSearchPaths: true, toolchain: nil, fs: PseudoFS()), AlwaysDeferredCoreClientDelegate(), toolPath: toolPath, arch: arch, sysroot: sysroot, language: language, blocklistsPathOverride: nil)
    }

    package func discoveredSwiftCompilerInfo(at toolPath: Path) async throws -> DiscoveredSwiftCompilerToolSpecInfo {
        try await SWBCore.discoveredSwiftCompilerInfo(MockCommandProducer(core: getCore(), productTypeIdentifier: "com.apple.product-type.framework", platform: nil, useStandardExecutableSearchPaths: true, toolchain: nil, fs: PseudoFS()), AlwaysDeferredCoreClientDelegate(), at: toolPath, blocklistsPathOverride: nil)
    }

    package func discoveredTAPIToolInfo(at toolPath: Path) async throws -> DiscoveredTAPIToolSpecInfo {
        try await SWBCore.discoveredTAPIToolInfo(MockCommandProducer(core: getCore(), productTypeIdentifier: "com.apple.product-type.framework", platform: nil, useStandardExecutableSearchPaths: true, toolchain: nil, fs: PseudoFS()), AlwaysDeferredCoreClientDelegate(), at: toolPath)
    }

    package func discoveredDocumentationCompilerInfo(at toolPath: Path) async throws -> DocumentationCompilerToolSpecInfo {
        try await SWBCore.discoveredDocumentationCompilerInfo(MockCommandProducer(core: getCore(), productTypeIdentifier: "com.apple.product-type.framework", platform: nil, useStandardExecutableSearchPaths: true, toolchain: nil, fs: PseudoFS()), AlwaysDeferredCoreClientDelegate(), at: toolPath)
    }

    private func discoveredToolSpecInfo<T: DiscoveredCommandLineToolSpecInfo>(specIdentifier: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> T {
        guard let info = try await discoveredToolSpecInfo(specIdentifier: specIdentifier, sourceLocation: sourceLocation) else {
            throw StubError.error("No tool spec info for \(specIdentifier)")
        }
        return try #require(info as? T)
    }

    fileprivate func discoveredToolSpecInfo(specIdentifier: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (any DiscoveredCommandLineToolSpecInfo)? {
        let core = try await getCore()
        let spec = try core.specRegistry.getSpec(specIdentifier) as CommandLineToolSpec
        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: nil, useStandardExecutableSearchPaths: true, toolchain: nil, fs: localFS)
        let delegate = DiscoveredInfoDelegate()
        let info = await spec.discoveredCommandLineToolSpecInfo(producer, MacroEvaluationScope(table: MacroValueAssignmentTable(namespace: MacroNamespace())), delegate)
        if info == nil {
            let errors = delegate._diagnosticsEngine.diagnostics.filter({ $0.behavior == .error })
            for error in errors {
                Issue.record(Comment(rawValue: error.formatLocalizedDescription(.debugWithoutBehavior)), sourceLocation: sourceLocation)
            }
            if errors.isEmpty {
                throw StubError.error("Failed to obtain command line tool spec info but no errors were emitted")
            }
        }
        return info
    }
}

extension Trait where Self == Testing.ConditionTrait {
    /// Emits a skip message and immediately stops the test case unless the test suite is running against a version of Xcode including at least the given version of a particular tool spec.
    ///
    /// - Parameter identifier: The reverse DNS identifier of the command line tool spec to look up.
    /// - Parameter requiredVersion: Version number indicating the minimum required version of the tool spec.
    package static func requireToolSpecVersion(_ identifier: String, _ requiredVersion: Version) -> Self {
        requireToolSpecVersion(identifier, requiredVersion.description)
    }

    /// Emits a skip message and immediately stops the test case unless the test suite is running against a version of Xcode including at least the given version of a particular tool spec.
    ///
    /// - Parameter identifier: The reverse DNS identifier of the command line tool spec to look up.
    /// - Parameter requiredVersionString: Version number indicating the minimum required version of the tool spec.
    package static func requireToolSpecVersion(_ identifier: String, _ requiredVersionString: String) -> Self {
        enabled("Skipping because \(identifier) spec version is too old (\(requiredVersionString) or later required)") {
            let requiredVersion = try Version(requiredVersionString)
            guard let spec = try await ConditionTraitContext.shared.discoveredToolSpecInfo(specIdentifier: identifier) else {
                return false
            }
            let specVersion = spec.toolVersion
            return specVersion >= requiredVersion
        }
    }
}

private class DiscoveredInfoDelegate: CoreClientTargetDiagnosticProducingDelegate {
    func beginActivity(ruleInfo: String, executionDescription: String, signature: SWBUtil.ByteString, target: SWBCore.ConfiguredTarget?, parentActivity: SWBCore.ActivityID?) -> SWBCore.ActivityID {
        .init(rawValue: -1)
    }

    func endActivity(id: SWBCore.ActivityID, signature: SWBUtil.ByteString, status: SWBProtocol.BuildOperationTaskEnded.Status) {
    }

    var hadErrors: Bool {
        _diagnosticsEngine.hasErrors
    }

    func diagnosticsEngine(for target: SWBCore.ConfiguredTarget?) -> SWBCore.DiagnosticProducingDelegateProtocolPrivate<SWBUtil.DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
    }

    let _diagnosticsEngine = DiagnosticsEngine()
    let diagnosticContext: SWBCore.DiagnosticContextData = .init(target: nil)
    let coreClientDelegate: any CoreClientDelegate = AlwaysDeferredCoreClientDelegate()
}

/// Utility functions for common testing operations.
package extension CoreBasedTests {
    /// Load a workspace from a serialized PIF file.
    func loadWorkspace(fromPIF path: Path) async throws -> Workspace {
        let plist = try PropertyList.fromJSONFileAtPath(path, fs: localFS)
        let loader = try await PIFLoader(data: plist, namespace: getCore().specRegistry.internalMacroNamespace)
        return try loader.load(workspaceSignature: "WORKSPACE")
    }
}
