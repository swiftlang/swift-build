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


// MARK: Provisional task


/// A provisional task is a placeholder for work which might need to be done during the build, but the need for which is not known until all the tasks have been created for a product plan.
/// The primary purpose of a provisional task is to coordinate the creation of a task which spans multiple task producers.  For example, a directory which only needs to be created if some task will place a file there.
public class ProvisionalTask: CustomStringConvertible
{

    enum AssignedTask
    {
    case noTask
        case actualTask(any PlannedTask)
    }

    let identifier: String

    /// The assignment for this provisional task, which indicates either `NoTask` (if the provisional task is not needed), or an actual `PlannedTask` object.  If the task is still nil at the end of planning then this is an error.
    private(set) var assignedTask: AssignedTask? = nil

    /// Convenience property for the planned task for this provisional tasks.  Returns the planned task, if any, or nil if there is not one.  If `assignedTask` has not yet been populated by the end of product planning then this will result in an error.
    public var plannedTask: (any PlannedTask)?
    {
        precondition(assignedTask != nil, "Provisional task '\(self)' has an assignedTask value of nil.")
        guard case .actualTask(let plannedTask) = assignedTask! else { return nil }
        return plannedTask
    }

    /// Whether this provisional task was used (if its output node has any clients).
    private(set) var used: Bool = false

    /// The provisional node which represents the output of this task.
    let outputNode: ProvisionalNode

    public init(identifier: String, mustBeDependedOn: Bool = true)
    {
        self.identifier = identifier
        self.outputNode = ProvisionalNode()

        // If the task doesn't need to be depended on, then it is by definition always 'used'.  So it will be valid so long as it is fulfilled with an actual task and concrete node.
        if !mustBeDependedOn { used = true }
    }

    /// Returns true if the provisional task is valid, i.e., that it has an assigned task and is used by some other valid task.
    public func isValid(_ context: any ProvisionalTaskValidationContext) -> Bool
    {
        // If the provisional task was never assigned an actual task or marked as not having one then that is an error.
        precondition(assignedTask != nil, "Provisional task '\(self)' has an assignedTask value of nil.")

        // The task is only valid if it was assigned an actual task.
        guard case .actualTask(_) = assignedTask! else { return false }

        // If there is an actual task, then it is valid if its output node was used.
        return used
    }

    /// Fulfills the provisional task with the given planned task and (optional) output node.
    public func fulfill(_ plannedTask: any PlannedTask, _ plannedNode: (any PlannedNode)? = nil)
    {
        precondition(assignedTask == nil, "Provisional task '\(self)' has already been fulfilled.")

        assignedTask = AssignedTask.actualTask(plannedTask)
        outputNode.concreteNode = plannedNode

        // Also set ourself as the planned task's provisional task.
        plannedTask.provisionalTask = self
    }

    /// Explicitly marks the provisional task as not having an actual task.  This means the provisional task was not needed in task construction.
    public func fulfillWithNoTask()
    {
        precondition(assignedTask == nil, "Provisional task '\(self)' has already been fulfilled.")

        assignedTask = AssignedTask.noTask
    }

    /// Returns the output node for the receiver, and marks its used bit.
    public func dependsOn() -> ProvisionalNode
    {
        used = true
        return outputNode
    }

    public var description: String
    {
        return identifier
    }
}


/// A provisional node is a node for a provisional task which gets filled in by a concrete planned node.
public final class ProvisionalNode
{
    /// The concrete node this provisional node represents, if any.  It will end up being nil after task generation if no planned task is using this node.
    var concreteNode: (any PlannedNode)? = nil
}


/// A provisional task validation context exposes information a provisional task needs to determine whether its concrete planned task should be used, or should be nullified.
public protocol ProvisionalTaskValidationContext: AnyObject
{
    /// The set of paths which have been declared as inputs to one or more tasks.
    var inputPaths: Set<Path> { get }

    /// The set of paths which have been declared as outputs of one or more tasks.
    var outputPaths: Set<Path> { get }

    /// The set of paths which have been declared as inputs to one or more tasks, plus all of their ancestor directories.
    var inputPathsAndAncestors: Set<Path> { get }

    /// The set of paths which have been declared as outputs of one or more tasks, plus all of their ancestor directories.
    var outputPathsAndAncestors: Set<Path> { get }
}


// MARK: Special types of provisional task


/// A create directory provisional task is used in creating the product structure.
public final class CreateDirectoryProvisionalTask: ProvisionalTask {

    /// If `true`, then the task for this provisional task will be nullified if there is another task which is producing this directory.  If `false`, then the task will never be discarded for that reason.  We might want to nullify if, for example, the project is copying a folder reference into place for this directory.  However, if this directory task is going to be mutated - e.g. if it's the top-level product - then we don't want to nullify it, since we presently can't handle mutating an alternate task in this way.
    let nullifyIfProducedByAnotherTask: Bool

    public init(identifier: String, mustBeDependedOn: Bool = true, nullifyIfProducedByAnotherTask: Bool) {
        self.nullifyIfProducedByAnotherTask = nullifyIfProducedByAnotherTask

        super.init(identifier: identifier, mustBeDependedOn: mustBeDependedOn)
    }

    /// This validation method checks to see whether there are any other planned tasks which are generating output files in the directory being created, or any of its subdirectories.  This is useful because otherwise every planned task would need to perform this checking to validate the create directory provisional tasks.
    public override func isValid(_ context: any ProvisionalTaskValidationContext) -> Bool {
        // We replicate and override some of our superclass' logic here because we want to do something slightly different where the 'used' property is concerned.

        // If the provisional task was never assigned an actual task or marked as not having one then that is an error.
        precondition(assignedTask != nil, "Provisional task \(self) has an assignedTask value of nil.")

        // The task is only valid if it was assigned an actual task.
        guard case .actualTask(_) = assignedTask! else {
            return false
        }

        // If 'used' is true then we can return true immediately, since a planned task is directly referring to the directory we're creating.  If 'used' is false then we continue on to see if any planned tasks are referring to any subdirectories in the directory we're creating.
        guard !used else {
            return true
        }

        // Get the path for the directory we're creating.  If we get this far, the outputNode had better have a path.
        let directoryPath = outputNode.concreteNode!.path

        // If there is another task creating exactly this path, then we don't need to (unless we were created such that we should not nullify the task for this reason).
        if nullifyIfProducedByAnotherTask {
            guard !context.outputPaths.contains(directoryPath) else {
                return false
            }
        }

        // Our task is valid if any task is putting files in the directory path or one of its descendants, or if any task has as an input that is or is in that directory or one of its descendants.
        return context.outputPathsAndAncestors.contains(directoryPath)  ||  context.inputPathsAndAncestors.contains(directoryPath)
    }

}


/// A create symbolic link provisional task is used in creating the product structure.
public final class CreateSymlinkProvisionalTask: ProvisionalTask
{
    let descriptor: SymlinkDescriptor

    public init(identifier: String, descriptor: SymlinkDescriptor)
    {
        self.descriptor = descriptor

        super.init(identifier: identifier)
    }

    // This validation method checks that the destination of the symbolic link will be used by other planned tasks.
    public override func isValid(_ context: any ProvisionalTaskValidationContext) -> Bool
    {
        // We replicate and override some of our superclass' logic here because we want to do something slightly different where the 'used' property is concerned.

        // If the provisional task was never assigned an actual task or marked as not having one then that is an error.
        precondition(assignedTask != nil, "Provisional task \(self) has an assignedTask value of nil.")

        // The task is only valid if it was assigned an actual task.
        guard case .actualTask(_) = assignedTask! else { return false }

        // Compute the path for the destination of the symlink.  If we get this far, the outputNode had better have a path (if descriptor.toPath is relative).
        let destinationPath = descriptor.toPath.isAbsolute
                ? descriptor.toPath
                : outputNode.concreteNode!.path.dirname.join(descriptor.effectiveToPath ?? descriptor.toPath).normalize()

        // A symlink task is considered valid if some task is going to generate content at its destination path.
        return context.outputPathsAndAncestors.contains(destinationPath)

        // We may wish to refine this algorithm further in the future.  For example:
        //  - A symlink task might also only be valid if the directory in which it is to be created is otherwise going to be created.  Presently we don't check that.
        //  - A symlink task might be valid even if nothing is going to be created at its destination location.
    }

    public override var description: String
    {
        return "Symlink \(descriptor.location.str) -> \(descriptor.toPath.str)"
    }
}


/// A product postprocessing provisional task is used for tasks which post-process the binary or product.
public final class ProductPostprocessingProvisionalTask: ProvisionalTask
{
    // This validation method checks that the assigned task exists, and that at least one of its input files is being generated.
    public override func isValid(_ context: any ProvisionalTaskValidationContext) -> Bool
    {
        if !super.isValid(context)
        {
            return false
        }

        // The task is only valid if it was assigned an actual task.
        guard case .actualTask(let actualTask) = assignedTask! else { return false }

        // Our task is valid if any task is generating one of its input files.
        for input in actualTask.inputs
        {
            if let inputFile = input as? (PlannedPathNode)
            {
                if context.outputPathsAndAncestors.contains(inputFile.path)
                {
                    return true
                }
            }
        }
        return false
    }
}
