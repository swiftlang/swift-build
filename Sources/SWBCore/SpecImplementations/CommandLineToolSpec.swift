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
public import struct Foundation.Data
public import class Foundation.JSONDecoder
public import SWBMacro
import SWBProtocol

/// Describes the type and other characteristics of a single kind of input file accepted by a build tool.
struct InputFileTypeDescriptor: Encodable, Sendable {
    /// Identifier of the file type — this is unbound until the build tool is used, since the particular file type any given identifier maps to can depend on the context.
    let identifier: String
    /// FIXME: There will be others, but for now the identifier is the only one we use.
}

// MARK: Input file grouping strategies

public protocol InputFileGroupingStrategyContext: SpecLookupContext {
    var fs: any FSProxy { get }
    var productType: ProductTypeSpec? { get }
    func error(_ message: String, location: Diagnostic.Location, component: Component)
}

public protocol InputFileGroupable: RegionVariable {
    var absolutePath: Path { get }
    var regionVariantName: String? { get }
}

extension FileToBuild: InputFileGroupable { }

public protocol InputFileGroupingStrategyFactory: Sendable {
    func makeStrategy(specIdentifier: String) -> any InputFileGroupingStrategy
}

/// Defines a strategy for grouping files for tasks which process multiple files at once.
public protocol InputFileGroupingStrategy: Encodable, Sendable {
    /// Return either a grouping identifier for the file or nil to indicate that it shouldn’t be grouped in any particular way.
    func determineGroupIdentifier(groupable: any InputFileGroupable) -> String?

    /// If determineGroupIdentifier returned non-nil, that group will later be given an opportunity to subsume other ungrouped files. `groupAdditionalFiles` should observe the `target` group and `source` groups to decide which `source` groups to merge into the `target` group, and return them as a list. (Although `target` is mutable, it should not mutate `target`. TODO: Make FileToBuildGroup a struct?)
    func groupAdditionalFiles<S: Sequence>(to target: FileToBuildGroup, from source: S, context: any InputFileGroupingStrategyContext) -> [FileToBuildGroup] where S.Element == FileToBuildGroup
}

public extension InputFileGroupingStrategy {
    func determineGroupIdentifier(groupable: any InputFileGroupable) -> String? {
        return nil
    }

    func groupAdditionalFiles<S: Sequence>(to target: FileToBuildGroup, from source: S, context: any InputFileGroupingStrategyContext) -> [FileToBuildGroup] where S.Element == FileToBuildGroup {
        return []
    }
}

/// A grouping strategy that groups all files in a build phase which match a given build rule into the same group.  For example, all files to be processed by the Swift compiler in a build phase will be passed to a single invocation of the compiler.
@_spi(Testing) public final class AllInputFilesGroupingStrategy : InputFileGroupingStrategy, Encodable {

    /// Group identifier that’s returned for every path.
    let groupIdentifier: String

    @_spi(Testing) public init(groupIdentifier: String) {
        self.groupIdentifier = groupIdentifier
    }

    /// Always just returns the identifier with which the grouping strategy was initialized.
    public func determineGroupIdentifier(groupable: any InputFileGroupable) -> String? {
        return groupIdentifier
    }
}

/// A grouping strategy that groups all files in a build phase with the same filename base into a single invocation of the tool, but files with different bases will be passed to different invocations.
@_spi(Testing) public final class CommonFileBaseInputFileGroupingStrategy : InputFileGroupingStrategy {

    /// Name of the tool to which the grouping strategy belongs (used as a part of the returned group identifier).
    let toolName: String

    @_spi(Testing) public init(toolName: String) {
        self.toolName = toolName
    }

    // Returns a grouping identifier based on the tool name and the base name of the path.
    public func determineGroupIdentifier(groupable: any InputFileGroupable) -> String? {
        return "tool:\(toolName) file-base:\(groupable.absolutePath.withoutSuffix)"
    }
}

protocol DependencyInfoEditableTaskPayload: TaskPayload {
    var dependencyInfoEditPayload: DependencyInfoEditPayload? { get }
}

// MARK:


/// A class that adopts this protocol can be used to collect information for creating tasks for a given command line tool spec, e.g. information from elsewhere in the build phase or target which is not local to the input files of the task being created.
public protocol BuildPhaseInfoForToolSpec: AnyObject {
    // Certainly other parameters can be added here, or ways to collect broader information than just on individual files, but the initial implementation only covers what it was needed for.
    //
    /// Have the info object collect information from the file-to-build.
    func addToContext(_ ftb: FileToBuild)
}


/// Discovered info about a command line tool spec.
public protocol DiscoveredCommandLineToolSpecInfo: BuildOptionGenerationContext, Sendable {
}

public final class DiscoveredCommandLineToolSpecInfoCache: Sendable {
    private enum CacheKey: Hashable, Sendable {
        case filePath(Path)
        case commandLine([String])
    }

    private let cache = AsyncCache<CacheKey, any DiscoveredCommandLineToolSpecInfo>()
    private let processExecutionCache: ProcessExecutionCache

    @_spi(Testing) public init(processExecutionCache: ProcessExecutionCache) {
        self.processExecutionCache = processExecutionCache
    }

    public func run(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ toolName: String, _ path: Path, _ process: @Sendable (_ contents: Data) async throws -> any DiscoveredCommandLineToolSpecInfo) async throws -> any DiscoveredCommandLineToolSpecInfo {
        try await cache.value(forKey: .filePath(path)) {
            let fileContents = try await delegate.withActivity(ruleInfo: "ReadFileContents " + path.str, executionDescription: "Discovering version info for \(toolName)", signature: ByteString(encodingAsUTF8: "ReadFileContents \(path.str)"), target: nil, parentActivity: ActivityID.buildDescriptionActivity) { _ in
                try Data(localFS.read(path))
            }
            return try await process(fileContents)
        }
    }

    public func run(_ delegate: any CoreClientTargetDiagnosticProducingDelegate, _ toolName: String?, _ commandLine: [String], _ process: @Sendable (_ processResult: Processes.ExecutionResult) async throws -> any DiscoveredCommandLineToolSpecInfo) async throws -> any DiscoveredCommandLineToolSpecInfo {
        try await cache.value(forKey: .commandLine(commandLine)) {
            try await process(processExecutionCache.run(delegate, commandLine, executionDescription: ["Discovering version info", toolName.map { "for \($0)" } ?? commandLine.first.map { tool in "for \(Path(tool).basename)" }].compactMap { $0 }.joined(separator: " ")))
        }
    }
}

/// Returns the set of 'feature' names detailed in a 'features.json' file that a tool may install alongside its executable.
/// The format is like this:
///
///   {
///     "features": [
///       {
///         "name": "<FEATURE_NAME>"
///       },
///       <...>
///     ]
///   }
///
func rawFeaturesFromToolFeaturesJSON(path: Path, fs: any FSProxy) throws -> Set<String> {
    struct FeatureSet: Codable {
        struct Feature: Codable {
            let name: String
        }
        let features: [Feature]
    }
    return try Set(JSONDecoder().decode(FeatureSet.self, from: path, fs: fs).features.map(\.name))
}

/// Set of features from a 'features.json' file that may be installed alongside its executable, see `rawFeaturesFromToolFeaturesJSON`.
public struct ToolFeatures<T>: Sendable where T: Sendable, T: Hashable, T: CaseIterable, T: RawRepresentable, T.RawValue == String {
    public let flags: Set<T>

    public static var none: ToolFeatures {
        return ToolFeatures([])
    }

    public init(_ flags: Set<T>) {
        self.flags = flags
    }

    public init(path: Path, fs: any FSProxy) throws {
        var flags: Set<T> = []
        let raw = try rawFeaturesFromToolFeaturesJSON(path: path, fs: fs)
        for flag in T.allCases {
            if raw.contains(flag.rawValue) {
                flags.insert(flag)
            }
        }
        self.flags = flags
    }

    public func has(_ flag: T) -> Bool {
        return flags.contains(flag)
    }

    public func has(_ rawFlag: String) -> Bool {
        guard let flag = T(rawValue: rawFlag) else {
            return false
        }
        return has(flag)
    }
}

public struct ProjectVersionInfo {
    public let project: String
    public let version: Version

    init(string: String) throws {
        guard let match = try #/^(?<project>[A-Za-z0-9_]+)-(?<version>[\d\.]+)$/#.wholeMatch(in: string) else {
            throw StubError.error("Could not parse project version from string: \(string)")
        }
        self.project = String(match.output.project)
        self.version = try Version(String(match.output.version))
    }
}

public struct AppleGenericVersionInfo: Sendable {
    let program: String
    let project: String
    public let version: Version

    init(string: String) throws {
        guard let match = try #/^PROGRAM:(?<program>.+)  PROJECT:(?<project>[A-Za-z0-9_]+)-(?<version>[\d\.]+)$/#.wholeMatch(in: string) else {
            throw StubError.error("Could not parse Apple Generic Version from string: \(string)")
        }
        self.program = String(match.output.program)
        self.project = String(match.output.project)
        self.version = try Version(String(match.output.version))
    }
}

extension DiscoveredCommandLineToolSpecInfo {
    /// Parses a standard version number from a command line invocation.
    public static func parseProjectNameAndSourceVersionStyleVersionInfo<T: DiscoveredCommandLineToolSpecInfo>(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, commandLine: [String], construct: (ProjectVersionInfo) -> T) async throws -> T {
        try await producer.discoveredCommandLineToolSpecInfo(delegate, nil, commandLine) { executionResult in
            let outputString = String(decoding: executionResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return try construct(ProjectVersionInfo(string: outputString))
        }
    }

    /// Parses a standard Apple Generic Versioning style version number from the output of invoking `what -q` on a binary.
    public static func parseWhatStyleVersionInfo<T: DiscoveredCommandLineToolSpecInfo>(_ producer: any CommandProducer, _ delegate: any CoreClientTargetDiagnosticProducingDelegate, toolPath: Path, construct: (AppleGenericVersionInfo) -> T) async throws -> T {
        if !toolPath.isAbsolute {
            throw StubError.error("\(toolPath.str) is not absolute")
        }
        return try await producer.discoveredCommandLineToolSpecInfo(delegate, toolPath.basename, ["/usr/bin/what", "-q", toolPath.str]) { executionResult in
            let outputString = String(decoding: executionResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = Set(outputString.split(separator: "\n").map(String.init)) // version info is printed once per architecture slice, but we never expect them to differ
            return try construct(AppleGenericVersionInfo(string: lines.only ?? outputString))
        }
    }
}

open class CommandLineToolSpec : PropertyDomainSpec, SpecType, TaskTypeDescription, @unchecked Sendable {
    package enum CommandLineTemplateArg : Sendable {
        /// Placeholder for the dynamically computed executable path.
        //
        // FIXME: Note, this is only used by 'Ld.xcspec', there might be a simpler implementation.
        case execPath

        /// Placeholder for the first input path (there should only be one).
        ///
        /// It is an error for this placeholder to appear in a command which may receive multiple inputs.
        case input

        /// Placeholder for a list of all the input paths.
        case inputs

        /// A literal string to include.
        case literal(value: MacroStringListExpression)

        /// Placeholder for the automatic options list.
        case options

        /// Placeholder for the output path.
        case output

        /// Placeholder for the custom "special-args" subclass extension mechanism.
        case specialArgs
    }

    package enum RuleInfoTemplateArg {
        /// A literal string to include.
        case string(_ value: StaticString)

        /// Placeholder for the first input path.
        case input

        /// Placeholder for a list of all the input paths.
        case inputs

        /// A literal string to include.
        case literal(value: MacroStringListExpression)

        /// Placeholder for the each of the output paths.
        case output
    }

    class public override var typeName: String {
        return "Tool"
    }
    class public override var subregistryName: String {
        return "Tool"
    }

    /// Non-custom instances should be parsed as GenericCommandLineTool instances.
    class public override var defaultClassType: (any SpecType.Type)? {
        return GenericCommandLineToolSpec.self
    }

    /// The command line template to use when creating tasks of this type.
    ///
    /// This is only used for generic specs.
    //
    // FIXME: Factor out all the generic-only things into a mix-in.
    package let commandLineTemplate: [CommandLineTemplateArg]?

    /// The template used to form the "rule info" of the command.
    ///
    /// This is only used for generic specs.
    let ruleInfoTemplate: [RuleInfoTemplateArg]?

    /// The executable path.
    let execPath: MacroStringExpression?

    /// A macro-expandable string that provides a display description of a single invocation of the tool (e.g. “Compiling $(InputFileName)”).
    @_spi(Testing) public let execDescription: MacroStringExpression?

    /// The declared output files, if present.
    @_spi(Testing) public let outputs: [MacroStringExpression]?

    /// The additional environment variables to provide to instances of the tool.
    @_spi(Testing) public let environmentVariables: [(String, MacroStringExpression)]?

    /// The path of the additional "generated Info.plist" content, if used.
    let generatedInfoPlistContent: MacroStringExpression?

    /// The option to pass to indicate what kind of source files are being processed.
    let sourceFileOption: String?

    /// Directories which must be created prior to running this tool.
    let additionalDirectoriesToCreate: [MacroStringExpression]?

    /// The input file type descriptors.
    let inputFileTypeDescriptors: [InputFileTypeDescriptor]?

    /// Grouping strategies for input files.  Applied in order.
    let inputFileGroupingStrategies: [any InputFileGroupingStrategy]?

    /// Whether the tool's settings should be included in the unioned defaults.
    let includeInUnionedDefaults: Bool

    /// Whether the tool expects all build settings to be passed in the environment.
    let wantsBuildSettingsInEnvironment: Bool

    /// True if build rules should be synthesized from the input file type descriptors for this command line tool.
    let shouldSynthesizeBuildRules: Bool

    /// If `true`, then outputs generated by this tool spec should not be further processed by other tools.
    public let dontProcessOutputs: Bool

    /// True if this tool specification is architecture neutral, i.e. it should only be run once for a file in the Sources build phase, not once for each architecture.
    public let isArchitectureNeutral: Bool

    /// Whether the command requires that inputs be treated as directory trees (i.e., considered recursively when detecting changes).
    public let areInputsDirectoryTrees: Bool

    /// Whether the command should be considered "unsafe" to interrupt, and the build should attempt to wait for instances to complete when cancelling a build.
    //
    // See: <rdar://problem/20712615> After cancelled build, codesign fails during next build due to temporary files
    public let isUnsafeToInterrupt: Bool

    /// Specifies that downstream indexing info should use this tool's input instead of its output. This is for source preprocessors: the user specifies File.swift, it's preprocessed to File.2.swift, and then File.2.swift is compiled. Normally, we would report indexing for File.2.swift, but we actually want to index the input File.swift file in this case.
    public let swapOutputsWithInputsForIndexing: Bool

    /// True if the llbuild control channel should be disable for this tool.
    let llbuildControlDisabled: Bool

    /// True if this tool supports running during `InstallAPI`.
    open var supportsInstallAPI: Bool {
        return false
    }

    /// True if this tool supports running during `InstallHeaders`.
    open var supportsInstallHeaders: Bool {
        return false
    }

    open var enableSandboxing: Bool {
        return false
    }

    public func commandLineForSignature(for task: any ExecutableTask) -> [ByteString]? {
        return nil
    }

    static func parseCommandLineTemplate(_ parser: SpecParser, _ components: [String]) -> [CommandLineTemplateArg] {
        // Convert each component into an appropriate arg.
        var hasExecPath = false
        var hasInput = false
        var hasInputs = false
        var hasOptions = false
        var hasOutput = false
        var hasSpecialArgs = false
        return components.map { (str: String) -> CommandLineTemplateArg in
            switch str {
            case "[exec-path]":
                if hasExecPath { parser.error("duplicate 'CommandLine' template arg: '\(str)'") }
                hasExecPath = true
                return .execPath
            case "[input]":
                if hasInputs { parser.error("invalid 'CommandLine' template: cannot use both '[input]' and '[inputs]'") }
                if hasInput { parser.error("duplicate 'CommandLine' template arg: '\(str)'") }
                hasInput = true
                return .input
            case "[inputs]":
                if hasInput { parser.error("invalid 'CommandLine' template: cannot use both '[input]' and '[inputs]'") }
                if hasInputs { parser.error("duplicate 'CommandLine' template arg: '\(str)'") }
                hasInputs = true
                return .inputs
            case "[options]":
                if hasOptions { parser.error("duplicate 'CommandLine' template arg: '\(str)'") }
                hasOptions = true
                return .options
            case "[output]":
                if hasOutput { parser.error("duplicate 'CommandLine' template arg: '\(str)'") }
                hasOutput = true
                return .output
            case "[special-args]":
                if hasSpecialArgs { parser.error("duplicate 'CommandLine' template arg: '\(str)'") }
                hasSpecialArgs = true
                return .specialArgs
            case let str where str.hasPrefix("[") && str.hasSuffix("]"):
                parser.error("invalid 'CommandLine' template placeholder arg: '\(str)'")
                return .literal(value: parser.delegate.internalMacroNamespace.parseLiteralStringList([str]))
            default:
                return .literal(value: parser.delegate.internalMacroNamespace.parseStringList(str) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error in 'CommandLine' template")
                    })
            }
        }
    }

    static func parseRuleInfoTemplate(_ parser: SpecParser, _ components: [String]) -> [RuleInfoTemplateArg] {
        // Convert each component into an appropriate arg.
        var hasInput = false
        var hasOutput = false
        return components.map { (str: String) -> RuleInfoTemplateArg in
            switch str {
            case "[input]":
                if hasInput { parser.error("duplicate 'RuleName' template arg: '\(str)'") }
                hasInput = true
                return .input
            case "[output]":
                if hasOutput { parser.error("duplicate 'RuleName' template arg: '\(str)'") }
                hasOutput = true
                return .output
            case let str where str.hasPrefix("[") && str.hasSuffix("]"):
                parser.error("invalid 'RuleName' template placeholder arg: '\(str)'")
                return .literal(value: parser.delegate.internalMacroNamespace.parseLiteralStringList([str]))
            default:
                return .literal(value: parser.delegate.internalMacroNamespace.parseStringList(str) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error in 'RuleName' template")
                    })
            }
        }
    }

    public init(_ parser: SpecParser, _ basedOnSpec: Spec?, isGeneric: Bool) {
        // Parse the execution description, which is a macro-expandable display description of a single invocation of the tool.
        if let execDescString = parser.parseString("ExecDescription") {
            self.execDescription = parser.delegate.internalMacroNamespace.parseString(execDescString)
        }
        else {
            self.execDescription = nil
        }

        // Parse the keys used by generic command line tools.
        if isGeneric {
            // Parse the command line template.
            if let commandLine = parser.parseCommandLineString("CommandLine", inherited: false) {
                self.commandLineTemplate = CommandLineToolSpec.parseCommandLineTemplate(parser, commandLine)
            } else if let inherited = (basedOnSpec as? CommandLineToolSpec)?.commandLineTemplate {
                self.commandLineTemplate = inherited
            } else {
                parser.error("missing required 'CommandLine' key")
                self.commandLineTemplate = nil
            }

            // Parse the rule info template.
            if let ruleName = parser.parseCommandLineString("RuleName", inherited: false) {
                self.ruleInfoTemplate = CommandLineToolSpec.parseRuleInfoTemplate(parser, ruleName)
            } else if let inherited = (basedOnSpec as? CommandLineToolSpec)?.ruleInfoTemplate {
                self.ruleInfoTemplate = inherited
            } else {
                parser.error("missing required 'RuleName' key")
                self.ruleInfoTemplate = []
            }

            // Parse the declared outputs.
            if let outputs = parser.parseStringList("Outputs", inherited: false) {
                self.outputs = outputs.map {
                    return parser.delegate.internalMacroNamespace.parseString($0) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error in 'Outputs'")
                    }
                }
            } else if let outputPath = parser.parseString("OutputPath", inherited: false) {
                let parsedOutputPath = parser.delegate.internalMacroNamespace.parseString(outputPath) { diag in
                    parser.handleMacroDiagnostic(diag, "macro parsing error in 'OutputPath'")
                }
                self.outputs = [parsedOutputPath]
            } else if let inherited = (basedOnSpec as? CommandLineToolSpec)?.outputs {
                self.outputs = inherited
            } else {
                // If the tool defined no outputs then force the definition of one using $(OutputPath). This corresponds to the effective behavior of Xcode, which would implicitly create the output node when the spec asked for [output].
                //
                // FIXME: Force the specs to define this, instead of synthesizing it: <rdar://problem/24544779> [Swift Build] Stop synthesizing Outputs for generic command line tools
                self.outputs = [parser.delegate.internalMacroNamespace.parseString("$(OutputPath)")]
            }
        } else {
            self.commandLineTemplate = nil
            self.ruleInfoTemplate = nil
            self.outputs = nil
        }

        // Parse the executable path.
        //
        // FIXME: This isn't used by most non-generic tools, but it probably makes sense to refactor them *to* use it rather than the other direction, for consistency.
        if let execPath = parser.parseString("ExecPath") {
            self.execPath = parser.delegate.internalMacroNamespace.parseString(execPath) { diag in
                parser.handleMacroDiagnostic(diag, "macro parsing error in 'ExecPath'")
            }
        } else {
            switch commandLineTemplate {
            case .some(let items) where items.count > 0:
                switch items[0] {
                case .literal(let arg):
                    self.execPath = parser.delegate.internalMacroNamespace.parseString(arg.stringRep)
                default:
                    self.execPath = nil
                }
            default:
                self.execPath = nil
            }
        }

        // Parse the environment variables.
        //
        // FIXME: This is supported for all specs, but the Codesign spec is the only non-generic tool which uses it. We should probably change it to be generic only.
        if let envVariables = parser.parseObject("EnvironmentVariables", inherited: false) {
            if case .plDict(let items) = envVariables {
                var variables: [(String, MacroStringExpression)] = []
                for (key,valueData) in items.sorted(by: \.0) {
                    guard case .plString(let value) = valueData else {
                        parser.error("invalid value for '\(key)' key in 'EnvironmentVariables' (expected string)")
                        continue
                    }
                    variables.append((key, parser.delegate.internalMacroNamespace.parseString(value) { diag in
                        parser.handleMacroDiagnostic(diag, "macro parsing error in 'EnvironmentVariables' for key '\(key)'")
                    }))
                }
                self.environmentVariables = variables
            } else {
                parser.error("invalid value for 'EnvironmentVariables' key (expected dictionary)")
                self.environmentVariables = nil
            }
        } else if let inherited = (basedOnSpec as? CommandLineToolSpec)?.environmentVariables {
            self.environmentVariables = inherited
        } else {
            self.environmentVariables = nil
        }

        self.includeInUnionedDefaults = parser.parseBool("IncludeInUnionedToolDefaults") ?? true
        self.wantsBuildSettingsInEnvironment = parser.parseBool("WantsBuildSettingsInEnvironment") ?? false
        self.generatedInfoPlistContent = parser.parseMacroString("GeneratedInfoPlistContentFilePath")

        self.sourceFileOption = parser.parseString("SourceFileOption")

        if let additionalDirectoriesToCreate = parser.parseStringList("AdditionalDirectoriesToCreate") {
            self.additionalDirectoriesToCreate = additionalDirectoriesToCreate.map({ parser.delegate.internalMacroNamespace.parseString($0) })
        }
        else {
            self.additionalDirectoriesToCreate = nil
        }

        // Parse the input file type descriptors.
        // FIXME: "InputFileTypes" is the preferred key here, but a few older specs use "FileTypes".  We should unify these, probably by removing support for "FileTypes".  In particular, no spec should define both keys.
        self.inputFileTypeDescriptors = {
            // Block to process an input file type into a descriptor.
            let processInputFileType = {
                // At the moment we are given a PLDict and just unwrap its payload. What we should really do is to get an instantiated SpecParser for the dictionary.  Right now, SpecParser seems to assume that it always gets the full SpecProxy — it should be a per-dictionary thing, as in Xcode, allowing for the same support for parsing of dictionary keys at any level of the structure.
                (dict: PropertyListItem) -> (InputFileTypeDescriptor?) in
                guard case .plDict(let dict) = dict else { return nil }
                let ident = dict["FileType"]!
                guard case .plString(let identString) = ident else { return nil }
                return InputFileTypeDescriptor(identifier: identString)
            }
            if let inputFileTypeDescriptors = parser.parseArrayOfDicts("InputFileTypes", required: true, allowUnarrayedElement: true, impliedElementKey: "FileType", block: processInputFileType) {
                return inputFileTypeDescriptors
            }
            return parser.parseArrayOfDicts("FileTypes", required: true, allowUnarrayedElement: true, impliedElementKey: "FileType", block: processInputFileType)
        }()

        // Make a note of whether or not we should synthesize build rules for this command line tool.
        // 'SynthesizeBuildRuleForBuildPhases' is only used by the AppleScript (OSA) compiler and is no longer supported in its original form.
        self.shouldSynthesizeBuildRules = parser.parseBool("SynthesizeBuildRule") ?? !(parser.parseStringList("SynthesizeBuildRuleForBuildPhases") ?? []).isEmpty
        if let groupings = parser.parseStringList("InputFileGroupings") {
            var groupingStrategies = Array<any InputFileGroupingStrategy>()
            for grouping in groupings {
                // We should really have something more extensible here, but for now this will do.
                switch grouping {
                case "tool":  groupingStrategies.append(AllInputFilesGroupingStrategy(groupIdentifier: parser.proxy.data["Identifier"]!.description))
                case "common-file-base": groupingStrategies.append(CommonFileBaseInputFileGroupingStrategy(toolName: parser.proxy.data["Identifier"]!.description))
                default:
                    if let strategy = parser.delegate.groupingStrategy(name: grouping, specIdentifier: parser.proxy.data["Identifier"]!.description) {
                        groupingStrategies.append(strategy)
                    } else {
                        parser.error("unknown grouping strategy: \(grouping)")
                    }
                }
            }
            self.inputFileGroupingStrategies = groupingStrategies
        }
        else {
            self.inputFileGroupingStrategies = nil
        }

        self.dontProcessOutputs = parser.parseBool("DontProcessOutputs") ?? false

        self.isArchitectureNeutral = parser.parseBool("IsArchitectureNeutral") ?? false

        self.areInputsDirectoryTrees = parser.parseBool("DeeplyStatInputDirectories") ?? false

        self.isUnsafeToInterrupt = parser.parseBool("IsUnsafeToInterrupt") ?? false
        self.swapOutputsWithInputsForIndexing = parser.parseBool("SwapOutputsWithInputsForIndexing") ?? false

        self.llbuildControlDisabled = parser.parseBool("LLBuildControlDisabled") ?? true

        // Parse and ignore keys we have no use for.
        //
        // FIXME: Eliminate any of these fields which are unused.
        parser.parseStringList("AdditionalFilesToClean")
        parser.parseString("AdditionalInputFiles") // FIXME: This should be a string list.
        parser.parseBool("CaresAboutInclusionDependencies")
        parser.parseString("CommandIdentifier")
        parser.parseObject("CommandOutputParser")
        parser.parseObject("CommandResultsPostprocessor")
        parser.parseBool("DashIFlagAcceptsHeadermaps")
        parser.parseString("ExecCPlusPlusLinkerPath")
        parser.parseString("ExecDescriptionForCompile")
        parser.parseString("ExecDescriptionForCreateBitcode")
        // FIXME: This key is unused in Swift Build.
        parser.parseString("ExecDescriptionForPrecompile")
        parser.parseString("ExecutionDescription")
        parser.parseStringList("FallbackTools")
        parser.parseString("GenericCommandFailedErrorString")
        parser.parseStringList("InputTypes")
        parser.parseBool("IsNoLongerSupported")
        parser.parseStringList("MessageCategoryInfoOptions")
        parser.parseStringList("MessageInfoCategory")
        parser.parseString("MessageLimit")
        parser.parseBool("MightNotEmitAllOutputs")
        parser.parseString("OutputDir")
        parser.parseString("OutputFileExtension")
        parser.parseBool("OutputsAreProducts")
        parser.parseBool("OutputsAreSourceFiles")
        parser.parseBool("OutputsAreTargets")
        parser.parseObject("OverridingProperties")
        parser.parseStringList("PatternsOfFlagsNotAffectingOutputFile")
        parser.parseString("PrecompStyle")
        parser.parseString("ProgressDescriptionForCompile")
        parser.parseString("ProgressDescriptionForCreateBitcode")
        // FIXME: This key is unused in Swift Build.
        parser.parseString("ProgressDescription")
        parser.parseString("ProgressDescriptionForPrecompile")
        parser.parseString("PrunePrecompiledHeaderCache")
        // This key is used by the build settings editor but is not used by Swift Build.
        parser.parseStringList("RelatedDisplaySpecifications")
        parser.parseStringList("RequiredComponents")
        parser.parseString("RuleFormat")
        parser.parseBool("ShouldRerunOnError")
        parser.parseBool("ShowInCompilerSelectionPopup")
        parser.parseBool("SoftError")
        parser.parseStringList("SuccessExitCodes")
        parser.parseBool("SupportsAnalyzeFile")
        parser.parseBool("SupportsColoredDiagnostics")
        parser.parseBool("SupportsGenerateAssemblyFile")
        parser.parseBool("SupportsGeneratePreprocessedFile")
        parser.parseBool("SupportsHeadermaps")
        parser.parseBool("SupportsIsysroot")
        parser.parseBool("SupportsMacOSXDeploymentTarget")
        parser.parseBool("SupportsMacOSXMinVersionFlag")
        parser.parseBool("SupportsPredictiveCompilation")
        parser.parseBool("SupportsSeparateUserHeaderPaths")
        parser.parseBool("SupportsSerializedDiagnostics")
        parser.parseBool("SupportsSymbolSeparation")
        parser.parseBool("UseCPlusPlusCompilerDriverWhenBundlizing")

        super.init(parser, basedOnSpec)
    }

    /// Construct a command line tool specification explicitly.
    package init(_ registry: SpecRegistry, _ proxy: SpecProxy, execDescription: MacroStringExpression? = nil, ruleInfoTemplate: [RuleInfoTemplateArg], commandLineTemplate: [CommandLineTemplateArg]) {
        self.execDescription = execDescription
        self.ruleInfoTemplate = ruleInfoTemplate
        self.commandLineTemplate = commandLineTemplate
        self.outputs = nil
        self.execPath = nil
        self.environmentVariables = nil
        self.includeInUnionedDefaults = false
        self.wantsBuildSettingsInEnvironment = false
        self.generatedInfoPlistContent = nil
        self.sourceFileOption = nil
        self.additionalDirectoriesToCreate = nil
        self.inputFileTypeDescriptors = nil
        self.shouldSynthesizeBuildRules = false
        self.inputFileGroupingStrategies = nil
        self.dontProcessOutputs = false
        self.isArchitectureNeutral = false
        self.areInputsDirectoryTrees = false
        self.isUnsafeToInterrupt = false
        self.swapOutputsWithInputsForIndexing = false
        self.llbuildControlDisabled = true

        super.init(registry, proxy)
    }

    convenience required public init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        self.init(parser, basedOnSpec, isGeneric: false)
    }

    /// Resolve the concrete specification to use for construction in the given context.
    ///
    /// This may be overridden by subclasses to support specs which can dispatch to alternate implementations based on the context.
    public func resolveConcreteSpec(_ cbc: CommandBuildContext) -> CommandLineToolSpec {
        return self
    }

    /// Creates and returns a new build phase info instance for this spec, or nil if this spec doesn't support creating them.
    open func newBuildPhaseInfo() -> (any BuildPhaseInfoForToolSpec)? {
        return nil
    }

    /// Returns the discovered info for the tool spec for the given producer and scope.  If this tool spec doesn't provide discovered info, or if no info for the parameters can be determined, then returns nil.
    open func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        return nil
    }

    /// Returns an alternate file type spec for the given input file.
    ///
    /// This is used by the C/C++ compiler specs to allow build settings like
    /// `GCC_INPUT_FILETYPE`, build-file-specific flags, and `-x` options in
    /// `OTHER_CFLAGS` / `OTHER_CPLUSPLUSFLAGS` to change the "effective"
    /// type of C/C++/ObjC source files, i.e. files whose interpretation is
    /// overridden to differ from their implied type based on the file extension.
    public func resolvedSourceFileType(file: FileToBuild, inBuildContext cbc: CommandBuildContext, delegate: any TaskGenerationDelegate) -> FileTypeSpec {
        return file.fileType
    }

    public func dependencyData(overrideDependencyData dependencyData: DependencyDataStyle? = nil, cbc: CommandBuildContext, delegate: any TaskGenerationDelegate, outputs: inout [any PlannedNode]) async -> DependencyDataStyle? {
        if let dependencyData {
            return dependencyData
        }

        var dependencyFiles: [DependencyDataFormat: [Path]] = [:]
        let producer = cbc.producer
        let scope = cbc.scope
        let inputFileType = cbc.inputs.first?.fileType
        let lookup = { self.lookup($0, cbc, delegate) }
        for buildOption in self.flattenedOrderedBuildOptions {
            guard let dependencyFormat = buildOption.dependencyFormat else {
                continue
            }

            let toolInfo = await discoveredCommandLineToolSpecInfo(producer, scope, delegate)

            // Check if the effective arguments for this build option were non-empty as a proxy for whether it got filtered out by architecture mismatch, etc.
            let isActive = !buildOption.getArgumentsForCommand(producer, scope: scope, inputFileType: inputFileType, optionContext: toolInfo, lookup: lookup).isEmpty

            switch buildOption.macro {
            case let decl as StringMacroDeclaration:
                if isActive, let value = cbc.scope.evaluate(decl, lookup: lookup).nilIfEmpty {
                    dependencyFiles[dependencyFormat, default: []].append(Path(value).normalize())
                }
            case let decl as StringListMacroDeclaration:
                if isActive, let values = cbc.scope.evaluate(decl, lookup: lookup).nilIfEmpty {
                    dependencyFiles[dependencyFormat, default: []].append(contentsOf: values.map { Path($0).normalize() })
                }
            case let decl as PathMacroDeclaration:
                if isActive, let value = cbc.scope.evaluate(decl, lookup: lookup).nilIfEmpty {
                    dependencyFiles[dependencyFormat, default: []].append(value)
                }
            case let decl as PathListMacroDeclaration:
                if isActive, let values = cbc.scope.evaluate(decl, lookup: lookup).nilIfEmpty {
                    dependencyFiles[dependencyFormat, default: []].append(contentsOf: values.map { Path($0).normalize() })
                }
            default:
                delegate.error("DependencyDataFormat is only allowed on build options of type String, StringList, Path, or PathList")
            }
        }

        if let only = dependencyFiles.only {
            switch only.key {
            case .dependencyInfo:
                if let onlyPath = only.value.only {
                    outputs.append(delegate.createNode(onlyPath))
                    return .dependencyInfo(onlyPath)
                } else {
                    assert(!only.value.isEmpty) // shouldn't be possible to get an empty array here
                    delegate.error("Multiple build options specified dependency info in ld64 format")
                }
            case .makefile:
                if let onlyPath = only.value.only {
                    outputs.append(delegate.createNode(onlyPath))
                    return .makefile(onlyPath)
                } else {
                    assert(!only.value.isEmpty) // shouldn't be possible to get an empty array here
                    outputs.append(contentsOf: only.value.map(delegate.createNode))
                    return .makefiles(only.value)
                }
            }
        } else if !dependencyFiles.isEmpty {
            delegate.error("Multiple build options specified dependency info in different formats")
        }

        return nil
    }

    /// Constructs the "rule info" and command line arguments for a task, and then instructs the task generation delegate to create the task with that information.
    open func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        await constructTasks(cbc, delegate, specialArgs: [])
    }

    /// Constructs the "rule info" and command line arguments for a task, and then instructs the task generation delegate to create the task with that information.
    public final func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, specialArgs: [String], dependencyData: DependencyDataStyle? = nil, payload: (any TaskPayload)? = nil, commandLine: [String]? = nil, additionalTaskOrderingOptions: TaskOrderingOptions = [], toolLookup: ((MacroDeclaration) -> MacroExpression?)? = nil) async {
        // Compute the output paths, if defined.
        //
        // FIXME: This is messy, and confusing: the tricky thing going on here is that we have two different ways in which output paths are defined. For generic specs, they define their outputs using a key in the spec. For non-generic specs, they usually define their outputs manually *or* they use the defined output path which is provided via the CBC from some phases.
        //
        // The generic specs can connect up to the CBC provided output path using the OutputPath macro. Most of them do this, but there are a few that do not.
        //
        // The end result of all of this is that it is quite confusing exactly where the output path is coming from. We need to clean this up, it is tracked by: <rdar://problem/24544651> [Swift Build] Improve definition of task output paths w/ specs and the CommandBuildContext
        let evaluatedOutputs = self.evaluatedOutputs(cbc, delegate)

        // Define custom lookup function to handling resolving OutputPath to the first defined output, if present. Otherwise, it will ultimately use the definition based on the CommandBuildContext.
        func lookup(_ macro: MacroDeclaration) -> MacroExpression? {
            // If we were passed a lookup block by our caller - most likely a concrete subclass - then look up the macro with it, and return the expr it gives us if it's non-nil.
            if let toolExpr = toolLookup?(macro) {
                return toolExpr
            }
            // Otherwise use built-in behavior.
            if macro == BuiltinMacros.OutputPath, let output = evaluatedOutputs?.first {
                return cbc.scope.table.namespace.parseLiteralString(output.path.str)
            }

            return nil
        }

        // Compute and declare the outputs.
        var outputs: [any PlannedNode] = evaluatedOutputs ?? []

        let dependencyData = await self.dependencyData(overrideDependencyData: dependencyData, cbc: cbc, delegate: delegate, outputs: &outputs)

        // Create the task rule info by expanding the template.
        let ruleInfo = defaultRuleInfo(cbc, delegate, lookup: lookup)

        let optionContext = await discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)

        // Compute the command line arguments from the template.
        let commandLine = commandLine ?? commandLineFromTemplate(cbc, delegate, optionContext: optionContext, specialArgs: specialArgs, lookup: lookup).map(\.asString)

        // Compute the environment variables to set.
        var environment: [(String, String)] = environmentFromSpec(cbc, delegate, lookup: lookup)

        // Honor the flag to push all build settings via the environment.
        //
        // FIXME: This is inefficient and not a good mechanism: <rdar://problem/24644061> [Swift Build] Move plug-in compiler off WantsBuildSettingsInEnvironment
        if wantsBuildSettingsInEnvironment {
            for macro in cbc.scope.table.valueAssignments.keys {
                environment.append((macro.name, cbc.scope.evaluateAsString(macro, lookup: lookup)))
            }
        }

        let indexingInputReplacement: Path?
        if swapOutputsWithInputsForIndexing {
            if let input = cbc.inputs.only, outputs.count == 1 {
                indexingInputReplacement = input.absolutePath
            }
            else {
                delegate.warning("SwapOutputsWithInputsForIndexing is enabled, but there were \(cbc.inputs.count) inputs and \(outputs.count) outputs (expected 1 and 1)")
                indexingInputReplacement = nil
            }
        }
        else {
            indexingInputReplacement = nil
        }

        for output in outputs {
            delegate.declareOutput(FileToBuild(absolutePath: output.path, inferringTypeUsing: cbc.producer, indexingInputReplacement: indexingInputReplacement))
        }

        // Add the additional outputs defined by the spec.  These are not declared as outputs but should be processed by the tool separately.
        let additionalEvaluatedOutputsResult = await additionalEvaluatedOutputs(cbc, delegate)
        outputs.append(contentsOf: additionalEvaluatedOutputsResult.outputs.map({ delegate.createNode($0) }))

        if let infoPlistContent = additionalEvaluatedOutputsResult.generatedInfoPlistContent {
            delegate.declareGeneratedInfoPlistContent(infoPlistContent)
        }

        // Compute the task's execution description.
        let executionDescription = resolveExecutionDescription(cbc, delegate, lookup: lookup)

        // Create the inputs.
        var inputs: [any PlannedNode] = cbc.inputs.flatMap{ input -> [any PlannedNode] in
            if areInputsDirectoryTrees {
                return [delegate.createDirectoryTreeNode(input.absolutePath),
                        delegate.createNode(input.absolutePath)] as [any PlannedNode]
            } else {
                return [delegate.createNode(input.absolutePath)] as [any PlannedNode]
            }
        }

        if let encryptionKeyFile = commandLine.elementAfterElement("--encrypt") {
            inputs.append(delegate.createNode(Path(encryptionKeyFile)))
        }

        // Handle the ordering nodes from the command build context.  There are typically virtual nodes used to enforce ordering of commands operating on the same output path.
        inputs.append(contentsOf: cbc.commandOrderingInputs)
        outputs.append(contentsOf: cbc.commandOrderingOutputs)

        await inputs.append(contentsOf: additionalInputDependencies(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(delegate.createNode))

        delegate.createTask(
            type: self, dependencyData: dependencyData, payload: payload,
            ruleInfo: ruleInfo, commandLine: commandLine,
            environment: EnvironmentBindings(environment),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: inputs, outputs: outputs, mustPrecede: [],
            action: createTaskAction(cbc, delegate),
            execDescription: executionDescription,
            preparesForIndexing: cbc.preparesForIndexing,
            enableSandboxing: enableSandboxing,
            llbuildControlDisabled: llbuildControlDisabled,
            additionalTaskOrderingOptions: additionalTaskOrderingOptions
        )
    }

    open func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        nil
    }

    @_disfavoredOverload open func evaluatedOutputs(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate) -> [(path: Path, isDirectory: Bool)]? {
        return self.outputs?.map {
            let pathString = cbc.scope.evaluate($0, lookup: { return self.lookup($0, cbc, delegate) })
            return (Path(pathString).normalize(), pathString.hasSuffix("/"))
        }
    }

    public final func evaluatedOutputs(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> [any PlannedNode]? {
        evaluatedOutputs(cbc, delegate)?.map { path, isDirectory -> any PlannedNode in
            isDirectory ? delegate.createDirectoryTreeNode(path) : delegate.createNode(path)
        }
    }

    public struct AdditionalEvaluatedOutputsResult {
        public var outputs = [Path]()
        public var generatedInfoPlistContent: Path? = nil
    }

    public func additionalEvaluatedOutputs(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async -> AdditionalEvaluatedOutputsResult {
        var result = AdditionalEvaluatedOutputsResult()

        // Add the additional plist content options.
        if let expr = generatedInfoPlistContent {
            // We provide the full lookup context here, which is used by IBCompiler, for example.
            let output = Path(cbc.scope.evaluate(expr, lookup: { return self.lookup($0, cbc, delegate) })).normalize()

            result.generatedInfoPlistContent = output

            // FIXME: In Xcode, this is also marked as an "auxiliary output", which we use in conjunction with the "MightNotEmitAllOutput" flag to determine whether or not the tool needs to rerun if the output is missing.

            result.outputs.append(output)
        }

        let producer = cbc.producer
        let scope = cbc.scope
        let inputFileType = cbc.inputs.first?.fileType
        let lookup = { self.lookup($0, cbc, delegate) }
        let optionContext = await discoveredCommandLineToolSpecInfo(producer, scope, delegate)
        result.outputs.append(contentsOf: self.flattenedOrderedBuildOptions.flatMap { buildOption -> [Path] in
            // Check if the effective arguments for this build option were non-empty as a proxy for whether it got filtered out by architecture mismatch, etc.
            guard let outputDependencies = buildOption.outputDependencies, !buildOption.getArgumentsForCommand(producer, scope: scope, inputFileType: inputFileType, optionContext: optionContext, lookup: lookup).isEmpty else {
                return []
            }
            return outputDependencies.compactMap { Path(scope.evaluate($0, lookup: lookup)).nilIfEmpty?.normalize() }
        })

        return result
    }

    /// Returns the list of evaluated paths of directories which must be created prior to the tool being run, if any.
    ///
    /// Presently only actool uses this, so it's not hooked up as a general-purpose property.
    public final func evaluatedRequiredDirectories(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [Path]? {
        guard let unevaluatedDirs = additionalDirectoriesToCreate else { return nil }

        return unevaluatedDirs.map({ Path(cbc.scope.evaluate($0, lookup: { return self.lookup($0, cbc, delegate, lookup) })).normalize() })
    }

    /// This method is invoked whenever rule info or command line construction methods evaluate a macro, to provide values specific to the command build context for those operations.
    /// Subclasses may override this method if they have domain-specific values they wish to define.
    /// - parameter lookup: An optional closure which will override even the values defined here.
    open func lookup(_ macro: MacroDeclaration, _ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, _ lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> MacroExpression? {
        // If we were passed a lookup closure, use that first.
        if let result = lookup?(macro) {
            return result
        }

        func first<T, U>(collection: (CommandBuildContext) -> [T], description: String, _ predicate: (T) -> U, behavior: Diagnostic.Behavior?) -> U? {
            guard let first = collection(cbc).first else {
                if let behavior = behavior {
                    delegate.emit(Diagnostic(behavior: behavior, location: .unknown, data: DiagnosticData("Unexpected use of \(macro.name) in a task with no \(description)s in spec \(self.identifier).", component: .parseIssue)))
                }
                return nil
            }
            return predicate(first)
        }

        func firstInput<T>(_ predicate: (FileToBuild) -> T, behavior: Diagnostic.Behavior = .error) -> T? {
            return first(collection: \.inputs, description: "input", predicate, behavior: behavior)
        }

        func firstOutput<T>(_ predicate: (Path) -> T, behavior: Diagnostic.Behavior = .error) -> T? {
            return first(collection: \.outputs, description: "output", predicate, behavior: behavior)
        }

        let namespace = cbc.scope.table.namespace

        // If we weren't passed a lookup closure, or calling it returned nil, then use this default set of lookups.
        switch macro {
        case BuiltinMacros.DerivedFilesDir:
            return Static { BuiltinMacros.namespace.parseString("$(DERIVED_SOURCES_DIR)") }
        case BuiltinMacros.InputFile,  BuiltinMacros.InputFilePath, BuiltinMacros.InputPath:
            return namespace.parseLiteralString(firstInput(\.absolutePath.str) ?? "")
        case BuiltinMacros.InputFileDir:
            return namespace.parseLiteralString(firstInput(\.absolutePath.dirname.str) ?? "")
        case BuiltinMacros.InputFileName:
            return namespace.parseLiteralString(firstInput(\.absolutePath.basename) ?? "")
        case BuiltinMacros.InputFileBase:
            return namespace.parseLiteralString(firstInput(\.absolutePath.basenameWithoutSuffix) ?? "")
        case BuiltinMacros.InputFileRegionPathComponent:
            return namespace.parseLiteralString(firstInput(\.regionVariantPathComponent) ?? "")
        case BuiltinMacros.InputFileRelativePath:
            // FIXME: Implement properly. rdar://problem/58833499
            return namespace.parseLiteralString(firstInput(\.absolutePath.str) ?? "")
        case BuiltinMacros.InputFileSuffix:
            return namespace.parseLiteralString(firstInput(\.absolutePath.fileSuffix) ?? "")
        case BuiltinMacros.InputFileTextEncoding:
            guard let first = firstInput({ $0 }) else {
                return namespace.parseLiteralString("")
            }

            if case .reference(let guid)? = first.buildFile?.buildableItem {
                var ref = cbc.producer.lookupReference(for: guid)
                func matchesPath(_ ref: Reference) -> Bool {
                    return cbc.producer.filePathResolver.resolveAbsolutePath(ref) == first.absolutePath
                }
                // Deconstruct variant groups.
                //
                // FIXME: Maybe we should be able to use the workspace method for this here?
                if let group = ref as? VariantGroup {
                    ref = group.children.first(where: matchesPath)
                }
                if let group = ref as? VersionGroup {
                    ref = group.children.first(where: matchesPath)
                }
                if let fileRef = ref as? FileReference {
                    return namespace.parseLiteralString(fileRef.fileTextEncoding?.rawValue ?? "")
                }
            }
            return namespace.parseLiteralString("")
        case BuiltinMacros.OutputFileBase:
            return namespace.parseLiteralString(firstOutput(\.basenameWithoutSuffix) ?? "")
        case BuiltinMacros.OutputPath, BuiltinMacros.OutputFile:
            return namespace.parseLiteralString(firstOutput(\.str) ?? "")
        case BuiltinMacros.OutputRelativePath:
            // Use a recursive call here instead of firstOutput(\.self) to respect OutputPath overrides from clients.
            if let path = self.lookup(BuiltinMacros.OutputPath, cbc, delegate, lookup)?.asLiteralString.map(Path.init) {
                for possibleAncestorMacro in [BuiltinMacros.TARGET_BUILD_DIR, BuiltinMacros.CONFIGURATION_BUILD_DIR, BuiltinMacros.BUILT_PRODUCTS_DIR, BuiltinMacros.SYMROOT, BuiltinMacros.OBJROOT, BuiltinMacros.DERIVED_DATA_DIR] {
                    let possibleAncestor = cbc.scope.evaluate(possibleAncestorMacro)
                    if let relativePath = path.relativeSubpath(from: possibleAncestor) {
                        var description = "$(\(possibleAncestorMacro.name))"
                        if !relativePath.isEmpty {
                            description.append(contentsOf: "/\(relativePath)")
                        }
                        return namespace.parseLiteralString(description, allowSubstitutionPrefix: true)
                    }
                }
                return namespace.parseLiteralString(path.str)
            }
            return namespace.parseLiteralString(firstOutput(\.str) ?? "")
        case BuiltinMacros.ProductResourcesDir:
            return namespace.parseLiteralString(cbc.resourcesDir?.str ?? "")
        case BuiltinMacros.TempResourcesDir:
            return namespace.parseLiteralString(cbc.tmpResourcesDir?.str ?? "")
        case BuiltinMacros.UnlocalizedProductResourcesDir:
            return namespace.parseLiteralString(cbc.unlocalizedResourcesDir?.str ?? "")
        case BuiltinMacros.build_file_compiler_flags:
            return firstInput(\.additionalArgs)?.flatMap({ $0 }) ?? namespace.parseLiteralStringList([])
        default:
            return nil
        }
    }

    /// Creates and returns the default rule info array for the command build context.
    /// - parameter lookup: An optional closure which functionally defined overriding values during build setting evaluation.
    public func defaultRuleInfo(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [String] {
        guard let ruleInfoTemplate else {
            // Non-generic compiler specs must override this method.
            fatalError("missing \(#function) implementation for \(type(of: self))")
        }

        return ruleInfoTemplate.flatMap { arg -> [String] in
            switch arg {
            case let .string(s):
                return [s.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }]
            case .input:
                return [cbc.inputs.first?.absolutePath.str ?? ""]
            case .inputs:
                return cbc.inputs.map { $0.absolutePath.str }
            case .output:
                // We always resolve the Output via a recursive macro evaluation. See constructTasks() for more information.
                return [cbc.scope.evaluate(BuiltinMacros.OutputPath, lookup: { return self.lookup($0, cbc, delegate, lookup) } )]
            case .literal(let expr):
                return cbc.scope.evaluate(expr, lookup: { return self.lookup($0, cbc, delegate, lookup) } )
            }
        }
    }

    /// Resolve an executable path or name to an absolute path.
    public func resolveExecutablePath(_ producer: any CommandProducer, _ path: Path) -> Path {
        return producer.executableSearchPaths.lookup(path) ?? path
    }

    /// Resolve an executable path or name to an absolute path.
    open func resolveExecutablePath(_ cbc: CommandBuildContext, _ path: Path) -> Path {
        return resolveExecutablePath(cbc.producer, path)
    }

    /// Compute the executable path to use for the given context.
    ///
    /// This method is only ever invoked if the spec uses the '[exec-path]' command line template feature **and** it provides no "ExecPath" key.
    open func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        fatalError("subclass responsibility")
    }

    /// Used for the result of `resolveExecutionDescription()` when no execution description is available.
    public static let fallbackExecutionDescription: String = "Processing…"

    /// Resolve the execution description to use for the given context.
    public func resolveExecutionDescription(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        guard let execDescription else {
            // FIXME: We should either require an execution description, or make up a better fallback description.
            return Self.fallbackExecutionDescription
        }
        return archSpecificExecutionDescription(execDescription, cbc, delegate, lookup: lookup)
    }

    // Returns an architecture specific execution description for a given expression. Use this to override self.execDescription.
    public func archSpecificExecutionDescription(_ execDescription: MacroStringExpression, _ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        var executionDescription = cbc.scope.evaluate(execDescription, lookup: { return self.lookup($0, cbc, delegate, lookup) })
        if !self.isArchitectureNeutral, let currentArch = cbc.scope.evaluate(BuiltinMacros.CURRENT_ARCH).nilIfEmpty, currentArch != "undefined_arch" {
            // If we're in a context with a defined current architecture, then append it to the description so users can more easily disambiguate between tasks that are replicated across multiple architectures.
            executionDescription = executionDescription + " (\(currentArch))"
        }
        return executionDescription
    }

    open func commandLineFromTemplate(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, optionContext: (any DiscoveredCommandLineToolSpecInfo)?, specialArgs: [String] = [], lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [CommandLineArgument] {
        return commandLineArgumentsFromTemplate(cbc, delegate, optionContext: optionContext, specialArgs: specialArgs, lookup: lookup)
    }

    /// Creates and returns the command line from the template provided by the specification.
    /// - parameter specialArgs: Used to replace the `special-args` placeholder in the command line template.
    /// - parameter lookup: An optional closure which functionally defined overriding values during build setting evaluation.
    public func commandLineArgumentsFromTemplate(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, optionContext: (any DiscoveredCommandLineToolSpecInfo)?, specialArgs: [String] = [], lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [CommandLineArgument] {
        let commandLineTemplate = self.commandLineTemplate!
        let lookup = { self.lookup($0, cbc, delegate, lookup) }

        var args = commandLineTemplate.flatMap { arg -> [CommandLineArgument] in
            switch arg {
            case .execPath:
                // If we have an executable path expression, evaluate that.
                if let execPath = self.execPath {
                    return [.path(Path(cbc.scope.evaluate(execPath, lookup: lookup)))]
                }

                // Otherwise, delegate to the spec.
                //
                // FIXME: This is really gross, and barely used.
                return [.path(Path(self.computeExecutablePath(cbc)))]

            case .input:
                // Return only the first input.
                //
                // FIXME: It should be an error for this ever to appear in a spec which can receive multiple inputs, but we need to add that enforcement condition (see also instances in custom tools).
                if let input = cbc.inputs.first {
                    return [.path(input.absolutePath)]
                }
                return []

            case .inputs:
                return cbc.inputs.map { .path($0.absolutePath) }

            case .literal(let value):
                return cbc.scope.evaluate(value, lookup: lookup).map { .literal(ByteString(encodingAsUTF8: $0)) }

            case .options:
                return self.commandLineFromOptions(cbc, delegate, optionContext: optionContext, lookup: lookup)

            case .output:
                // We always resolve the Output via a recursive macro evaluation. See constructTasks() for more information.
                return [.path(Path(cbc.scope.evaluate(BuiltinMacros.OutputPath, lookup: { return self.lookup($0, cbc, delegate, lookup) } )))]

            case .specialArgs:
                return specialArgs.map { .literal(ByteString(encodingAsUTF8: $0)) }
            }
        }

        // Resolve the executable path.
        //
        // FIXME: It would be nice to just move this to a specific handler for this first item in the template array (we could generalize the existing ExecPath key for this purpose).
        args[0] = { path in
            if path.asString.hasPrefix("builtin-") || (path.asString.hasPrefix("<") && path.asString.hasSuffix(">")) {
                return path
            }

            // Otherwise, look up the path if necessary.
            return .path(resolveExecutablePath(cbc, Path(path.asString)))
        }(args[0])

        return args
    }

    /// Creates and returns the command line arguments generated by the options of the specification.
    ///
    /// - parameter lookup: An optional closure which functionally defined overriding values during build setting evaluation.
    public func commandLineFromOptions(_ producer: any CommandProducer, scope: MacroEvaluationScope, inputFileType: FileTypeSpec?, optionContext: (any BuildOptionGenerationContext)?, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [CommandLineArgument] {
        return self.flattenedOrderedBuildOptions.flatMap { $0.getArgumentsForCommand(producer, scope: scope, inputFileType: inputFileType, optionContext: optionContext, lookup: lookup) }
    }

    /// Creates and returns the command line arguments generated by the options of the specification.
    ///
    /// - parameter lookup: An optional closure which functionally defined overriding values during build setting evaluation.
    public func commandLineFromOptions(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, optionContext: (any BuildOptionGenerationContext)?, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [CommandLineArgument] {
        return commandLineFromOptions(cbc.producer, scope: cbc.scope, inputFileType: cbc.inputs.first?.fileType, optionContext: optionContext, lookup: { self.lookup($0, cbc, delegate, lookup) })
    }

    /// Creates and returns the command line arguments generated by the specification's build setting corresponding to the given macro declaration.
    ///
    /// - parameter lookup: An optional closure which functionally defined overriding values during build setting evaluation.
    func commandLineFromMacroDeclaration(_ producer: any CommandProducer, optionContext: (any BuildOptionGenerationContext)?, scope: MacroEvaluationScope, macro: MacroDeclaration, inputFileType: FileTypeSpec?, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [CommandLineArgument] {
        return buildOptions.first { $0.name == macro.name }?.getArgumentsForCommand(producer, scope: scope, inputFileType: inputFileType, optionContext: optionContext, lookup: lookup) ?? []
    }

    /// Creates and returns the command line arguments generated by the specification's build setting corresponding to the given macro declaration.
    ///
    /// - parameter lookup: An optional closure which functionally defined overriding values during build setting evaluation.
    func commandLineFromMacroDeclaration(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, optionContext: (any BuildOptionGenerationContext)?, _ macro: MacroDeclaration, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) async -> [CommandLineArgument] {
        return commandLineFromMacroDeclaration(cbc.producer, optionContext: optionContext, scope: cbc.scope, macro: macro, inputFileType: cbc.inputs.first?.fileType, lookup: { self.lookup($0, cbc, delegate, lookup) })
    }

    /// Computes the paths of any additional input dependencies of the command based on the active build options.
    public func additionalInputDependencies(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, optionContext: (any BuildOptionGenerationContext)?, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [Path] {
        let producer = cbc.producer
        let scope = cbc.scope
        let inputFileType = cbc.inputs.first?.fileType
        let lookup = { self.lookup($0, cbc, delegate, lookup) }
        return self.flattenedOrderedBuildOptions.flatMap { buildOption -> [Path] in
            // Check if the effective arguments for this build option were non-empty as a proxy for whether it got filtered out by architecture mismatch, etc.
            guard let inputInclusions = buildOption.inputInclusions, !buildOption.getArgumentsForCommand(producer, scope: scope, inputFileType: inputFileType, optionContext: optionContext, lookup: lookup).isEmpty else {
                return []
            }
            return inputInclusions.compactMap { Path(scope.evaluate($0, lookup: lookup)).nilIfEmpty?.normalize() }
        }
    }

    /// Compute the list of additional linker arguments to use when this tool is used for building with the given scope.
    public func computeAdditionalLinkerArgs(_ producer: any CommandProducer, scope: MacroEvaluationScope, inputFileTypes: [FileTypeSpec], optionContext: (any BuildOptionGenerationContext)?, delegate: any TaskGenerationDelegate) async -> (args: [[String]], inputPaths: [Path]) {
        // FIXME: Optimize the list to search here.
        return (args: self.flattenedOrderedBuildOptions.map { $0.getAdditionalLinkerArgs(producer, scope: scope, inputFileTypes: inputFileTypes) }, inputPaths: [])
    }

    // Creates and returns the environment from the specification.  This includes both the 'EnvironmentVariables' property for this tool spec, and any build options which define that their value should be exported via their 'SetValueInEnvironmentVariable' property.
    /// - parameter lookup: An optional closure which functionally defined overriding values during build setting evaluation.
    open func environmentFromSpec(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> [(String, String)] {
        let wrappedLookup = { self.lookup($0, cbc, delegate, lookup) }
        var environment = [(String, String)]()

        // Add this spec's defined environment variables from its 'EnvironmentVariables' property.
        for (key, value) in self.environmentVariables ?? [] {
            environment.append((key, cbc.scope.evaluate(value, lookup: wrappedLookup)))
        }

        // Add environment variables from build options which specify they should be added via a 'SetValueInEnvironmentVariable' property.
        // FIXME: Optimize the list to search here.
        for buildOption in self.flattenedOrderedBuildOptions {
            if let assignment = buildOption.getEnvironmentAssignmentForCommand(cbc, lookup: wrappedLookup) {
                environment.append(assignment)
            }
        }
        return environment
    }

    public func environmentFromSpec(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> EnvironmentBindings {
        return EnvironmentBindings(environmentFromSpec(cbc, delegate, lookup: lookup))
    }

    open func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] {
        return []
    }

    open func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        return []
    }

    public func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] {
        return []
    }

    public func generateDocumentationInfo(for task: any ExecutableTask, input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput] {
        return []
    }

    open func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] {
        return []
    }

    open func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        // By default, we enable diagnostic scraping for all tools.
        return GenericOutputParser.self
    }

    public func interestingPath(for task: any ExecutableTask) -> Path? {
        return nil
    }

    /// A hook to allow tasks to write out any dependency data that may be collected dynamically via task generation.
    public func create(dependencyData: DependencyDataStyle, for task: any ExecutableTask, fs: any FSProxy) throws {
        // Each spec needs to own how this is collected and serialized.
    }

    /// Make any adjustments to the task's discovered dependency data.
    ///
    /// This method is called at task execution time just prior to task completion,
    /// to allow any final adjustments of existing dependency information before
    /// it is processed by the low-level build engine.
    public func adjust(dependencyFiles: DependencyDataStyle, for task: any ExecutableTask, fs: any FSProxy) throws {
        guard let payload = task.payload as? (any DependencyInfoEditableTaskPayload) else { return }

        if let editPayload = payload.dependencyInfoEditPayload {
            if case .dependencyInfo(let dependencyInfoPath) = dependencyFiles {
                do {
                    var dependencyInfo = try SWBUtil.DependencyInfo(bytes: try fs.read(dependencyInfoPath).bytes)
                    if try dependencyInfo.modify(payload: editPayload, fs: fs) {
                        // Only write to disk if it was modified.
                        try fs.write(
                            dependencyInfoPath,
                            contents: ByteString(dependencyInfo.normalized().asBytes())
                        )
                    }
                } catch {
                    throw error
                }
            }
        }
    }

    open var payloadType: (any TaskPayload.Type)? {
        return nil
    }

    open var toolBasenameAliases: [String] {
        return []
    }

    open func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Helper shim to partially simulate an "abstract class"
        struct Base: ConditionallyStartable { static let instance = Self() }
        return Base.instance.shouldStart(task, buildCommand: buildCommand)
    }

    public func executeExternalTool<T>(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, commandLine: [String], workingDirectory: String?, environment: [String: String], executionDescription: String?, _ parse: @escaping (ByteString) throws -> T) async throws -> T {
        let executionResult = try await delegate.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment, executionDescription: executionDescription)
        guard executionResult.exitStatus.isSuccess else {
            throw RunProcessNonZeroExitError(args: commandLine, workingDirectory: workingDirectory, environment: .init(environment), status: executionResult.exitStatus, stdout: ByteString(executionResult.stdout), stderr: ByteString(executionResult.stderr))
        }
        return try parse(ByteString(executionResult.stdout))
    }

    public func generatedFilePaths(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, commandLine: [String], workingDirectory: String?, environment: [String: String], executionDescription: String?, _ parse: @escaping (ByteString) throws -> [Path]) async throws -> [Path] {
        return try await executeExternalTool(cbc, delegate, commandLine: commandLine, workingDirectory: workingDirectory, environment: environment, executionDescription: executionDescription, parse)
    }
}

extension CommandLineToolSpec.RuleInfoTemplateArg: ExpressibleByStringLiteral {
    package typealias StringLiteralType = StaticString

    package init(stringLiteral value: StringLiteralType) {
        self = .string(value)
    }
}

open class GenericCommandLineToolSpec : CommandLineToolSpec, @unchecked Sendable {
    required public init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: true)
    }
}

/// A general-purpose output parser for scraping traditional POSIX-style diagnostics.  Output is passed through to the delegate as it is received, while diagnostic parsing is done line-by-line as each newline is encountered.
open class GenericOutputParser : TaskOutputParser {

    /// The delegate that's informed about output and diagnostics.
    public let delegate: any TaskOutputParserDelegate

    /// Workspace context associated with the output parser.
    public let workspaceContext: WorkspaceContext

    public let buildRequestContext: BuildRequestContext

    /// The task on whose behalf we are scraping output.
    let task: any ExecutableTask

    /// Regex to extract diagnostic information from a line of output (capture group 0 is the location, 1 is the severity, and 2 is the message).  This regex contains the name of the tool, and is therefore not a static.
    let diagnosticRegex: RegEx

    /// The set of tool names that might appear in a diagnostic, in place of a location.
    public let toolBasenames: Set<String>

    /// Buffered output that has not yet been parsed (parsing is line-by-line, so we buffer incomplete lines until we receive more output).
    private var unparsedBytes: [UInt8] = []

    /// The Diagnostic that is being constructed, possibly across multiple lines of input.
    private var inProgressDiagnostic: Diagnostic?

    /// Holds the FixIts, in the order read, that are associated with the diagnostic that is being constructed, possibly across multiple lines of input.
    private var fixits: [Diagnostic.FixIt]

    required public init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?) {
        self.task = task
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate

        // Get the executable's basename from its command line arguments.  We need this because some commands use their names in the diagnostic prefix.
        let executableName = Path(task.commandLineAsStrings.first(where: { _ in true })!).basename

        // We don't expect clients to add the executable name as an alias.
        assert(!task.type.toolBasenameAliases.contains(executableName))

        // Create a subregex based on all the basenames we have.
        //
        // This regex is expected to match one of these patterns:
        // * basename: ....
        // * /path/to/basename: ...
        let toolBasenames = task.type.toolBasenameAliases + [executableName]
        let toolnameSubregex = toolBasenames.map({ "(?:.*\\/)?" + RegEx.escapedPattern(for: $0) }).joined(separator: "|")

        // Finally, create the regex.
        //
        // We require that either the diagnostic be at the start of the line
        // (excluding whitespace), or have a leading compiler-style indicator (:).
        // Following that, there must be a diagnostic kind keyword or a basename
        // alias, and then a diagnostic.
        //
        // We also restrict the leading indicator to not have any quote characters,
        // which helps filter out anything which looks like a diagnostic but is
        // appearing within a quoted string.
        self.diagnosticRegex = try! RegEx(pattern: "^([^'\"]+: +|[ \\t\\f\\p{Z}]*)(error|warning|note|notice|fixit|\(toolnameSubregex)): (.*)$")
        self.toolBasenames = Set(toolBasenames)
        self.fixits = []
    }

    public func write(bytes: ByteString) {
        // Forward the unparsed bytes immediately (without line buffering).
        delegate.emitOutput(bytes)

        // Append the new output to whatever partial line of output we might already have buffered.
        unparsedBytes.append(contentsOf: bytes.bytes)

        // Split the buffer into slices separated by newlines.  The last slice represents the partial last line (there always is one, even if it's empty).
        let lines = unparsedBytes.split(separator: UInt8(ascii: "\n"), maxSplits: .max, omittingEmptySubsequences: false)

        // Parse any complete lines of output.
        for line in lines.dropLast() {
            parseLine(line)
        }

        // Remove any complete lines from the buffer, leaving only the last partial line (if any).
        unparsedBytes.removeFirst(unparsedBytes.count - lines.last!.count)
    }

    /// Regex to extract location information from a diagnostic prefix (capture group 0 is the name, 1 is the line number, and 2 is the column).
    static let locationRegex = RegEx(patternLiteral: "^([^:]+):(?:([0-9]+):)?(?:([0-9]+):)? +$")

    /// Private function that parses and returns a DiagnosticLocation based on a fragment of the input string.
    open func parseLocation(_ string: String, in workingDirectory: Path) -> Diagnostic.Location? {
        if let match = GenericOutputParser.locationRegex.matchGroups(in: string).first {
            let filename = match[0]
            // If the match is one of the tool basename, it is not a filename.
            if !toolBasenames.contains(filename) {
                // Otherwise, we assume it's in traditional "path:line:column" form, where the line and column numbers are optional.
                let line = Int(match[1])
                let column = Int(match[2])
                return .path((Path(filename).makeAbsolute(relativeTo: workingDirectory) ?? Path(filename)).normalize(), line: line, column: column)
            }
        }
        return nil
    }

    /// Private function that parses a single line of output and informs the delegate if it finds any diagnostics.  The terminating newline is not included in \(lineBytes).  This function returns true if it produced a diagnostic from the line, or false if not.
    @discardableResult func parseLine<S: Collection>(_ lineBytes: S) -> Bool where S.Element == UInt8 {
        // Use the non-failable constructor to recover from potentially invalid UTF-8
        let lineString = String(decoding: lineBytes, as: Unicode.UTF8.self)

        // Apply the regex, and if it matches, extract the information from its match groups.
        guard let match = diagnosticRegex.firstMatch(in: lineString) else { return false }

        // If we get here, we have a match, consisting of a location, a kind, and a message.  The message is the third match group.
        let message = parseMessage(match[2])

        if match[1] == "fixit" {
            if inProgressDiagnostic != nil {
                // If the line can't be parsed by the constructor, it is probably corrupt, and we drop it but report that we consumed the line
                if let fixIt = Diagnostic.FixIt(lineString, ignorePaths: toolBasenames, workingDirectory: task.workingDirectory) {
                    fixits.append(fixIt)
                }
            } else {
                // Ignore apparent fixit lines if there is no 'parent' diagnostic to attach them to; fixits are generally expected to only follow error or warning diagnostics
                return false
            }
        } else {
            // The location is the first match group.  It usually consists of a path followed by a line number, object identifier, or other location inside the entity at that path, but we leave the details to a private function (for subclassibility).
            let location = parseLocation(match[0], in: task.workingDirectory) ?? .unknown

            flushPendingDiagnostics()

            // The kind (a.k.a. "behavior") is the second match group.  If we cannot determine the specific behavior (error, warning, etc), we fall back to "notice" to avoid showing spurious errors or warnings for things we don't understand.
            let behavior = Diagnostic.Behavior(name: match[1]) ?? .note

            // Create a temporary diagnostic that contains the extracted information.
            inProgressDiagnostic = Diagnostic(behavior: behavior, location: location, data: DiagnosticData(message), appendToOutputStream: false)
        }

        // Finally, return true to indicate that we did create a diagnostic for this line of output.
        return true
    }

    /// Private function that parses and returns a the message based on a fragment of the input string that the parser identified as the message.
    open func parseMessage(_ string: String) -> String {
        string
    }

    // Note carefully that if flushPendingDiagnostics() is called before all trailing fixit lines have been read and parsed, the remaining fixits will be orphaned and likely dropped.
    func flushPendingDiagnostics() {
        if let inProgressDiagnostic {
            // Emit a diagnostic that contains the extracted information.  We avoid appending it to the output stream, since it's already been emitted as text.
            let diag = Diagnostic(behavior: inProgressDiagnostic.behavior, location: inProgressDiagnostic.location, data: inProgressDiagnostic.data, appendToOutputStream: false, fixIts: fixits)
            delegate.diagnosticsEngine.emit(diag)
        }
        fixits.removeAll()
        inProgressDiagnostic = nil
    }

    public func close(result: TaskResult?) {
        // Parse any unterminated line we might still have in the buffer.
        if !unparsedBytes.isEmpty {
            parseLine(unparsedBytes)
        }
        flushPendingDiagnostics()
        delegate.close()
    }
}

@_spi(Testing) public final class ShellScriptOutputParser : GenericOutputParser {
    override func parseLine<S: Collection>(_ lineBytes: S) -> Bool where S.Element == UInt8 {
        if !super.parseLine(lineBytes) {
            // Use the non-failable constructor to recover from potentially invalid UTF-8
            let lineString = String(decoding: lineBytes, as: Unicode.UTF8.self)

            // Add a "notice" diagnostic for the whole line (without the line terminator).
            let diag = Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData(lineString), appendToOutputStream: false)
            delegate.diagnosticsEngine.emit(diag)
        }
        return true
    }
}

/// An output parser which forwards all output unchanged, then generates diagnostics from a serialized diagnostics file passed in the payload once it is closed.
public final class SerializedDiagnosticsOutputParser: TaskOutputParser {
    private let task: any ExecutableTask

    public let workspaceContext: WorkspaceContext
    public let buildRequestContext: BuildRequestContext
    public let delegate: any TaskOutputParserDelegate

    required public init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?) {
        self.task = task
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
    }

    public func write(bytes: ByteString) {
        // Forward the unparsed bytes immediately (without line buffering).
        delegate.emitOutput(bytes)

        // Disable diagnostic scraping, since we use serialized diagnostics.
    }

    public func close(result: TaskResult?) {
        defer {
            delegate.close()
        }
        // Don't try to read diagnostics if the process crashed or got cancelled as they were almost certainly not written in this case.
        if result.shouldSkipParsingDiagnostics { return }

        for path in task.type.serializedDiagnosticsPaths(task, workspaceContext.fs) {
            delegate.processSerializedDiagnostics(at: path, workingDirectory: task.workingDirectory, workspaceContext: workspaceContext)
        }
    }
}

fileprivate extension Diagnostic.FixIt {

    // For better performance, these are declared outside the initializer, so they are just created once, but are really just an implementation detail of the initializer.
    static private let fixitRangeRegex = RegEx(patternLiteral: "^([^:]+):([0-9]+):([0-9]+)-([0-9]+):([0-9]+): +fixit: (.*)$") // filename + range
    static private let fixitLineColumnRegex = RegEx(patternLiteral: "^([^:]+):([0-9]+):([0-9]+): +fixit: (.*)$") // filename + line + column

    init?(_ string: String, ignorePaths: Set<String>, workingDirectory: Path) {
        // reminder: fixit lines should look like this: FILE:LINE:COL-LINE:COL: fixit: REPLACEMENT\n
        if let match = Diagnostic.FixIt.fixitRangeRegex.matchGroups(in: string).first {
            let filename = match[0]
            guard !ignorePaths.contains(filename) else { return nil }
            let path = (Path(filename).makeAbsolute(relativeTo: workingDirectory) ?? Path(filename)).normalize()
            // These four match strings are likely valid integers based on the regex, but the type system of course can't express this
            let line1 = Int(match[1]) ?? 0
            let column1 = Int(match[2]) ?? 0
            let line2 = Int(match[3]) ?? 0
            let column2 = Int(match[4]) ?? 0
            guard let message = try? match[5].unJSONEscaped() else { return nil }
            self.init(sourceRange: .init(path: path, startLine: line1, startColumn: column1, endLine: line2, endColumn: column2), newText: message)
            return
        }
        if let match = Diagnostic.FixIt.fixitLineColumnRegex.matchGroups(in: string).first {
            let filename = match[0]
            guard !ignorePaths.contains(filename) else { return nil }
            let path = (Path(filename).makeAbsolute(relativeTo: workingDirectory) ?? Path(filename)).normalize()
            let line = Int(match[1]) ?? 0
            let column = Int(match[2]) ?? 0
            guard let message = try? match[3].unJSONEscaped() else { return nil }
            self.init(sourceRange: .init(path: path, startLine: line, startColumn: column, endLine: line, endColumn: column), newText: message)
            return
        }
        return nil
    }
}

/// Convert the given path to one that can be used in a relocatable index
/// store. This path need not actually exist on the filesystem, but care should
/// be taken to ensure any comparisons to the path from the index store are
/// against the same relocated path.
public func generateIndexOutputPath(from output: Path, basePath: Path) -> Path? {
    // We want the paths in the index store to be relocatable. This could be
    // relative, but use an absolute path instead to ensure no accidental
    // conversion to absolute by eg. the compilers.
    if let relative = output.relativeSubpath(from: basePath) {
        if let newPath = Path(relative).makeAbsolute(relativeTo: Path(Path.pathSeparatorString)) {
            return newPath
        }
    }
    return nil
}
