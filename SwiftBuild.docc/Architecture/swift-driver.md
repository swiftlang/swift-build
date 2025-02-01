# Swift Driver

This document will explain specifics about the Swift driver planning invocation and execution.

Check out <doc:dynamic-tasks> for background about how dynamic tasks in Swift Build work.

## Difference to clang

Swift has no header files, so it needs to generate modules that downstream targets can depend their compilation on. Due to the absence of header files the compiler also needs to parse in multiple files (in fact, all files of the same target + Swift modules from upstream targets) to reason about declarations within the source.
Swift uses different compilation modes for that to split up that work. Whole module optimization *(which is also an optimization level, we focus on the compilation mode here)* parses and compiles all files within the context of one long running process that also produces all .o files of that target. Single file *(not available in the build settings editor anymore)* spawns one process per file - each process needs to parse all files but compilation is focused on this one file. And batch mode, the default - now called incremental, is in between. It spawns n processes for m files and forms batches to compile a given number of source files per process.
The creation of those processes and the orchestration between them is owned by Swift driver.

## Legacy Swift Driver

The legacy Swift driver integration in Swift Build calls `swiftc` as a command line utility, waits for it to finish and parses a JSON based stdout protocol to show sub-processes in the build log:

![](swift-driver-legacy.png)

This has fundamental problems for the build system:

* `swiftc` spawns processes to parallelize work and utilize the CPU. Swift Build tries the same but without a complex communication protocol they compete against each other bringing the system to a halt in the worst case
  * Example:
    * Swift Build spawns cpu.count processes in parallel (if possible, given the dependency graph)
    * Swift driver spawns cpu.count frontend processes in parallel (for compilation those are always independent)
    * This results in n*n processes, so the problem grows with the number of cores
* Swift Build always needs to wait for `swiftc` to finish although the necessary products to unblock downstream tasks (Swift module) can get created eagerly
* Process spawning is a complex operation with many parameters, Swift Build uses llbuild for that which spawns every build system task the same way. Swift driver needs to replicate this or do it differently

## New architecture

![](swift-driver-new1.png)

With the new integration of Swift driver, Swift Build calls into it using a library interface (libSwiftDriver.dylib → part of Xcode toolchain). Instead of one task to call the Swift driver (swiftc before), there are two tasks. SwiftDriver Compilation does the actual compilation of the files, creating .o files to unblock the linker. SwiftDriver Compilation Requirements on the other hand only produces the Swift module. It can and should run in parallel to compilation to eagerly unblock downstream tasks.
Here’s an overview of the dynamic tasks that are scheduled in the different buckets (Emit-Module and Compile are using the same task action SwiftDriverJobTaskAction):

![](swift-driver-new2.png)

## Incremental Builds

Usually llbuild decides if a task needs to re-run based on a) an input has changed or b) the output is not valid anymore. An invalid output has multiple possible causes, it could be a missing/deleted/never created file but it could also be that a task defines that the previous output is always invalid - meaning the task always needs to re-run.
Swift driver does something similar, it keeps an incremental state and collects timestamps. On subsequent builds it reads in the incremental state and schedules only driver jobs that need to re-run.
For the integration of Swift driver in Swift Build the decision was made to give Swift driver the sovereignty of incremental state for Swift. So Swift Build will always ask the driver about what tasks to run.
