# Project Tests

This document describes how to write "project tests", a set of specific types of integration tests used to test build system functionality.

## Overview

Like most software projects, Swift Build has numerous kinds of tests, including unit tests, integration tests, and performance tests. By far the most important kind of tests in the build system domain however are project tests.

There are two main approaches to writing project tests in Swift Build, based on the different layers in the build system’s overall architecture.

### Task Construction Tests

Task construction tests validate the contents of the task graph generated as part of a build’s initial planning stage, including the input and output dependency edges of tasks, the command like invocation used to perform the task, and other metadata. In a task construction test, the underlying task commands are NOT run, similar in concept to dry run builds.

### Build Operation Tests

Build operation tests encompass both the task planning stage covered by task construction tests, as well as the subsequent execution of the underlying commands associated with each task in the graph. Build operation tests are usually chiefly focused on validating the outputs (files) produced by a build operation rather than the structure of the task graph, though they often do some combination of the two.

### Core Qualification Tests

The intent is that these are the highest level of tests (in terms of abstraction layer). They go directly through the public API and spawn a build service process, unlike build operation tests which only test the build operation execution, or task construction tests which only test construction of the task graph but don't execute tools. These tests are focused on end to end experiences where exercising the communication between the client framework and the build service process adds additional coverage.

## Setup

Both task construction and build operation tests usually involve setting up a test project or workspace, which is an in-memory representation of a workspace, project, or Swift package.

It's also customary to wrap the test in `withTemporaryDirectory` in order to provide a location for any files written during the test execution to be placed, and which will automatically be cleaned up once the test ends.

A minimal test case might look something like this:

```swift
func testProject() throws {
    try withTemporaryDirectory { tmpDir in
        let project = TestProject(
            "aProject",
            sourceRoot: tmpDir,
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Assets.xcassets"),
                    TestFile("Class.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.apple.project",
                        "SWIFT_VERSION": "5.0",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "SomeLibrary",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Class.swift"
                        ]),
                        TestResourcesBuildPhase([
                            TestBuildFile("Assets.xcassets"),
                        ]),
                    ]
                ),
            ])
    }
}
```

These test methods are normally placed in a test class derived from `XCTestCase` and conforming to `CoreBasedTests`.

## Evaluation

The next phase involves building the project, which requires setting up a test harness which operates on the project or workspace set up in the previous section, and allows operations to be performed on it.

For task construction tests, create a `TaskConstructionTester`:

```swift
let tester = try TaskConstructionTester(core, testProject)
```

For build operation tests, create a `BuildOperationTester`:

```swift
let tester = try BuildOperationTester(core, testProject)
```

_Both test harness' initializers require a `Core` object. The `CoreBasedTests` protocol provides a `getCore()` instance method which can be used to retrieve a Core instance within a test method._

The `tester` object has several methods to perform some kind of build and subsequently provide a results object to perform analysis on it. The most widely used is `checkBuild` (and `checkIndexBuild` for index builds), which accepts a build request and is common to both `TaskConstructionTester` and `BuildOperationTester`.

`checkBuildDescription` and `checkNullBuild` are exclusive to `BuildOperationTester`.

For example:

```swift
await tester.checkBuild(BuildParameters(configuration: "Debug")) { results in
    // ...
}
```

All of the "check" methods can be invoked multiple times on the same `tester` object, which can be useful for testing incremental build behavior.

## Analysis

Once a build has been performed via a call to one of the "check" methods, the `results` parameter in the results analysis closure provides an opportunity to inspect the task graph and (for build operation tests), the output files produced in the file system.

There are numerous "check" methods on the `results` object, many of which are provided via protocols common to both task construction and build operation tests.

The two most common families of checking methods relate to checking for build tasks, and checking for diagnostic messages. They operate on a consumer model: clients are expected to call `checkTask` multiple times with various parameters to "consume" all of the tasks in a graph, finally calling `checkNoTask` to ensure that no unchecked tasks remained. The same is true for diagnostics.

#### checkNoDiagnostics

For tests validating a successful build, it's good practice to call `checkNoDiagnostics` at the beginning of the analysis closure to ensure that the build completed successfully without any warnings or errors.

For tests where a build is expected to fail, call `checkError` and `checkWarning` as needed to consume the expected diagnostic messages.

```swift
await tester.checkBuild(BuildParameters(configuration: "Debug")) { results in
    results.checkError(.equal("The build encountered an error."))
    results.checkNoDiagnostics()
}
```

#### checkTask

In task construction tests, the `checkTask` and related methods check if a task merely exists in the graph. In build operation tests, these methods check if the task exists in the graph _and actually executed_.

This distinction can be important for build operation tests validating incremental build behavior, which want to ensure that certain tasks did or did not run in an incremental build, based on the changes made to persistent state between builds.

The `checkTask` method accepts a `TaskCondition` object which allows searching for a task based on varying match criteria, such as its rule info array (or subparts of it), command line arguments, or associated target.

It is an error if the match criteria passed to `checkTask` returns more than a single task. For this reason, `checkTask` often needs to be given a more specific (or multiple) match criteria. To search for multiple tasks at once, use the `checkTasks` overload, which instead returns an array of zero or more tasks.

If a task matching the given criteria is found, the trailing closure passed to `checkTask` will be called, and APIs to inspect various state about the task will be provided via the `task` object. The most useful attributes of a task to validate are usually its command line invocation and input and output dependency edges.

```swift
await tester.checkBuild(BuildParameters(configuration: "Debug")) { results in
    results.checkTask(.matchRuleType("Ld")) { task in
        task.checkCommandLine(["ld", "-o", "/tmp/file.dylib", "/tmp/input1.o", "/tmp/input2.o"])
        task.checkInputs([.path("/tmp/input1.o"), .path("/tmp/input2.o")])
        task.checkOutputs([.path("/tmp/file.dylib")])
    }
}
```

#### consumeTasksMatchingRuleTypes

Most tests only want to check the behavior of a handful of specific build tasks or build tasks of a given type. `consumeTasksMatchingRuleTypes` is a convenience method to consume or "skip" tasks of certain rule types that a given test is not interested in observing.

By default, it skips invisible `Gate` tasks, empty directory creation tasks, and a handful of others, and can be passed a custom list of task types to skip.

```swift
await tester.checkBuild(BuildParameters(configuration: "Debug")) { results in
    results.consumeTasksMatchingRuleTypes() // ignore the default set of tasks
    results.consumeTasksMatchingRuleTypes(["Ld", "Lipo"]) // ignore tasks related to linking
}
```

#### checkTaskFollows, checkTaskDoesNotFollow

`checkTaskFollows` and `checkTaskDoesNotFollow` provide the ability to to test whether two tasks have a direct or transitive dependency on one another (or not). Overloads are provided to check specific task instances, or a task instance in combination with a match criteria to identify some other matching task in the graph.

```swift
await tester.checkBuild(BuildParameters(configuration: "Debug")) { results in
    results.checkTaskFollows(task1, antecedent: task2)

    results.checkTaskFollows(task1, .matchRuleType("Ld"))
}
```
