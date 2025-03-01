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
import SWBTaskConstruction
import SWBTaskExecution
package import Testing

package protocol TasksCheckingResult {
    associatedtype Task

    var uncheckedTasks: [Task] { get }

    func removeMatchedTask(_ task: Task)

    func _match(_ task: Task, _ condition: TaskCondition) -> Bool
    func _shouldPrecede(_ lhs: Task, _ rhs: Task) -> Bool

}

extension TasksCheckingResult where Task == any PlannedTask {
    package func _match(_ task: Task, _ condition: TaskCondition) -> Bool {
        condition.match(task)
    }

    package func _shouldPrecede(_ lhs: Task, _ rhs: Task) -> Bool {
        lhs.execTask.shouldPrecede(rhs.execTask)
    }
}

extension TasksCheckingResult where Task: ExecutableTask {
    package func _match(_ task: Task, _ condition: TaskCondition) -> Bool {
        condition.match(task)
    }

    package func _shouldPrecede(_ lhs: Task, _ rhs: Task) -> Bool {
        lhs.shouldPrecede(rhs)
    }
}

extension TasksCheckingResult {
    private var sortedTasks: [Task] {
        uncheckedTasks.sorted(by: { _shouldPrecede($0, $1) })
    }

    private func matchAll(_ task: Task, _ conditions: [TaskCondition]) -> Bool {
        conditions.allSatisfy { _match(task, $0) }
    }

    /// Get all unmatched tasks matching the given conditions.
    package func findMatchingTasks(_ conditions: [TaskCondition]) -> [Task] {
        return uncheckedTasks.filter { matchAll($0, conditions) }
    }

    /// Get one task matching the given conditions.  Emit an error and return nil if there are no matching tasks, or multiple matching tasks.
    package func findOneMatchingTask(_ conditions: [TaskCondition], sourceLocation: SourceLocation = #_sourceLocation) -> Task? {
        let matchedTasks = findMatchingTasks(conditions)
        if matchedTasks.isEmpty {
            Issue.record("unable to find any task matching conditions '\(conditions)', among tasks: '\(sortedTasks.map{ String(describing: $0) }.joined(separator: ",\n\t"))'", sourceLocation: sourceLocation)
            return nil
        } else if matchedTasks.count > 1 {
            Issue.record("found multiple tasks matching conditions '\(conditions)', found: \(matchedTasks)", sourceLocation: sourceLocation)
            return nil
        } else {
            return matchedTasks[0]
        }
    }

    /// Find and return a task matching the given conditions.
    ///
    /// If there is no such task, or if there are multiple tasks matching the given conditions, then a test error will be emitted and nil will be returned.
    package func getTask(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) -> Task? {
        return findOneMatchingTask(conditions, sourceLocation: sourceLocation)
    }

    /// Find a task matching the given conditions, and check it.
    ///
    /// It is a test error if there is no such task, or if there are multiple tasks matching the given conditions.
    package func checkTask<T>(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation, body: (Task) -> T) -> T? {
        return checkTask(conditions, sourceLocation: sourceLocation, body: body)
    }

    /// Find a task matching the given conditions, and check it.
    ///
    /// It is a test error if there is no such task, or if there are multiple tasks matching the given conditions.
    @_disfavoredOverload package func checkTask<T>(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation, body: (Task) throws -> T) throws -> T {
        return try checkTask(conditions, sourceLocation: sourceLocation, body: body)
    }

    /// Find a task matching the given conditions, and check it.
    ///
    /// It is a test error if there is no such task, or if there are multiple tasks matching the given conditions.
    package func checkTask<T>(_ conditions: [TaskCondition], sourceLocation: SourceLocation = #_sourceLocation, body: (Task) -> T) -> T? {
        if let task = findOneMatchingTask(conditions, sourceLocation: sourceLocation) {
            // Remove the task.
            removeMatchedTask(task)

            // Run the matcher.
            return body(task)
        } else {
            return nil
        }
    }

    /// Find a task matching the given conditions, and check it.
    ///
    /// It is a test error if there is no such task, or if there are multiple tasks matching the given conditions.
    @_disfavoredOverload package func checkTask<T>(_ conditions: [TaskCondition], sourceLocation: SourceLocation = #_sourceLocation, body: (Task) throws -> T) throws -> T {
        if let task = findOneMatchingTask(conditions, sourceLocation: sourceLocation) {
            // Remove the task.
            removeMatchedTask(task)

            // Run the matcher.
            return try body(task)
        } else {
            return try #require(nil) // findOneMatchingTask has already emitted a failure message with a nice error
        }
    }

    /// Find and return all tasks matching the given conditions.
    package func getTasks(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) -> [Task] {
        return findMatchingTasks(conditions)
    }

    /// Find all tasks matching the given conditions, and check them.
    package func checkTasks<T>(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation, body: (GenericSequence<Task>) throws -> T) rethrows -> T {
        // Find the task matching the conditions.
        let matchedTasks = findMatchingTasks(conditions)

        // Remove the tasks.
        matchedTasks.forEach(removeMatchedTask)

        // Run the matcher.
        return try body(GenericSequence(matchedTasks))
    }

    /// Check that a single task exists matching the given conditions.
    package func checkTaskExists(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) {
        if let task = findOneMatchingTask(conditions, sourceLocation: sourceLocation) {
            // Remove the task.
            removeMatchedTask(task)
        }
    }

    /// Check that no task exists matching the given conditions.
    package func checkNoTask(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) {
        checkNoTask(conditions, sourceLocation: sourceLocation)
    }

    /// Check that no task exists matching the given conditions.
    package func checkNoTask(_ conditions: [TaskCondition], sourceLocation: SourceLocation = #_sourceLocation) {
        for matchedTask in findMatchingTasks(conditions) {
            Issue.record("found unexpected task matching conditions '\(conditions)', found: \(matchedTask)", sourceLocation: sourceLocation)
        }
    }

    /// Consume all tasks with the given rule type.  This is convenient for debugging to consume (remove) many tasks which are not relevant to the functionality being tested.
    ///
    /// This method may be optionally constrained to matching tasks from a single target.
    ///
    /// By default this will consume all tasks of a set of types which are commonly not interesting to check in most tests.  But some tests will in fact be interested in some of these types and should not exclude them.
    package func consumeTasksMatchingRuleTypes(_ ruleTypes: Set<String> = ["Gate", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "ClangStatCache", "LinkAssetCatalogSignature"], targetName: String? = nil) {
        for ruleType in ruleTypes {
            var conditions: [TaskCondition] = [.matchRuleType(ruleType)]
            if let targetName {
                conditions.append(.matchTargetName(targetName))
            }

            // Find the tasks matching the conditions.
            let matchedTasks = findMatchingTasks(conditions)

            // Remove the tasks.
            matchedTasks.forEach(removeMatchedTask)
        }
    }
}

package protocol CommandLineCheckable {
    var commandLineAsByteStrings: [ByteString] { get }
}

extension CommandLineCheckable {
    private var _commandLineAsStrings: [String] {
        return commandLineAsByteStrings.map { $0.asString }
    }

    /// Checks that the receiver's command line is exactly the given strings.
    package func checkCommandLine(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        XCTAssertEqualSequences(_commandLineAsStrings, strings, sourceLocation: sourceLocation)
    }

    /// Workhorse method to check that the receiver contains all of the strings in `strings`, and in the given order, but allows there to be other strings between the elements of `strings`.
    private func _checkCommandLineContains(_ strings: [String]) -> String? {
        let commandLineStrings = _commandLineAsStrings
        let commandLineString = _commandLineAsStrings.quotedDescription
        var startSearchIdx = 0
        var lastStringFound: String? = nil
        for string in strings {
            var found = false
            var curIdx = startSearchIdx
            while curIdx < commandLineStrings.count, !found {
                if commandLineStrings[curIdx] == string {
                    found = true
                }
                // Always advance to the next index after the match, to start the search for the next string
                curIdx += 1
            }

            if !found {
                // Report that we couldn't find this string.
                if let lastStringFound = lastStringFound {
                    return "couldn't find string '\(string)' after string '\(lastStringFound)' in command line: \(commandLineString)"
                }
                else {
                    return "couldn't find string '\(string)' in command line: \(commandLineString)"
                }
            }
            else {
                // If we found a match, then remember the last string found and advance the startSearchIdx to search for the next string.
                lastStringFound = string
                startSearchIdx = curIdx
            }
        }

        return nil
    }

    /// Checks that the receiver's command line contains the given string.
    package func checkCommandLineContains(_ string: String, sourceLocation: SourceLocation = #_sourceLocation) {
        if let error = _checkCommandLineContains([string]) {
            Issue.record(Comment(rawValue: error), sourceLocation: sourceLocation)
        }
    }

    /// Checks that the receiver contains all of the strings in `strings`, and in the given order, but allows there to be other strings between the elements of `strings`.
    package func checkCommandLineContains(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        if let error = _checkCommandLineContains(strings) {
            Issue.record(Comment(rawValue: error), sourceLocation: sourceLocation)
        }
    }

    /// Checks that the receiver's command line contains the given strings in the given order without interruption.
    package func checkCommandLineContainsUninterrupted(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(_commandLineAsStrings.contains(strings), "couldn't find sequence \(strings) in \(_commandLineAsStrings)", sourceLocation: sourceLocation)
    }

    /// Checks that the receiver's command line does not contain the given string.
    package func checkCommandLineDoesNotContain(_ string: String, sourceLocation: SourceLocation = #_sourceLocation) {
        if _commandLineAsStrings.contains(string) {
            Issue.record("found string '\(string)' in command line: \(_commandLineAsStrings.quotedDescription)", sourceLocation: sourceLocation)
        }
    }

    // We presently don't have a method to check that a command line does not contain an array of strings in a non-contiguous block.

    /// Checks that the receiver's command line does not contain the given strings as a contiguous block.
    package func checkCommandLineDoesNotContainUninterrupted(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        if _commandLineAsStrings.contains(strings) {
            Issue.record("found sequence '\(strings)' in command line: \(_commandLineAsStrings.quotedDescription)", sourceLocation: sourceLocation)
        }
    }

    package func checkCommandLineMatches(_ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
        let directlyComparable = _commandLineAsStrings.count == patterns.count && !patterns.contains(where: {
            switch $0 {
                // These cases never matches individual items, they are just used for matching string lists.
            case .start, .end, .anySequence:
                return true
            case .any, .contains, .equal, .regex, .prefix, .suffix, .and, .or, .not, .pathEqual:
                return false
            }
        })
        let matchMessage: String?
        if directlyComparable {
            var messageComponents = _commandLineAsStrings.enumerated().compactMap { index, value in
                if !(patterns[index] ~= value) {
                    func patternDescription(pattern: StringPattern) -> String {
                        switch pattern {
                        case .start, .end, .anySequence:
                            preconditionFailure("Unreachable")
                        case .any:
                            "pattern 'any'"
                        case let .contains(infix):
                            "pattern 'contains' with infix '\(infix)'"
                        case let .equal(value):
                            "pattern 'equal' with value '\(value)'"
                        case let .regex(regex):
                            "pattern 'regex' with expression '\(regex)'"
                        case let .prefix(prefix):
                            "pattern 'prefix' with prefix '\(prefix)'"
                        case let .suffix(suffix):
                            "pattern 'suffix' with suffix '\(suffix)'"
                        case let .and(lhs, rhs):
                            "pattern 'and' with lhs '\(patternDescription(pattern: lhs))' and rhs '\(patternDescription(pattern: rhs))'"
                        case let .or(lhs, rhs):
                            "pattern 'or' with lhs '\(patternDescription(pattern: lhs))' and rhs '\(patternDescription(pattern: rhs))'"
                        case let .not(pattern):
                            "pattern 'not' with pattern '\(patternDescription(pattern: pattern))'"
                        case let .pathEqual(prefix, path):
                            if prefix.isEmpty {
                                "pattern 'pathEqual' with value '\(path.str)'"
                            } else {
                                "pattern 'pathEqual' with prefix '\(prefix)' and value '\(path.str)'"
                            }
                        }
                    }
                    return "Actual value '\(value)' at index \(index) did not match expectation: \(patternDescription(pattern: patterns[index]))"
                }
                return nil
            }
            // Emit the command line we're checking.  This is valuable when iterating on tests to we can see *where* in the command line the arguments are appearing.
            if !messageComponents.isEmpty {
                messageComponents.append("In command line: \(_commandLineAsStrings)")
            }
            matchMessage = messageComponents.joined(separator: "\n")
        } else {
            // If the pattern array is not equal in length to the actual command line, or the pattern contains multi-element patterns, we can't build a custom matching message.
            matchMessage = nil
        }
        XCTAssertMatch(self._commandLineAsStrings, patterns, matchMessage, sourceLocation: sourceLocation)
    }

    package func checkCommandLineNoMatch(_ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
        XCTAssertNoMatch(self._commandLineAsStrings, patterns, sourceLocation: sourceLocation)
    }

    package func checkCommandLineLastArgumentEqual(_ string: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(_commandLineAsStrings.last == string, sourceLocation: sourceLocation)
    }

    package func checkSandboxedCommandLine(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        checkCommandLineMatches([.equal("/usr/bin/sandbox-exec"), .anySequence] + strings.map { .equal($0) }, sourceLocation: sourceLocation)
    }
}

// Wraps an array in a way that prevents directly indexing into it.
package struct GenericSequence<Element>: Sequence {
    typealias IteratorFunction = Array<Element>.Iterator

    private let wrapped: [Element]

    package init(_ wrapped: [Element]) {
        self.wrapped = wrapped
    }

    package func makeIterator() -> AnyIterator<Element> {
        return AnyIterator(wrapped.makeIterator())
    }

    package var isEmpty: Bool {
        wrapped.isEmpty
    }

    package var count: Int {
        wrapped.count
    }

    package func sorted<C: Comparable>(by predicate: (Element) -> C) -> [Element] {
        wrapped.sorted(by: predicate)
    }
}

extension GenericSequence: Sendable where Element: Sendable {}

extension GenericSequence where Element: PlannedTask {
    @available(*, unavailable, message: "Don't index into the results of task checking because the results are not guaranteed to be ordered. Enumerate the results in a way that doesn't rely on a specific order, or if you need to check for a single task, use `checkTask` instead of `checkTasks`.")
    package subscript(position: Int) -> Element {
        preconditionFailure()
    }
}

extension GenericSequence where Element: ExecutableTask {
    @available(*, unavailable, message: "Don't index into the results of task checking because the results are not guaranteed to be ordered. Enumerate the results in a way that doesn't rely on a specific order, or if you need to check for a single task, use `checkTask` instead of `checkTasks`.")
    package subscript(position: Int) -> Element {
        preconditionFailure()
    }
}
