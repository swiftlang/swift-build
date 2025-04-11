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

public import SWBUtil
public import SWBMacro
import Foundation

/// Information on a macro config file.
@_spi(Testing) public struct MacroConfigInfo: Sendable {
    /// The macro definitions.
    @_spi(Testing) public let table: MacroValueAssignmentTable

    /// The diagnostics produced when loading the xcconfig.
    @_spi(Testing) public var diagnostics: [Diagnostic]

    /// The ordered list of paths the xcconfig depends on, including the path of the xcconfig itself.
    @_spi(Testing) public let dependencyPaths: [Path]

    /// The invalidation signature for the info.
    @_spi(Testing) public let signature: FilesSignature

    /// Whether we failed to read the file at all. If this is `true`, the macro table is guaranteed to be empty.
    @_spi(Testing) public let isFileReadFailure: Bool
}

@_spi(Testing) public enum MacroConfigLoadContext: Sendable {
    case baseConfiguration
    case commandLineConfiguration
    case environmentConfiguration
}

/// Loads macro config files (.xcconfig) in the context of a particular workspace.
final class MacroConfigFileLoader: Sendable {
    private let core: Core
    private let fs: any FSProxy

    init(core: Core, fs: any FSProxy) {
        self.core = core
        self.fs = fs
    }

    /// Load an xcconfig file from a path.
    func loadSettingsFromConfig(path: Path, namespace: MacroNamespace, searchPaths: [Path], filesSignature: ([Path]) -> FilesSignature) -> MacroConfigInfo {
        // Load the text from the file.
        guard let data = try? fs.read(path) else {
            let table = MacroValueAssignmentTable(namespace: namespace)
            let dependencyPaths = [path]
            return MacroConfigInfo(table: table, diagnostics: [], dependencyPaths: dependencyPaths, signature: filesSignature(dependencyPaths), isFileReadFailure: true)
        }

        return loadSettingsFromConfig(data: data, path: path, namespace: namespace, searchPaths: searchPaths, filesSignature: filesSignature)
    }

    /// Stores data about previously visited xcconfig files.
    fileprivate final class AncestorInclude {
        let path: Path
        let fs: any FSProxy

        /// Gets real path after resolving symlink and fully normalizing the path.
        var resolvedPath: Path { return resolvedPathCache.getValue(self) }
        private var resolvedPathCache = LazyCache { (ancestorInclude: AncestorInclude) -> Path in
            do {
                return try ancestorInclude.path.resolveSymlink(fs: ancestorInclude.fs)
            } catch {
                return ancestorInclude.normalizedPath
            }
        }

        var normalizedPath: Path { return normalizedPathCache.getValue(self) }
        private var normalizedPathCache = LazyCache{ (ancestorInclude: AncestorInclude) -> Path in
            return ancestorInclude.path.normalize()
        }

        var description: String {
            return self.normalizedPath == resolvedPath ? "'\(self.resolvedPath.str)'" : "'\(self.normalizedPath.str)' (symlink to '\(self.resolvedPath.str)')"
        }

        var descriptionWithBasename: String {
            return self.normalizedPath == resolvedPath ? "'\(self.resolvedPath.basename)'" : "'\(self.normalizedPath.basename)' (symlink to '\(self.resolvedPath.basename)')"
        }

        init(path: Path, fs: any FSProxy) {
            self.path = path
            self.fs = fs
        }
    }

    /// Load settings from an xcconfig data string.
    func loadSettingsFromConfig(data: ByteString, path: Path?, namespace: MacroNamespace, searchPaths: [Path], filesSignature: ([Path]) -> FilesSignature) -> MacroConfigInfo {
        // Use a custom config file parser to build up a table.
        final class ConfigDiagnostics {
            internal private(set) var diagnostics: [Diagnostic] = []
            func append(_ diagnostic: Diagnostic) {
                diagnostics.append(diagnostic)
            }
        }
        final class NestedConfigurations {
            var paths: [Path] = []
        }
        final class AncestorIncludes {
            var paths = OrderedSet<AncestorInclude>()
        }
        struct SettingsConfigFileParserDelegate: MacroConfigFileParserDelegate {
            let fs: any FSProxy
            /// The base directory path against which to resolve relative include references.
            let basePath: Path?
            let searchPaths: [Path]
            let table: MacroValueAssignmentTableRef
            let diagnostics: ConfigDiagnostics
            let nestedConfigurations: NestedConfigurations
            /// A collection of included xcconfig files leading to the one currently being parsed. The element currently being parsed is the last one in the array.
            let ancestorIncludes: AncestorIncludes
            let developerPath: Core.DeveloperPath

            /// If a #include(?) directive has been found then this method creates and returns a parser to parse that file.  The delegate of the subparser will share the macro value assignment table and diagnostics object of this delegate, so that the include file's information will be added to that of the file that included it.
            /// - parameter fileName: The file to be included.  If this is not an absolute path, then it will be searched for in the base path of the file included it, and any defined search paths.
            /// - parameter optional: If true, then if the file cannot be found, no error will be emitted and the #include directive will be silently ignored.  This only applies to *finding* the included file; if the include file exists but cannot be read or parsed, then errors will still be emitted.
            func foundPreprocessorInclusion(_ fileName: String, optional: Bool, parser: MacroConfigFileParser) -> MacroConfigFileParser? {
                // Convert the input string to a Path (either relative or absolute).
                var path = Path(fileName)

                // First resolve the special case of <DEVELOPER_DIR>.
                //
                // FIXME: Move this to its proper home, and support the other special cases Xcode has (PLATFORM_DIR and SDK_DIR). This should move to using a generic facility, e.g., source trees: <rdar://problem/23576831> Add search paths for .xcconfig macros to match what Xcode has
                if path.str.hasPrefix("<DEVELOPER_DIR>") {
                    switch developerPath {
                    case .xcode(let developerPath), .swiftToolchain(let developerPath, _), .fallback(let developerPath):
                        path = Path(path.str.replacingOccurrences(of: "<DEVELOPER_DIR>", with: developerPath.str))
                    }
                }

                let allSearchPaths: [Path] = basePath != nil ? [basePath!] + searchPaths : searchPaths

                // If the path isn’t absolute, we look first in the includer’s directory and after that in the search paths.
                if !path.isAbsolute {
                    // If we have no search paths, then we emit an error and return nil.
                    guard allSearchPaths.count > 0 else {
                        if !optional {
                            handleDiagnostic(MacroConfigFileDiagnostic(kind: .missingIncludedFile, level: .error, message: "could not find included file '\(fileName)' because there are no search paths to locate it", lineNumber: parser.lineNumber), parser: parser)
                        }
                        return nil
                    }

                    // Look for the included file in the search paths.  We stop at the first path at which we find it.
                    for spath in allSearchPaths {
                        if fs.exists(spath.join(path)) {
                            path = spath.join(path)
                            break
                        }

                        // File extension is optional.
                        if path.fileExtension.isEmpty {
                            let newPath = Path("\(path.str).xcconfig")
                            if fs.exists(spath.join(newPath)) {
                                path = spath.join(newPath)
                                break
                            }
                        }
                    }

                    // If the path is still not absolute, then we couldn't find it in the search paths, so we emit an error and return nil.
                    if !path.isAbsolute {
                        if !optional {
                            handleDiagnostic(MacroConfigFileDiagnostic(kind: .missingIncludedFile, level: .error, message: "could not find included file '\(fileName)' in search paths", lineNumber: parser.lineNumber), parser: parser)
                        }
                        return nil
                    }
                } else {
                    // File extension is optional.
                    if !fs.exists(path) && path.fileExtension.isEmpty {
                        let newPath = Path("\(path.str).xcconfig")
                        if fs.exists(newPath) {
                            path = newPath
                        }
                    }
                }

                let pathToInclude = AncestorInclude(path: path, fs: fs)

                // If included file at the current absolute path has already been parsed, there is an include cycle present which will cause SWBBuildService to crash.
                if ancestorIncludes.paths.contains(pathToInclude) {
                    // Transforms array of parent config files, with config file creating cycle appended, into a string for giving diagnostics to users.
                    var cycleDetailsStr = ""
                    var foundOriginalPath = false
                    var startingCycleIndex = 0

                    // Constructs detailed info about the cycle.
                    for (index, element) in ancestorIncludes.paths.enumerated() {
                        if element.resolvedPath == pathToInclude.resolvedPath {
                            foundOriginalPath = true
                            startingCycleIndex = index
                        }
                        if foundOriginalPath {
                            if index != (ancestorIncludes.paths.count - 1) {
                                cycleDetailsStr += "\(element.description) includes \(ancestorIncludes.paths[index + 1].description)\n"
                            } else {
                                cycleDetailsStr += "\(element.description) includes \(pathToInclude.description)\n"
                            }
                        }
                    }

                    let cyclePathStr = (ancestorIncludes.paths[startingCycleIndex...] + [pathToInclude]).map{ $0.descriptionWithBasename }.joined(separator: " -> ")

                    // To maintain compatibility, we need to warn here. rdar://45532351 to consider putting this behind an option to expose it's level of diagnostic.
                    handleDiagnostic(MacroConfigFileDiagnostic(kind: .cyclicIncludeFileDirective, level: .warning, message: "Skipping the inclusion of '\(pathToInclude.normalizedPath.basename)' from '\(parser.path.normalize().basename)' as it would create a cycle.\nCycle Path: \(cyclePathStr)\nCycle Details:\n\(cycleDetailsStr)", lineNumber: parser.lineNumber), parser: parser)

                    return nil
                }

                // Record that we found an absolute path for the included file, whether or not it exists.
                nestedConfigurations.paths.append(path)

                // If the file does not exist, then we emit an error and return.
                // We don't want to add this path to the ancestorIncludes in that case!
                if !fs.exists(path) {
                    if !optional {
                        handleDiagnostic(MacroConfigFileDiagnostic(kind: .missingIncludedFile, level: .error, message: "included file '\(fileName)' does not exist", lineNumber: parser.lineNumber), parser: parser)
                    }
                    return nil
                }

                // Push copy of path to indicate it is still being parsed. EndPreproccessorInclusion will pop this from ancestorIncludes.
                ancestorIncludes.paths.append(pathToInclude)

                // Read the data at the path.  If it can't be read, then emit an error and return nil.
                guard let data = try? fs.read(path) else {
                    handleDiagnostic(MacroConfigFileDiagnostic(kind: .missingIncludedFile, level: .error, message: "unable to read included file '\(path.str)'", lineNumber: parser.lineNumber), parser: parser)
                    return nil
                }

                // If we get this far, we have found a file and read its contents.  Create and return a parser for it.
                let delegate = SettingsConfigFileParserDelegate(fs: fs, basePath: path.dirname, searchPaths: allSearchPaths, table: table, diagnostics: diagnostics, nestedConfigurations: nestedConfigurations, ancestorIncludes: ancestorIncludes, developerPath: developerPath)
                return MacroConfigFileParser(byteString: data, path: path, delegate: delegate)
            }

            mutating func foundMacroValueAssignment(_ macroName: String, conditions: [(param: String, pattern: String)], value: String, parser: MacroConfigFileParser) {
                // Look up the macro name, creating it as a user-defined macro if it isn’t already known.
                let macro = table.namespace.lookupOrDeclareMacro(UserDefinedMacroDeclaration.self, macroName)

                // If we have any conditions, we also construct a condition set.
                var conditionSet: MacroConditionSet?
                if !conditions.isEmpty {
                    conditionSet = MacroConditionSet(conditions: conditions.map{ MacroCondition(parameter: table.namespace.declareConditionParameter($0.0), valuePattern: $0.1) })
                }

                // Parse the value in a manner consistent with the macro definition.
                table.push(macro, table.namespace.parseForMacro(macro, value: value), conditions: conditionSet)
            }

            func handleDiagnostic(_ diagnostic: MacroConfigFileDiagnostic, parser: MacroConfigFileParser) {
                switch diagnostic.level {
                case .warning:
                    diagnostics.append(Diagnostic(behavior: .warning, location: .path(parser.path, line: diagnostic.lineNumber), data: DiagnosticData(diagnostic.message)))
                case .error:
                    diagnostics.append(Diagnostic(behavior: .error, location: .path(parser.path, line: diagnostic.lineNumber), data: DiagnosticData(diagnostic.message)))
                }
            }

            func endPreprocessorInclusion() {
                // Remove the last item of the ancestorIncludes list once done with parsing.
                let _ = ancestorIncludes.paths.removeLast()
            }
        }

        // Create a table, a delegate, and a parser, and parse the input.
        let table = MacroValueAssignmentTable(namespace: namespace)
        let diagnostics = ConfigDiagnostics()
        let nestedConfigs = NestedConfigurations()
        let ancestorIncludes = AncestorIncludes()
        path.map{ nestedConfigs.paths.append($0) }

        if let path {
            ancestorIncludes.paths.append(AncestorInclude(path: path, fs: fs))
        }

        let tableRef = MacroValueAssignmentTableRef(table: table)
        let delegate = SettingsConfigFileParserDelegate(fs: fs, basePath: path?.dirname, searchPaths: searchPaths, table: tableRef, diagnostics: diagnostics, nestedConfigurations: nestedConfigs, ancestorIncludes: ancestorIncludes, developerPath: core.developerPath)
        let parser = MacroConfigFileParser(byteString: data, path: path ?? Path("no path to xcconfig file provided"), delegate: delegate)
        parser.parse()
        return MacroConfigInfo(table: tableRef.table, diagnostics: diagnostics.diagnostics, dependencyPaths: nestedConfigs.paths, signature: filesSignature(nestedConfigs.paths), isFileReadFailure: false)
    }
}

fileprivate final class MacroValueAssignmentTableRef {
    var table: MacroValueAssignmentTable

    init(table: MacroValueAssignmentTable) {
        self.table = table
    }

    var namespace: MacroNamespace {
        table.namespace
    }

    func push(_ macro: MacroDeclaration, _ value: MacroExpression, conditions: MacroConditionSet? = nil) {
        table.push(macro, value, conditions: conditions)
    }
}

/// Logic for AncestorInclude to conform to necessary protocols.
extension MacroConfigFileLoader.AncestorInclude: Equatable, Hashable {
    static func == (lhs: MacroConfigFileLoader.AncestorInclude, rhs: MacroConfigFileLoader.AncestorInclude) -> Bool {
        return lhs.resolvedPath == rhs.resolvedPath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(resolvedPath)
    }
}
