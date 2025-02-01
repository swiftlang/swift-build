# Build System Architecture

This document surveys the architecture of the Swift Build build system, from the lowest layers to the highest.

## General Structure

Swift Build runs as a service process separate from the SwiftPM or Xcode process it's associated with.  Clients start a SWBBuildService process on demand, and there is a single SWBBuildService process per client process.  Clients and SWBBuildService communicate via serialized messages across a pipe.

Swift Build is structured in layers of framework targets.  For the most part this is a vertical stack of frameworks, although in some places there are multiple peer frameworks.  Swift Build makes extensive use of protocols to achieve this layering, and to control access to data.

Swift Build is built on top of the [llbuild](https://github.com/apple/swift-llbuild) project, an open-source build system.  llbuild is included as a library in SWBBuildService's address space, as opposed to running as a separate process. SWBBuildService and llbuild will communicate bidirectionally, with SWBBuildService instructing llbuild to perform work, and llbuild calling back to SWBBuildService for additional information it needs.

- - -

## Low-Level Build System

**Framework:** SWBLLBuild

The low-level build system is little more than a shim layer on top of llbuild and its own `BuildSystem` subcomponent, providing Swift bindings on top of the C API in a form suitable for use by Swift Build.

This layer ideally would eventually be replaced by official llbuild Swift bindings supplied directly from the project.

## Utility Frameworks

**Frameworks:** SWBUtil, SWBCSupport

SWBUtil contains utility code used across all other layers of Swift Build frameworks.  These include extensions to standard libraries, implementations of standard-library-like classes (e.g., *OrderedSet*), covers for Foundation code (e.g. *PropertyList*), covers for POSIX code (e.g., *FSProxy*, *Process*) and other utility code.  Code in SWBUtil is arguably not specific to Swift Build and might be of interest to any project.

SWBCSupport contains a small amount of C or Objective-C code bridged into Swift.

**Testing:** SWBUtil tests are often true "unit" tests, exercising small and well-defined behaviors.  Tests of SWBUtil classes should be reasonably complete along with the implementation of the classes.

There are presently no tests for SWBCSupport code.  Ideally all code will will eventually be ported to Swift inside the proper framework with proper tests written.  If we determine that some of this code should remain non-Swift code, we should still consider whether it should be moved elsewhere, and we should still write tests to exercise it.

## Core Framework

**Framework:** SWBCore

SWBCore contains classes which are used at multiple higher layers of Swift Build, but unlike SWBUtil are specific to Swift Build.  It includes several key subsystems:

### Macros

This is the engine used for build setting evaluation.  Build settings are declared as having a type (usually string or string-list), string expressions are parsed so they can be evaluated when requested, and then those expressions are evaluated using a `MacroEvaluationScope` for a particular context.

### Settings

The `Settings` class contains build settings and other information bound for a particular target (or, occasionally, other configurations) to be able to build that target.  A `Settings` object has a complicated creation procedure (encapsulated in the class) in order to bind all of the relevant information.  This is a central class for other parts of Swift Build to get information about what is being built.

### Project Model

This is the Swift Build representation of a package graph in SwiftPM or workspace in Xcode, including all model objects and all data that they contain.  This representation very closely matches the higher-level representations, although some transforms or derived information are present in some cases where it is considered beneficial.  The term "PIF" (Project Interchange Format) is used both to describe the serialized representation used to transfer the model from clients to Swift Build, and as a shorthand for the Swift Build-side representation of the model.

### Specifications

Specifications ("specs") are a data-driven representation of certain objects used by the build system.  Specs are most often used for build tools (compilers, linkers, etc.), but are used for a few other concepts such as file types.

### Platforms and SDKs

A platform corresponds to a particular device target, such as macOS, iOS, iOS Simulator, etc.  A platform will have one or more SDKs, which contain the headers and libraries to build against.  Platforms and SDKs often contain information to direct Swift Build how to build for that target (from the platform's `Info.plist` and the SDK's `SDKSettings.plist`), and Swift Build loads that information to make use of it.

### Task Planning Support Classes

One of Swift Build's central concerns is analyzing the inputs (workspace, build parameters) and generating a dependency graph (a.k.a. build description) from those inputs.  This is called "task planning" or "task construction".  Several classes used to represent files to build (nodes), commands to run (tasks), and information from clients (the build request, provisioning info, etc.) are defined at the core level as they are used at multiple higher levels.

**Testing:** SWBCore tests are often true "unit" tests, exercising well-defined behaviors.  Many classes in SWBCore will have reasonably complete tests written alongside them, although there are exceptions, such as:

* Some simple structs and extensions such as in `SigningSupport` may not be tested in isolation but instead tested by implication at a higher layer.

## Task Construction

**Framework:** SWBTaskConstruction

This framework sits on top of SWBCore, and defines all of the high-level "business logic" for constructing concrete tasks to execute for a build from a project model, including the full command lines to use.

Task construction (a.k.a. task planning) involves taking a set of inputs (typically a `WorkspaceContext` and a `BuildRequest`) and generating a collection of tasks and nodes representing the dependency graph of work to be done.  This output is encapsulated in a `BuildPlan` which is used by the higher-level build system framework to create a build description and generate the llbuild manifest file.

The `ProductPlanner` will create a `ProductPlan` for each target to build, and a `TaskProducer` for each chunk of work needed to plan that target. A task producer roughly corresponds to a build phase in the product model, although there are some additional task producers which do not have concrete build phases, and the role of build phases is being deemphasized over time.  The product planner launches all the task producers in parallel to create their tasks, and then collects them via a serial aggregation queue to create the build plan.

Much of the interesting work in task construction is in the individual task producer subclasses, and those in turn often invoke individual tool specifications in SWBCore to create individual tasks to process input files to output files.

Most of the dependency graph must be created up-front, but there are some exceptions (e.g. Clang and Swift compilation) where a static node in the dependency graph may request dynamic work as an input.  Some tool specifications, such as that for the Core Data compiler, also run preflight operations during task construction to learn what output files will be generated for an input file so that inputs and outputs of a task can be declared during task construction.

*To be documented:* `PlannedTask`, `ExecutableTask`, `TaskPayload`

**Testing:** Task construction testing has supporting infrastructure in the form of the `TaskConstructionTester` class which is used to perform task construction from a set of inputs, and then vend the results to a checker block.  The checker block typically checks for the presence of expected targets and tasks (and sometimes the absence of ones which should not exist), and examines the rule info, command line, environment, and inputs and outputs of those tasks for the expected values.

There are also supporting classes in `TestWorkspaces.swift` which are used to describe a test project or workspace in-memory (i.e., without needing to create a test workspace on disk).

While there are a few large task construction tests which test the most common set of task construction logic, most newer tests are scenario-based, covering new functionality or fixed bugs.

Enhancement of the supporting task construction test infrastructure is encouraged, when additional functionality will make writing tests easier.

## Task Execution

**Framework:** SWBTaskExecution; in principle this should be a peer to SWBTaskConstruction, but the `BuildDescription` class currently imports that framework.

This framework sits on top of SWBCore, and defines the code which *executes* during an actual build. We make this strongly separated from SWBTaskConstruction because in general we expect task construction to be cached, and we don't use the actual objects constructed there during a build. Separating the modules makes it more clear what code is allowed in each place.

The task execution framework governs the running of tasks during a build, and it consists of two major subsystems:

### Build Description & Build Manifest

The term "build description" is often used to mean both the build description itself (the `BuildDescription` class), and the build manifest, which is the file Swift Build writes for llbuild to use to drive its build logic.

The manifest is a JSON file consisting of a list of commands and some auxiliary information.  This is essentially a serialized representation of the dependency graph.  For any given build, there is a single description-manifest pair.

The build description is additional information which Swift Build needs to provide to llbuild during the build, for example task actions and build settings.  There is some overlap of information between the manifest and the build description, but ultimately we hope to eliminate this redundancy by allowing Swift Build to query llbuild for information in the manifest.

When Swift Build is handed a build request to build a workspace, the `BuildDescriptionManager` first checks whether it already has a cached (in-memory or on-disk) build description for those inputs, and if it does, then it will use it.  Consequently, it should never be assumed that task planning will occur for every build; it may be bypassed entirely.  But if no cached build description is found, then a build plan will be generated from the inputs, and a new build description and manifest will be created from the build plan.

### Task Actions

Task actions are in-process commands which run during a build.  These are, literally, tasks which run inside Swift Build's address space rather than as subprocesses running on-disk tools.  Some task actions are in-process for historical reasons, while others require information only available inside Swift Build (for example, to to request dynamic inputs or implement custom behaviors).  llbuild will call back to Swift Build when a task specifies a task action.

*To be documented:* `Task`, `TaskAction`

**Testing:** Tests for task actions are scenario-based, typically using a pseudo file system, to check that running a task action behaves as expected.

There are some some simple build description tests, but the more interesting tests are up in SWBBuildSystem.

## Build System Framework

**Framework:** SWBBuildSystem; this is the parent to SWBTaskConstruction and SWBTaskExecution

This framework sits on top of SWBCore, SWBTaskConstruction, and SWBTaskExecution. It coordinates the construction and planning of build operations, defines the concrete tasks used to execute them, manages their execution, and handles dispatching status back to clients.

The `BuildManager` class manages the build operations in the Swift Build process, while the `BuildOperation` class represents a single build operation.

**Testing:** As in SWBTaskConstruction tests, the SWBBuildSystem tests include a helped class `BuildOperationTester` which is used to construct a build description from build inputs, and then to run that build and examine the results.  Most of the tests which run builds involve performing real builds rather than simulated builds, as the simulation support is still in development.

## Build Service

**Framework:** SWBBuildService

This framework sits atop the rest of the service-level ones, and it implements the actual service logic.

This is the layer that communicates with the client via serialized messages.  This layer also manages the individual sessions, one for each workspace open in the client.

The `ClientExchangeDelegate.swift` file contains communications channels where SWBBuildService will call back to clients for information it needs during task construction or task execution.  There is a slightly different mechanism for retrieving signing & provisioning inputs, which should probably be migrated to the `ClientExchangeDelegate` model.

**Framework:** SWBServiceCore

This framework implements general-purpose logic for a service. It is intended to be decoupled from the concrete service Swift Build implements; i.e. it could be reused to build another similar service.

**Bundle:** SWBBuildServiceBundle

This is the actual SWBBuildService service. It is a bundle which contains an executable which implements the service over a pipe.

This is just a thin shim on the SWBBuildService framework.

**Testing:** There is no testing at this layer yet.

## Protocol

**Framework:** SWBProtocol

This framework contains the shared protocol definitions for messages exchanged between the client framework (SwiftBuild.framework) and build service (SWBBuildService).

## Public API

**Framework:** SwiftBuild

This is the client facing framework which provides access to swift-build, for integration into clients.

## Command Line Tools

- **swbuild:** This is the command line tool for interacting with public API and service, and for testing.
