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

import Foundation
package import SWBCore
package import SWBUtil

/// Data structure that collects and records file and module dependencies for translation units.
package final class ClangModuleDependencyGraph {

    let core: Core
    let definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>]

    package init(core: Core, definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>]) {
        self.core = core
        self.definingTargetsByModuleName = definingTargetsByModuleName
    }

    /// Represents the file and module dependencies for a single translation unit or module.
    package struct DependencyInfo: Serializable, Hashable, Sendable {
        package enum Kind: Serializable, Hashable, Sendable {
            /// Dependency info for a command used to compile a source file.
            case command
            /// Dependency info for an explicitly-built module.
            case module(pcmOutputPath: Path)

            package func serialize<T>(to serializer: T) where T : SWBUtil.Serializer {
                serializer.serializeAggregate(2) {
                    switch self {
                    case .command:
                        serializer.serialize(0)
                        serializer.serializeNil()
                    case .module(pcmOutputPath: let path):
                        serializer.serialize(1)
                        serializer.serialize(path)
                    }
                }
            }

            package init(from deserializer: any SWBUtil.Deserializer) throws {
                try deserializer.beginAggregate(2)
                switch try deserializer.deserialize() as Int {
                case 0:
                    self = .command
                    try deserializer.deserializeNilThrow()
                case 1:
                    self = .module(pcmOutputPath: try deserializer.deserialize())
                default:
                    throw StubError.error("Unexpected explicit modules dependency info kind kind.")
                }
            }
        }

        /// The kind of dependency info.
        package let kind: Kind

        /// The working directory used when building the module or TU.
        package let workingDirectory: Path

        /// The list of file (paths) dependencies that are required by the translation unit or module.
        package let files: OrderedSet<Path>

        /// The CASID of the include-tree required by this translation unit or module, if any.
        package let includeTreeID: String?

        /// The list of module dependencies that are required by the translation unit or module, as PCM paths.
        package let modules: OrderedSet<Path>

        package struct CompileCommand: Serializable, Hashable, Sendable {
            /// The cache key for the translation unit or module, when compilation caching is enabled.
            package let cacheKey: String?
            package let arguments: [String]

            fileprivate init(
                cacheKey: String?,
                arguments: [String]
            ) {
                self.cacheKey = cacheKey
                self.arguments = arguments
            }

            package func serialize<T>(to serializer: T) where T : Serializer {
                serializer.serializeAggregate(2) {
                    serializer.serialize(cacheKey)
                    serializer.serialize(arguments)
                }
            }

            package init(from deserializer: any Deserializer) throws {
                try deserializer.beginAggregate(2)
                self.cacheKey = try deserializer.deserialize()
                self.arguments = try deserializer.deserialize()
            }
        }

        /// The list of command line arguments that use explicit modules for compiling the translation unit.
        /// For example, for a source file, it contains the original command line plus the arguments that configure the
        /// compilation with explicit modules. For module dependencies, it contains the command line arguments to build
        /// the pcm file. There may be multiple command lines if a single clang driver invocation expands to multiple jobs
        /// for example, when using `-save-temps`.
        package let commands: [CompileCommand]

        package let transitiveIncludeTreeIDs: OrderedSet<String>
        package let transitiveCompileCommandCacheKeys: OrderedSet<String>

        /// Whether the build of this dependency uses serialized diagnostics.
        package let usesSerializedDiagnostics: Bool

        fileprivate init(
            fileDependencies: OrderedSet<Path>,
            includeTreeID: String?,
            moduleDependencies: OrderedSet<Path>,
            workingDirectory: Path,
            commands: [CompileCommand],
            transitiveIncludeTreeIDs: OrderedSet<String>,
            transitiveCompileCommandCacheKeys: OrderedSet<String>,
            usesSerializedDiagnostics: Bool
        ) {
            self.kind = .command
            self.files = fileDependencies
            self.includeTreeID = includeTreeID
            self.modules = moduleDependencies
            self.workingDirectory = workingDirectory
            self.commands = commands
            self.transitiveIncludeTreeIDs = transitiveIncludeTreeIDs
            self.transitiveCompileCommandCacheKeys = transitiveCompileCommandCacheKeys
            self.usesSerializedDiagnostics = usesSerializedDiagnostics
        }

        fileprivate init(
            pcmOutputPath: Path,
            fileDependencies: OrderedSet<Path>,
            includeTreeID: String?,
            moduleDependencies: OrderedSet<Path>,
            workingDirectory: Path,
            command: CompileCommand,
            transitiveIncludeTreeIDs: OrderedSet<String>,
            transitiveCompileCommandCacheKeys: OrderedSet<String>,
            usesSerializedDiagnostics: Bool
        ) {
            self.kind = .module(pcmOutputPath: pcmOutputPath)
            self.files = fileDependencies
            self.includeTreeID = includeTreeID
            self.modules = moduleDependencies
            self.workingDirectory = workingDirectory
            self.commands = [command]
            self.transitiveIncludeTreeIDs = transitiveIncludeTreeIDs
            self.transitiveCompileCommandCacheKeys = transitiveCompileCommandCacheKeys
            self.usesSerializedDiagnostics = usesSerializedDiagnostics
        }

        package func serialize<T>(to serializer: T) where T : Serializer {
            serializer.serializeAggregate(9) {
                serializer.serialize(kind)
                serializer.serialize(files)
                serializer.serialize(includeTreeID)
                serializer.serialize(modules)
                serializer.serialize(workingDirectory)
                serializer.serialize(commands)
                serializer.serialize(transitiveIncludeTreeIDs)
                serializer.serialize(transitiveCompileCommandCacheKeys)
                serializer.serialize(usesSerializedDiagnostics)
            }
        }

        package init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(9)
            self.kind = try deserializer.deserialize()
            self.files = try deserializer.deserialize()
            self.includeTreeID = try deserializer.deserialize()
            self.modules = try deserializer.deserialize()
            self.workingDirectory = try deserializer.deserialize()
            self.commands = try deserializer.deserialize()
            self.transitiveIncludeTreeIDs = try deserializer.deserialize()
            self.transitiveCompileCommandCacheKeys = try deserializer.deserialize()
            self.usesSerializedDiagnostics = try deserializer.deserialize()
        }
    }

    // Entries in the registry represent scan outputs which have been written to disk during this build. It uses two level locking so that even if two scans of different source files discover the same module dependency, the scan of that dependency is only written once.
    private let recordedDependencyInfoRegistry = Registry<Path, Lazy<Void>>()

    private struct LibclangRegistryKey: Hashable {
        var libclangPath: String
        var casOptions: CASOptions?
    }

    private let registryQueue = SWBQueue(label: "ClangModuleDependencyGraph", attributes: .concurrent, autoreleaseFrequency: .workItem)
    private var scannerRegistry: [LibclangRegistryKey: LibclangWithScanner] = [:]

    package func waitForCompletion() async {
        await registryQueue.sync(flags: .barrier) { }
    }

    private struct LibclangWithScanner {
        let libclang: Libclang
        let scanner: DependencyScanner
        let casDBs: ClangCASDatabases?

        init(libclang: Libclang, casDBs: ClangCASDatabases?, casOptsForInvocations: ClangCASOptions?) throws {
            self.libclang = libclang
            self.scanner = try libclang.createScanner(casDBs: casDBs, casOpts: casOptsForInvocations)
            self.casDBs = casDBs
        }
    }

    private func libclangWithScanner(forPath path: Path, casOptions: CASOptions?, cacheFallbackIfNotAvailable: Bool, core: Core) throws -> LibclangWithScanner {
        let key = LibclangRegistryKey(libclangPath: path.str, casOptions: casOptions)
        if let libclangWithScanner = registryQueue.blocking_sync(execute: { scannerRegistry[key] }) {
            return libclangWithScanner
        }

        return try registryQueue.blocking_sync(flags: .barrier) {
            // Check if another task already loaded a new Libclang, and if so, use that instead.
            // If not, load it from scratch. This happens within the barrier block so that only a single
            // task loads the specified libclang.dylib, since multiple concurrent loading can lead to a race
            // condition that results in a crash when configuring Libclang.
            return try self.scannerRegistry.getOrInsert(key) {
                guard let newLibclang = core.lookupLibclang(path: path).libclang else {
                    throw StubError.error("could not load \(path.str)")
                }
                var casOptions = casOptions
                for _ in 0..<2 {
                    do {
                        let casSettings = try casOptions.map { casOptions -> (ClangCASDatabases, ClangCASOptions?) in
                            func createCASOptions(ignoreRemote: Bool) throws -> ClangCASOptions {
                                let casOpts = try ClangCASOptions(newLibclang).setOnDiskPath(casOptions.casPath.str)
                                if let pluginPath = casOptions.pluginPath {
                                    casOpts.setPluginPath(pluginPath.str)
                                }
                                if let remotePath = casOptions.remoteServicePath, !ignoreRemote {
                                    casOpts.setPluginOption(name: "remote-service-path", value: remotePath.str)
                                }
                                return casOpts
                            }

                            let casOpts = try createCASOptions(ignoreRemote: false)
                            let casOptsForInvocations: ClangCASOptions?
                            if casOptions.enableIntegratedCacheQueries && casOptions.hasRemoteCache {
                                casOptsForInvocations = try createCASOptions(ignoreRemote: true)
                            } else {
                                casOptsForInvocations = nil
                            }
                            return try (ClangCASDatabases(options: casOpts), casOptsForInvocations)
                        }
                        return try LibclangWithScanner(libclang: newLibclang, casDBs: casSettings?.0, casOptsForInvocations: casSettings?.1)
                    } catch DependencyScanner.Error.featureUnsupported {
                        throw StubError.error("libclang at '\(path)' does not have up-to-date dependency scanner")
                    } catch ClangCASDatabases.Error.featureUnsupported {
                        if cacheFallbackIfNotAvailable {
                            casOptions = nil
                            continue
                        } else {
                            throw StubError.error("libclang at '\(path)' does not have up-to-date caching support")
                        }
                    } catch {
                        throw StubError.error("could not load \(path.str): \(error)")
                    }
                }
                fatalError("libclang lookup should retry at most once")
            }
        }
    }

    private func register(path: Path, dependencyInfo: DependencyInfo, fileSystem fs: any FSProxy) throws {
        let serializer = MsgPackSerializer()
        serializer.serialize(dependencyInfo)
        // Because which scan task will be the first to discover a given module and write its scan to disk is unknown, we don't
        // track these paths as outputs in the build system. As a result, we must create the parent directory here if needed.
        try fs.createDirectory(path.dirname, recursive: true)
        try fs.write(path, contents: serializer.byteString, atomically: true)
    }

    package struct ScanResult: Sendable {
        package let dependencyPaths: Set<Path>
        package let requiredTargetDependencies: Set<RequiredDependency>

        package struct RequiredDependency: Hashable, Sendable {
            package let target: ConfiguredTarget
            package let moduleName: String
        }
    }

    /// Scans the file and module dependencies using the given libclang.dylib
    /// FIXME <rdar://60711683>: Re-add the environment argument and pass it through.
    package func scanModuleDependencies(
        libclangPath: Path,
        scanningOutputPath: Path,
        usesCompilerLauncher: Bool,
        usesSerializedDiagnostics: Bool,
        fileCommandLine: [String],
        workingDirectory: Path,
        casOptions: CASOptions?,
        cacheFallbackIfNotAvailable: Bool,
        verifyingModule: String?,
        outputPath: String,
        reportRequiredTargetDependencies: BooleanWarningLevel,
        fileSystem: any FSProxy
    ) throws -> ScanResult {
        let clangWithScanner = try libclangWithScanner(forPath: libclangPath, casOptions: casOptions, cacheFallbackIfNotAvailable: cacheFallbackIfNotAvailable, core: core)

        let (compilerLauncher, compiler, originalFileArgs) = usesCompilerLauncher
            ? (fileCommandLine[0], fileCommandLine[1], fileCommandLine[2...])
            : (nil, fileCommandLine[0], fileCommandLine[1...])

        let moduleNameWithContext = { (name: String, contextHash: String) in
            var nameWithContext = "\(name):\(contextHash)"
            // Module verification cannot share outputs with other compilations for the module under test, because we will customize its diagnostic processing.
            if let verifyingModule, name == verifyingModule || name == verifyingModule + "_Private" || name == "Test" {
                nameWithContext += ":verify"
            }
            return nameWithContext
        }

        // Maps module identifiers ("name:context_hash") to the output paths.
        var moduleOutputPaths: [String: Path] = [:]
        let outputPathForModule = { (name: String, contextHash: String) in
            let nameWithContext = moduleNameWithContext(name, contextHash)
            return moduleOutputPaths.getOrInsert(nameWithContext) {
                Path(outputPath + "/" + nameWithContext.replacingOccurrences(of: ":", with: "-") + ".pcm")
            }
        }

        var moduleTransitiveIncludeTreeIDs: [String: OrderedSet<String>] = [:]
        var moduleTransitiveCacheKeys: [String: OrderedSet<String>] = [:]

        let fileDeps: DependencyScanner.FileDependencies
        let modulesCallbackErrors = LockedValue<[any Error]>([])
        let dependencyPaths = LockedValue<Set<Path>>([])
        let requiredTargetDependencies = LockedValue<Set<ScanResult.RequiredDependency>>([])
        do {
            fileDeps = try clangWithScanner.scanner.scanDependencies(
                commandLine: [compiler] + originalFileArgs,
                workingDirectory: workingDirectory.str,
                lookupOutput: { name, contextHash, kind in
                    let moduleOutputPath = outputPathForModule(name, contextHash)
                    switch kind {
                    case .moduleFile:
                        return moduleOutputPath.str
                    case .dependencyTarget:
                        // llbuild ignores the target portion of make-style dependencies, so use a constant string so we don't need to escape special characters
                        return "moduledependenciestarget"
                    case .dependencyFile:
                        return moduleOutputPath.withoutSuffix + ".d"
                    case .serializedDiagnosticFile:
                        return moduleOutputPath.withoutSuffix + ".dia"
                    }
                },
                modulesCallback: { depModules, topologicallySorted in
                    func getTopologicalOrder(_ depModules: [DependencyScanner.ModuleDependency], _ alreadyTopologicallySorted: Bool) -> [DependencyScanner.ModuleDependency] {
                        if alreadyTopologicallySorted {
                            return depModules
                        }

                        let nameToIdx: [String: Int] = depModules.map{ $0.name + ":" + $0.context_hash }.enumerated().reduce(into: [:]) { (dict, indexAndKey) in
                            let (index, key) = indexAndKey
                            dict[key] = index
                        }
                        var seen: Set<String> = []
                        var depModulesTopological: [DependencyScanner.ModuleDependency] = []
                        func appendTopological(_ module: DependencyScanner.ModuleDependency) {
                            guard seen.insert(module.name + ":" + module.context_hash).inserted else {
                                return
                            }

                            for dep in module.module_deps {
                                appendTopological(depModules[nameToIdx[dep]!])
                            }

                            depModulesTopological.append(module)
                        }
                        for module in depModules {
                            appendTopological(module)
                        }
                        return depModulesTopological
                    }

                    // Register modular dependencies, using the output path as part of the key.
                    for module in getTopologicalOrder(depModules, topologicallySorted) {
                        let pcmPath = outputPathForModule(module.name, module.context_hash)
                        let scanResultsPath = Path(pcmPath.withoutSuffix + ".scan")
                        let moduleDeps = module.module_deps.map { depString in
                            let (name, contextHash) = depString.split(":")
                            return outputPathForModule(name, contextHash)
                        }

                        var transitiveIncludeTreeIDs: OrderedSet<String> = []
                        var transitiveCommandCacheKeys: OrderedSet<String> = []

                        if let selfIncludeTreeID = module.include_tree_id {
                            transitiveIncludeTreeIDs.append(selfIncludeTreeID)
                        }
                        if let selfCacheKey = module.cache_key {
                            transitiveCommandCacheKeys.append(selfCacheKey)
                        }

                        for moduleDep in module.module_deps {
                            transitiveIncludeTreeIDs.append(contentsOf: moduleTransitiveIncludeTreeIDs[moduleDep]!)
                            transitiveCommandCacheKeys.append(contentsOf: moduleTransitiveCacheKeys[moduleDep]!)
                        }

                        moduleTransitiveIncludeTreeIDs[module.name + ":" + module.context_hash] = transitiveIncludeTreeIDs
                        moduleTransitiveCacheKeys[module.name + ":" + module.context_hash] = transitiveCommandCacheKeys

                        do {
                            let fileDependencies = OrderedSet(module.file_deps.map(Path.init))
                            dependencyPaths.withLock {
                                $0.formUnion(fileDependencies)
                            }
                            try recordedDependencyInfoRegistry.getOrInsert(scanResultsPath, isValid: { _ in true }) {
                                var commandLine: [String] = []
                                if let compilerLauncher {
                                    commandLine += [compilerLauncher]
                                }
                                commandLine += [compiler]
                                commandLine += module.build_arguments

                                let dependencyInfo = DependencyInfo(
                                    pcmOutputPath: pcmPath,
                                    fileDependencies: fileDependencies,
                                    includeTreeID: module.include_tree_id,
                                    moduleDependencies: OrderedSet(moduleDeps),
                                    // Cached builds do not rely on the process working directory, and different scanner working directories should not inhibit task deduplication. The same is true if the scanner reports the working directory can be ignored.
                                    workingDirectory: module.cache_key != nil || module.is_cwd_ignored ? Path.root : workingDirectory,
                                    command: DependencyInfo.CompileCommand(cacheKey: module.cache_key, arguments: commandLine),
                                    transitiveIncludeTreeIDs: transitiveIncludeTreeIDs,
                                    transitiveCompileCommandCacheKeys: transitiveCommandCacheKeys,
                                    usesSerializedDiagnostics: usesSerializedDiagnostics)
                                if reportRequiredTargetDependencies != .no, let targetDependencies = definingTargetsByModuleName[module.name] {
                                    requiredTargetDependencies.withLock {
                                        for targetDependency in targetDependencies {
                                            $0.insert(.init(target: targetDependency, moduleName: module.name))
                                        }
                                    }
                                }

                                try register(path: scanResultsPath, dependencyInfo: dependencyInfo, fileSystem: fileSystem)
                                return ()
                            }
                        } catch {
                            modulesCallbackErrors.withLock {
                                $0.append(error)
                            }
                        }
                    }
                }
            )
        }

        try modulesCallbackErrors.withLock { errors in
            if !errors.isEmpty {
                throw StubError.error("error(s) when scanning dependencies:\n" + errors.map({ $0.localizedDescription }).joined(separator: "\n"))
            }
        }

        var commands: [DependencyInfo.CompileCommand] = []
        for command in fileDeps.commands {
            var fileArgs: [String] = []
            if let compilerLauncher {
                fileArgs.append(compilerLauncher)
            }

            if let exec = command.executable {
                fileArgs.append(exec)
            } else {
                // In the v3 API the executable is implicitly the compiler.
                fileArgs.append(compiler)
            }

            fileArgs += command.build_arguments

            commands.append(DependencyInfo.CompileCommand(cacheKey: command.cache_key, arguments: fileArgs))
        }

        let moduleDeps = fileDeps.commands.flatMap(\.module_deps).map { depString in
            let (name, contextHash) = depString.split(":")
            return outputPathForModule(name, contextHash)
        }

        var transitiveIncludeTreeIDs: OrderedSet<String> = []
        var transitiveCommandCacheKeys: OrderedSet<String> = []

        if let selfIncludeTreeID = fileDeps.includeTreeID {
            transitiveIncludeTreeIDs.append(selfIncludeTreeID)
        }
        for command in commands {
            if let commandCacheKey = command.cacheKey {
                transitiveCommandCacheKeys.append(commandCacheKey)
            }
        }

        for moduleDep in fileDeps.commands.flatMap(\.module_deps) {
            let depIncludeTreeIDs = moduleTransitiveIncludeTreeIDs[moduleDep]
            transitiveIncludeTreeIDs.append(contentsOf: depIncludeTreeIDs!)

            let depCacheKeys = moduleTransitiveCacheKeys[moduleDep]
            transitiveCommandCacheKeys.append(contentsOf: depCacheKeys!)
        }

        let dependencyInfo = DependencyInfo(
            fileDependencies: OrderedSet(fileDeps.commands.flatMap(\.file_deps).map(Path.init)),
            includeTreeID: fileDeps.includeTreeID,
            moduleDependencies: OrderedSet(moduleDeps),
            // Cached builds do not rely on the process working directory, and different scanner working directories should not inhibit task deduplication
            workingDirectory: fileDeps.commands.allSatisfy { $0.cache_key != nil } ? Path.root : workingDirectory,
            commands: commands,
            transitiveIncludeTreeIDs: transitiveIncludeTreeIDs,
            transitiveCompileCommandCacheKeys: transitiveCommandCacheKeys,
            usesSerializedDiagnostics: usesSerializedDiagnostics)
        try recordedDependencyInfoRegistry.getOrInsert(scanningOutputPath, isValid: { _ in true }) {
            try register(path: scanningOutputPath, dependencyInfo: dependencyInfo, fileSystem: fileSystem)
        }
        dependencyPaths.withLock {
            $0.formUnion(dependencyInfo.files)
        }

        return ScanResult(dependencyPaths: dependencyPaths.withLock { $0 }, requiredTargetDependencies: requiredTargetDependencies.withLock { $0 })
    }

    /// Query the dependencies for the specified key.
    package func queryDependencies(at path: Path, fileSystem fs: any FSProxy) throws -> DependencyInfo {
        do {
            let contents = try fs.read(path)
            let deserializer = MsgPackDeserializer(contents)
            let info: DependencyInfo = try deserializer.deserialize()
            return info
        } catch {
            let timestampDescription = (try? fs.getFileTimestamp(path)).map(String.init) ?? "<unknown>"
            throw StubError.error("Failed to query serialized dependencies at '\(path.str)' with timestamp \(timestampDescription); \(error)")
        }
    }

    package func getCASDatabases(libclangPath: Path, casOptions: CASOptions) throws -> ClangCASDatabases? {
        let clangWithScanner = try libclangWithScanner(
            forPath: libclangPath,
            casOptions: casOptions,
            cacheFallbackIfNotAvailable: false,
            core: core
        )
        return clangWithScanner.casDBs
    }

    package var isEmpty: Bool {
        recordedDependencyInfoRegistry.isEmpty
    }

    package func generatePrecompiledModulesReport(in directory: Path, fs: any FSProxy) async throws -> String {
        // Collect DependencyInfo of every module built during the current build.
        var dependencyInfoByModuleName = [String: Set<DependencyInfo>]()
        try await withThrowingTaskGroup(of: DependencyInfo.self) { group in
            for dependencyInfoPath in self.recordedDependencyInfoRegistry.keys {
                group.addTask {
                    try DependencyInfo(from: MsgPackDeserializer(fs.read(dependencyInfoPath)))
                }
            }
            for try await dependencyInfo in group {
                guard case .module(pcmOutputPath: let pcmPath) = dependencyInfo.kind else {
                    continue
                }
                var moduleID = pcmPath.basenameWithoutSuffix.components(separatedBy: ":")[0]
                let isVerify = moduleID.hasSuffix("-verify")
                if isVerify {
                    moduleID.removeLast("-verify".count)
                }
                let moduleName = moduleID.prefix(upTo: moduleID.lastIndex(of: "-") ?? moduleID.endIndex)
                dependencyInfoByModuleName[String(moduleName), default: []].insert(dependencyInfo)
            }
        }

        var summaryCSV = CSVBuilder()
        var summaryMessage = ""
        summaryCSV.writeRow(["Name", "Variants"])

        for (moduleName, variants) in dependencyInfoByModuleName.sorted(by: \.0) {
            summaryCSV.writeRow([moduleName, "\(variants.count)"])
            summaryMessage += "\(moduleName): \(variants.count == 1 ? "1 variant" : "\(variants.count) variants")\n"

            let mergeResult = nWayMerge(variants.map {
                (["CWD: \($0.workingDirectory.str)"] + ($0.commands.only?.arguments ?? [])).filter {
                    if ["pcm", "dia", "d"].contains(Path($0).fileExtension) {
                        // Filter differences in module paths, they are a function of the other args
                        return false
                    } else if $0.hasPrefix("llvmcas://") {
                        // Filter differences in CAS URLs, they are a function of the other args
                        return false
                    } else {
                        return true
                    }
                }
            }).filter {
                if $0.elementOf.count == variants.count {
                    // Don't report args common to all variants
                    return false
                } else {
                    return true
                }
            }

            var moduleCSV = CSVBuilder()
            moduleCSV.writeRow(["Variant"] + mergeResult.map(\.element))

            for (idx, variant) in variants.enumerated() {
                guard case .module(pcmOutputPath: let pcmPath) = variant.kind else {
                    continue
                }
                let variantID = pcmPath.basenameWithoutSuffix
                var checkboxes: [String] = []
                for mergeElement in mergeResult {
                    if mergeElement.elementOf.contains(idx) {
                        checkboxes.append("✅")
                    } else {
                        checkboxes.append("❌")
                    }
                }
                moduleCSV.writeRow([variantID] + checkboxes)
            }

            try fs.write(directory.join("\(moduleName).csv"), contents: ByteString(encodingAsUTF8: moduleCSV.output))
        }
        try fs.write(directory.join("Summary.csv"), contents: ByteString(encodingAsUTF8: summaryCSV.output))
        summaryMessage += "\nFull report written to '\(directory.str)'"
        return summaryMessage
    }
}
