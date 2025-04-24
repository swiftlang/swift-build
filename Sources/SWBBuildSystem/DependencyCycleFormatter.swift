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

import SWBCore
import SWBTaskExecution
import SWBUtil
import Foundation
private import SWBLLBuild
import SWBTaskConstruction

/// Convenience enum to encode whether a task is the beginning or end of a target, or something else.
/// "End of a target" in this case is a task which tasks in other targets may be directly depending on, and so can mark the point at which we cross a target boundary.
private enum TaskType: Equatable {
    case beginTargetTask(targetName: String)
    case endTargetTask(targetName: String)
    case other
}

private func ==(lhs: TaskType, rhs: TaskType) -> Bool {
    switch (lhs, rhs) {
    case (.beginTargetTask(_), .beginTargetTask(_)): return true
    case (.endTargetTask(_), .endTargetTask(_)): return true
    case (.other, .other): return true
    default: return false
    }
}

private extension ExecutableTask {
    /// The task type is inferred by examining the prefix and suffix of the first element of task's rule info.
    /// - remark: This implies that this method needs to be kept up-to-date if new rule infos which mark the beginning or end of a task are introduced.
    var taskType: TaskType {
        switch ruleInfo.first {
        case "Gate":
            if ruleInfo[1].hasPrefix("target-") {
                if ruleInfo[1].hasSuffix("-entry") || ruleInfo[1].hasSuffix("-begin-compiling") || ruleInfo[1].hasSuffix("-begin-linking") {
                    return .beginTargetTask(targetName: forTarget!.target.name)
                } else if ruleInfo[1].hasSuffix("-end") || ruleInfo[1].hasSuffix("-modules-ready") || ruleInfo[1].hasSuffix("-linker-inputs-ready") {
                    return .endTargetTask(targetName: forTarget!.target.name)
                }
            }
        default:
            break
        }
        return .other
    }
}

/// Struct which contains the context to format a dependency cycle for better readability.
struct DependencyCycleFormatter {
    private let buildDescription: BuildDescription
    private let buildRequest: BuildRequest
    private let rules: [BuildKey]
    private let workspace: Workspace
    private let dynamicTaskContext: DynamicTaskOperationContext

    init(buildDescription: BuildDescription, buildRequest: BuildRequest, rules: [BuildKey], workspace: Workspace, dynamicTaskContext: DynamicTaskOperationContext) {
        self.buildDescription = buildDescription
        self.buildRequest = buildRequest
        self.rules = rules
        self.workspace = workspace
        self.dynamicTaskContext = dynamicTaskContext
    }

    // If the cycle contains a CpHeader task followed by a Compile Source phase of the same target, suggest moving the Headers phase.
    private func shouldMakeHeadersAfterCompileSourcesSuggestion() -> String? {
        var cpHeaderForTarget: String?
        var hasHeadersAfterSources = false

        for rule in rules {
            guard let task = self.executableTask(for: rule) else { continue }
            if task.ruleInfo.first == "CpHeader" {
                cpHeaderForTarget = task.forTarget!.target.name
            }
            if task.ruleInfo.first == "Gate" && task.ruleInfo.last?.hasPrefix("target-\(cpHeaderForTarget ?? "")") == true && task.ruleInfo.last?.hasSuffix("-compile-sources") == true {
                hasHeadersAfterSources = true
            }
        }

        if hasHeadersAfterSources {
            return " This usually can be resolved by moving the target's Headers build phase before Compile Sources."
        }
        return ""
    }

    // This method contains some heuristics for diagnosing possible causes of in-target dependency cycles.
    private func likelyCauseOfInTargetCycle() -> String {
        let tasks = rules.compactMap { self.executableTask(for: $0)?.ruleInfo }

        // If there is a validate binary task for an app extension, followed by processing the Info.plist in the cycle, suggest moving the app extension embedding build phase.
        if let validateBinaryTaskIndex = tasks.firstIndex(where: { $0.first == "ValidateEmbeddedBinary" && $0.last?.hasSuffix(".appex") == true }) {
            if validateBinaryTaskIndex < tasks.count - 1 && tasks[validateBinaryTaskIndex + 1].first == "ProcessInfoPlistFile" {
                return " This can usually be resolved by moving the app extension embedding build phase to the end of the list."
            }
        }

        // If a compile task is followed by copying a module map in the cycle, suggest moving the copy phase.
        if let compileTaskIndex = tasks.firstIndex(where: { $0.first?.hasPrefix("Compile") == true }) {
            if compileTaskIndex < tasks.count - 1 && tasks[compileTaskIndex + 1].last?.hasSuffix("modulemap") == true {
                if let command = tasks[compileTaskIndex + 1].first, command == "CpHeader" || command == "CpResource" {
                    return " This usually means the target's module map is copied after compiling its sources."
                }
            }
        }

        // If the cycle ends with a shell script tasks, suggest moving that task.
        if let shellScriptTask = tasks.last, shellScriptTask.first == "PhaseScriptExecution" {
            let shellScriptPhaseName: String
            if let name = shellScriptTask.dropFirst(1).first {
                shellScriptPhaseName = "the shell script phase '\(name)'"
            } else {
                shellScriptPhaseName = "a shell script phase"
            }
            return " This usually can be resolved by moving \(shellScriptPhaseName) so that it runs before the build phase that depends on its outputs."
        }

        if let suggestion = shouldMakeHeadersAfterCompileSourcesSuggestion() {
            return suggestion
        }

        // We have no suggestion to make.
        return ""
    }

    /// Remove all of the rules up to the beginning of the cycle and return the rest.
    private func rulesInsideCycle() throws -> [BuildKey] {
        guard let firstIndexOfCycleRule = rules.firstIndex(where: { $0.key == rules.last?.key }) else {
            throw StubError.error("Cycle in dependencies detected, but the beginning and end of the cycle could not be matched. Please file a bug report with the build transcript and how to reproduce the cycle if possible.")
        }

        var cycleRules = Array(rules[firstIndexOfCycleRule..<rules.endIndex])

        // If the first rule is a node which is followed by an end gate task, then add the end gate task node to the end of the nodes, since we will need it to compute the last message.
        if let firstRule = cycleRules.first, firstRule is BuildKey.Node, cycleRules.count > 1 {
            let secondRule = cycleRules[1]
            if let task = self.executableTask(for: secondRule), case .endTargetTask(_) = task.taskType {
                cycleRules.append(secondRule)
            }
        }

        return cycleRules
    }

    /// Main method to generate a formatted dependency cycle string.
    func formattedMessage() -> String {
        var message = "Cycle "

        // Remove all of the rules leading up to the cycle.
        let rulesInCycle: [BuildKey]
        do {
            rulesInCycle = try rulesInsideCycle()
        }
        catch {
            return error.localizedDescription
        }

        // Compute the targets involved in the cycle and add them to the message.
        let involvingTargets = targetNamesInvolvedInCycle(rulesInCycle)
        let isSingleTargetCycle: Bool
        if involvingTargets.count <= 1 {
            isSingleTargetCycle = true
            message += "inside \(involvingTargets.first ?? "a single target"); building could produce unreliable results.\(likelyCauseOfInTargetCycle())\n"
        } else {
            isSingleTargetCycle = false
            precondition(involvingTargets.count >= 3, "multiple-target cycle path is expected to always contain at least three targets")
            let suggestion = shouldMakeHeadersAfterCompileSourcesSuggestion()
            message += "in dependencies between targets '\(involvingTargets[0])' and '\(involvingTargets[involvingTargets.count-2])'; building could produce unreliable results.\(suggestion ?? "")\n"
            message += "Cycle path: \(involvingTargets.joined(separator: " → "))\n"
        }

        // Create the filtered and formatted cycle output.
        let cycleOutput: [[String]]
        let involvesManualTargetOrder: Bool
        do {
            if isSingleTargetCycle {
                cycleOutput = try formattedSingleTargetCycleOutput(rulesInCycle)
                involvesManualTargetOrder = false
            } else {
                (cycleOutput, involvesManualTargetOrder) = try formattedMultiTargetCycleOutput(rulesInCycle)
            }
        }
        catch {
            return error.localizedDescription
        }

        message += "Cycle details:\n"
        if involvesManualTargetOrder {
            message += "Target build order preserved because "
            if buildRequest.schemeCommand != nil {
                message += "“Build Order” is set to “Manual Order” in the scheme settings\n\n"
            } else {
                message += "“Parallelize build for command-line builds” in the project settings is off\n\n"
            }
        }

        // Prepend '→' whenever a new target is mentioned.
        var prefixedCycleOutput = [String]()
        for messageForTarget in cycleOutput {
            let messages: [String] = messageForTarget.enumerated().map { message in
                let marker = message.offset == 0 ? "→" : "○"
                return "\(marker) \(message.element)"
            }
            prefixedCycleOutput.append(contentsOf: messages)
        }

        message += "\(prefixedCycleOutput.joined(separator: "\n"))"
        return message
    }

    /// Generate a message about how we attempted to resolve the cycle.
    func formattedCycleResolutionMessage(candidateRule: BuildKey, action: CycleAction) -> String {
        var message = formattedMessage()
        message += "\n\nAttempting to resolve cycle by "
        switch (action) {
        case .forceBuild:
            message += "forcing build"
        case .supplyPriorValue:
            message += "supplying prior value"
        @unknown default:
            fatalError("Unknown value '\(action.rawValue)' in \(type(of: action)) enumeration")
        }
        if let cmd = self.executableTask(for: candidateRule) {
            if let formattedCmd = cmd.formattedRuleInfo(for: .dependencyCycle) {
                message += " of \(formattedCmd)"
            }
        }
        return message
    }

    private func dynamicTaskForCustomTask(_ customTask: BuildKey.CustomTask) -> DynamicTask? {
        let byteString = ByteString(customTask.taskDataBytes)
        let deserializer = MsgPackDeserializer.init(
            byteString,
            delegate: CustomTaskDeserializerDelegate(workspace: workspace)
        )
        return try? DynamicTask(from: deserializer)
    }

    private func executableTaskForCustomRule(_ rule: BuildKey.CustomTask) throws -> (any ExecutableTask)? {
        if let dynamicTask = dynamicTaskForCustomTask(rule) {
            guard let spec = DynamicTaskSpecRegistry.spec(for: dynamicTask.toolIdentifier) else {
                throw StubError.error("Dynamic task with unknown spec \(dynamicTask.toolIdentifier)")
            }
            return try spec.buildExecutableTask(dynamicTask: dynamicTask, context: dynamicTaskContext)
        }
        return nil
    }

    // FIXME: I would like the model here to be that the message payload contains a pair of rule+task+(other?) tuples, and the node between them, and then generates a nicely formatted message taking all of those into account.
    // But to do that we'd need to move off of ExecutableTask.formattedRuleInfo() in DiagnosticSupport.swift, which is a larger project (and also raises the question of supporting another place where all the rule info types need to be known).
    // So for now this is just an enum.
    //
    /// Bundled information about a dependency cycle message we want to emit.  This is either a rule or a pre-made message.
    struct DependencyCycleMessagePayload {
        enum Kind {
            case rule(BuildKey)
            case message(String)
        }

        let target: ConfiguredTarget?
        let kind: Kind

        init(_ target: ConfiguredTarget?, _ kind: Kind) {
            self.target = target
            self.kind = kind
        }

        /// Return the formatted message for this rule in the cycle.
        func message(with formatter: DependencyCycleFormatter) throws -> String? {
            switch kind {
            case .message(let message):
                return message

            case .rule(let rule):
                // FIXME: This doesn't handle the case where the workspace has multiple targets with the same name (in different projects).
                switch rule {
                case let rule as BuildKey.CustomTask:
                    if let dynamicTask = formatter.dynamicTaskForCustomTask(rule) {
                        guard let spec = DynamicTaskSpecRegistry.spec(for: dynamicTask.toolIdentifier) else {
                            return "Dynamic task with unknown spec \(dynamicTask.toolIdentifier)"
                        }
                        let cmd = try spec.buildExecutableTask(dynamicTask: dynamicTask, context: formatter.dynamicTaskContext)
                        return cmd.formattedRuleInfo(for: .dependencyCycle)
                    } else {
                        return rule.taskData
                    }
                case let rule as BuildKey.Command:
                    if let cmd = formatter.executableTask(for: rule) {
                        return cmd.formattedRuleInfo(for: .dependencyCycle)
                    } else {
                        // If we can't compute a message, then we return the rule, as simply eliding something that we thought we were going to emit a message for seems bad.
                        return rule.description
                    }
                case is BuildKey.DirectoryContents, is BuildKey.FilteredDirectoryContents:
                    // Filter directory contents build keys
                    return nil
                case is BuildKey.DirectoryTreeSignature, is BuildKey.DirectoryTreeStructureSignature:
                    // Filter directory tree signatures
                    return nil
                case is BuildKey.Node, is BuildKey.Stat:
                    // Filter out nodes
                    return nil
                case let rule as BuildKey.Target:
                    // Include targets, but filter the root one ""
                    let targetName = rule.name
                    return targetName.isEmpty ? nil : "Target \(targetName)"
                default:
                    if rule.kind == .unknown {
                        // Should we return the rule here, or elide it?
                        return nil
                    }
                    // Filter unknown enum cases; we can't know what to do here.
                    throw StubError.error("Unknown value '\(rule.kind.rawValue)' in \(type(of: rule.kind)) enumeration")
                }
            }
        }

    }

    /// Generate the filtered and formatted output for a cycle which spans multiple targets.
    ///
    /// The principle here is that we only report the dependencies between the targets and not within each target.  Empirically these cycles rarely-if-ever rely on specific within-a-single-target behavior, and they can substantially increase the amount of text in the message, making it harder to understand.  We can enhance this in the future if we find specific scenarios where that level of detail is useful.
    private func formattedMultiTargetCycleOutput(_ cycleRules: [BuildKey]) throws -> (cycleOutput: [[String]], involvesManualTargetOrder: Bool) {
        var involvesManualTargetOrder = false

        // Transform the cycle rules into a form suitable for output.
        var previousConfiguredTarget: ConfiguredTarget? = nil
        var previousTargetDependencies = [ResolvedTargetDependency]()
        var savedTasks = [(rule: BuildKey, task: any ExecutableTask)]()
        let cycleMessagePayloads: [DependencyCycleMessagePayload] = (try cycleRules.compactMap({ rule in
            // The custom rule explaining the reason for the target dependency, if we create one for this rule.
            var messagePayloads: [DependencyCycleMessagePayload]? = nil

            // Get the task for the rule, if any.
            let task: (any ExecutableTask)? = try {
                if let task = executableTask(for: rule) {
                    return task
                } else if let customRule = rule as? BuildKey.CustomTask, let task = try executableTaskForCustomRule(customRule) {
                    return task
                } else {
                    return nil
                }
            }()

            if let task {
                if let configuredTarget = task.forTarget {
                    // We're only going to report anything if we've crossed a target boundary.
                    // In the future we can adjust this if we find multi-target cycles where tasks within a target are relevant, either materially or to provide useful context to humans.
                    if configuredTarget != previousConfiguredTarget {
                        // We only create a message if we have saved tasks.
                        if !savedTasks.isEmpty, let previousConfiguredTarget {
                            // If both this and the saved task are gate tasks, then we almost certainly have a target dependency, either explicit, implicit, or due to ordering.
                            // It would be weird if there is a task without a target between the previous task and this task, which is why we use .first here.  If we find a scenario where that happens, we can revise this.  (We use .first rather than .only so we don't drop something on the floor that we are capable of reporting.)
                            if task.isGate, let previousTask = savedTasks.first?.task, previousTask.isGate {
                                // Resolve the dependency between the previous target and this one.
                                let resolvedTargetDependency = previousTargetDependencies.filter({ $0.target == configuredTarget }).only

                                // We only note that manual target order is in use if we see that we've crossed a target boundary but we couldn't find an expressed target dependency.  Otherwise it (in theory) doesn't matter whether manual target order is in use, because the target dependencies in the cycle should be the same even if it weren't.
                                if resolvedTargetDependency == nil, !buildDescription.targetsBuildInParallel {
                                    involvesManualTargetOrder = true
                                }

                                // Create a new custom task with the message describing the dependency between these targets.
                                // Note that we would only not have a previous target here if we're still in the first target of the cycle.  But we should find the dependency again later on.
                                // FIXME: This doesn't handle the case where the workspace has multiple targets with the same name (in different projects).
                                let targetName = configuredTarget.target.name
                                let previousTargetName = previousConfiguredTarget.target.name
                                let message: String
                                switch resolvedTargetDependency?.reason {
                                case .explicit?:
                                    message = "Target '\(previousTargetName)' has an explicit dependency on Target '\(targetName)'"
                                case let .implicitBuildPhaseLinkage(filename, _, buildPhase)?:
                                    message = "Target '\(previousTargetName)' has an implicit dependency on Target '\(targetName)' because '\(previousTargetName)' references the file '\(filename)' in the build phase '\(buildPhase)'"
                                case let .implicitBuildSettingLinkage(settingName, options)?:
                                    message = "Target '\(previousTargetName)' has an implicit dependency on Target '\(targetName)' because '\(previousTargetName)' defines the option '\(options.joined(separator: " "))' in the build setting '\(settingName)'"
                                case let .impliedByTransitiveDependencyViaRemovedTargets(intermediateTargetName: intermediateTargetName):
                                    message = "Target '\(previousTargetName)' has a dependency on Target '\(targetName)' via its transitive dependency through '\(intermediateTargetName)'"
                                case nil:
                                    if !buildDescription.targetsBuildInParallel {
                                        message = "Target '\(previousTargetName)' is ordered after Target '\(targetName)' in a “Target Dependencies” build phase" + (buildRequest.schemeCommand != nil ? " or in the scheme" : "")
                                    } else {
                                        message = "Target '\(previousTargetName)' depends on Target '\(targetName)', but the reason for the dependency could not be determined"
                                    }
                                }

                                messagePayloads = [DependencyCycleMessagePayload(configuredTarget, .message(message))]
                            }

                            // If the two tasks are not gate tasks, then we're crossing a target boundary for a different reason and we need to create a message from the tasks and the intervening node.
                            else {
                                messagePayloads = savedTasks.enumerated().map({ index, saved in DependencyCycleMessagePayload( index == 0 ? previousConfiguredTarget : nil, .rule(saved.rule)) }) +
                                    [DependencyCycleMessagePayload(configuredTarget, .rule(rule))]
                            }
                        }

                        // Record the current target as the new previous target.  Also zero out previousTargetDependencies since we're in a new target.
                        previousConfiguredTarget = configuredTarget
                        previousTargetDependencies = []
                    }

                    // Save this task rule and task.
                    savedTasks = [(rule, task)]
                }
                else {
                    // If this task doesn't have a target, then add this task rule and task to the saved list so we have tasks going back to the last task with a target.
                    savedTasks.append((rule, task))
                }

                // If this task has target dependencies, then record them as the previous target's dependencies.
                // Note that only (some?) gate tasks populate this property; see the comment in ExecutableTask.targetDependencies.
                if !task.targetDependencies.isEmpty {
                    previousTargetDependencies = task.targetDependencies
                }
            }

            return messagePayloads
        }) as [[DependencyCycleMessagePayload]]).reduce([], +)

        // Create the formatted output for the cycle.
        let messages: [(target: ConfiguredTarget?, message: String)] = try cycleMessagePayloads.compactMap { payload in
            if let message = try payload.message(with: self) {
                return (payload.target, message)
            }
            return nil
        }

        // Partition messages into a separate array for each contiguous set of messages which belong to the same target (or to no target).  This is so our caller can add appropriate prefix characters to them.
        var currentMessages = [String]()
        var currentTarget: ConfiguredTarget? = nil
        var messagesByTarget = [[String]]()
        for (target, message) in messages {
            if target == nil || target == currentTarget {
                currentMessages.append(message)
            } else {
                if !currentMessages.isEmpty {
                    messagesByTarget.append(currentMessages)
                    currentMessages.removeAll()
                }
                currentTarget = target
                currentMessages.append(message)
            }
        }
        messagesByTarget.append(currentMessages)

        return (messagesByTarget, involvesManualTargetOrder)
    }

    // FIXME: This is still using the logic from the pre-Aug 2023 class, and it can likely be updated to use some of the rewritten infrastructure for the multi-target logic above, as well as improving its approach overall.
    //
    /// Generate the filtered and formatted output for a cycle within a single target.
    ///
    /// This reports all tasks in the cycle.
    private func formattedSingleTargetCycleOutput(_ cycleRules: [BuildKey]) throws -> [[String]] {
        // For target dependencies, remove the task that led to it.
        var effectiveRules = cycleRules
        for rule in cycleRules.enumerated().dropLast(4) {
            let nodePairs = [("entry", "end"),
                             ("begin-compiling", "modules-ready"),
                             ("begin-linking", "linker-inputs-ready")]

            for (begin, end) in nodePairs {
                // Check if the successor build keys match a target dependency:
                // target entry node => target entry gate task => target end node => target end gate task
                if let cmd = self.executableTask(for: cycleRules[rule.offset + 2]), cmd.taskType == .beginTargetTask(targetName: ""), cycleRules[rule.offset + 1].key.hasSuffix("-\(begin)>")  {
                    if let cmd = self.executableTask(for: cycleRules[rule.offset + 4]), cmd.taskType == .endTargetTask(targetName: ""), cycleRules[rule.offset + 3].key.hasSuffix("-\(end)>") {
                        // If they do, replace the current task, because only the target's name is relevant but not the concrete task.
                        if let targetName = self.executableTask(for: rule.element)?.forTarget?.target.name {
                            effectiveRules[rule.offset] = BuildKey.CustomTask(name: targetName, taskData: "Target '\(targetName)'")
                        }
                    }
                }
            }
        }

        // Mark target dependencies
        var lastTargetsDependencies = [ResolvedTargetDependency]()
        var lastTargetsName: String?
        let filteredRules: [BuildKey] = effectiveRules.compactMap {
            if let cmd = self.executableTask(for: $0) {
                switch cmd.taskType {
                case .beginTargetTask(let targetName):
                    lastTargetsName = targetName
                    lastTargetsDependencies = cmd.targetDependencies
                    return nil
                case .endTargetTask(let targetName):
                    // FIXME: <rdar://96577920> Target names are not globally unique; compare on the ConfiguredTarget instance
                    let resolvedTargetDependency = lastTargetsDependencies.filter({ $0.target.target.name == targetName }).only

                    if let lastTargetsName = lastTargetsName {
                        let suffix: String
                        switch resolvedTargetDependency?.reason {
                        case .explicit?:
                            suffix = " via the “Target Dependencies“ build phase"
                        case let .implicitBuildPhaseLinkage(filename, _, buildPhase)?:
                            suffix = " because the scheme has implicit dependencies enabled and the Target '\(lastTargetsName)' references the file '\(filename)' in the build phase '\(buildPhase)'"
                        case let .implicitBuildSettingLinkage(settingName, options)?:
                            suffix = " because the scheme has implicit dependencies enabled and the Target '\(lastTargetsName)' defines the options '\(options.joined(separator: " "))' in the build setting '\(settingName)'"
                        case let .impliedByTransitiveDependencyViaRemovedTargets(intermediateTargetName: intermediateTargetName):
                            suffix = " via its transitive dependency through '\(intermediateTargetName)'"
                        case nil:
                            if !buildDescription.targetsBuildInParallel {
                                suffix = " due to target order in a “Target Dependencies” build phase" + (buildRequest.schemeCommand != nil ? " or the scheme" : "")
                            } else {
                                suffix = ""
                            }
                        }

                        return BuildKey.CustomTask(name: lastTargetsName, taskData: "Target '\(lastTargetsName)' has dependency on Target '\(targetName)'\(suffix)")
                    } else {
                        return $0
                    }
                default:
                    break
                }
            }

            return $0
        }

        // Detailed output for the cycle.
        let cycleOutput: [String] = try filteredRules.compactMap {
            switch $0 {
            case let rule as BuildKey.Command:
                if let cmd = self.executableTask(for: rule) {
                    return cmd.formattedRuleInfo(for: .dependencyCycle)
                } else {
                    return nil
                }
            case let rule as BuildKey.CustomTask:
                if let dynamicTask = dynamicTaskForCustomTask(rule) {
                    guard let spec = DynamicTaskSpecRegistry.spec(for: dynamicTask.toolIdentifier) else {
                        return "Dynamic task with unknown spec \(dynamicTask.toolIdentifier)"
                    }
                    let cmd = try spec.buildExecutableTask(dynamicTask: dynamicTask, context: dynamicTaskContext)
                    return cmd.formattedRuleInfo(for: .dependencyCycle)
                } else {
                    return rule.taskData
                }
            case is BuildKey.DirectoryContents, is BuildKey.FilteredDirectoryContents:
                // Filter directory contents build keys
                return nil
            case is BuildKey.DirectoryTreeSignature, is BuildKey.DirectoryTreeStructureSignature:
                // Filter directory tree signatures
                return nil
            case is BuildKey.Node, is BuildKey.Stat:
                // Filter out nodes
                return nil
            case let rule as BuildKey.Target:
                // Include targets, but filter the root one ""
                let targetName = rule.name
                return targetName.isEmpty ? nil : "Target \(targetName)"
            default:
                if $0.kind == .unknown { return nil }
                // Filter unknown enum cases; we can't know what to do here
                fatalError("Unknown value '\($0.kind.rawValue)' in \(type(of: $0.kind)) enumeration")
            }
        }

        return [cycleOutput]
    }

    /// "Raw" cycle, just as we got it from llbuild.
    func llbuildFormattedCycle() -> String {
        var foundCycle = false
        var message = "Raw dependency cycle trace:\n\n"
        message += rules.enumerated().flatMap({ index, rule -> [String] in
            let prefix: [String]
            if !foundCycle, index < rules.count - 1, rule == rules.last {
                prefix = ["CYCLE POINT"]
                foundCycle = true
            } else {
                prefix = []
            }
            return prefix + [llbuildFormatted(rule: rule)]
        }).joined(separator: " ->\n\n")
        assert(foundCycle, "We should always have been able to find the cycle start and end points.")
        return message
    }

    private func llbuildFormatted(rule: BuildKey) -> String {
        let rawDescription: String
        switch rule {
        case let rule as BuildKey.CustomTask:
            if let dynamicTask = dynamicTaskForCustomTask(rule) {
                rawDescription = dynamicTask.taskKey.debugDescription
            } else {
                rawDescription = String(bytes: rule.keyData, encoding: .utf8) ?? rule.key
            }
            default:
                rawDescription = rule.key
        }
        return "\(rule.kind): \(rawDescription)"
    }

    /// Look up and return an `ExecutableTask` from the `BuildDescription` if `buildKey` is a command.
    private func executableTask(for buildKey: BuildKey) -> (any ExecutableTask)? {
        return  buildKey.kind == .command ? buildDescription.taskStore.task(for: TaskIdentifier(rawValue: buildKey.key)) : nil
    }

    /// Grab target names from the rules involved in the cycle.
    private func targetNamesInvolvedInCycle(_ cycleRules: [BuildKey]) -> [String] {
        // We just iterate through all the rules, for each rule we check if it's a task that has a target name, if so we add it to the list of target names.
        // We also filter out consecutive identical target names.
        var lastTargetName = ""
        var targetNames = cycleRules.compactMap {
            if let task = self.executableTask(for: $0), let targetName = task.forTarget?.target.name {
                let isNewTarget = (lastTargetName != targetName)
                lastTargetName = targetName
                return isNewTarget ? targetName : nil
            }
            return nil
        }

        // Make sure the cycle starts and ends with the same target.  If it doesn't, then we add the first target as the last target.  (This seems a little sketchy but is how it's always worked.)
        if targetNames.first != targetNames.last {
            targetNames.append(targetNames.first!)
        }

        return targetNames
    }

}
