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

/// Defines criteria for determining whether a task should be included in the build plan.
public protocol TaskValidityCriteria: Sendable {
    /// Returns true if the task satisfying these criteria should be included in the build.
    /// - Parameters:
    ///   - task: The task being validated
    ///   - context: The validation context providing information about all tasks in the build
    func isValid(_ task: any PlannedTask, _ context: any TaskValidationContext) -> Bool
}

/// A task validation context exposes information a task needs to determine whether it should be included in the build.
public protocol TaskValidationContext: AnyObject {
    /// The set of paths which have been declared as inputs to one or more tasks.
    var inputPaths: Set<Path> { get }

    /// The set of paths which have been declared as outputs of one or more tasks.
    var outputPaths: Set<Path> { get }

    /// The set of paths which have been declared as inputs to one or more tasks, plus all of their ancestor directories.
    var inputPathsAndAncestors: Set<Path> { get }

    /// The set of paths which have been declared as outputs of one or more tasks, plus all of their ancestor directories.
    var outputPathsAndAncestors: Set<Path> { get }
}

public struct DirectoryCreationValidityCriteria: TaskValidityCriteria {
    public let directoryPath: Path
    public let nullifyIfProducedByAnotherTask: Bool

    public init(directoryPath: Path, nullifyIfProducedByAnotherTask: Bool) {
        self.directoryPath = directoryPath
        self.nullifyIfProducedByAnotherTask = nullifyIfProducedByAnotherTask
    }

    public func isValid(_ task: any PlannedTask, _ context: any TaskValidationContext) -> Bool {
        if nullifyIfProducedByAnotherTask {
            // If there is another task creating exactly this path, then we don't need to
            guard !context.outputPaths.contains(directoryPath) else {
                return false
            }
        }

        // Task is valid if any task is putting files in the directory or descendants,
        // or if any task has an input in that directory or descendants.
        return context.outputPathsAndAncestors.contains(directoryPath)
            || context.inputPathsAndAncestors.contains(directoryPath)
    }
}

public struct SymlinkCreationValidityCriteria: TaskValidityCriteria {
    public let symlinkPath: Path
    public let destinationPath: Path

    public init(symlinkPath: Path, destinationPath: Path) {
        self.symlinkPath = symlinkPath
        self.destinationPath = destinationPath
    }

    public func isValid(_ task: any PlannedTask, _ context: any TaskValidationContext) -> Bool {
        // Symlink is valid if some task is going to generate content at its destination.
        return context.outputPathsAndAncestors.contains(destinationPath)
    }
}

public struct PostprocessingValidityCriteria: TaskValidityCriteria {
    public init() {}

    public func isValid(_ task: any PlannedTask, _ context: any TaskValidationContext) -> Bool {
        // Task is valid if any of its input files is being generated.
        for input in task.inputs {
            if let inputPath = (input as? PlannedPathNode)?.path {
                if context.outputPathsAndAncestors.contains(inputPath) {
                    return true
                }
            }
        }
        return false
    }
}
