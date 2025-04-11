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
package import SWBUtil
import struct Foundation.Data
package import struct SWBProtocol.BuildDescriptionID
package import struct SWBProtocol.BuildOperationTaskEnded
package import struct SWBProtocol.TargetDependencyRelationship
import class SWBTaskConstruction.ProductPlan
package import SWBMacro
import Synchronization

/// The delegate for constructing a build description.
package protocol BuildDescriptionConstructionDelegate: ActivityReporter {
    var diagnosticContext: DiagnosticContextData { get }

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine>

    var diagnostics: [ConfiguredTarget?: [Diagnostic]] { get }

    /// Check if the construction has been cancelled and should abort as soon as possible.
    var cancelled: Bool { get }

    /// Update the progress of an ongoing build description construction.
    func updateProgress(statusMessage: String, showInLog: Bool)

    func emit(_ diagnostic: Diagnostic)

    /// Report the build description ID of the build operation.
    func buildDescriptionCreated(_ buildDescriptionID: BuildDescriptionID)

    /// Record the raw manifest dictionary.  This is used for testing.
    func recordManifest(targetDefinitions: [String: ByteString], toolDefinitions: [String: ByteString], nodeDefinitions: [String: ByteString], commandDefinitions: [String: ByteString]) throws
}

package extension BuildDescriptionConstructionDelegate {
    func recordManifest(targetDefinitions: [String: ByteString], toolDefinitions: [String: ByteString], nodeDefinitions: [String: ByteString], commandDefinitions: [String: ByteString]) {
        // This is only used for testing.
    }
}

/// Persistable representation of the complete set of tasks needed for a build.
///
/// This representation primarily is in the form of a build file suitable for use with llbuild's BuildSystem library, but also contains additional task-specific data used for the execution of internal tasks, as well as metadata to allow matching up status information from llbuild to the corresponding Swift Build and PIF objects.
package final class BuildDescription: Serializable, Sendable, Encodable, CacheableValue {

    enum CodingKeys: CodingKey {
        case dir
        case signature
        case invalidationPaths
        case copiedPathMap
        case invalidationSignature
        case targetDependencies
        case bypassActualTasks
    }

    /// The current build file schema version.
    static let manifestClientVersion: Int = 0

    /// The path of the directory in which the the description and manifest are stored.
    package let dir: Path

    /// The unique identifier for this build description.
    package var ID: BuildDescriptionID {
        return BuildDescriptionID(signature.asString)
    }

    /// The signature of the description.  The signature's string form will be used as a component of the filename of the manifest and the serialized description.
    package let signature: BuildDescriptionSignature

    /// Additional paths which invalidate the build description
    package let invalidationPaths: [Path]

    /// Map of the files which are copied during the build operation, used for mapping diagnostics.
    package let copiedPathMap: [String: String]

    /// Last known signature of `invalidationPaths`.
    package let invalidationSignature: FilesSignature

    /// The list of recursive search path requests used in computing these tasks.
    package let recursiveSearchPathResults: [RecursiveSearchPathResolver.CachedResult]

    static let bundleExtension = "xcbuilddata"

    /// Static `bundlePath` for use before a `BuildDescription` is created (ie. to find the description)
    package static func buildDescriptionPackagePath(inDir dir: Path, signature: BuildDescriptionSignature) -> Path {
        dir.join("\(signature.asString).\(Self.bundleExtension)")
    }

    /// The path to the llbuild build database corresponding to this build description. Note that it is next to, not inside the build description package.
    package var buildDatabasePath: Path {
        dir.join("build.db")
    }

    /// The path to the bundle which contains the serialized build description, manifest, etc.
    package var packagePath: Path {
        Self.buildDescriptionPackagePath(inDir: dir, signature: signature)
    }

    /// The path to the serialized build description.
    package var serializedBuildDescriptionPath: Path {
        packagePath.join("description.msgpack")
    }

    /// The path to the on-disk task store.
    package var taskStorePath: Path {
        packagePath.join("task-store.msgpack")
    }

    /// The path to the build manifest.
    package var manifestPath: Path {
        return packagePath.join("manifest.json")
    }

    /// The path to the serialized build request.
    package var buildRequestPath: Path {
        return packagePath.join("build-request.json")
    }

    /// The path to the target build graph artifact file.
    package var targetGraphPath: Path {
        return packagePath.join("target-graph.txt")
    }

    // rdar://107734664 (Consider passing the task store as a parameter to build description methods rather than as a property of BuildDescription)
    package let taskStore: FrozenTaskStore

    /// The set of all (non-virtual) paths produced by tasks in the build description.
    private let allOutputPaths: Set<Path>

    private let rootPathsPerTarget: [ConfiguredTarget: [Path]]
    private let moduleCachePathsPerTarget: [ConfiguredTarget: [Path]]

    private let dependencyValidationPerTarget: [ConfiguredTarget: BooleanWarningLevel]

    /// The map of used in-process classes.
    package let taskActionMap: [String: TaskAction.Type]

    /// The path to the module validation session file.
    package let moduleSessionFilePath: Path?

    /// The count of tasks in each target, used for target completion tracking.
    package let targetTaskCounts: [ConfiguredTarget: Int]

    package let targetDependencies: [TargetDependencyRelationship]

    /// Maps module names to the GUID of the configured target which will define them.
    package let definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>]

    /// Info captured about the build to be optionally written to a file.
    ///
    /// This info is not serialized to the build description, and is only written out if it is not nil, so toggling the environment variable which emits this info needs to produce a new build description.
    package let capturedBuildInfo: CapturedBuildInfo?

    /// The list of task construction diagnostics. They are getting serialized.
    package let diagnostics: [ConfiguredTarget?: [Diagnostic]]

    package var hadErrors: Bool {
        for diagnostics in diagnostics.values {
            for diagnostic in diagnostics {
                if diagnostic.behavior == .error {
                    return true
                }
            }
        }

        return false
    }

    /// Thread safe cache of whether a path is a build directory.
    ///
    /// This is used for dependency validation, where we need to know whether DSTROOT, OBJROOT, and SYMROOT are marked with the build directory xattr.
    /// We need to look this up for every build task, but the ROOT settings are always the same for each target, and often even the same for _all_ targets.
    private let isBuildDirectoryCache: Cache<Path, Bool>

    package let bypassActualTasks: Bool

    /// `true` if this description's task graph allows targets to build in parallel. Should be preferred over querying the build request, which is not always respected.
    package let targetsBuildInParallel: Bool

    /// `true` if builds using this description should emit frontend command lines. This setting is important for debugging workflows, so we want the ability to enable it conveniently via build setting.
    /// However, it should be consistent across all tasks in a build to avoid introducing unnecessary variants of dynamic compile tasks. To address this, we store it as a bit on the build description.
    package let emitFrontendCommandLines: Bool

    /// Load a build description from the given path.
    fileprivate init(inDir dir: Path, signature: BuildDescriptionSignature, taskStore: FrozenTaskStore, allOutputPaths: Set<Path>, rootPathsPerTarget: [ConfiguredTarget: [Path]], moduleCachePathsPerTarget: [ConfiguredTarget: [Path]], settingsPerTarget: [ConfiguredTarget: Settings], enableStaleFileRemoval: Bool = true, taskActionMap: [String: TaskAction.Type], targetTaskCounts: [ConfiguredTarget: Int], moduleSessionFilePath: Path?, diagnostics: [ConfiguredTarget?: [Diagnostic]], fs: any FSProxy, invalidationPaths: [Path], recursiveSearchPathResults: [RecursiveSearchPathResolver.CachedResult], copiedPathMap: [String: String], targetDependencies: [TargetDependencyRelationship], definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>], capturedBuildInfo: CapturedBuildInfo?, bypassActualTasks: Bool, targetsBuildInParallel: Bool, emitFrontendCommandLines: Bool) throws {
        self.dir = dir
        self.signature = signature
        self.taskStore = taskStore
        self.allOutputPaths = allOutputPaths
        self.rootPathsPerTarget = rootPathsPerTarget
        self.moduleCachePathsPerTarget = moduleCachePathsPerTarget
        self.dependencyValidationPerTarget = settingsPerTarget.mapValues { $0.globalScope.evaluate(BuiltinMacros.VALIDATE_DEPENDENCIES) }
        self.taskActionMap = taskActionMap
        self.targetTaskCounts = targetTaskCounts
        self.moduleSessionFilePath = moduleSessionFilePath
        self.diagnostics = diagnostics
        self.isBuildDirectoryCache = .init()
        self.invalidationPaths = invalidationPaths
        self.invalidationSignature = fs.filesSignature(invalidationPaths)
        self.recursiveSearchPathResults = recursiveSearchPathResults
        self.copiedPathMap = copiedPathMap
        self.targetDependencies = targetDependencies
        self.definingTargetsByModuleName = definingTargetsByModuleName
        self.capturedBuildInfo = capturedBuildInfo
        self.bypassActualTasks = bypassActualTasks
        self.targetsBuildInParallel = targetsBuildInParallel
        self.emitFrontendCommandLines = emitFrontendCommandLines
    }

    // MARK: Client API

    /// The sequence of all configured targets.
    package var allConfiguredTargets: Dictionary<ConfiguredTarget, Int>.Keys {
        // TODO coming soon: <rdar://problem/40538331> ☂️ Opaque Result Types
        return targetTaskCounts.keys
    }

    /// State of a build node to use for 'prepare-for-index' build operation.
    package struct BuildNodeToPrepareForIndex {
        package let target: ConfiguredTarget
        package let nodeName: String
    }

    /// If the `prepareForIndexing` build command is used, it returns the subset of nodes to build, otherwise it returns `nil`.
    package func buildNodesToPrepareForIndex(buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, workspaceContext: WorkspaceContext) -> [BuildNodeToPrepareForIndex]? {
        if case let .prepareForIndexing(targetsToPrepare?, _) = buildRequest.buildCommand {
            var nodesToBuild: [BuildNodeToPrepareForIndex] = []
            for targetToPrepare in targetsToPrepare {
                let foundTargets = self.allConfiguredTargets.filter{ $0.target.guid == targetToPrepare.guid }
                guard let selectedTarget = foundTargets.one(by: {
                    buildRequestContext.selectConfiguredTargetForIndex($0, $1, hasEnabledIndexBuildArena: buildRequest.enableIndexBuildArena, runDestination: buildRequest.parameters.activeRunDestination)
                }) else {
                    continue
                }
                for task in taskStore.tasksForTarget(selectedTarget) {
                    guard !task.isGate, task.preparesForIndexing else { continue }
                    guard let ruleName = task.ruleInfo.first, ruleName == ProductPlan.preparedForIndexPreCompilationRuleName else { continue }
                    guard let output = (task.action as? AuxiliaryFileTaskAction)?.context.output else { continue }
                    nodesToBuild.append(BuildNodeToPrepareForIndex(target: selectedTarget, nodeName: output.str))
                    break
                }
            }
            return nodesToBuild
        } else {
            return nil
        }
    }

    package func levelForDiagnosticMessagesForTaskInputsWithoutProducer(task: any ExecutableTask) -> BooleanWarningLevel {
        if let target = task.forTarget, let value = self.dependencyValidationPerTarget[target] {
            return value
        }
        return .yes
    }

    package func isPathInBuildDirectory(path: Path, task: any ExecutableTask, fs: any FSProxy) -> Bool {
        // Only check tasks attached to a target.
        // Users cannot presently manually specify inputs for any of the kinds of target-independent tasks which exist today.
        guard let target = task.forTarget, let rootPaths = self.rootPathsPerTarget[target] else {
            return false
        }

        // Only consider paths which _aren't_ in the module cache, which isn't tracked by the build system at present (this may change in future with explicit modules). Normally such paths would be excluded by the root paths check below, but the module cache path may be under one of the other root paths in certain configurations (e.g. overridden SYMROOT).
        for cachePath in moduleCachePathsPerTarget[target, default: []] {
            if cachePath.isAncestor(of: path) == true {
                return false
            }
        }

        // Only consider build directories as those which the build system itself has created.
        // Otherwise, DSTROOT might be equal to SRCROOT, and we'll get a false positive error about a missing input
        // that was actually part of the source inputs.
        let effectiveRootPaths = rootPaths.filter { rootPath in
            return isBuildDirectoryCache.getOrInsert(rootPath) {
                do {
                    if try fs.hasCreatedByBuildSystemAttribute(rootPath) {
                        return true
                    }
                } catch {
                }
                return false
            }
        }

        // We only want to validate inputs which are inside the build directory.
        // Other inputs (for example under SRCROOT) are naturally not expected to be produced by another task and are intended to exist before the build starts.
        if !effectiveRootPaths.contains(where: { $0.isAncestor(of: path) }) {
            return false
        }

        return true
    }

    package func diagnosticMessageForTaskInputWithoutProducer(path: Path, isDiscoveredDependency: Bool, task: any ExecutableTask, fs: any FSProxy) -> String? {
        if !isPathInBuildDirectory(path: path, task: task, fs: fs) {
            return nil
        }

        // Inputs with no producer task issue a warning, because this indicates a missing dependency, the consequence of which may be incorrect builds or a missing file error due to llbuild scanning order.
        if !allOutputPaths.contains(path) {
            return "Missing creator task for \(isDiscoveredDependency ? "discovered dependency " : "")input node: '\(path.str)'. Did you forget to declare this node as an output of a script phase or custom build rule which produces it?"
        }

        return nil
    }

    // MARK: Serialization

    package func serialize<T: Serializer>(to serializer: T) {
        guard serializer.delegate is BuildDescriptionSerializerDelegate else { fatalError("delegate must be a BuildDescriptionSerializerDelegate") }

        serializer.beginAggregate(19)
        serializer.serialize(dir)
        serializer.serialize(signature)
        // Serialize the tasks first so we can index into this array during deserialization.
        serializer.serialize(allOutputPaths)
        serializer.serialize(rootPathsPerTarget)
        serializer.serialize(moduleCachePathsPerTarget)
        serializer.serialize(dependencyValidationPerTarget)
        serializer.beginAggregate(taskActionMap.count)
        for (tool, taskActionClass) in taskActionMap.sorted(byKey: <) {
            serializer.beginAggregate(2)
            serializer.serialize(tool)
            serializer.serialize(taskActionClass.serializableTypeCode)
            serializer.endAggregate()
        }
        serializer.endAggregate()
        serializer.serialize(targetTaskCounts)
        serializer.serialize(moduleSessionFilePath)

        // Force the diagnostics to be ordered deterministically in the description.
        let diagnostics = self.diagnostics.mapValues { $0.sorted(by: { $0.formatLocalizedDescription(.debug) < $1.formatLocalizedDescription(.debug) }) }
        serializer.serialize(diagnostics)

        serializer.serialize(invalidationPaths)
        serializer.serialize(invalidationSignature)
        serializer.serialize(recursiveSearchPathResults)
        serializer.serialize(copiedPathMap)
        serializer.serialize(targetDependencies)
        serializer.serialize(definingTargetsByModuleName)
        serializer.serialize(bypassActualTasks)
        serializer.serialize(targetsBuildInParallel)
        serializer.serialize(emitFrontendCommandLines)
        serializer.endAggregate()
    }

    package init(from deserializer: any Deserializer) throws {
        // Check that we have the appropriate delegate.
        guard let delegate = deserializer.delegate as? BuildDescriptionDeserializerDelegate else { throw DeserializerError.invalidDelegate("delegate must be a BuildDescriptionDeserializerDelegate") }

        try deserializer.beginAggregate(19)
        self.dir = try deserializer.deserialize()
        self.signature = try deserializer.deserialize()
        self.allOutputPaths = try deserializer.deserialize()
        self.rootPathsPerTarget = try deserializer.deserialize()
        self.moduleCachePathsPerTarget = try deserializer.deserialize()
        self.dependencyValidationPerTarget = try deserializer.deserialize()
        var taskActionMap = [String: TaskAction.Type]()
        let taskActionMapCount = try deserializer.beginAggregate()
        for _ in 0..<taskActionMapCount {
            try deserializer.beginAggregate(2)
            let tool: String = try deserializer.deserialize()
            let code: SerializableTypeCode = try deserializer.deserialize()
            guard let taskActionClass = (TaskAction.classForCode(code) as? TaskAction.Type?) else { throw DeserializerError.deserializationFailed("Invalid TaskAction code: \(code)") }
            taskActionMap[tool] = taskActionClass
        }
        self.taskActionMap = taskActionMap
        self.targetTaskCounts = try deserializer.deserialize()
        self.moduleSessionFilePath = try deserializer.deserialize()
        self.diagnostics = try deserializer.deserialize()
        self.isBuildDirectoryCache = .init()
        self.invalidationPaths = try deserializer.deserialize()
        self.invalidationSignature = try deserializer.deserialize()
        self.recursiveSearchPathResults = try deserializer.deserialize()
        self.copiedPathMap = try deserializer.deserialize()
        self.targetDependencies = try deserializer.deserialize()
        self.definingTargetsByModuleName = try deserializer.deserialize()
        // We don't serialize the captured build info.
        self.capturedBuildInfo = nil
        self.bypassActualTasks = try deserializer.deserialize()
        self.targetsBuildInParallel = try deserializer.deserialize()
        self.emitFrontendCommandLines = try deserializer.deserialize()
        guard let taskStore = delegate.taskStore else {
            throw DeserializerError.deserializationFailed("Expected delegate to provide a TaskStore")
        }
        self.taskStore = taskStore
    }

    package var cost: Int {
        self.taskStore.taskCount
    }
}

private extension DependencyDataStyle {
    var name: String {
        switch self {
        case .dependencyInfo:
            return "dependency-info"
        case .makefile, .makefiles:
            return "makefile"
        case .makefileIgnoringSubsequentOutputs:
            return "makefile-ignoring-subsequent-outputs"
        }
    }

    var paths: [Path] {
        switch self {
        case .dependencyInfo(let path):
            return [path]
        case .makefile(let path):
            return [path]
        case .makefiles(let paths):
            return paths
        case .makefileIgnoringSubsequentOutputs(let path):
            return [path]
        }
    }
}

/// Support class for construction of a complete build description.
package final class BuildDescriptionBuilder {
    final class NodeList {
        var nodes: [any PlannedNode] = []
    }

    /// Task-specific aggregated information used for mutable node handling.
    final class MutatingTaskInfo {
        /// The trigger node to produce from this task, if any.
        var triggerNode: (PlannedVirtualNode)? = nil

        /// The trigger input to inject a dependency on, if any.
        ///
        /// This list is non-empty iff this is a mutating task.
        var commandDependencies: [PlannedVirtualNode] = []
    }

    /// The path to store the description at.
    private let path: Path

    /// The signature of the description.
    private let signature: BuildDescriptionSignature

    /// Whether to rewrite commands to use simulated tasks.
    private let bypassActualTasks: Bool

    /// `true` if the task graph allows targets to build in parallel.
    private let targetsBuildInParallel: Bool

    /// `true` if build using this description should emit frontend command lines.
    private let emitFrontendCommandLines: Bool

    /// A set of additional inputs to automatically add to tasks.
    ///
    /// This is currently used to implement the must-precede relationships, since llbuild does not support them natively.
    private let taskAdditionalInputs: [Ref<any PlannedTask>: NodeList]

    /// The set of known mutable nodes.
    private let mutatedNodes: Set<Ref<any PlannedNode>>

    /// A mapping of tasks which interact with mutable nodes.
    private let mutatingTasks: [Ref<any PlannedTask>: MutatingTaskInfo]

    /// The path to the module validation session file.
    private let moduleSessionFilePath: Path?

    /// The list of known tasks.
    private var taskStore: TaskStore

    /// The map of target definitions to JSON fragments.
    fileprivate var targetDefinitions: [String: ByteString] = [:]

    private var targetDependencies: [TargetDependencyRelationship]

    private let definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>]

    /// The map of tool definitions to JSON fragments.
    private var toolDefinitions: [String: ByteString] = [:]

    /// The map of node definitions to JSON fragments.
    private var nodeDefinitions: [String: ByteString] = [:]

    /// The map of commands to JSON fragments.
    private var commandDefinitions: [String: ByteString] = [:]

    /// The map of used in-process classes.
    private var taskActionMap: [String: TaskAction.Type] = [:]

    /// The set of all seen inputs, used to determine roots.
    private var allInputs = Set<Ref<any PlannedNode>>()

    /// The set of all seen outputs, used to determine roots.
    //
    // FIXME: Eliminate this, and force clients to ask for what is needed (e.g., the target root node).
    //
    // FIXME: In addition to the stated use, this is also currently being used by the shell script phase tasks to hijack their output files, based on the global set. We need to resolve that.
    var allOutputs = Set<Ref<any PlannedNode>>()

    /// Collect amended outputs per task
    var taskOutputMap = [Ref<any PlannedTask>: [any PlannedNode]]()

    /// The diagnostics engine for task construction.
    fileprivate var diagnosticsEngines = [ConfiguredTarget?: DiagnosticsEngine]()

    /// Additional paths which invalidate the build description because they provide significant input to the build, e.g.
    /// user-provided module maps.
    private let invalidationPaths: [Path]

    /// Map of the files which are copied during the build operation, used for mapping diagnostics.
    private let copiedPathMap: [String: String]

    /// The list of recursive search path requests used in computing these tasks.
    let recursiveSearchPathResults: [RecursiveSearchPathResolver.CachedResult]

    /// The map of output paths per configured target.
    private let outputPathsPerTarget: [ConfiguredTarget?: [Path]]

    private let allOutputPaths: Set<Path>

    // The map of root paths per configured target.
    private let rootPathsPerTarget: [ConfiguredTarget: [Path]]

    // The map of module cache path per configured target.
    private let moduleCachePathsPerTarget: [ConfiguredTarget: [Path]]

    // The map of stale file removal identifier per configured target.
    private let staleFileRemovalIdentifierPerTarget: [ConfiguredTarget?: String]

    // The map of settings per configured target.
    private let settingsPerTarget: [ConfiguredTarget: Settings]

    /// Info captured about the build to be optionally written to a file.
    package let capturedBuildInfo: CapturedBuildInfo?

    /// For processing Gate and Constructed Tasks in parallel.
    private let processTaskLock = SWBMutex(())

    /// Create a builder for constructing build descriptions.
    ///
    /// - Parameters:
    ///   - path: The path of a directory to store the build description to.
    ///   - bypassActualTasks: If enabled, replace tasks with fake ones (`/usr/bin/true`).
    init(path: Path, signature: BuildDescriptionSignature, buildCommand: BuildCommand, taskAdditionalInputs: [Ref<any PlannedTask>: NodeList], mutatedNodes: Set<Ref<any PlannedNode>>, mutatingTasks: [Ref<any PlannedTask>: MutatingTaskInfo], bypassActualTasks: Bool, targetsBuildInParallel: Bool, emitFrontendCommandLines: Bool, moduleSessionFilePath: Path?, invalidationPaths: [Path], recursiveSearchPathResults: [RecursiveSearchPathResolver.CachedResult], copiedPathMap: [String: String], outputPathsPerTarget: [ConfiguredTarget?: [Path]], allOutputPaths: Set<Path>, rootPathsPerTarget: [ConfiguredTarget: [Path]], moduleCachePathsPerTarget: [ConfiguredTarget: [Path]], staleFileRemovalIdentifierPerTarget: [ConfiguredTarget?: String], settingsPerTarget: [ConfiguredTarget: Settings], targetDependencies: [TargetDependencyRelationship], definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>], workspace: Workspace, capturedBuildInfo: CapturedBuildInfo?) {
        self.path = path
        self.signature = signature
        self.taskAdditionalInputs = taskAdditionalInputs
        self.mutatedNodes = mutatedNodes
        self.mutatingTasks = mutatingTasks
        self.bypassActualTasks = bypassActualTasks
        self.targetsBuildInParallel = targetsBuildInParallel
        self.emitFrontendCommandLines = emitFrontendCommandLines
        self.moduleSessionFilePath = moduleSessionFilePath
        self.invalidationPaths = invalidationPaths
        self.recursiveSearchPathResults = recursiveSearchPathResults
        self.copiedPathMap = copiedPathMap
        self.outputPathsPerTarget = outputPathsPerTarget
        self.allOutputPaths = allOutputPaths
        self.rootPathsPerTarget = rootPathsPerTarget
        self.moduleCachePathsPerTarget = moduleCachePathsPerTarget
        self.staleFileRemovalIdentifierPerTarget = staleFileRemovalIdentifierPerTarget
        self.settingsPerTarget = settingsPerTarget
        self.targetDependencies = targetDependencies
        self.definingTargetsByModuleName = definingTargetsByModuleName
        self.capturedBuildInfo = capturedBuildInfo
        self.taskStore = TaskStore()
    }

    /// Create a build description from the build.
    ///
    /// - Returns: The constructed build description.
    func construct(fs: any FSProxy, delegate: any BuildDescriptionConstructionDelegate) throws -> BuildDescription {
        // We currently always construct the description by serializing the data, then loading it.

        // Stale file removal
        if !staleFileRemovalIdentifierPerTarget.isEmpty {
            for (configuredTarget, outputPaths) in outputPathsPerTarget {
                // The staleFileRemovalIdentifier is used to construct a node which is used as the input to the target-start gate task, so that stale file removal occurs before the target starts building.  It is also the output of the stale file removal task constructed below which is how it connects up.
                guard let staleFileRemovalIdentifier = staleFileRemovalIdentifierPerTarget[configuredTarget] else {
                    continue
                }

                allOutputs.insert(Ref(MakePlannedVirtualNode(staleFileRemovalIdentifier)))
                // It's a matter of convenience (I think - mhr) that the SFR task key here is the same as the SFR node added to "outputs" - they could be different, if we want them to be.
                commandDefinitions["<\(staleFileRemovalIdentifier)>"] = OutputByteStream().writingJSONObject({
                    $0["tool"] = "stale-file-removal"
                    $0["expectedOutputs"] = outputPaths.map { $0.str }

                    // Unwrap the configured target, as target-independent tasks don't have a set of root paths.
                    if let configuredTarget = configuredTarget, let rootPaths = rootPathsPerTarget[configuredTarget] {
                        $0["roots"] = rootPaths.map { $0.str }
                    }

                    $0["outputs"] = ["<\(staleFileRemovalIdentifier)>"]
                }).bytes
            }
        }


        // Create the root target node.
        do {
            // The roots are any outputs which are never declared as an input.
            //
            // We sort this to ensure deterministic output.
            let allRootIdentifiers = allOutputs.subtracting(allInputs).map({ $0.instance.identifier }).sorted()

            let stableIdentifier = "<all>"
            commandDefinitions[stableIdentifier] = OutputByteStream().writingJSONObject({
                $0["tool"] = "phony"
                $0["inputs"] = allRootIdentifiers
                $0["outputs"] = ["<all>"]
            }).bytes
        }

        func encodeIfNeeded(_ value: ByteString) -> ByteString {
            let stream = OutputByteStream()
            stream <<< Format.asJSON(value)
            return stream.bytes
        }

        // Construct the build manifest.
        //
        // This is a YAML file that we are building piecemeal. See:
        //   https://github.com/apple/swift-llbuild/blob/main/docs/buildsystem.rst
        //
        // FIXME: Construct directly on disk.
        let manifest = OutputByteStream()
        let clientDefinitions: KeyValuePairs = [
            // FIXME: For now we write as the 'basic' client, until we have the ability to embed llbuild.
            "name": encodeIfNeeded("basic"),
            "version": ByteString(encodingAsUTF8: String(BuildDescription.manifestClientVersion)),
            "file-system": encodeIfNeeded(ByteString(encodingAsUTF8: fs.fileSystemMode.manifestLabel)),
            "perform-ownership-analysis": SWBFeatureFlag.performOwnershipAnalysis.value ? encodeIfNeeded("yes") : encodeIfNeeded("no")
        ]

        let sections = [
            ("targets", targetDefinitions),
            ("tools", toolDefinitions),
            ("nodes", nodeDefinitions),
            ("commands", commandDefinitions),
        ]

        manifest.writeJSONObject { json in
            json.writeMapWithLiteralValues(clientDefinitions, forKey: "client")
            for (name, map) in sections where !map.isEmpty {
                json.writeMapWithLiteralValues(map.sorted(byKey: <), forKey: name)
            }
        }

        // Pass the manifest data to the delegate.
        do {
            try delegate.recordManifest(targetDefinitions: targetDefinitions, toolDefinitions: toolDefinitions, nodeDefinitions: nodeDefinitions, commandDefinitions: commandDefinitions)
        }
        catch {
            throw StubError.error("unable to record manifest to build description delegate: \(error)")
        }

        let frozenTaskStore = taskStore.freeze()

        // Compute the count of tasks by target, which we use to know when a task is complete.
        var targetTaskCounts = [ConfiguredTarget: Int]()
        frozenTaskStore.forEachTask { task in
            if let target = task.forTarget, !task.isGate {
                targetTaskCounts[target] = (targetTaskCounts[target] ?? 0) + 1
            }
        }

        // Construct the target configuration info.  This is used when the build is instructed to write a file with information about the targets that were built for post-build analysis purposes.

        // Create the build description.
        let buildDescription: BuildDescription
        do {
            buildDescription = try BuildDescription(inDir: path, signature: signature, taskStore: frozenTaskStore, allOutputPaths: allOutputPaths, rootPathsPerTarget: rootPathsPerTarget, moduleCachePathsPerTarget: moduleCachePathsPerTarget, settingsPerTarget: settingsPerTarget, taskActionMap: taskActionMap, targetTaskCounts: targetTaskCounts, moduleSessionFilePath: moduleSessionFilePath, diagnostics: diagnosticsEngines.mapValues { engine in engine.diagnostics }, fs: fs, invalidationPaths: invalidationPaths, recursiveSearchPathResults: recursiveSearchPathResults, copiedPathMap: copiedPathMap, targetDependencies: targetDependencies, definingTargetsByModuleName: definingTargetsByModuleName, capturedBuildInfo: capturedBuildInfo, bypassActualTasks: bypassActualTasks, targetsBuildInParallel: targetsBuildInParallel, emitFrontendCommandLines: emitFrontendCommandLines)
        }
        catch {
            throw StubError.error("unable to create build description: \(error)")
        }

        // Write the manifest to disk at the location defined by the build description.
        do {
            try fs.createDirectory(buildDescription.manifestPath.dirname, recursive: true)
            try fs.write(buildDescription.manifestPath, contents: manifest.bytes, atomically: true)
        }
        catch {
            throw StubError.error("unable to write manifest to '\(buildDescription.manifestPath.str)': \(error)")
        }

        return buildDescription
    }

    // MARK: Client API

    /// Add a warning.
    func addWarning(forTarget: ConfiguredTarget? = nil, _ message: String) {
        diagnosticsEngines.getOrInsert(forTarget, { DiagnosticsEngine() }).emit(data: DiagnosticData(message), behavior: .warning)
    }

    /// Add an error.
    func addError(forTarget: ConfiguredTarget? = nil, _ message: String) {
        diagnosticsEngines.getOrInsert(forTarget, { DiagnosticsEngine() }).emit(data: DiagnosticData(message), behavior: .error)
    }

    /// Assign and record the stable identifier for a planned task.
    private func assignTaskIdentifier(_ task: any PlannedTask) throws -> TaskIdentifier {
        // Add to the task list.
        // FIXME: This cast is unfortunate.
        let execTask = task.execTask as! Task
        return try taskStore.insertTask(execTask)
    }

    /// Get the inputs for a task, amended if necessary.
    private func amendedInputsForTask(_ task: any PlannedTask, _ inputs: [any PlannedNode]) -> [any PlannedNode] {
        var inputs = inputs
        if let extraInputList = taskAdditionalInputs[Ref(task)] {
            inputs += extraInputList.nodes
        }
        if let info = mutatingTasks[Ref(task)], !info.commandDependencies.isEmpty {
            // If this is a mutating command, we must rewrite out any mutated input nodes...
            inputs = inputs.filter{ !mutatedNodes.contains(Ref($0)) }

            // ... and append all the necessary command dependencies.
            //
            // NOTE: These must be sorted, as it is not guaranteed that they
            // will be added in a deterministic order.
            inputs += info.commandDependencies.sorted(by: { $0.name < $1.name })
        }
        return inputs
    }

    /// Get the outputs for a task, amended if necessary.
    private func amendedOutputsForTask(_ task: any PlannedTask, _ outputs: [any PlannedNode]) -> [any PlannedNode] {
        // If we have a trigger node, annotate it ap
        var outputs = outputs
        if let info = mutatingTasks[Ref(task)] {
            if let trigger = info.triggerNode {
                createNodeDefinition(trigger) { definition in
                    definition.writeJSONObject {
                        $0["is-command-timestamp"] = true
                    }
                }
                // Trigger nodes are implicitly treated as outputs.
                outputs.append(trigger)
            }

            // If this is a mutating command, we must rewrite out any mutated actual output nodes (downstream edges must be either themselves mutating, or depend on some other gate to introduce an ordering between them).
            if !info.commandDependencies.isEmpty {
                outputs = outputs.filter{ !mutatedNodes.contains(Ref($0)) }

                // We currently require producers to have defined an extra virtual node to use for the purposes of forcing the ordering of this command.
                if outputs.isEmpty {
                    addError(forTarget: task.forTarget, "invalid task ('\(task.ruleInfo.quotedDescription)') with mutable output but no other virtual output node")
                }
            }
        }
        return outputs
    }

    /// Helper method for assigning the command definition.
    private func createCommandDefinition(_ task: any PlannedTask, inputs: [any PlannedNode] = [], outputs: [any PlannedNode] = [], body: (OutputByteStream) -> Void) throws {
        // Create the actual definition.
        let definition = OutputByteStream()
        body(definition)

        try processTaskLock.withLock {
            // Add it to the definitions map.
            let identifier = try assignTaskIdentifier(task)
            assert(!commandDefinitions.contains(identifier.rawValue), "non-unique task identifier")
            commandDefinitions[identifier.rawValue] = definition.bytes

            // Use this map later to diagnose the attempts to define multiple producers for an output
            taskOutputMap[Ref(task), default:[]].append(contentsOf: outputs)

            // Update the global input and output list.
            allInputs.formUnion(inputs.map{ Ref($0) })
            allOutputs.formUnion(outputs.map{ Ref($0) })
        }
    }

    /// Helper method for create a node definition.
    fileprivate func createNodeDefinition(_ node: any PlannedNode, body: (OutputByteStream) -> Void) {
        // Create the actual definition.
        let definition = OutputByteStream()
        body(definition)

        processTaskLock.withLock {
            // Add it to the definitions map.
            let identifier = node.identifier
            let newDefinition = definition.bytes
                assert(!nodeDefinitions.contains(identifier) || nodeDefinitions[identifier] == newDefinition, "non-unique node identifier '\(identifier)'")
                nodeDefinitions[identifier] = newDefinition
            }
    }

    // MARK: Adding commands for PlannedTasks.


    /// Add a phony command definition for a task.
    ///
    /// - parameter task: The task to associate with the command.
    func addPhonyCommand(_ task: any PlannedTask, inputs: [any PlannedNode], outputs: [any PlannedNode]) throws {
        // Amend the inputs and outputs.
        let inputs = amendedInputsForTask(task, inputs)
        let outputs = amendedOutputsForTask(task, outputs)

        // Add the command definition.
        try createCommandDefinition(task, inputs: inputs, outputs: outputs) { definition in
            definition.writeJSONObject {
                $0["tool"] = "phony"
                $0["inputs"] = inputs.map { $0.identifier }
                $0["outputs"] = outputs.map { $0.identifier }
                if task.repairViaOwnershipAnalysis {
                    $0["repair-via-ownership-analysis"] = true
                }
            }
        }
    }

    /// Add a mkdir command definition for a task.
    ///
    /// - parameter task: The task to associate with the command.
    func addMkdirCommand(_ task: any PlannedTask, inputs: [any PlannedNode], outputs: [any PlannedNode], description: [String]) throws {
        // Amend the inputs and outputs.
        let inputs = amendedInputsForTask(task, inputs)
        let outputs = amendedOutputsForTask(task, outputs)

        // Add the command definition.
        try createCommandDefinition(task, outputs: outputs) { definition in
            definition.writeJSONObject {
                $0["tool"] = "mkdir"
                $0["description"] = description.joined(separator: " ")
                $0["inputs"] = inputs.map { $0.identifier }
                $0["outputs"] = outputs.map { $0.identifier }
                if task.repairViaOwnershipAnalysis {
                    $0["repair-via-ownership-analysis"] = true
                }
            }
        }
    }

    /// Add a symlink command definition for a task.
    ///
    /// - parameter task: The task to associate with the command.
    func addSymlinkCommand(_ task: any PlannedTask, contents: String, inputs: [any PlannedNode], outputs: [any PlannedNode], description: [String]) throws {
        // Amend the inputs and outputs.
        let inputs = amendedInputsForTask(task, inputs)
        let outputs = amendedOutputsForTask(task, outputs)

        // Add the command definition.
        try createCommandDefinition(task, outputs: outputs) { definition in
            definition.writeJSONObject {
                $0["tool"] = "symlink"
                $0["description"] = description.joined(separator: " ")
                $0["inputs"] = inputs.map { $0.identifier }
                $0["outputs"] = outputs.map { $0.identifier }
                $0["contents"] = contents
                if task.repairViaOwnershipAnalysis {
                    $0["repair-via-ownership-analysis"] = true
                }
            }
        }
    }

    /// Add a subprocess command definition for a task.
    ///
    /// - parameter task: The task to associate with the command.
    func addSubprocessCommand(_ task: any PlannedTask, inputs: [any PlannedNode], outputs: [any PlannedNode], description: [String], commandLine: [ByteString], environment: EnvironmentBindings? = nil, workingDirectory: Path? = nil, allowMissingInputs: Bool = false, alwaysOutOfDate: Bool = false, deps: DependencyDataStyle? = nil, isUnsafeToInterrupt: Bool, llbuildControlDisabled: Bool = false) throws {
        // Amend the inputs and outputs.
        let inputs = amendedInputsForTask(task, inputs)
        let outputs = amendedOutputsForTask(task, outputs)

        var commandLine = commandLine
        if bypassActualTasks {
            commandLine = [ByteString(encodingAsUTF8: "/usr/bin/true")] + commandLine
        }

        // Add the command definition.
        try createCommandDefinition(task, inputs: inputs, outputs: outputs) { definition in
            definition.writeJSONObject {
                $0["tool"] = "shell"
                $0["description"] = description.joined(separator: " ")
                $0["inputs"] = inputs.map { $0.identifier }
                $0["outputs"] = outputs.map { $0.identifier }
                $0["args"] = commandLine
                // FIXME: inherit-env defaults to true; we should pass false and inject the process environment explicitly, so that it is overridable for tests
                // $0["inherit-env"] = "true"
                if let environment {
                    $0["env"] = environment.bindings
                }
                if allowMissingInputs {
                    $0["allow-missing-inputs"] = true
                }
                if alwaysOutOfDate {
                    $0["always-out-of-date"] = true
                }
                if isUnsafeToInterrupt {
                    $0["can-safely-interrupt"] = false
                }
                if let workingDirectory {
                    $0["working-directory"] = workingDirectory.str
                }
                if llbuildControlDisabled {
                    // Disable the control file descriptor
                    $0["control-enabled"] = false
                }
                if let deps {
                    $0["deps"] = deps.paths.map { $0.str }
                    $0["deps-style"] = deps.name
                }
                if task.repairViaOwnershipAnalysis {
                    $0["repair-via-ownership-analysis"] = true
                }

                // We always compute the signature ourselves instead of letting llbuild use its default logic.
                // However, we currently do use roughly the same information to compute it.
                let signature = Self.computeShellToolSignature(args: task.type.commandLineForSignature(for: task.execTask) ?? commandLine, environment: environment, dependencyData: deps, isUnsafeToInterrupt: isUnsafeToInterrupt, additionalSignatureData: task.additionalSignatureData)

                $0["signature"] = signature
            }
        }
    }

    package static func computeShellToolSignature(args: [ByteString], environment: EnvironmentBindings?, dependencyData: DependencyDataStyle?, isUnsafeToInterrupt: Bool, additionalSignatureData: String) -> ByteString {
        let ctx = InsecureHashContext()
        for arg in args {
            ctx.add(bytes: arg)
        }

        if let environment {
            environment.computeSignature(into: ctx)
        }

        if let deps = dependencyData {
            for path in deps.paths {
                ctx.add(string: path.str)
            }

            ctx.add(string: deps.name)
        }

        ctx.add(string: isUnsafeToInterrupt ? "true" : "false")

        if !additionalSignatureData.isEmpty {
            ctx.add(string: additionalSignatureData)
        }

        return ctx.signature
    }

    /// Add a command for a task, using a custom tool.
    func addCustomCommand(_ task: any PlannedTask, tool: String, inputs: [any PlannedNode], outputs: [any PlannedNode], deps: DependencyDataStyle? = nil, allowMissingInputs: Bool, alwaysOutOfDate: Bool, description: [String]) throws {
        // Honor `bypassActualTasks`.
        if bypassActualTasks {
            try addSubprocessCommand(task, inputs: inputs, outputs: outputs, description: description, commandLine: ["/usr/bin/true"], allowMissingInputs: allowMissingInputs, alwaysOutOfDate: alwaysOutOfDate, isUnsafeToInterrupt: false)
            return
        }

        // Amend the inputs and outputs.
        let inputs = amendedInputsForTask(task, inputs)
        let outputs = amendedOutputsForTask(task, outputs)

        processTaskLock.withLock {
            // Record the custom tool type.
            // FIXME: This cast is unfortunate.
            let execTask = task.execTask as! Task
            assert(execTask.action != nil)
            assert(taskActionMap[tool] == nil || taskActionMap[tool]! == type(of: execTask.action!))
            taskActionMap[tool] = type(of: execTask.action!)
        }

        // Add the command definition.
        try createCommandDefinition(task, inputs: inputs, outputs: outputs) { definition in
            definition.writeJSONObject {
                $0["tool"] = tool
                $0["description"] = description.joined(separator: " ")
                $0["inputs"] = inputs.map { $0.identifier }
                $0["outputs"] = outputs.map { $0.identifier }
                if let deps, case .dependencyInfo(let path) = deps {
                    $0["deps"] = path.str
                }
                if allowMissingInputs {
                    $0["allow-missing-inputs"] = true
                }
                if alwaysOutOfDate {
                    $0["always-out-of-date"] = true
                }
                if task.repairViaOwnershipAnalysis {
                    $0["repair-via-ownership-analysis"] = true
                }
            }
        }
    }
}

// Add public support for constructing a build description without exposing the builder.
extension BuildDescription {
    /// Construct a build description from a list of tasks.
    ///
    /// Each provided task is expected to have been derived from a task planning process using the tasks in the TaskExecution module.
    //
    // FIXME: Bypass actual tasks should go away, eventually.
    //
    // FIXME: This layering isn't working well, we are plumbing a bunch of stuff through here just because we don't want to talk to TaskConstruction.
    static package func construct(workspace: Workspace, tasks: [any PlannedTask], path: Path, signature: BuildDescriptionSignature, buildCommand: BuildCommand, diagnostics: [ConfiguredTarget?: [Diagnostic]] = [:], indexingInfo: [(forTarget: ConfiguredTarget?, path: Path, indexingInfo: any SourceFileIndexingInfo)] = [], fs: any FSProxy = localFS, bypassActualTasks: Bool = false, targetsBuildInParallel: Bool = true, emitFrontendCommandLines: Bool = false, moduleSessionFilePath: Path? = nil, invalidationPaths: [Path] = [], recursiveSearchPathResults: [RecursiveSearchPathResolver.CachedResult] = [], copiedPathMap: [String: String] = [:], rootPathsPerTarget: [ConfiguredTarget:[Path]] = [:], moduleCachePathsPerTarget: [ConfiguredTarget: [Path]] = [:], staleFileRemovalIdentifierPerTarget: [ConfiguredTarget?: String] = [:], settingsPerTarget: [ConfiguredTarget: Settings] = [:], delegate: any BuildDescriptionConstructionDelegate, targetDependencies: [TargetDependencyRelationship] = [], definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>], capturedBuildInfo: CapturedBuildInfo?, userPreferences: UserPreferences) async throws -> BuildDescription? {
        var diagnostics = diagnostics

        // We operate on the sorted tasks here to ensure that the list of task additional inputs is deterministic.
        //
        // We need to sort on the stable identifiers in order to ensure the uniqueness of the sort.
        let sortedTasks = tasks.sorted{ $0.identifier < $1.identifier }

        let messageShortening = userPreferences.activityTextShorteningLevel

        // Construct the graph between nodes and tasks.
        delegate.updateProgress(statusMessage: messageShortening == .full ? "Creating build graph" : "Constructing build graph", showInLog: false)
        var producers = Dictionary<Ref<any PlannedNode>, [any PlannedTask]>()
        var outputPathsPerTarget = Dictionary<ConfiguredTarget?, [Path]>()
        for (current, task) in sortedTasks.enumerated() {
            if delegate.cancelled { return nil }
            let statusMessage = messageShortening >= .allDynamicText ? "Describing: \(activityMessageFractionString(current+1, over: sortedTasks.count))" : "Constructing build graph: \(current+1) of \(sortedTasks.count) tasks"
            delegate.updateProgress(statusMessage: statusMessage, showInLog: false)

            for output in task.outputs {
                producers[Ref(output), default: []].append(task)
            }

            // Do not consider gate tasks or the top-level build directories as one of the output paths.
            if !(task is GateTask) && task.ruleInfo.first != "CreateBuildDirectory" {
                let target = task.forTarget

                // Ignore resign tasks for stale file removal, <rdar://problem/42642132> tracks a more generic solution for this.
                if task.outputs.filter({ $0.name.hasPrefix("ReSign") }).count > 0 || task.ruleInfo.first == "ClangStatCache" {
                    continue
                }

                var outputs = outputPathsPerTarget[target] ?? [Path]()
                outputs.append(contentsOf: task.outputs.map { $0.path }.filter { !$0.str.isEmpty })
                outputPathsPerTarget[target] = outputs
            }

            // Diagnose dangling tasks which cannot be run.
            if task.outputs.isEmpty {
                diagnostics[task.forTarget, default: []].append(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("unexpected task with no outputs: '\(task.ruleInfo.quotedDescription)'")))
            }
        }

        // Gather the collection of "mustPrecede" relationships to establish.
        //
        // FIXME: We should just get llbuild to support must-follow and must-precede in terms of commands, then we could ditch all of this.
        delegate.updateProgress(statusMessage: messageShortening == .full ? "Constructing" : "Computing build graph information", showInLog: false)
        var taskAdditionalInputs: [Ref<any PlannedTask>: BuildDescriptionBuilder.NodeList] = [:]
        for task in sortedTasks {
            if delegate.cancelled { return nil }

            // If there are no relationships, continue.
            if task.mustPrecede.isEmpty {
                continue
            }

            // Otherwise, pick an output node to use as the handle to order this task.
            //
            // FIXME: This is very fragile, if we pick outputs we would rewrite as part of the mutable output handling this won't work.
            guard let lastOutput = task.outputs.last else {
                diagnostics[task.forTarget, default: []].append(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("unable to force ordering of task (no outputs): \(task)")))
                continue
            }

            // Extract the maximum number of outputs from the task outputs which are of the same type (virtual or not), as the last output.
            let taskOutputs = task.outputs.reversed().prefix(while: { (lastOutput is (PlannedVirtualNode)) == ($0 is (PlannedVirtualNode)) }).reversed()

            for antecedent in task.mustPrecede {
                let nodeList: BuildDescriptionBuilder.NodeList
                if let list = taskAdditionalInputs[Ref(antecedent.instance)] {
                    nodeList = list
                } else {
                    nodeList = BuildDescriptionBuilder.NodeList()
                    taskAdditionalInputs[Ref(antecedent.instance)] = nodeList
                }
                nodeList.nodes.append(contentsOf: taskOutputs)
            }
        }

        // Compute information on the mutating tasks, to use in rewrite the graph as part of description construction.
        //
        // This is part of our current primitive strategy which involves rewriting commands which mutate inputs to be downstream triggers of the producer (or other mutators).

        // First, identify all mutated nodes and the tasks which mutate them.
        final class MutableNodeInfo {
            /// The initial creator of the node.
            var creator: (any PlannedTask)? = nil

            /// The list of all tasks which mutate this node.
            var mutatingTasks = [any PlannedTask]()
        }
        var mutableNodes = Dictionary<Ref<any PlannedNode>, MutableNodeInfo>()
        // `nodesToCreateOnlyIfMissing` are output nodes whose producer tasks should be run only if they do not exist. This uses the peculiar behavior of llbuild's 'is-mutating' property which does exactly this. These nodes are not actually mutated but are treated in this way because we don't want these tasks to run if their outputs already exist.
        var nodesToCreateOnlyIfMissing = Array<Ref<any PlannedNode>>()
        // `additionalNodes` are additional node entries that should be serialized out to the build description. One such use of this are for `context-exclusion-patterns` node entries.
        var additionalNodes = Array<Ref<any PlannedNode>>()
        for task in sortedTasks {
            if delegate.cancelled { return nil }

            // FIXME: Make this more efficient.
            let mutatedNodes = Set<Ref<any PlannedNode>>(task.inputs.map{ Ref($0) }).intersection(Set<Ref<any PlannedNode>>(task.outputs.map{ Ref($0) }))
            for node in mutatedNodes {
                let info = mutableNodes.getOrInsert(node) { MutableNodeInfo() }
                info.mutatingTasks.append(task)
            }

            // Any directory paths with exclusion filters need to be added to the nodes list.
            for filteredDirectory in task.inputs.filter({ ($0 as? (PlannedDirectoryTreeNode))?.exclusionPatterns.isEmpty == false }) {
                additionalNodes.append(Ref(filteredDirectory))
            }

            if task.ruleInfo.first == "CreateBuildDirectory" {
                for node in task.outputs.filter({ $0 is (PlannedPathNode) }) {
                    nodesToCreateOnlyIfMissing.append(Ref(node))
                }
            }
        }

        // Find the creators of all of the mutable nodes.
        for (node, info) in mutableNodes {
            var creators = [any PlannedTask]()
            for task in producers[node]! {
                if delegate.cancelled { return nil }

                // Ignore the actual mutating tasks.
                //
                // This is O(N), but we expect the # of mutators of a node to always be bounded to a small constant.
                if info.mutatingTasks.contains(where: { $0 === task }) {
                    continue
                }

                creators.append(task)

                if let _ = info.creator {
                    continue
                }

                info.creator = task
            }

            if creators.count > 1 {
                let childDiagnostics = creators.map({ .task($0.execTask) }).richFormattedRuleInfo(workspace: workspace)

                diagnostics[nil, default: []].append(
                    Diagnostic(behavior: .error,
                               location: .unknown,
                               data: DiagnosticData("Multiple commands produce '\(node.instance.path.str)'"),
                               childDiagnostics: childDiagnostics))
            }
        }

        // Construct the information used to edit the description, indexed by the task.
        typealias MutatingTaskInfo = BuildDescriptionBuilder.MutatingTaskInfo
        var mutatingTasks = Dictionary<Ref<any PlannedTask>, MutatingTaskInfo>()
        for (nodeRef, info) in mutableNodes {
            if delegate.cancelled { return nil }

            let node = nodeRef.instance

            guard let creator = info.creator else {
                diagnostics[info.mutatingTasks.first?.forTarget, default: []].append(Diagnostic(behavior: .warning, location: .unknown, data: DiagnosticData("missing creator for mutated node: ('\(node.path.str)')")))
                continue
            }

            // Topologically order the commands, relative to the build graph while *ignoring* the mutated node.
            //
            // This works because we enforce that every mutating command *must* be strongly ordered w.r.t. the creator and the other mutators, so that we know the order they should run in.
            func distance(from origin: any PlannedTask, to predecessor: any PlannedTask) -> Int? {
                let ignoring = node
                return minimumDistance(from: Ref(origin), to: Ref(predecessor), successors: { taskRef in
                        let task = taskRef.instance
                        var inputNodes = task.inputs
                        if let extraInputs = taskAdditionalInputs[Ref(task)] {
                            inputNodes += extraInputs.nodes
                        }
                    let inputs = inputNodes.flatMap { input -> [Ref<any PlannedTask>] in
                            if input === ignoring { return [] }

                            return producers[Ref(input)]?.map{ Ref($0) } ?? []
                        }
                        return inputs
                    })
            }
            let orderedMutatingTasks = info.mutatingTasks.sorted(by: {
                    // A task precedes another iff there is exists some path to it.
                    return distance(from: $1, to: $0) != nil
                })

            // Starting with the creator, create a command trigger for the next command in the mutating task chain.
            var producer = creator
            for consumer in orderedMutatingTasks {
                // Validate that this node is strongly ordered w.r.t. to the previous one (our sort only ensure that we see them in the right order if ordered).
                //
                // This validation is very expensive, and when there is only a creator and a single producer it is unnecessary (there is no concern about the order of mutators). Thus, we only do it when we have a longer mutation chain.
                if orderedMutatingTasks.count > 1 && distance(from: consumer, to: producer) == nil {
                    diagnostics[info.mutatingTasks.first?.forTarget, default: []].append(Diagnostic(behavior: .warning, location: .unknown, data: DiagnosticData("unexpected mutating task ('\(consumer.ruleInfo.quotedDescription)') with no relation to prior mutator ('\(producer.ruleInfo.quotedDescription)')")))
                }

                // Create (or reuse) the trigger for the producing task.
                let producerInfo = mutatingTasks.getOrInsert(Ref(producer), { MutatingTaskInfo() })
                let triggerNode = producerInfo.triggerNode ?? MakePlannedVirtualNode("<TRIGGER: \(producer.ruleInfo.quotedDescription)>")
                producerInfo.triggerNode = triggerNode

                // Create the command dependency on the consumer
                let consumerInfo = mutatingTasks.getOrInsert(Ref(consumer), { MutatingTaskInfo() })
                consumerInfo.commandDependencies.append(triggerNode)

                // Update the current producer.
                producer = consumer
            }
        }

        if SWBFeatureFlag.performOwnershipAnalysis.value == false {
            struct DirectoryOutputs {
                private var paths = [Path: [any PlannedTask]]()
                private(set) var diagnostics: [ConfiguredTarget?: [Diagnostic]] = [:]

                mutating func checkPathAndAncestors(path inputPath: Path, isDirectory: Bool, task inputTask: any PlannedTask) {
                    func pathString(_ path: Path, isDirectory: Bool) -> String {
                        [path.withoutTrailingSlash().str, isDirectory ? "/" : ""].joined()
                    }

                    // Check if the input is a directory or not; we want to begin checking from the containing directory if it's a file, but use the original input (file) path in the diagnostic below, if there's a conflict.
                    var path = !isDirectory ? inputPath.dirname : inputPath
                    while !path.isEmpty && !path.isRoot {
                        if let tasks = paths[path] {
                            diagnostics[nil, default: []].append(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Multiple commands produce conflicting outputs"), childDiagnostics: ([(pathString(inputPath, isDirectory: isDirectory), inputTask)] + tasks.map { task in (pathString(path, isDirectory: true), task) }).map { (path, task) in
                                Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("\(path) (for task: \(task.ruleInfo))"))
                            }))
                        }
                        path = path.dirname
                    }
                }

                mutating func add(path: Path, task: any PlannedTask) {
                    paths[path, default: []].append(task)
                }
            }

            var ownedDirectories = DirectoryOutputs()

            // Create a list of tuples of all output nodes in the graph, and their creator tasks, sorted by depth (which is the same as lexicographic order in this case). The list may contain multiple entries for the same output path, if multiple tasks in the graph (erroneously) produce the same output. Assumes paths are normalized.
            let outputNodesAndTasks = sortedTasks
                .flatMap { task in task is GateTask ? [] : task.outputs.map { output in (output, task) } }
                .sorted(by: { $0.0.path < $1.0.path })

            // Add all the directory tree output nodes to an "owned" directories list, checking each output path and its ancestors for containment in the list. The fact that we add iterate in depth order allows us to efficiently check each path for conflicting ancestors.
            for (node, task) in outputNodesAndTasks {
                switch node {
                case is PlannedDirectoryTreeNode:
                    ownedDirectories.checkPathAndAncestors(path: node.path, isDirectory: true, task: task)
                    ownedDirectories.add(path: node.path, task: task)
                case is PlannedPathNode:
                    ownedDirectories.checkPathAndAncestors(path: node.path, isDirectory: false, task: task)
                default:
                    break
                }
            }

            diagnostics.merge(ownedDirectories.diagnostics, uniquingKeysWith: +)
        }

        // Create the builder.
        let builder = BuildDescriptionBuilder(path: path, signature: signature, buildCommand: buildCommand, taskAdditionalInputs: taskAdditionalInputs, mutatedNodes: Set(mutableNodes.keys), mutatingTasks: mutatingTasks, bypassActualTasks: bypassActualTasks, targetsBuildInParallel: targetsBuildInParallel, emitFrontendCommandLines: emitFrontendCommandLines, moduleSessionFilePath: moduleSessionFilePath, invalidationPaths: invalidationPaths, recursiveSearchPathResults: recursiveSearchPathResults, copiedPathMap: copiedPathMap, outputPathsPerTarget: outputPathsPerTarget, allOutputPaths: Set(producers.keys.map { $0.instance.path }), rootPathsPerTarget: rootPathsPerTarget, moduleCachePathsPerTarget: moduleCachePathsPerTarget, staleFileRemovalIdentifierPerTarget: staleFileRemovalIdentifierPerTarget, settingsPerTarget: settingsPerTarget, targetDependencies: targetDependencies, definingTargetsByModuleName: definingTargetsByModuleName, workspace: workspace, capturedBuildInfo: capturedBuildInfo)
        for (target, diagnostics) in diagnostics {
            let engine = builder.diagnosticsEngines.getOrInsert(target, { DiagnosticsEngine() })
            for diag in diagnostics {
                engine.emit(diag)
            }
        }

        // Define a basic target.
        builder.targetDefinitions[""] = (OutputByteStream() <<< Format.asJSON(["<all>"])).bytes

        func writeContentExclusionPatternIfNecessary(nodeRef: Ref<any PlannedNode>, stream: JSONOutputStreamer) {
            let dirNode = nodeRef.instance as? (PlannedDirectoryTreeNode)
            if dirNode?.exclusionPatterns.isEmpty == false {
                stream["content-exclusion-patterns"] = dirNode?.exclusionPatterns ?? []
            }
        }

        // Process the mutable nodes.
        for nodeRef in mutableNodes.keys + nodesToCreateOnlyIfMissing {
            if delegate.cancelled { return nil }

            builder.createNodeDefinition(nodeRef.instance) { definition in
                definition.writeJSONObject {
                    writeContentExclusionPatternIfNecessary(nodeRef: nodeRef, stream: $0)
                    $0["is-mutated"] = true
                }
            }
        }

        // Process the additional nodes.
        for nodeRef in additionalNodes {
            if delegate.cancelled { return nil }

            builder.createNodeDefinition(nodeRef.instance) { definition in
                definition.writeJSONObject {
                    writeContentExclusionPatternIfNecessary(nodeRef: nodeRef, stream: $0)
                }
            }
        }

        // Process tasks.
        // The order of the status messages will not be in the order of tasks executed as the following implementation uses multiple threads concurrently to process tasks
        if !sortedTasks.isEmpty {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    let (progressStream, progressContinuation) = AsyncStream<Void>.makeStream()
                    group.addTask {
                        var preplannedCount = 0
                        for await _ in progressStream {
                            preplannedCount += 1
                            let statusMessage = messageShortening >= .allDynamicText ? "Constructing \(activityMessageFractionString(preplannedCount, over: sortedTasks.count))" : "Constructing \(preplannedCount) of \(sortedTasks.count) tasks"
                            delegate.updateProgress(statusMessage: statusMessage, showInLog: false)
                            if preplannedCount >= sortedTasks.count {
                                progressContinuation.finish()
                            }
                        }
                    }

                    // the above task of emitting the status messages overlaps with the parallel processing of Gate/Constructed tasks
                    try await sortedTasks.enumerated().parallelForEach(group: &group, maximumParallelism: 100) { _, task in
                        try _Concurrency.Task.checkCancellation()
                        progressContinuation.yield(())
                        switch task {
                        case let task as GateTask:
                            try task.addToDescription(builder)
                        case let task as ConstructedTask:
                            try task.addToDescription(builder)
                        default:
                            fatalError("unknown concrete task type")
                        }
                    }

                    try await group.waitForAll()
                }
            } catch is CancellationError  {
                return nil
            }
        }

        // Diagnose attempts to define multiple producers (tasks) for an output.
        var outputsSet = Set<Ref<any PlannedNode>>() // for identifying duplicate output nodes across tasks
        for (_, task) in sortedTasks.enumerated() {
            let amendedOutputs = builder.taskOutputMap[Ref(task)] ?? [] // get the amended outputs of the task
            for output in amendedOutputs {
                if outputsSet.contains(Ref(output)) {
                    // This condition should almost never appear on a user projects, but we surface   it as an error versus an assert in case there are valid situations where the user can author a project    that would hit it.
                    builder.addWarning(forTarget: task.forTarget, "duplicate output file '\(output.path.str)' on task: \(task.ruleInfo.joined(separator: " "))")
                }
                outputsSet.insert(Ref(output))
            }
        }

        delegate.updateProgress(statusMessage: "Writing build description", showInLog: false)
        return try builder.construct(fs: fs, delegate: delegate)
    }
}

package final class TaskActionRegistry: Sendable {
    private let implementations: [SerializableTypeCode: any PolymorphicSerializable.Type]

    @PluginExtensionSystemActor @_spi(Testing) public init(pluginManager: PluginManager) throws {
        implementations = try TaskActionExtensionPoint.taskActionImplementations(pluginManager: pluginManager)
    }

    func withSerializationContext<T>(_ block: () throws -> T) rethrows -> T {
        try TaskAction.$taskActionImplementations.withValue(implementations) {
            try block()
        }
    }
}

/// A delegate which must be used to serialize a `BuildDescription`.
package final class BuildDescriptionSerializerDelegate: SerializerDelegate, ConfiguredTargetSerializerDelegate, UniquingSerializerDelegate {
    /// Indexes into the `BuildDescription`'s `Task` array to serialize references to those `Task`s efficiently.
    fileprivate(set) var taskIndexes = [Task: Int]()

    package var currentBuildParametersIndex: Int = 0
    package var buildParametersIndexes = [BuildParameters: Int]()

    package var currentConfiguredTargetIndex: Int = 0
    package var configuredTargetIndexes = [ConfiguredTarget: Int]()

    package let uniquingCoordinator = UniquingSerializationCoordinator()

    let taskActionRegistry: TaskActionRegistry

    package init(taskActionRegistry: TaskActionRegistry) {
        self.taskActionRegistry = taskActionRegistry
    }
}

/// A delegate which must be used to deserialize a `BuildDescription`.
package final class BuildDescriptionDeserializerDelegate: DeserializerDelegate, MacroValueAssignmentTableDeserializerDelegate, ConfiguredTargetDeserializerDelegate, TaskDeserializerDelegate, UniquingDeserializerDelegate {
    /// The `MacroNamespace` to use to deserialize `MacroEvaluationTable`s and their content.
    ///
    /// This will return the `userNamespace` of the `Workspace` the receiver was created with.
    package var namespace: MacroNamespace { return self.workspace.userNamespace }

    /// The `PlatformRegistry` to use to look up platforms.
    package let platformRegistry: PlatformRegistry

    /// The `SDKRegistry` to use to look up SDKs.
    package let sdkRegistry: SDKRegistry

    /// The workspace in which to look up `Target`s being deserialized.
    package let workspace: Workspace

    /// A list of `BuildParameters` built up during deserialization so that after one has been deserialized, later references can be looked up by index based on the order they were deserialized.
    package var buildParameters = [BuildParameters]()

    /// A list of `ConfigureTarget`s built up during deserialization so that after one has been deserialized, later references can be looked up by index based on the order they were deserialized.
    package var configuredTargets = [ConfiguredTarget]()

    /// The specification registry to use to look up `CommandLineToolSpec`s for deserializing Task.type properties.
    package let specRegistry: SpecRegistry

    package let uniquingCoordinator = UniquingDeserializationCoordinator()

    package var taskStore: FrozenTaskStore? = nil

    let taskActionRegistry: TaskActionRegistry

    package init(workspace: Workspace, platformRegistry: PlatformRegistry, sdkRegistry: SDKRegistry, specRegistry: SpecRegistry, taskActionRegistry: TaskActionRegistry) {
        self.workspace = workspace
        self.platformRegistry = platformRegistry
        self.sdkRegistry = sdkRegistry
        self.specRegistry = specRegistry
        self.taskActionRegistry = taskActionRegistry
    }
}

package enum BuildDescriptionSerializationFormat: String {
    case YAML
    case JSON
}

package extension PlannedNode {
    var identifier: String {
        switch self {
        case let virtualNode as PlannedVirtualNode:
            // By convention, virtual nodes are written as '<NAME>'.
            let name = virtualNode.name
            if name.hasPrefix("<") && name.hasSuffix(">") {
                return name
            } else {
                return "<" + name + ">"
            }

        case let pathNode as PlannedPathNode:
            // By convention, individual paths are literal strings (without a '/' suffix).
            let pathStr = pathNode.path.strWithPosixSlashes
            assert(!pathStr.hasSuffix("/"))
            return pathStr

        case let dirNode as PlannedDirectoryTreeNode:
            // By convention, directory tree nodes are paths ending in a '/'.
            let pathStr = dirNode.path.strWithPosixSlashes
            assert(!pathStr.hasSuffix("/"))
            return pathStr + "/"

        default:
            fatalError("unknown node: \(self)")
        }
    }
}
