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

public import protocol Foundation.LocalizedError
import SWBCSupport
import SWBLibc

/// A wrapper for a libclang library.
public final class Libclang {
    public enum Error: Swift.Error {
    case unableToGetDriverActions(String)
    }

    fileprivate let lib: libclang_t

    public init?(path: String) {
        guard let lib = libclang_open(path) else {
            return nil
        }

        self.lib = lib
    }

    public func leak() {
        libclang_leak(self.lib)
    }

    deinit {
        libclang_close(self.lib)
    }

    /// Get the clang version.
    public func getVersionString() -> String {
        var result: String = ""
        libclang_get_clang_version(lib) { result = String(cString: $0!) }
        return result
    }

    /// Create a new dependency scanner.
    public func createScanner(casDBs: ClangCASDatabases? = nil, casOpts: ClangCASOptions? = nil) throws -> DependencyScanner {
        return try DependencyScanner(self, casDBs: casDBs, casOpts: casOpts)
    }

    public func loadDiagnostics(filePath: String) throws -> [ClangDiagnostic] {
        return try ClangDiagnosticSet(self, filePath: filePath).diagnostics
    }

    /// Get the list of actions the clang driver would perform for the given command line.
    public func getDriverActions(
        clangArgs: [String],
        workingDirectory: String,
        environment: [String: String]
    ) throws -> [[String]] {
        var result: [[String]] = []
        let args = CStringArray(clangArgs)
        // FIXME <rdar://60711683>: Reenable the use of the environment.
        // let envp = CStringArray(environment.map{ "\($0.0)=\($0.1)" })
        var error: String? = nil
        let success = libclang_driver_get_actions(
            lib, CInt(args.cArray.count - 1), args.cArray, nil,
            workingDirectory,
            /*callback: */ { (argc, argv) in
                let argc = Int(argc)
                result.append((0 ..< argc).map{ String(cString: argv![$0]!) })
            },
            /*error_callback:*/ { (string: UnsafePointer<CChar>?) -> Void in
                let errString = String(cString: string!)
                if let curErr = error {
                    error = "\(curErr); \(errString)"
                } else {
                    error = errString
                }
            })
        guard success else {
            assert(error != nil)
            throw Error.unableToGetDriverActions(error!)
        }
        return result
    }

    public var supportsStructuredDiagnostics: Bool {
        libclang_has_structured_scanner_diagnostics(lib)
    }

    public var supportsCASPruning: Bool {
        libclang_has_cas_pruning_feature(lib)
    }

    public var supportsCASUpToDateChecks: Bool {
        libclang_has_cas_up_to_date_checks_feature(lib)
    }

    public var supportsCurrentWorkingDirectoryOptimization: Bool {
        libclang_has_current_working_directory_optimization(lib)
    }
}

enum DependencyScanningError: Error {
    case invalidModuleName(name: String)
}

/// A caching C-family language dependency scanner.
///
/// NOTE: This class is thread-safe.
public final class DependencyScanner {
    public enum Error: Swift.Error {
        /// Indicates that this version of libclang does not have dependency scanning support.
        case featureUnsupported
        case dependencyScanErrorString(String)
        case dependencyScanDiagnostics([ClangDiagnostic])
        case dependencyScanUnknownError
    }

    public struct ModuleDependency {
        init(clang_module_dependency: clang_module_dependency_t) {
            self.clang_module_dependency = clang_module_dependency
        }

        private let clang_module_dependency: clang_module_dependency_t
        public var name: String { String(cString: clang_module_dependency.name) }
        public var context_hash: String { String(cString: clang_module_dependency.context_hash) }
        public var module_map_path: String { String(cString: clang_module_dependency.module_map_path) }
        public var file_deps: some Sequence<String> { clang_module_dependency.file_deps.toLazyStringSequence() }
        public var include_tree_id: String? { clang_module_dependency.include_tree_id.map { String(cString: $0) } }
        public var module_deps: some Sequence<String> { clang_module_dependency.module_deps.toLazyStringSequence() }
        public var cache_key: String? { clang_module_dependency.cache_key.map { String(cString: $0) } }
        public var build_arguments: some Sequence<String> { clang_module_dependency.build_arguments.toLazyStringSequence() }
        public var is_cwd_ignored: Bool { clang_module_dependency.is_cwd_ignored }
    }

    public struct Command {
        public var context_hash: String
        public var file_deps: [String]
        public var module_deps: [String]
        public var cache_key: String?
        /// If nil, this is a legacy invocation, and the executable is clang.
        public var executable: String?
        public var build_arguments: [String]
    }

    public struct FileDependencies {
        public var includeTreeID: String?
        public var commands: [Command]
    }

    public enum ModuleOutputKind {
        case moduleFile
        case dependencyFile
        case dependencyTarget
        case serializedDiagnosticFile
    }

    /// We hold a reference to the lib, to guarantee lifetime.
    public let libclang: Libclang

    /// The scanner instance.
    private let scanner: libclang_scanner_t

    /// Create a new dependency scanner.
    ///
    /// The scanner will hold all of the shared caches which are used to
    /// accelerate dependency scanning. Those caches are *NOT* invalidated when
    /// files on disk change, so it is the responsibility of the client to
    /// allocate a new scanner when the caches need to be invalidated.
    public init(_ libclang: Libclang, casDBs: ClangCASDatabases? = nil, casOpts: ClangCASOptions? = nil) throws {
        guard libclang_has_scanner(libclang.lib) else {
            throw Error.featureUnsupported
        }
        self.libclang = libclang
        self.scanner = libclang_scanner_create(libclang.lib, casDBs?.dbs, casOpts?.options)
    }

    deinit {
        libclang_scanner_dispose(scanner)
    }

    /// Scan the dependencies for the Clang invocation given in `commandLine`.
    ///
    /// - Parameters:
    ///   - commandLine: The clang driver or -cc1 command line (including an argv[0] equivalent).
    ///   - workingDirectory: The working directory the command is evaluated within.
    ///   - lookupOutput: A callback to retrieve the path of a given module output.
    ///   - modulesCallback: A callback that will be invoked with a list of found module dependencies and boolean signifying whether the list is in topological order.
    /// - Returns: A list of the discovered dependencies, or nil if an error was encountered.
    public func scanDependencies(
        commandLine: [String],
        workingDirectory: String,
        lookupOutput: (_ name: String, _ contextHash: String, ModuleOutputKind) -> String?,
        modulesCallback: ([ModuleDependency], Bool) -> Void
    ) throws -> FileDependencies {
        let args = CStringArray(commandLine)
        var error: String? = nil
        var diagnostics: [ClangDiagnostic]? = nil
        var result: FileDependencies?
        // The count is `- 1` here, because CStringArray appends a trailing nullptr.
        let success = libclang_scanner_scan_dependencies(
            scanner, CInt(args.cArray.count - 1), args.cArray, workingDirectory,
            /*lookup_output:*/ { (cmoduleName: UnsafePointer<CChar>?, ccontextHash: UnsafePointer<CChar>?,
                                  ckind: clang_output_kind_t, coutput: UnsafeMutablePointer<CChar>?,
                                  maxLen: size_t) -> size_t in
                guard let kind = ModuleOutputKind(ckind) else {
                    return 0 // Unknown output
                }
                let moduleName = String(cString: cmoduleName!)
                let contextHash: String = String(cString: ccontextHash!)
                if var output = lookupOutput(moduleName, contextHash, kind) {
                    return output.withUTF8 { bytes in
                        if bytes.count <= maxLen {
                            memcpy(coutput!, bytes.baseAddress!, bytes.count)
                        }
                        return bytes.count
                    }
                } else {
                    assert(kind != .moduleFile, "moduleFile is a required output")
                    return 0 // Empty
                }
            },
            /*modules_callback:*/ { (modules: clang_module_dependency_set_t, topologicallySorted: Bool) -> Void in
                var mods: [ModuleDependency] = []
                for i in 0..<modules.count {
                    let m = modules.modules![Int(i)]
                    mods.append(ModuleDependency(clang_module_dependency: m))
                }
                modulesCallback(mods, topologicallySorted)
            },
            /*callback:*/ { (fileDeps: clang_file_dependencies_t) -> Void in
                var commands: [Command] = []
                for i in 0..<fileDeps.num_commands {
                    commands.append(Command(
                        context_hash: String(cString: fileDeps.commands[i].context_hash),
                        file_deps: Array<String>.fromCStringArray(fileDeps.commands[i].file_deps),
                        module_deps: Array<String>.fromCStringArray(fileDeps.commands[i].module_deps),
                        cache_key: fileDeps.commands[i].cache_key.map{String(cString:$0)},
                        executable: fileDeps.commands[i].executable.map({String(cString:$0)}),
                        build_arguments: Array<String>.fromCStringArray(fileDeps.commands[i].build_arguments)
                    ))
                }
                result = FileDependencies(includeTreeID: fileDeps.include_tree_id.map { String(cString: $0) }, commands: commands)
            },
            /*diagnostics_callback:*/ { (diagnosticSet: libclang_diagnostic_set_t?) -> Void in
                guard let diagnosticSet else {
                    diagnostics = []
                    return
                }
                diagnostics = (0..<diagnosticSet.pointee.count).map { i in
                    .init(diagnosticSet.pointee.diagnostics.advanced(by: Int(i)).pointee!)
                }
            },
            /*error_callback:*/ { (string: UnsafePointer<CChar>?) -> Void in
                error = String(cString: string!)
            })
        guard success, let fileDeps = result else {
            if let diagnostics = diagnostics {
                throw Error.dependencyScanDiagnostics(diagnostics)
            } else if let error = error {
                throw Error.dependencyScanErrorString(error)
            } else {
                throw Error.dependencyScanUnknownError
            }
        }
        return fileDeps
    }
}

fileprivate struct ClangDiagnosticSet {
    public enum Error: Swift.Error {
        case error(String)
    }

    public let diagnostics: [ClangDiagnostic]

    public init(_ libclang: Libclang, filePath: String) throws {
        var error: UnsafePointer<Int8>!
        defer { error?.deallocate() }
        guard let diagnosticSet = filePath.withCString({ path in
            return libclang_read_diagnostics(libclang.lib, path, &error)
        }) else {
            throw Error.error(String(cString: error))
        }

        self.diagnostics = (0..<diagnosticSet.pointee.count).map { i in
            .init(diagnosticSet.pointee.diagnostics.advanced(by: Int(i)).pointee!)
        }

        libclang_diagnostic_set_dispose(diagnosticSet)
    }
}

public struct ClangDiagnostic: Hashable {
    public enum Severity: Int, Hashable {
        case ignored = 0
        case note = 1
        case warning = 2
        case error = 3
        case fatal = 4
    }

    public let fileName: String?
    public let line: UInt32
    public let column: UInt32
    public let offset: UInt32
    public let severity: Severity
    public let text: String
    public let optionName: String?
    public let categoryText: String?
    public let ranges: [ClangSourceRange]
    public let fixIts: [ClangFixIt]
    public let childDiagnostics: [ClangDiagnostic]

    fileprivate init(_ diagnostic: libclang_diagnostic_t) {
        fileName = diagnostic.pointee.file_name.map { String(cString: $0) } ?? nil
        line = diagnostic.pointee.line
        column = diagnostic.pointee.column
        offset = diagnostic.pointee.offset
        severity = ClangDiagnostic.Severity(rawValue: Int(diagnostic.pointee.severity))!
        text = String(cString: diagnostic.pointee.text)
        optionName = diagnostic.pointee.option_name.map { String(cString: $0) } ?? nil
        categoryText = diagnostic.pointee.category_text.map { String(cString: $0) } ?? nil
        ranges = (0..<diagnostic.pointee.range_count).map { i in
            .init(diagnostic.pointee.ranges.advanced(by: Int(i)).pointee!)
        }
        fixIts = (0..<diagnostic.pointee.fixit_count).map { i in
            .init(diagnostic.pointee.fixits.advanced(by: Int(i)).pointee!)
        }
        childDiagnostics = (0..<diagnostic.pointee.child_count).map { i in
            .init(diagnostic.pointee.child_diagnostics.advanced(by: Int(i)).pointee!)
        }
    }
}

public struct ClangFixIt: Hashable {
    public let range: ClangSourceRange
    public let text: String

    fileprivate init(_ diagnostic: libclang_diagnostic_fixit_t) {
        range = .init(diagnostic.pointee.range)
        text = String(cString: diagnostic.pointee.text)
    }
}

public struct ClangSourceRange: Hashable {
    public let path: String
    public let startLine: UInt32
    public let startColumn: UInt32
    public let startOffset: UInt32
    public let endLine: UInt32
    public let endColumn: UInt32
    public let endOffset: UInt32

    fileprivate init(_ range: libclang_source_range_t) {
        path = range.pointee.path.map { String(cString: $0) } ?? ""
        startLine = range.pointee.start_line
        startColumn = range.pointee.start_column
        startOffset = range.pointee.start_offset
        endLine = range.pointee.end_line
        endColumn = range.pointee.end_column
        endOffset = range.pointee.end_offset
    }
}

extension DependencyScanner.ModuleOutputKind {
    init?(_ kind: clang_output_kind_t) {
        switch kind {
        case clang_output_kind_moduleFile:
            self = .moduleFile
        case clang_output_kind_dependencies:
            self = .dependencyFile
        case clang_output_kind_dependenciesTarget:
            self = .dependencyTarget
        case clang_output_kind_serializedDiagnostics:
            self = .serializedDiagnosticFile
        default:
            return nil
        }
    }
}

public final class ClangCASOptions {
    /// We hold a reference to the lib, to guarantee lifetime.
    public let libclang: Libclang

    /// The CAS options instance.
    let options: libclang_casoptions_t

    public init(_ libclang: Libclang) throws {
        guard libclang_has_cas_plugin_feature(libclang.lib) else {
            throw ClangCASDatabases.Error.featureUnsupported
        }
        self.libclang = libclang
        self.options = libclang_casoptions_create(libclang.lib)
    }

    deinit {
        libclang_casoptions_dispose(options)
    }

    @discardableResult
    public func setOnDiskPath(_ path: String) -> ClangCASOptions {
        libclang_casoptions_setondiskpath(options, path)
        return self
    }

    @discardableResult
    public func setPluginPath(_ path: String) -> ClangCASOptions {
        libclang_casoptions_setpluginpath(options, path)
        return self
    }

    @discardableResult
    public func setPluginOption(name: String, value: String) -> ClangCASOptions {
        libclang_casoptions_setpluginoption(options, name, value)
        return self
    }
}

public final class ClangCASDatabases {
    public enum Error: LocalizedError, CustomStringConvertible {
        /// Indicates that this version of libclang does not have cas support
        case featureUnsupported
        case creationFailed(String)
        case operationFailed(String)

        public var errorDescription: String? {
            return self.description
        }

        public var description: String {
            switch self {
            case .featureUnsupported:
                return "CAS feature is not supported"
            case .creationFailed(let reason):
                return "CAS creation failed: \(reason)"
            case .operationFailed(let reason):
                return "CAS operation failed: \(reason)"
            }
        }
    }

    /// We hold a reference to the lib, to guarantee lifetime.
    public let libclang: Libclang

    /// The CAS databases instance.
    let dbs: libclang_casdatabases_t

    public init(options: ClangCASOptions) throws {
        let libclang = options.libclang
        guard libclang_has_cas(libclang.lib) else {
            throw Error.featureUnsupported
        }
        self.libclang = libclang
        var error: Error? = nil
        guard let dbs = libclang_casdatabases_create(options.options, { cerror in
            error = .creationFailed(String(cString: cerror!))
        }) else {
            throw error!
        }
        self.dbs = dbs
    }

    deinit {
        libclang_casdatabases_dispose(dbs)
    }

    public func getOndiskSize() throws -> Int? {
        var error: ClangCASDatabases.Error? = nil
        let ret = libclang_casdatabases_get_ondisk_size(dbs, { c_error in
            error = .operationFailed(String(cString: c_error!))
        })
        if let error {
            throw error
        }
        if ret < 0 {
            return nil
        }
        return Int(ret)
    }

    public func setOndiskSizeLimit(_ limit: Int?) throws {
        var error: ClangCASDatabases.Error? = nil
        libclang_casdatabases_set_ondisk_size_limit(dbs, Int64(limit ?? 0), { c_error in
            error = .operationFailed(String(cString: c_error!))
        })
        if let error {
            throw error
        }
    }

    public func pruneOndiskData() throws {
        var error: ClangCASDatabases.Error? = nil
        libclang_casdatabases_prune_ondisk_data(dbs, { c_error in
            error = .operationFailed(String(cString: c_error!))
        })
        if let error {
            throw error
        }
    }

    /// Query the CAS for the associated outputs of a cache key.
    ///
    /// Only queries the local CAS, even if remote caching is enabled.
    public func getLocalCachedCompilation(cacheKey: String) throws -> ClangCASCachedCompilation? {
        return try getCachedCompilation(cacheKey: cacheKey, globally: false)
    }

    /// Query the CAS for the associated outputs of a cache key.
    public func getCachedCompilation(cacheKey: String, globally: Bool) throws -> ClangCASCachedCompilation? {
        var error: ClangCASDatabases.Error? = nil
        let c_cachedComp = libclang_cas_get_cached_compilation(dbs, cacheKey, globally, { c_error in
            error = .operationFailed(String(cString: c_error!))
        })
        if let error {
            throw error
        }
        guard let c_cachedComp else {
            return nil
        }
        return ClangCASCachedCompilation(libclang: libclang, cachedComp: c_cachedComp)
    }

    /// Query asynchronously the CAS for the associated outputs of a cache key.
    ///
    /// If remote caching is enabled and the key doesn't exist in the local CAS
    /// it will do a remote key lookup.
    public func getCachedCompilation(cacheKey: String) async throws -> ClangCASCachedCompilation? {
        let libclang = self.libclang
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ClangCASCachedCompilation?, Swift.Error>) in
            libclang_cas_get_cached_compilation_async(dbs, cacheKey, /*globally*/true) { c_cachedComp, c_error in
                if let c_error {
                    continuation.resume(throwing: Error.operationFailed(String(cString: c_error)))
                    return
                }
                guard let c_cachedComp else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ClangCASCachedCompilation(libclang: libclang, cachedComp: c_cachedComp))
            }
        }
    }

    /// Load the CAS object asynchronously. If remote caching is enabled, and the object doesn't exist
    /// in the local CAS, it will download the data into the local CAS.
    public func loadObject(casID: String) async throws -> ClangCASObject? {
        let libclang = self.libclang
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ClangCASObject?, Swift.Error>) in
            libclang_cas_load_object_async(dbs, casID) { c_obj, c_error in
                if let c_error {
                    continuation.resume(throwing: Error.operationFailed(String(cString: c_error)))
                    return
                }
                guard let c_obj else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ClangCASObject(libclang: libclang, object: c_obj))
            }
        }
    }

    public func isMaterialized(casID: String) throws -> Bool {
        var error: ClangCASDatabases.Error? = nil
        let ret = libclang_cas_casobject_is_materialized(dbs, casID) { c_error in
            error = .operationFailed(String(cString: c_error!))
        }
        if let error {
            throw error
        }
        return ret
    }
}

public final class ClangCASObject {
    /// We hold a reference to the lib, to guarantee lifetime.
    public let libclang: Libclang

    /// The loaded CAS object instance.
    let obj: libclang_cas_casobject_t

    fileprivate init(libclang: Libclang, object: libclang_cas_casobject_t) {
        self.libclang = libclang
        self.obj = object
    }

    deinit {
        libclang_cas_casobject_dispose(obj)
    }
}

/// A set of compilation outputs associated with a compilation cache key.
public final class ClangCASCachedCompilation {
    /// We hold a reference to the lib, to guarantee lifetime.
    public let libclang: Libclang

    /// The CAS cached compilation instance.
    let cachedComp: libclang_cas_cached_compilation_t

    fileprivate init(libclang: Libclang, cachedComp: libclang_cas_cached_compilation_t) {
        self.libclang = libclang
        self.cachedComp = cachedComp
    }

    deinit {
        libclang_cas_cached_compilation_dispose(cachedComp)
    }

    public struct Output {
        public let name: String
        public let casID: String
        fileprivate let idx: Int
    }

    /// The compilation outputs associated with the compilation cache key.
    public func getOutputs() -> [Output] {
        var outputs: [Output] = []
        for i in 0..<libclang_cas_cached_compilation_get_num_outputs(cachedComp) {
            var name: String?
            libclang_cas_cached_compilation_get_output_name(cachedComp, i) { c_name in
                name = String(cString: c_name!)
            }
            var casID: String?
            libclang_cas_cached_compilation_get_output_casid(cachedComp, i) { c_casid in
                casID = String(cString: c_casid!)
            }
            outputs.append(Output(name: name!, casID: casID!, idx: i))
        }
        return outputs
    }

    /// Whether the CAS object for the `output` exists in the local CAS.
    ///
    /// If it doesn't exist, and remote caching is enabled, it can be downloaded in the local CAS
    /// by passing the CASID of the output to `ClangCASDatabases.loadObject`.
    public func isOutputMaterialized(_ output: Output) -> Bool {
        return libclang_cas_cached_compilation_is_output_materialized(cachedComp, output.idx)
    }

    /// If remote caching is enabled it uploads the data for the compilation outputs and
    /// the association of cache key -> outputs.
    public func makeGlobal() async throws {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            libclang_cas_cached_compilation_make_global_async(cachedComp) { c_error in
                if let c_error {
                    continuation.resume(throwing: ClangCASDatabases.Error.operationFailed(String(cString: c_error)))
                    return
                }
                continuation.resume()
            }
        }
    }

    /// `makeGlobal` variant using a callback.
    public func makeGlobalAsync(_ body: @escaping ((any Error)?) -> Void) {
        libclang_cas_cached_compilation_make_global_async(cachedComp) { c_error in
            if let c_error {
                body(ClangCASDatabases.Error.operationFailed(String(cString: c_error)))
                return
            }
            body(nil)
        }
    }

    /// Replays the cached compilation using the associated compilation outputs.
    public func replay(commandLine: [String], workingDirectory: String) throws -> String {
        let args = CStringArray(commandLine)
        var diagnosticText: String?
        var error: (any Error)?
        let succeeded = libclang_cas_replay_compilation(cachedComp, CInt(args.cArray.count - 1), args.cArray, workingDirectory) { c_diagnostic_text, c_error in
            if let c_diagnostic_text {
                diagnosticText = String(cString: c_diagnostic_text)
            }
            if let c_error {
                error = ClangCASDatabases.Error.operationFailed(String(cString: c_error))
            }
        }
        guard succeeded else {
            throw error!
        }
        return diagnosticText!
    }
}
