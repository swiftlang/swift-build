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

package import SWBUtil
package import SWBMacro


/// An abstract representation of a search path entry, with any auxiliary information as appropriate depending on the type.
package enum SearchPathEntry
{
    /// A "user" header search path, in the manner of the `-iquote` option.  This kind of path is searched for quote-style includes, but is ignored for bracket-style includes.
    case userHeaderSearchPath(path: Path)

    /// A regular header search path, in the manner of the `-I` option.  This kind of path is searched for bracket-style includes, and also for quote-style includes that don’t find anything in the user header search paths.  The `asSeparateArguments` attribute indicates whether the `-I` flag should appear as a separate command line argument from the path, or whether it should be prepended to the path as a prefix.  It is a bit of a hack and it presently only needed in order to make sure Swift Build has exactly the same command line arguments as Xcode — in the future, it makes much more sense to always render them as separate.
    case headerSearchPath(path: Path, asSeparateArguments: Bool)

    /// A system header search path, in the manner of the `-isystem` option.  This kind of path is similar to a regular header search path, except that any headers found in a system header search path have “system” semantics in terms of silencing some kinds of warnings etc.
    case systemHeaderSearchPath(path: Path)

    /// A special kind of marker that corresponds to the `-I-` option in GCC and Clang.  This marker “splits” the sequence of search paths by turning any regular header search paths that occur ahead of it on the command line into user search paths, and making any following search paths be regular header search paths.  It also has the side effect of disabling the implicit “search-in-the-includer’s directory” semantics.  This option has been deprecated for some time and should be avoided except where absolutely needed for backward compatibility.
    case headerSearchPathSplitter

    /// A regular framework search path, in the manner of the `-F` option.  This kind of path is searched for framework-style includes.  The `asSeparateArguments` attribute indicates whether the `-F` flag should appear as a separate command line argument from the path, or whether it should be prepended to the path as a prefix.  It is a bit of a hack and it presently only needed in order to make sure Swift Build has exactly the same command line arguments as Xcode — in the future, it makes much more sense to always render them as separate.
    case frameworkSearchPath(path: Path, asSeparateArguments: Bool)

    /// A system framework search path, in the manner of the `-iframework` option.  This kind of path is similar to a regular framework search path, except that the headers of any frameworks found in a system framework search path have “system” semantics in terms of silencing some kinds of warnings etc.
    case systemFrameworkSearchPath(path: Path)

    /// A list of literal arguments to be emitted to the command line.  This is needed for cases in which certain kinds of header semantics require additional non-search-path options (such as `-ivfsoverlay`, for example).  It is a bit of a hack and it presently only needed in order to make sure Swift Build has exactly the same command line argument order as Xcode.
    case literalArguments([String])
}

/// An abstract representation of a list of search paths.
package final class SearchPathBuilder
{
    /// The list of search path entries.
    private var searchPathEntries = [SearchPathEntry]()

    /// A set of paths the tool should treat as input paths to the command.  We preserve the order in which they were added for convenience of testing.
    private(set) var inputPaths = OrderedSet<Path>()

    /// The set of ordinary header search paths already added.
    private(set) var headerSearchPaths: Set<Path>

    /// The set of system header search paths already added.
    private(set) var systemHeaderSearchPaths = Set<Path>()

    /// The set of ordinary framework search paths already added.
    private(set) var frameworkSearchPaths: Set<Path>

    /// The set of system framework search paths already added.
    private(set) var systemFrameworkSearchPaths = Set<Path>()

    /// Create a search path build object.  A set of ordinary header (-I) and framework (-F) search paths which have already been added to the command being built can optionally be included so that system search paths will not be added for the same paths.
    init(headerSearchPaths: Set<Path> = Set<Path>(), frameworkSearchPaths: Set<Path> = Set<Path>()) {
        self.headerSearchPaths = headerSearchPaths.filter({ !$0.isEmpty })
        self.frameworkSearchPaths = frameworkSearchPaths.filter({ !$0.isEmpty })
    }

    // Add a search path entry to the list, and if requested also add the path for the entry to the set of input paths.
    private func addSearchPathEntry(_ entry: SearchPathEntry, _ path: Path, _ isInputPath: Bool = false) {
        // Don't add the empty string as a search path.
        guard !path.isEmpty else {
            return
        }

        // Add the entry to the list.
        searchPathEntries.append(entry)

        // Mark the search path to be added as an input.
        if isInputPath {
            inputPaths.append(path)
        }

        // Depending on the entry type, add the path to the appropriate set.
        switch entry {
        case .headerSearchPath(_, _):
            headerSearchPaths.insert(path)
        case .systemHeaderSearchPath(_):
            systemHeaderSearchPaths.insert(path)
        case .frameworkSearchPath(_, _):
            frameworkSearchPaths.insert(path)
        case .systemFrameworkSearchPath(_):
            systemFrameworkSearchPaths.insert(path)
        default:
            break
        }
    }

    /// Add a user header search path to the list of search paths.
    func addUserHeaderSearchPath(_ path: Path, isInputPath: Bool = false)
    {
        let normalizedPath = path.normalize()
        addSearchPathEntry(.userHeaderSearchPath(path: normalizedPath), normalizedPath, isInputPath)
    }

    /// Add an ordinary header search path to the list of search paths.
    func addHeaderSearchPath(_ path: Path, asSeparateArguments: Bool = false, isInputPath: Bool = false)
    {
        let normalizedPath = path.normalize()
        addSearchPathEntry(.headerSearchPath(path: normalizedPath, asSeparateArguments: asSeparateArguments), normalizedPath, isInputPath)
    }

    /// Add a system header search path to the list of search paths.  The path will not be added if an ordinary or system header search path for the path has previously been added.
    func addSystemHeaderSearchPath(_ path: Path, isInputPath: Bool = false)
    {
        let normalizedPath = path.normalize()
        guard !headerSearchPaths.contains(normalizedPath) && !systemHeaderSearchPaths.contains(normalizedPath) else {
            return
        }
        addSearchPathEntry(.systemHeaderSearchPath(path: normalizedPath), normalizedPath, isInputPath)
    }

    /// Add a system header search path to the list of search paths.
    func addHeaderSearchPathSplitter()
    {
        searchPathEntries.append(.headerSearchPathSplitter)
    }

    /// Add an ordinary framework search path to the list of search paths.
    func addFrameworkSearchPath(_ path: Path, asSeparateArguments: Bool = false, isInputPath: Bool = false)
    {
        let normalizedPath = path.normalize()
        addSearchPathEntry(.frameworkSearchPath(path: normalizedPath, asSeparateArguments: asSeparateArguments), normalizedPath, isInputPath)
    }

    /// Add a system framework search path to the list of search paths.  The path will not be added if an ordinary or system framework search path for the path has previously been added.
    func addSystemFrameworkSearchPath(_ path: Path, isInputPath: Bool = false)
    {
        let normalizedPath = path.normalize()
        guard !frameworkSearchPaths.contains(normalizedPath) && !systemFrameworkSearchPaths.contains(normalizedPath) else {
            return
        }
        addSearchPathEntry(.systemFrameworkSearchPath(path: normalizedPath), normalizedPath, isInputPath)
    }

    /// Adds a list of literal arguments to the command line.
    func addLiteralArguments(_ args: [String], inputPaths: [Path] = [])
    {
        searchPathEntries.append(.literalArguments(args))
        self.inputPaths.append(contentsOf: inputPaths.map({ $0.normalize() }).filter({ !$0.isEmpty }))
    }

    var searchPaths: SearchPaths {
        SearchPaths(searchPathEntries: searchPathEntries, inputPaths: inputPaths, headerSearchPaths: headerSearchPaths, systemHeaderSearchPaths: systemHeaderSearchPaths, frameworkSearchPaths: frameworkSearchPaths, systemFrameworkSearchPaths: systemFrameworkSearchPaths)
    }
}

package struct SearchPaths: Sendable {
    init(searchPathEntries: [SearchPathEntry], inputPaths: OrderedSet<Path>, headerSearchPaths: Set<Path>, systemHeaderSearchPaths: Set<Path> = Set<Path>(), frameworkSearchPaths: Set<Path>, systemFrameworkSearchPaths: Set<Path> = Set<Path>()) {
        self.searchPathEntries = searchPathEntries
        self.inputPaths = inputPaths
        self.headerSearchPaths = headerSearchPaths
        self.systemHeaderSearchPaths = systemHeaderSearchPaths
        self.frameworkSearchPaths = frameworkSearchPaths
        self.systemFrameworkSearchPaths = systemFrameworkSearchPaths
    }

    /// The list of search path entries.
    package let searchPathEntries: [SearchPathEntry]

    /// A set of paths the tool should treat as input paths to the command.  We preserve the order in which they were added for convenience of testing.
    package let inputPaths: OrderedSet<Path>

    /// The set of ordinary header search paths already added.
    package let headerSearchPaths: Set<Path>

    /// The set of system header search paths already added.
    package let systemHeaderSearchPaths: Set<Path>

    /// The set of ordinary framework search paths already added.
    package let frameworkSearchPaths: Set<Path>

    /// The set of system framework search paths already added.
    package let systemFrameworkSearchPaths: Set<Path>

    /// Generate the command line arguments for search path entries for the given command line builder.
    package func searchPathArguments(for builder: any SearchPathCommandLineBuilder, scope: MacroEvaluationScope) -> [String] {
        return builder.searchPathArguments(searchPathEntries, scope)
    }
}

/// Adopting this protocol indicates that the adopter can generate command line arguments for search path entries.
package protocol SearchPathCommandLineBuilder
{
    func searchPathArguments(_ entry: SearchPathEntry, _ scope: MacroEvaluationScope) -> [String]

    func searchPathArguments(_ entries: [SearchPathEntry], _ scope: MacroEvaluationScope) -> [String]
}

extension SearchPathCommandLineBuilder
{
    package func searchPathArguments(_ entries: [SearchPathEntry], _ scope: MacroEvaluationScope) -> [String]
    {
        return entries.flatMap({ return self.searchPathArguments($0, scope) })
    }
}


/// Utility methods for GCC-compatible compiler specifications.
package struct GCCCompatibleCompilerSpecSupport
{
    /// Constructs and returns common header search path entries for LLVM-based compiler specs.  Also returns any input paths (to headermap or VFS files) which users of these search paths should depend on.
    package static func headerSearchPathArguments(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, usesModules: Bool) -> SearchPaths
    {
        let searchPathBuilder = SearchPathBuilder()

        // Evaluate some settings we need to look at several times.
        let alwaysSearchUserPaths = scope.evaluate(BuiltinMacros.ALWAYS_SEARCH_USER_PATHS)

        // Add the arguments for the headermap files, if any.
        if scope.evaluate(BuiltinMacros.USE_HEADERMAP)
        {
            // Swift Build does not support "traditional" (single-file) headermaps.  Use of separate headermaps has been the default for new projects for years, and use of the VFS (when clang modules are enabled) requires separate headermaps.
            // If the target is configured to use a traditional headermap, then we the HeadermapTaskProducer emits a warning about that, and we use separate headermaps anyway.

            let usesVFS = (producer.needsVFS || scope.evaluate(BuiltinMacros.HEADERMAP_USES_VFS)) && usesModules

            // Use the separate headermap files.
            let hmapFileForGeneratedFiles = scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_GENERATED_FILES)
            searchPathBuilder.addUserHeaderSearchPath(hmapFileForGeneratedFiles, isInputPath: true)

            let hmapFileForOwnTargets = scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_OWN_TARGET_HEADERS)
            searchPathBuilder.addHeaderSearchPath(hmapFileForOwnTargets, isInputPath: true)

            // If we are using the VFS, replace the all targets headermap with it.
            if usesVFS
            {
                // Mark the creation context as needing VFS construction.
                // If we are using the VFS, we still need an equivalent of the all targets headermap for non-framework headers.
                let hmapFileForAllNonFrameworkTargetHeaders = scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_ALL_NON_FRAMEWORK_TARGET_HEADERS)
                searchPathBuilder.addHeaderSearchPath(hmapFileForAllNonFrameworkTargetHeaders, isInputPath: true)

                // FIXME: We shouldn't be passing a literal argument here, that should be handled by GCCCompatibleCompilerCommandLineBuilder, but for Swift Build bring-up we need to preserve the ordering of -ivfsoverlay relative to the search path args.
                let productHeadersVFSFile = scope.evaluate(BuiltinMacros.CPP_HEADERMAP_PRODUCT_HEADERS_VFS_FILE)
                // FIXME: We should make Path be able to be used here, potentially using a "path string provider" protocol or somesuch.
                searchPathBuilder.addLiteralArguments(["-ivfsoverlay", productHeadersVFSFile.str], inputPaths: [productHeadersVFSFile])
            }
            else
            {
                // Not using a VFS, so we just add the headermap for all headers that are a member of any target.
                let hmapFileForAllTargetHeaders = scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_ALL_TARGET_HEADERS)
                searchPathBuilder.addHeaderSearchPath(hmapFileForAllTargetHeaders, isInputPath: true)
            }

            // Finally, add the headermap for all headers in the project, regardless of target affiliation.
            let hmapFileForProjectFiles = scope.evaluate(BuiltinMacros.CPP_HEADERMAP_FILE_FOR_PROJECT_FILES)
            searchPathBuilder.addUserHeaderSearchPath(hmapFileForProjectFiles, isInputPath: true)
        }

        // If we should use header symlinks, we add the path to that directory to the search path.  We do this early, so that it comes near the beginning of the bracket search paths and overrides them all.
        if scope.evaluate(BuiltinMacros.USE_HEADER_SYMLINKS)
        {
            let headerSymlinksDir = scope.evaluate(BuiltinMacros.CPP_HEADER_SYMLINKS_DIR)
            searchPathBuilder.addUserHeaderSearchPath(headerSymlinksDir)
        }

        // Add search paths for USER_HEADER_SEARCH_PATHS before other header search paths.
        let userHeaderSearchPaths = producer.expandedSearchPaths(for: BuiltinMacros.USER_HEADER_SEARCH_PATHS, scope: scope)
        if alwaysSearchUserPaths
        {
            // If we should always search user paths, then we pass the USER_HEADER_SEARCH_PATHS using an ordinary header search option.
            for searchPath in userHeaderSearchPaths
            {
                searchPathBuilder.addHeaderSearchPath(Path(searchPath))
            }
        }
        else
        {
            // If we should *not* always search user paths, then we pass the USER_HEADER_SEARCH_PATHS using a user header search option.
            for searchPath in userHeaderSearchPaths
            {
                searchPathBuilder.addUserHeaderSearchPath(Path(searchPath))
            }
        }

        // Add ordinary header search paths for HEADER_SEARCH_PATHS.
        for searchPath in producer.expandedSearchPaths(for: BuiltinMacros.HEADER_SEARCH_PATHS, scope: scope)
        {
            searchPathBuilder.addHeaderSearchPath(Path(searchPath))
        }

        // Add system header search paths for SYSTEM_HEADER_SEARCH_PATHS.  The builder will filter out any which have already been added as ordinary header search paths.
        for searchPath in producer.expandedSearchPaths(for: BuiltinMacros.SYSTEM_HEADER_SEARCH_PATHS, scope: scope)
        {
            searchPathBuilder.addSystemHeaderSearchPath(Path(searchPath))
        }

        // Add ordinary header search paths for PRODUCT_TYPE_HEADER_SEARCH_PATHS.
        for searchPath in producer.expandedSearchPaths(for: BuiltinMacros.PRODUCT_TYPE_HEADER_SEARCH_PATHS, scope: scope)
        {
            searchPathBuilder.addHeaderSearchPath(Path(searchPath))
        }

        // Add paths to the derived file folders.  Since we don't know a priori whether there will be any generated files, we have to play it safe and add paths to anywhere Xcode might generate them.
        let derivedFileDir = scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR)

        if scope.evaluate(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS), (scope.evaluateAsString(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS_IN_HEADER_SEARCH_PATHS).isEmpty || scope.evaluate(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS_IN_HEADER_SEARCH_PATHS)) {
            // Note that we include the current-variant-and-architecture-specific directory because Xcode directs MiG (and possibly other tools) to generate separate derived files per architecture and variant.
            let currentArch = scope.evaluate(BuiltinMacros.CURRENT_ARCH)
            let variantPath = Path("\(derivedFileDir.str)-\(scope.evaluate(BuiltinMacros.CURRENT_VARIANT))")
            if currentArch != "undefined_arch" {
                searchPathBuilder.addHeaderSearchPath(variantPath.join(scope.evaluate(BuiltinMacros.CURRENT_ARCH)))
                searchPathBuilder.addHeaderSearchPath(derivedFileDir.join(currentArch))
            } else {
                searchPathBuilder.addHeaderSearchPath(variantPath)
            }

            searchPathBuilder.addHeaderSearchPath(derivedFileDir)
        }

        // If there are Iig generated files in this target, add them to the search path.
        if let target = producer.configuredTarget?.target as? BuildPhaseTarget {
            if let iigType = producer.lookupFileType(identifier: "sourcecode.iig"),
               target.sourcesBuildPhase?.containsFiles(ofType: iigType, producer, producer, scope, producer.filePathResolver) ?? false {
                searchPathBuilder.addHeaderSearchPath(Path(scope.evaluate(BuiltinMacros.IIG_HEADERS_DIR)))
            }
        }

        return searchPathBuilder.searchPaths
    }

    /// Constructs and returns common framework search path arguments for LLVM-based compiler specs.
    package static func frameworkSearchPathArguments(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, asSeparateArguments: Bool = false) -> SearchPaths
    {
        let searchPathBuilder = SearchPathBuilder()

        guard producer.isApplePlatform else {
            return searchPathBuilder.searchPaths
        }

        // Add ordinary framework search paths for FRAMEWORK_SEARCH_PATHS.
        for searchPath in producer.expandedSearchPaths(for: BuiltinMacros.FRAMEWORK_SEARCH_PATHS, scope: scope)
        {
            searchPathBuilder.addFrameworkSearchPath(Path(searchPath), asSeparateArguments: asSeparateArguments)
        }

        // Add system framework search paths for PRODUCT_TYPE_HEADER_SEARCH_PATHS.
        for searchPath in producer.expandedSearchPaths(for: BuiltinMacros.PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS, scope: scope)
        {
            searchPathBuilder.addSystemFrameworkSearchPath(Path(searchPath))
        }

        // Add system framework search paths for SYSTEM_FRAMEWORK_SEARCH_PATHS.  The builder will filter out any which have already been added as ordinary framework search paths.
        for searchPath in producer.expandedSearchPaths(for: BuiltinMacros.SYSTEM_FRAMEWORK_SEARCH_PATHS, scope: scope)
        {
            searchPathBuilder.addSystemFrameworkSearchPath(Path(searchPath))
        }

        return searchPathBuilder.searchPaths
    }

    private static func sparseSDKSearchPathArguments(_ sparseSDKs: [SDK], _ existingHeaderSearchPaths: Set<Path>, _ existingFrameworkSearchPaths: Set<Path>, asSeparateArguments: Bool = false, skipHeaderSearchPaths: Bool = false) -> SearchPaths
    {
        // Create a search path build with the search paths which are already in the arguments as -I and -F options, so we don't add SDK search paths to the same paths.
        let searchPathBuilder = SearchPathBuilder(headerSearchPaths: existingHeaderSearchPaths, frameworkSearchPaths: existingFrameworkSearchPaths)

        for sdk in sparseSDKs
        {
            if !skipHeaderSearchPaths {
                // Figure out which, if any, additional header search path options to add.  We start with the header search paths defined by the sparse SDK, if any.
                let headerSearchPaths = sdk.headerSearchPaths

                // Add additional header paths as system header search paths.  The builder will filter out any which have already been added as ordinary header search paths.
                if !headerSearchPaths.isEmpty
                {
                    for path in headerSearchPaths
                    {
                        searchPathBuilder.addSystemHeaderSearchPath(path)
                    }
                }
            }

            // Figure out which, if any, additional framework search path options to add.  We start with the framework search paths defined by the sparse SDK, if any.
            let frameworkSearchPaths = sdk.frameworkSearchPaths

            // Add additional framework paths as system framework search paths.  The builder will filter out any which have already been added as ordinary framework search paths.
            if !frameworkSearchPaths.isEmpty
            {
                for path in frameworkSearchPaths
                {
                    searchPathBuilder.addSystemFrameworkSearchPath(path)
                }
            }
        }

        return searchPathBuilder.searchPaths
    }

    /// Constructs and returns common search path arguments for sparse SDKs for LLVM-based compiler specs.
    /// - parameter existingHeaderSearchPaths: Header search paths which are already present in the command being constructed.
    /// - parameter existingFrameworkSearchPaths: Framework search paths which are already present in the command being constructed.
    static func sparseSDKSearchPathArguments(_ sparseSDKs: [SDK], _ existingHeaderSearchPaths: Set<Path>, _ existingFrameworkSearchPaths: Set<Path>, asSeparateArguments: Bool = false) -> SearchPaths {
        return sparseSDKSearchPathArguments(sparseSDKs, existingHeaderSearchPaths, existingFrameworkSearchPaths, asSeparateArguments: asSeparateArguments, skipHeaderSearchPaths: false)
    }

    /// Constructs and returns common search path arguments for sparse SDKs for LLVM-based compiler specs.
    /// - parameter existingFrameworkSearchPaths: Framework search paths which are already present in the command being constructed.
    static func sparseSDKFrameworkSearchPathArguments(_ sparseSDKs: [SDK], _ existingSearchPaths: Set<Path>, asSeparateArguments: Bool = false) -> SearchPaths {
        return sparseSDKSearchPathArguments(sparseSDKs, Set(), existingSearchPaths, asSeparateArguments: asSeparateArguments, skipHeaderSearchPaths: true)
    }
}


/// Adopting this protocol indicates that the adopter can generate LLVM-based compiler command line arguments for search path entries.
package protocol GCCCompatibleCompilerCommandLineBuilder: SearchPathCommandLineBuilder
{
}


extension GCCCompatibleCompilerCommandLineBuilder
{
    package func searchPathArguments(_ entry: SearchPathEntry, _ scope: MacroEvaluationScope) -> [String]
    {
        var args = [String]()
        switch entry
        {
          case .userHeaderSearchPath(let path):
            args.append(contentsOf: ["-iquote", path.str])

          case .headerSearchPath(let path, let separateArgs):
            args.append(contentsOf: separateArgs ? ["-I", path.str] : ["-I" + path.str])

          case .systemHeaderSearchPath(let path):
            args.append(contentsOf: ["-isystem", path.str])

          case .headerSearchPathSplitter:
            args.append("-I-")              // <rdar://problem/24312805> states that clang has never supported this option.

          case .frameworkSearchPath(let path, let separateArgs):
            args.append(contentsOf: separateArgs ? ["-F", path.str] : ["-F" + path.str])

          case .systemFrameworkSearchPath(let path):
            args.append(contentsOf: ["-iframework", path.str])

          case .literalArguments(let literalArgs):
            args.append(contentsOf: literalArgs)
        }
        return args
    }
}

/// Represents a language dialect recognized by GCC-compatible compilers.
public enum GCCCompatibleLanguageDialect: Equatable, Hashable, Sendable {
    case c
    case cPlusPlus
    case objectiveC
    case objectiveCPlusPlus
    case other(dialectName: String)

    public init(dialectName: String) {
        switch dialectName {
        case GCCCompatibleLanguageDialect.c.dialectNameForCompilerCommandLineArgument:
            self = .c
        case GCCCompatibleLanguageDialect.cPlusPlus.dialectNameForCompilerCommandLineArgument:
            self = .cPlusPlus
        case GCCCompatibleLanguageDialect.objectiveC.dialectNameForCompilerCommandLineArgument:
            self = .objectiveC
        case GCCCompatibleLanguageDialect.objectiveCPlusPlus.dialectNameForCompilerCommandLineArgument:
            self = .objectiveCPlusPlus
        default:
            self = .other(dialectName: dialectName)
        }
    }

    /// String representation of the language dialect,
    /// suitable for passing to the compiler's `-x` option.
    ///
    /// [Using the GNU Compiler Collection (GCC): Overall Options](https://gcc.gnu.org/onlinedocs/gcc/Overall-Options.html#index-x)
    public var dialectNameForCompilerCommandLineArgument: String {
        switch self {
        case .c:
            return "c"
        case .cPlusPlus:
            return "c++"
        case .objectiveC:
            return "objective-c"
        case .objectiveCPlusPlus:
            return "objective-c++"
        case .other(let dialectName):
            return dialectName
        }
    }

    /// List of all C-family language dialects:
    /// C, C++, Objective-C, and Objective-C++.
    public static var allCLanguages: Set<GCCCompatibleLanguageDialect> {
        return [.c, .cPlusPlus, .objectiveC, .objectiveCPlusPlus]
    }

    /// Whether the language dialect is either C++ or Objective-C++.
    public var isPlusPlus: Bool {
        return self == .cPlusPlus || self == .objectiveCPlusPlus
    }

    /// Whether the language dialect is either Objective-C or Objective-C++.
    public var isObjective: Bool {
        return self == .objectiveC || self == .objectiveCPlusPlus
    }
}

extension GCCCompatibleLanguageDialect {
    /// Returns the default file extension (with the leading '.') that should
    /// be used for source files corresponding to the language dialect.
    public var sourceFileNameSuffix: String? {
        switch self {
        case .c: return ".c"
        case .cPlusPlus: return ".cpp"
        case .objectiveC: return ".m"
        case .objectiveCPlusPlus: return ".mm"
        default: return nil
        }
    }

    /// Returns the file extension (with the leading '.') that should be used
    /// for preprocessor output corresponding to the language dialect.
    public var preprocessedSourceFileNameSuffix: String? {
        switch self {
        case .c: return ".i"
        case .cPlusPlus: return ".ii"
        case .objectiveC: return ".mi"
        case .objectiveCPlusPlus: return ".mii"
        default: return nil
        }
    }
}
