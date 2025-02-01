# Dynamic Tasks

## Architecture Overview

Swift Build uses llbuild to invoke a planned build by creating a build manifest (see `BuildDescription` and related files). This manifest is created during task construction and is immutable.
llbuild's execution mechanism on the other hand doesn't require an immutable manifest. It needs tasks to provide their inputs (files or other tasks), a callback to indicate if a previously produced build value is still valid and another callback to produce that build value. To create the tasks, llbuild uses the manifest with its command/inputs/outputs declarations.
A file that is an output to a task has a reference to this task as its producer. Other tasks using this file as an input define it as input.

Dynamic tasks in Swift Build use this API for tasks that are unknown at task construction time and get discovered during task execution. Since downstream tasks need to be blocked until the yet unknown tasks finished, there needs to be an upfront planned task that provides gates around dynamic tasks.
Example: Swift compilation frontend invocations are dynamic tasks but they need to block linking which is planned upfront. Take make this work, there's an upfront planned task that requests those dynamic tasks but also specifies their expected outputs as its own outputs. That blocks downstream tasks until the requested dynamic tasks all finished.

## Concrete Implementation

Tasks in llbuild implement the abstract class `Command` - most that are used in Swift Build are using `ExternalCommand`. `ExternalCommand` encodes the logic to define input and output nodes, it requests inputs and checks for outputs on incremental builds. It also creates parent directories for expected outputs. Subclasses override `executeExternalCommand` to perform the actual work.
Tools that Swift Build invokes outside via their command line interface use `ShellCommand` which spawns a process using the provided command line options. Dynamic tasks go through `CAPIExternalCommand` which wraps the API to the Swift interface.
Swift Build implements those via `InProcessCommand` that represents task actions (in-process work) and dynamic tasks that get created by their defined `DynamicTaskSpec` (`DynamicTaskSpecRegistry.implementations`).

### Execution Flow

Let's use a simplified example of tasks to compile two Swift files with a following link step. With the Swift driver implementation utilizing dynamic tasks, there's one upfront planned task to request dynamic tasks which blocks the downstream linker task. The linker produces the product of interest, so llbuild reads the manifest and creates a command for it. The command (`ShellCommand`) specifies a command line and inputs/outputs. The inputs are .o files, so when they get requested, llbuild will request each producer of those files.
In this simplified example, the only producer is the upfront planned task which has both Swift files as inputs and the .o files as outputs. But it doesn't create them, it requests dynamic tasks. First, the driver planning task that runs in process and initializes the driver and let's it create a planned build. It then uses this planned build to request other dynamic tasks for the frontend invocations. Those create the actual .o files that the gate-task expects so it finishes and unblocks llbuild in executing the linker task.

![](dynamic-tasks-execution-flow.png)

### Setup

Here's an overview of the classes in llbuild (green) and Swift Build (blue) that are required to request and execute dynamic tasks:

![](dynamic-tasks-setup.png)

The callbacks in TaskAction use defined state and allow for different work:

#### taskSetup

This might get called multiple times on the same `TaskAction` instance and should reset every state. It allows the task action to request tasks (`dynamicExecutionDelegate.requestDynamicTask`) or file inputs (`dynamicExecutionDelegate.requestInputNode`). Every request takes an identifier that needs to be unique over all inputs (files and tasks) represented by the `nodeID`/`taskID` of the interface.
Example: Swift driver planning is requested for a Swift driver job scheduling action in taskSetup - it needs to be requested, no matter what.

#### taskDependencyReady

This gets called for every input (potentially multiple times). The provided `dependencyID` matches the previously provided `nodeID`/`taskID`. This callback also allows to request more work.
Example: Once driver planning finishes, this callback is used to use the result of planning and schedule driver jobs itself.

#### performTaskAction

In this state it's not possible to request any more inputs. It is guaranteed that all requested inputs successfully provided a build value in the `taskDependencyReady` callback. Keep in mind that the value does not necessarily represents a successful state - it might be failed, missing or invalid.
`performTaskAction` is meant to validate local state like previously generated errors (failed inputs) and to do the actual work of the task action.
Example: Swift driver planning is a dynamic task that calls the driver in `performTaskAction`, SwiftDriverJobTaskAction executes the compiler frontend invocation via the provided llbuild spawn interface.
