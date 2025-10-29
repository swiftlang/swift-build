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

import SWBUtil
import enum SWBProtocol.ExternalToolResult
import struct SWBProtocol.BuildOperationTaskEnded
package import SWBCore
import SWBTaskConstruction
import SWBMacro

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
        let targets = await buildGraph.allTargets.asyncMap { configuredTarget in
            let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
            let targetName = configuredTarget.target.name
            let projectName = settings.project?.name
            let platform = settings.platform
            let platformName = platform?.name
            let buildFileResolver = BuildDependencyInfoBuildFileResolver(workspaceContext: workspaceContext, configuredTarget: configuredTarget, settings: settings, platform: platform, globalTargetInfoProvider: globalProductPlan)
            let (inputs, inputsErrors) = await BuildDependencyInfo.inputs(configuredTarget, settings, buildFileResolver)
            let outputPaths = BuildDependencyInfo.outputPaths(configuredTarget, settings)

            errors.append(contentsOf: inputsErrors)

            return TargetDependencyInfo(targetName: targetName, projectName: projectName, platformName: platformName, inputs: inputs, outputPaths: outputPaths, dependencies: [])
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

        self.init(targets: targets, errors: errors.elements)
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
            let libType: TargetDependencyInfo.Input.LibraryType = (flag == "-upward_framework") ? .upward : .dynamic
            await addFramework(TargetDependencyInfo.Input(inputType: .framework, name: .stem(stem), linkType: .searchPath, libraryType: libType))
        } addLibrary: { macro, flag, stem in
            let libType: TargetDependencyInfo.Input.LibraryType = (flag == "-upward-l") ? .upward : .unknown
            await addLibrary(TargetDependencyInfo.Input(inputType: .library, name: .stem(stem), linkType: .searchPath, libraryType: libType))
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
    func executeExternalTool(commandLine: [String], workingDirectory: Path?, environment: [String : String]) async throws -> ExternalToolResult {
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
