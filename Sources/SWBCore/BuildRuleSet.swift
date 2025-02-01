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

/// A build rule set is a collection of rules against which candidates can be matched.  The ``match(_:_:)`` function matches a candidate against each rule in the list, returning the action of the first one that matches.  The rule set may cache the result of the condition evaluation, so each build rule condition is required to depend only on its inputs.
public protocol BuildRuleSet {
    /// Returns the first build rule action that matches `candidate`, if any.
    func match(_ candidate: FileToBuild, _ scope: MacroEvaluationScope) -> MatchResult
}

public struct MatchDiagnostic: Hashable {
    public let behavior: Diagnostic.Behavior
    public let message: String

    @_spi(Testing) public init(behavior: Diagnostic.Behavior, message: String) {
        self.behavior = behavior
        self.message = message
    }
}

public struct MatchResult {
    public let action: (any BuildRuleAction)?
    public let diagnostics: [MatchDiagnostic]

    fileprivate init(action: (any BuildRuleAction)?, diagnostics: [MatchDiagnostic]) {
        self.action = action
        self.diagnostics = diagnostics
    }
}

/// A build rule set which encapsulates a list of other build rule sets in order from highest to lowest precedence.
/// This exists so that user rules override built-in rules without generating a warning about multiple same-priority matches.
public final class LeveledBuildRuleSet: BuildRuleSet {
    /// A list of build rule sets to match against, in order from highest to lowest precedence.
    let buildRuleSets: [any BuildRuleSet]

    /// Initializes a build rule set with a list of basic build rule sets, which are considered to be in highest-to-lowest priority.
    public init(ruleSets: [any BuildRuleSet]) {
        self.buildRuleSets = ruleSets
    }

    public func match(_ candidate: FileToBuild, _ scope: MacroEvaluationScope) -> MatchResult {
        for set in buildRuleSets {
            let match = set.match(candidate, scope)
            if match.action != nil {
                return match
            }
        }
        return MatchResult(action: nil, diagnostics: [])
    }
}

/// A basic build rule set which encapsulates a list of condition-action pairs.
public final class BasicBuildRuleSet: BuildRuleSet {
    /// A list of condition-action pairs in order from highest to lowest precedence.
    let rules: [(any BuildRuleCondition, any BuildRuleAction)]

    /// FIXME: Add a cache here.

    /// Initializes a build rule set with a list of condition-action pairs, which are considered to be in highest-to-lowest priority.  The rule set may cache the result of the condition evaluation, so each build rule condition is required to depend only on its inputs.
    public init(rules: [(any BuildRuleCondition, any BuildRuleAction)]) {
        self.rules = rules
    }

    public func match(_ candidate: FileToBuild, _ scope: MacroEvaluationScope) -> MatchResult {
        // At the moment we look through our list of build rules from top to bottom, but in the future we will have a cache to make it O(1) in the limit.
        for (condition, action) in rules {
            if condition.match(candidate, scope) != .none {
                return MatchResult(action: action, diagnostics: [])
            }
        }
        return MatchResult(action: nil, diagnostics: [])
    }
}

/// A basic build rule set which encapsulates a list of condition-action pairs and provides disambiguation diagnostics for multiple matches when the input rule set does not have a defined ordering.
public final class DisambiguatingBuildRuleSet: BuildRuleSet {
    /// A list of condition-action pairs in arbitrary order.
    let rules: [(any BuildRuleCondition, any BuildRuleAction)]

    /// Whether to emit warning diagnostics for multiple matches.
    let enableDebugActivityLogs: Bool

    /// Initializes a build rule set with a set of condition-action pairs, which are in arbitrary order.  The rule set may cache the result of the condition evaluation, so each build rule condition is required to depend only on its inputs.
    public init(rules: [(any BuildRuleCondition, any BuildRuleAction)], enableDebugActivityLogs: Bool) {
        self.rules = rules
        self.enableDebugActivityLogs = enableDebugActivityLogs
    }

    public func match(_ candidate: FileToBuild, _ scope: MacroEvaluationScope) -> MatchResult {
        let actions = Dictionary(grouping: rules.compactMap { (condition, action) -> (action: any BuildRuleAction, priority: BuildRuleConditionMatchPriority)? in
            let priority = condition.match(candidate, scope)
            guard priority != .none else {
                return nil
            }
            return (action, priority)
        }, by: { $0.priority }).mapValues { $0.map { $0.0 } }

        let priorityLevels = [BuildRuleConditionMatchPriority.normal, .low]

        let diagnostics: [MatchDiagnostic] = {
            for priority in priorityLevels {
                // NOTE: There might be multiple matches for the same action because our input data structure pairs an action multiple times, based on the number of input conditions it accepts. Due to type system limitations w.r.t. Hashable, we can't have an OrderedSet of BuildRuleActions, but we can use a generic Hashable Pair of data to convey identifier and name pairs.
                if let matches = actions[priority].map({ OrderedSet($0.map({ Pair($0.identifier, $0.name) })) }),
                    matches.count > 1 {

                    let identifiers = matches.map { $0.first }

                    // <rdar://50701007> Ignore a known problem case -- the linker and postprocessor rules conflict and we always choose the linker rule, so the postprocessor rule is effectively ignored. We need to find a way to generalize some conflict resolution and/or ordering mechanism.
                    if identifiers == ["com.apple.xcode.tools.ibtool.storyboard.linker", "com.apple.xcode.tools.ibtool.storyboard.postprocessor"] {
                        return []
                    }

                    // FIXME: COMBINE_HIDPI_IMAGES is a bit of a special case in the build system...
                    if identifiers == ["com.apple.compilers.tiffutil", "com.apple.build-tasks.copy-png-file"] || identifiers == ["com.apple.compilers.tiffutil", "com.apple.build-tasks.copy-tiff-file"] {
                        return []
                    }

                    let names = matches.map { $0.second }

                    return [
                        MatchDiagnostic(
                            behavior: enableDebugActivityLogs ? .warning : .note,
                            message: "Multiple rules matching input '\(candidate.absolutePath.str)':\n\(names.joined(separator: "\n"))\n\nApplying first matching rule '\(names[0])'"
                        )
                    ]
                }
            }

            // no matching rule at all, but we'll warn about that at a later stage
            return []
        }()

        // FIXME: <rdar://problem/23567194> We may need to further refine this to check the tool for the file types it supports, especially if the tool the action contains need to be resolved to a concrete tool.  Presently we don't do that, but instead bake the supported files types for the tool into the build rule condition.  This was done in <rdar://problem/40799214>, and that may need to be backed out if we decide we need to take a different approach.
        return MatchResult(action: priorityLevels.compactMap { actions[$0]?.first }.first, diagnostics: diagnostics)
    }
}

extension Core {
    /// Create and return a build rule condition/action pair for the given build rule data.  If a platform is provided, any specifications mentioned in the build rule (such as file types or command line specs) will be bound from the point of view of that platform.
    public func createShellScriptBuildRule(_ guid: String, _ name: String, _ inputSpecifier: BuildRuleInputSpecifier, _ scriptContents: String, _ inputFiles: [MacroStringExpression], _ inputFileLists: [MacroStringExpression], _ outputs: [(path: MacroStringExpression, additionalCompilerFlags: MacroStringListExpression?)], _ outputFileLists: [MacroStringExpression], _ dependencyInfo: DependencyInfoFormat?, _ runOncePerArchitecture: Bool, platform: Platform? = nil, scope: MacroEvaluationScope) throws -> (any BuildRuleCondition, any BuildRuleAction) {
        let outputFiles = outputs.map {
            BuildRuleScriptAction.OutputFileInfo(path: $0.path, additionalCompilerFlags: $0.additionalCompilerFlags)
        }

        /// Some Swift clients need to run build rule scripts even in installapi, because their source files
        /// (which are necessary for Swift installapi) are generated by some kind of code generator. Allow
        /// an escape hatch for these projects, at the cost of slight installapi time regressions.
        let shouldRunDuringInstallAPI = scope.evaluate(BuiltinMacros.APPLY_RULES_IN_INSTALLAPI)

        // FIXME: There needs to be a way to specify the interpreter
        let action = BuildRuleScriptAction(guid: guid, name: name, interpreterPath: "/bin/sh", scriptSource: scriptContents, inputFiles: inputFiles, inputFileLists: inputFileLists, outputFiles: outputFiles, outputFileLists: outputFileLists, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture, runDuringInstallAPI: shouldRunDuringInstallAPI, runDuringInstallHeaders: false)

        let condition: any BuildRuleCondition
        switch inputSpecifier {
        case let .fileType(fileTypeIdentifier):
            let domain = platform?.name ?? ""
            condition = BuildRuleFileTypeCondition(fileType: try specRegistry.getSpec(fileTypeIdentifier, domain: domain) as FileTypeSpec)
        case let .patterns(filePatterns):
            condition = BuildRuleFileNameCondition(namePatterns: filePatterns)
        }

        // Return the build rule condition and action.
        return (condition, action)
    }

    /// Create and return a build rule condition/action pair for the given build rule data.  If a platform is provided, any specifications mentioned in the build rule (such as file types or command line specs) will be bound from the point of view of that platform.
    public func createSpecBasedBuildRule(_ inputSpecifier: BuildRuleInputSpecifier, _ compilerSpecificationIdentifier: String, platform: Platform? = nil) throws -> (any BuildRuleCondition, any BuildRuleAction) {
        let domain = platform?.name ?? ""

        switch inputSpecifier {
        case let .fileType(fileTypeIdentifier):
            let spec = try specRegistry.getSpec(compilerSpecificationIdentifier, domain: domain) as CommandLineToolSpec

            // Capture the tool spec's supports file types, if any.  But we only need to do this if the condition is not a pattern identifier.
            var toolSpecSupportedFileTypes = [FileTypeSpec]()
            if let inputFileTypeDescriptors = spec.inputFileTypeDescriptors {
                for inputFileType in inputFileTypeDescriptors {
                    let fileType = try specRegistry.getSpec(inputFileType.identifier, domain: domain) as FileTypeSpec
                    toolSpecSupportedFileTypes.append(fileType)
                }
            }

            let action = BuildRuleTaskAction(toolSpec: spec)

            let condition: any BuildRuleCondition
            let fileType = try specRegistry.getSpec(fileTypeIdentifier, domain: domain) as FileTypeSpec
            let fileTypes = toolSpecSupportedFileTypes.compactMap({ $0.conformsTo(fileType) ? $0 : nil })
            if fileTypes.isEmpty {
                // If the compiler spec defined any supported file types, then the file types for the condition are those from the compiler spec which conform to the one we looked up.
                condition = BuildRuleFileTypeCondition(fileType: fileType)
            } else {
                // Otherwise we use the one was looked up.
                condition = BuildRuleFileTypeCondition(fileTypes: fileTypes)
            }

            // Return the build rule condition and action.
            return (condition, action)
        case let .patterns(filePatterns):
            return (BuildRuleFileNameCondition(namePatterns: filePatterns), BuildRuleTaskAction(toolSpec: try specRegistry.getSpec(compilerSpecificationIdentifier, domain: domain) as CommandLineToolSpec))
        }
    }
}
