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

#if canImport(System)
import struct System.FilePath
#else
import struct SystemPackage.FilePath
#endif

import struct Foundation.Data
import class Foundation.JSONEncoder
import class Foundation.JSONDecoder

import SWBUtil
import enum SWBProtocol.ExternalToolResult
import struct SWBProtocol.BuildOperationTaskEnded
package import SWBCore
import SWBTaskConstruction
import SWBMacro

// MARK: Data structures


/// Hierarchy of data structures containing the dependencies for all targets in a build.
///
/// These structures can be encoded to and decoded from JSON.  The JSON is an API used by clients, and the data structures may become such an API eventually if we decide to share them directly with clients.
///
/// The names of properties in these structures are chosen mainly to be useful in the JSON file, so they may be a bit more verbose for use in Swift than they might be otherwise.
///
/// Presently the main way to instantiate these structures is to use `init(workspaceContext:buildRequest:buildRequestContext:operation:)`, which is defined below after the data structures.


/// The input and output dependencies for all targets in a build.
package struct BuildDependencyInfo: Codable {

    /// Structure describing the dependencies for a single target.  This includes a structure describing the identity of the target, and the declared inputs and outputs of the target.
    package struct TargetDependencyInfo: Codable {

        /// Structure describing the identity of a target.  This structure is `Hashable` so it can be used to determine if we've seen exactly this target before, and for testing purposes.
        package struct Target: Hashable {

            /// The name of the target.
            package let targetName: String

            /// The name of the project (for builds which use multiple Xcode projects).
            package let projectName: String?

            /// The name of the platform the target is building for.
            package let platformName: String?

        }

        /// Structure describing an input to a target.
        package struct Input: Hashable, Codable, Sendable {

            /// An input can be a framework or a library.
            package enum InputType: String, Codable, Sendable {
                case framework
                case library
            }

            /// The name reflects what information we have about the input in the project. Since Xcode often finds libraries and frameworks with search paths, we will have the the name of the input - or even only a stem if it's a `-l` option from `OTHER_LDFLAGS`. We may have an absolute path.
            package enum NameType: Hashable, Codable, Sendable {
                /// An absolute path, typically either because we found it in a build setting such as `OTHER_LDFLAGS`, or because some internal logic decided to link with an absolute path.
                case absolutePath(String)

                /// A file name being linked with a search path. This will be the whole name such as `Foo.framework` or `libFoo.dylib`.
                case name(String)

                /// The stem of a file being linked with a search path. For libraries this will be the part of the file name after `lib` and before the suffix. For other files this will be the file's base name without the suffix.
                ///
                /// Stems are often found after `-l` or `-framework` options in a build setting such as `OTHER_LDFLAGS`.
                case stem(String)

                /// Convenience method to return the associated value of the input as a String.  This is mainly for sorting purposes during tests to emit consistent results, since the names may be of different types.
                package var stringForm: String {
                    switch self {
                    case .absolutePath(let str):
                        return str
                    case .name(let str):
                        return str
                    case .stem(let str):
                        return str
                    }
                }

                /// Convenience method to return a string to use for sorting different names.
                package var sortableName: String {
                    switch self {
                    case .absolutePath(let str):
                        return FilePath(str).lastComponent.flatMap({ $0.string }) ?? str
                    case .name(let str):
                        return str
                    case .stem(let str):
                        return str
                    }
                }

            }

            /// For inputs which are linkages, we note whether we're linking using a search path or an absolute path.
            package enum LinkType: String, Codable, Sendable {
                case absolutePath
                case searchPath
            }

            /// The library type of the input. If we know that it's a dynamic or static library (usually from the file type of the input) then we note that. But for inputs from `-l` options in `OTHER_LDFLAGS`, we don't know the type.
            package enum LibraryType: String, Codable, Sendable {
                case dynamic
                case `static`
                case unknown
            }

            package let inputType: InputType
            package let name: NameType
            package let linkType: LinkType
            package let libraryType: LibraryType

            package init(inputType: InputType, name: NameType, linkType: LinkType, libraryType: LibraryType) {
                self.inputType = inputType
                self.name = name
                self.linkType = linkType
                self.libraryType = libraryType
            }

        }

        /// The identifying information of the target.
        package let target: Target

        /// List of input files being used by the target.
        /// - remark: Presently this is the list of linked libraries and frameworks, often located using search paths.
        package let inputs: [Input]

        /// List of paths of outputs in the `DSTROOT` which we report.
        /// - remark: Presently this contains only the product of the target, if any.
        package let outputPaths: [String]

    }

    /// Info for all of the targets in the build.
    package let targets: [TargetDependencyInfo]

    /// Any errors detected in collecting the dependency info for the build.
    package let errors: [String]

}


// MARK: Encoding and decoding


extension BuildDependencyInfo.TargetDependencyInfo {

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target.targetName, forKey: .targetName)
        try container.encode(target.projectName, forKey: .projectName)
        try container.encode(target.platformName, forKey: .platformName)
        if !inputs.isEmpty {
            // Sort the inputs by name, stem, or last path component.
            let sortedInputs = inputs.sorted(by: { $0.name.sortableName < $1.name.sortableName })
            try container.encode(sortedInputs, forKey: .inputs)
        }
        if !outputPaths.isEmpty {
            try container.encode(outputPaths.sorted(), forKey: .outputPaths)
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let targetName = try container.decode(String.self, forKey: .targetName)
        let projectName = try container.decode(String.self, forKey: .projectName)
        let platformName = try container.decode(String.self, forKey: .platformName)
        self.target = Target(targetName: targetName, projectName: projectName, platformName: platformName)
        self.inputs = try container.decodeIfPresent([Input].self, forKey: .inputs) ?? []
        self.outputPaths = try container.decodeIfPresent([String].self, forKey: .outputPaths) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case targetName
        case projectName
        case platformName
        case inputs
        case outputPaths
    }

    package init(targetName: String, projectName: String?, platformName: String?, inputs: [Input], outputPaths: [String]) {
        self.target = Target(targetName: targetName, projectName: projectName, platformName: platformName)
        self.inputs = inputs
        self.outputPaths = outputPaths
    }

}

extension BuildDependencyInfo.TargetDependencyInfo.Input {

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputType, forKey: .inputType)
        try container.encode(name, forKey: .name)
        try container.encode(linkType, forKey: .linkType)
        try container.encode(libraryType, forKey: .libraryType)
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.inputType = try container.decode(BuildDependencyInfo.TargetDependencyInfo.Input.InputType.self, forKey: .inputType)
        self.name = try container.decode(BuildDependencyInfo.TargetDependencyInfo.Input.NameType.self, forKey: .name)
        self.linkType = try container.decode(BuildDependencyInfo.TargetDependencyInfo.Input.LinkType.self, forKey: .linkType)
        self.libraryType = try container.decode(BuildDependencyInfo.TargetDependencyInfo.Input.LibraryType.self, forKey: .libraryType)
    }

    private enum CodingKeys: String, CodingKey {
        case inputType
        case name
        case linkType
        case libraryType
    }

}

extension BuildDependencyInfo.TargetDependencyInfo.Input.NameType {

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absolutePath(let path):
            try container.encode(path, forKey: .path)
        case .name(let name):
            try container.encode(name, forKey: .name)
        case .stem(let stem):
            try container.encode(stem, forKey: .stem)
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .path) {
            self = .absolutePath(path)
        }
        else if let name = try container.decodeIfPresent(String.self, forKey: .name) {
            self = .name(name)
        }
        else if let stem = try container.decodeIfPresent(String.self, forKey: .stem) {
            self = .stem(stem)
        }
        else {
            throw StubError.error("unknown type for input name")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case name
        case stem
    }

}


// MARK: Custom string definitions for better debugging


extension BuildDependencyInfo.TargetDependencyInfo.Target: CustomStringConvertible {
    package var description: String {
        return "\(type(of: self))<target=\(targetName):project=\(projectName == nil ? "nil" : projectName!):platform=\(platformName == nil ? "nil" : platformName!)>"
    }
}

extension BuildDependencyInfo.TargetDependencyInfo.Input: CustomStringConvertible {
    package var description: String {
        return "\(type(of: self))<\(inputType):\(name):linkType=\(linkType):libraryType=\(libraryType)>"
    }
}

extension BuildDependencyInfo.TargetDependencyInfo.Input.NameType: CustomStringConvertible {
    package var description: String {
        switch self {
        case .absolutePath(let path):
            return "path=\(path).str"
        case .name(let name):
            return "name=\(name)"
        case .stem(let stem):
            return "stem=\(stem)"
        }
    }
}


// MARK: Creating a BuildDependencyInfo from a BuildRequest


extension BuildDependencyInfo {

    package init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, operation: BuildDependencyInfoOperation) async throws {
        /// We need to create a `GlobalProductPlan` and its associated data to be able to evaluate many things involving product references.
        let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: operation)
        if operation.hadErrors {
            throw StubError.error("Unable to get target build graph")
        }
        let planRequest = BuildPlanRequest(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, buildGraph: buildGraph, provisioningInputs: [:])
        let globalProductPlanDelegate = BuildDependencyInfoGlobalProductPlanDelegate()
        let globalProductPlan = await GlobalProductPlan(planRequest: planRequest, delegate: globalProductPlanDelegate, nodeCreationDelegate: nil)
        // FIXME: Should we report any issues creating the GlobalProductPlan somehow?

        // FUTURE: In the future if we want to get the full build description, see GetIndexingInfoMsg.handle() in Messages.swift for an example of how that could work.

        var errors = OrderedSet<String>()

        // Walk the target dependency closure to collect the desired info.
        self.targets = await buildGraph.allTargets.asyncMap { configuredTarget in
            let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
            let targetName = configuredTarget.target.name
            let projectName = settings.project?.name
            let platform = settings.platform
            let platformName = platform?.name
            let buildFileResolver = BuildDependencyInfoBuildFileResolver(workspaceContext: workspaceContext, configuredTarget: configuredTarget, settings: settings, platform: platform, globalTargetInfoProvider: globalProductPlan)
            let (inputs, inputsErrors) = await BuildDependencyInfo.inputs(configuredTarget, settings, buildFileResolver)
            let outputPaths = BuildDependencyInfo.outputPaths(configuredTarget, settings)

            errors.append(contentsOf: inputsErrors)

            return TargetDependencyInfo(targetName: targetName, projectName: projectName, platformName: platformName, inputs: inputs, outputPaths: outputPaths)
        }

        // Validate that we didn't encounter anything surprising.
        var seenTargets = Set<BuildDependencyInfo.TargetDependencyInfo.Target>()
        for target in targets {
            // I'm not sure how we'd actually encounter this, unless somehow target specialization went awry or we encounter some unforeseen scenario.
            if seenTargets.contains(target.target) {
                errors.append("Found multiple identical targets named '\(target.target.targetName)' in project '\(target.target.projectName ?? "nil")' for platform '\(target.target.platformName ?? "nil")")
            }
            else {
                seenTargets.insert(target.target)
            }
        }

        self.errors = errors.elements
    }

    // FIXME: This is incomplete. We likely need to use `TaskProducer.willProduceBinary()` to know this, which means factoring that out somewhere where we can use it.  For now we use whether the target is a StandardTarget as a proxy for this.
    //
    /// Utility method which returns whether this target creates a binary, so we know whether to capture linkage information for it.
    private static func targetCreatesBinary(_ configuredTarget: ConfiguredTarget) -> Bool {
        return configuredTarget.target is SWBCore.StandardTarget
    }

    // FIXME: This may not be correct.  Wrapped targets will always create a product, but standalone products may not if they don't create a binary.  We should figure out whether we need to account for this.
    //
    /// Utility method which returns whether this target creates a product.
    private static func targetCreatesProduct(_ configuredTarget: ConfiguredTarget) -> Bool {
        return configuredTarget.target is SWBCore.StandardTarget
    }

    /// Collect the inputs for each build file in the target, respecting platform filters, the `EXCLUDED`/`INCLUDED` build file name build settings, and other relevant properties.
    ///
    /// Our general philosophy (for now) is to collect the most specific information we can divine. For example, if all we have is the stem of a library or framework, then we record that. But if we have a full library or framework name then we record that, even if the linker (or other tool) will find it using a search path, which could find a file with a different name.
    private static func inputs(_ configuredTarget: ConfiguredTarget, _ settings: Settings, _ buildFileResolver: BuildDependencyInfoBuildFileResolver) async -> (inputs: [TargetDependencyInfo.Input], errors: [String]) {
        actor InputCollector {
            private(set) var inputs = [TargetDependencyInfo.Input]()
            private(set) var errors = [String]()

            func addInput(_ input: TargetDependencyInfo.Input) {
                inputs.append(input)
            }

            func addError(_ error: String) {
                errors.append(error)
            }
        }
        let inputs = InputCollector()

        // Collect inputs for targets which create a binary.
        if targetCreatesBinary(configuredTarget), let standardTarget = configuredTarget.target as? SWBCore.StandardTarget {
            let buildFilesContext = BuildDependencyInfoBuildFileFilteringContext(scope: settings.globalScope)

            // Collect the build files in the Link Binaries build phase, if there is one.
            for buildFile in standardTarget.frameworksBuildPhase?.buildFiles ?? [] {
                let resolvedBuildFile: (reference: Reference, absolutePath: Path, fileType: FileTypeSpec)
                do {
                    resolvedBuildFile = try buildFileResolver.resolveBuildFileReference(buildFile)
                }
                catch {
                    // FIXME: Figure out how to report an issue in as an error in the data structures.
                    continue
                }

                // Check the platform filters and skip if not eligible for this platform.
                if case .excluded(_) = buildFilesContext.filterState(of: resolvedBuildFile.absolutePath, filters: buildFile.platformFilters) {
                    // We could emit info about why a file was excluded if we ever need it for diagnostic reasons.
                    continue
                }

                let filename = resolvedBuildFile.absolutePath.basename

                // TODO: all of the below are using linkType: .searchPath, we aren't reporting .absolutePath

                if resolvedBuildFile.fileType.conformsTo(identifier: "wrapper.framework") {
                    // TODO: static frameworks?
                    await inputs.addInput(TargetDependencyInfo.Input(inputType: .framework, name: .name(filename), linkType: .searchPath, libraryType: .dynamic))
                }
                else if resolvedBuildFile.fileType.conformsTo(identifier: "compiled.mach-o.dylib") {
                    await inputs.addInput(TargetDependencyInfo.Input(inputType: .library, name: .name(filename), linkType: .searchPath, libraryType: .dynamic))
                }
                else if resolvedBuildFile.fileType.conformsTo(identifier: "sourcecode.text-based-dylib-definition") {
                    await inputs.addInput(TargetDependencyInfo.Input(inputType: .library, name: .name(filename), linkType: .searchPath, libraryType: .dynamic))
                }
                else if resolvedBuildFile.fileType.conformsTo(identifier: "archive.ar") {
                    await inputs.addInput(TargetDependencyInfo.Input(inputType: .library, name: .name(filename), linkType: .searchPath, libraryType: .static))
                }
                // FIXME: Handle wrapper.xcframework
            }

            // Collect any linkage flags in OTHER_LDFLAGS, even if there is no Link Binary build phase.
            await findLinkedInputsFromBuildSettings(settings, addFramework: { await inputs.addInput($0) }, addLibrary: { await inputs.addInput($0) }, addError: { await inputs.addError($0) })
        }

        // TODO: Deduplicate inputs if we can (and if we want to bother).

        return await (inputs.inputs, inputs.errors)
    }

    /// Examine `OTHER_LDFLAGS` and related settings to detect linked inputs.
    /// - remark: This is written somewhat generically (with the callback blocks) in the hopes that `LinkageDependencyResolver.dependencies(for:...)` can someday adopt it, as the general approach was stolen from there.
    package static func findLinkedInputsFromBuildSettings(_ settings: Settings, addFramework: @Sendable (TargetDependencyInfo.Input) async -> Void, addLibrary: @Sendable (TargetDependencyInfo.Input) async -> Void, addError: @Sendable (String) async -> Void) async {
        await LdLinkerSpec.processLinkerSettingsForLibraryOptions(settings: settings) { macro, flag, stem in
            await addFramework(TargetDependencyInfo.Input(inputType: .framework, name: .stem(stem), linkType: .searchPath, libraryType: .dynamic))
        } addLibrary: { macro, flag, stem in
            await addLibrary(TargetDependencyInfo.Input(inputType: .library, name: .stem(stem), linkType: .searchPath, libraryType: .unknown))
        } addError: { error in
            await addError(error)
        }
    }

    /// Returns the output paths in the `DSTROOT` of the given `ConfiguredTarget`.
    private static func outputPaths(_ configuredTarget: ConfiguredTarget, _ settings: Settings) -> [String] {
        var outputPaths = [String]()

        // Get the path to the product of the target, removing the leading DSTROOT.
        if targetCreatesProduct(configuredTarget) {
            var productPath = settings.globalScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(settings.globalScope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME))
            if settings.globalScope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) {
                let DSTROOT = settings.globalScope.evaluate(BuiltinMacros.DSTROOT)
                if !DSTROOT.isEmpty, let relativeProductPath = productPath.relativeSubpath(from: DSTROOT).map({ Path($0) }) {
                    productPath = relativeProductPath.isAbsolute ? relativeProductPath : Path("/\(relativeProductPath.str)")
                    outputPaths.append(productPath.str)
                }
            }
        }

        // Right now we only return the product of the target.
        return outputPaths
    }

}

/// Special `CoreClientDelegate`-conforming struct because our use of `GlobalProductPlan` here should never be running external tools.
fileprivate struct UnsupportedCoreClientDelegate: CoreClientDelegate {
    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
        throw StubError.error("Running external tools is not supported when computing build dependency target info.")
    }
}

fileprivate struct BuildDependencyInfoBuildFileFilteringContext: BuildFileFilteringContext {
    var excludedSourceFileNames: [String]
    var includedSourceFileNames: [String]
    var currentPlatformFilter: SWBCore.PlatformFilter?

    init(scope: MacroEvaluationScope) {
        self.excludedSourceFileNames = scope.evaluate(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES)
        self.includedSourceFileNames = scope.evaluate(BuiltinMacros.INCLUDED_SOURCE_FILE_NAMES)
        self.currentPlatformFilter = PlatformFilter(scope)
    }
}

fileprivate final class BuildDependencyInfoGlobalProductPlanDelegate: GlobalProductPlanDelegate {

    // GlobalProductPlanDelegate conformance

    let cancelled = false

    func updateProgress(statusMessage: String, showInLog: Bool) { }

    // CoreClientTargetDiagnosticProducingDelegate conformance

    let coreClientDelegate: any CoreClientDelegate = UnsupportedCoreClientDelegate()

    // TargetDiagnosticProducingDelegate conformance

    let diagnosticContext = DiagnosticContextData(target: nil)

    private let _diagnosticsEngine = DiagnosticsEngine()

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    // ActivityReporter conformance

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        .init(rawValue: -1)
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) { }

    func emit(data: [UInt8], for activity: SWBCore.ActivityID, signature: SWBUtil.ByteString) { }

    func emit(diagnostic: SWBUtil.Diagnostic, for activity: SWBCore.ActivityID, signature: SWBUtil.ByteString) { }

    let hadErrors = false

}

fileprivate struct BuildDependencyInfoBuildFileResolver: BuildFileResolution {
    let workspaceContext: WorkspaceContext

    let configuredTarget: ConfiguredTarget?

    let settings: Settings

    let platform: Platform?

    let globalTargetInfoProvider: any GlobalTargetInfoProvider
}
