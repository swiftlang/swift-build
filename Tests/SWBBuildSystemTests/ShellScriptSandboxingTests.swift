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

import func Foundation.NSHomeDirectory

import Testing

import SWBBuildSystem
import SWBCore
import SWBProtocol
import SWBTaskExecution
import SWBTestSupport
@_spi(Testing) import SWBUtil

import RegexBuilder

@Suite(.serialized, .bug("rdar://137357063", "fails when run concurrently"), .flaky("test periodically fails in Swift CI"))
fileprivate struct ShellScriptSandboxingTests: CoreBasedTests {
    // Note:
    // TaskConstructionTester is not suitable for run script phases.
    // Make sure BuildOperationTester is used.
    // (see testNonUTF8ShellScript for reference)

    // Note:
    // In the following tests
    // since we cannot pass "testWorkspace.sourceRoot.join("aProject/A.txt")"
    // to `contents` field of the shell-script phase
    // we feed the full path of "aProject/A.txt" via overriding the FAKE_PATH build setting

    func checkForFlakyViolations(_ results: BuildOperationTester.BuildResults, _ violationPattern: consuming sending Regex<Substring>) {
        // Checking for individual violations introduces test flakes because Swift Build cannot reliably obtain the list of violations directly from sandbox-exec
        // Resolving the flakes is blocked by rdar://88928687 (Get the list of sandbox violations directly from sandbox-exec)
        // but we use failIfNotFound as a quick workaround
        if !results.checkError(.prefix("Command PhaseScriptExecution failed."), failIfNotFound: false) {
            results.checkError(.regex(violationPattern))
        }
    }

    /// This test is to ensure hardened build succeeds if
    /// a target properly declares its input/output directly (not via xcfilelist)
    @Test(.requireSDKs(.macOS))
    func ensureProperlyDeclaredInputOutputSucceeds() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("raw.txt"),
                                TestFile("subfolder/rawFileInSubfolder.txt"),
                                TestFile("subfolder/subsubfolder/rawFileInSubsubfolder.txt"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "Calculate Checksum Target",
                                buildPhases: [
                                    // The input file already exists and is listed as an input.
                                    // The script uses absolute path to read the content of the input file.
                                    TestShellScriptBuildPhase(name: "ChecksumFileInRootViaAbsolutePath", shellPath: "/bin/bash", originalObjectID: "ChecksumFileInRootViaAbsolutePath", contents: #"cat "${SCRIPT_INPUT_FILE_0}" | md5 > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/myCryptoProject/raw.txt"], outputs: ["$DERIVED_FILE_DIR/checksum1.txt"]),

                                    // The input file already exists and is listed as an input.
                                    // We use `cd` to navigate to its containing subdirectory, then use `cat` with a relative path
                                    TestShellScriptBuildPhase(name: "ChecksumFileInRootViaCD", shellPath: "/bin/bash", originalObjectID: "ChecksumFileInRootViaCD", contents: #"cd "${SRCROOT}"; cd myCryptoProject; cat raw.txt | md5 > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/myCryptoProject/raw.txt"], outputs: ["$DERIVED_FILE_DIR/checksum2.txt"]),

                                    // Same as above, with one extra subfolder
                                    TestShellScriptBuildPhase(name: "ChecksumFileInSubfolder", shellPath: "/bin/bash", originalObjectID: "ChecksumFileInSubfolder", contents: #"cd "${SRCROOT}"; cd myCryptoProject; cd subfolder; cat rawFileInSubfolder.txt | md5 > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/myCryptoProject/subfolder/rawFileInSubfolder.txt"], outputs: ["$DERIVED_FILE_DIR/checksum3.txt"]),

                                    // Same as above, with two extra subfolders
                                    TestShellScriptBuildPhase(name: "ChecksumFileInSubsubfolder", shellPath: "/bin/bash", originalObjectID: "ChecksumFileInSubsubfolder", contents: #"cd "${SRCROOT}"; cd myCryptoProject; cd subfolder; cd subsubfolder; pwd; cat rawFileInSubsubfolder.txt | md5 > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/myCryptoProject/subfolder/subsubfolder/rawFileInSubsubfolder.txt"], outputs: ["$DERIVED_FILE_DIR/checksum4.txt"]),

                                    // Script name with spaces
                                    TestShellScriptBuildPhase(name: "Script Name With Spaces", shellPath: "/bin/bash", originalObjectID: "Script Name With Spaces", contents: #"cat "${SCRIPT_INPUT_FILE_0}" | md5 > "${SCRIPT_OUTPUT_FILE_0}""#, inputs: ["$(SRCROOT)/myCryptoProject/raw.txt"], outputs: ["$DERIVED_FILE_DIR/checksum5.txt"]),

                                    // Is ${TARGET_TEMP_DIR} equal to ${TEMP_DIR}?
                                    TestShellScriptBuildPhase(name: "buildTempDirAlias", shellPath: "/bin/bash", originalObjectID: "buildTempDirAlias", contents: #"echo "${TEMP_DIR}" > "${SCRIPT_OUTPUT_FILE_0}"; echo -n "${TARGET_TEMP_DIR}" >> "${SCRIPT_OUTPUT_FILE_0}""#, inputs: [], outputs: ["$DERIVED_FILE_DIR/buildTempDirAlias.txt"], alwaysOutOfDate: true),

                                    // Is writing to /tmp allowed?
                                    TestShellScriptBuildPhase(name: "WriteToSlashTmp", shellPath: "/bin/bash", originalObjectID: "WriteToSlashTmp", contents: "echo -n \"Hello from \(tmpDirPath.str)\" > \"\(tmpDirPath.str)/unique-long-path-name-1651182697.txt\"; cat \(tmpDirPath.str)/unique-long-path-name-1651182697.txt > \"${SCRIPT_OUTPUT_FILE_0}\"", inputs: [], outputs: ["$DERIVED_FILE_DIR/WriteToSlashTmp.txt"], alwaysOutOfDate: true),

                                    // Is writing to the null device allowed?
                                    TestShellScriptBuildPhase(name: "WriteToDevNull", shellPath: "/bin/bash", originalObjectID: "WriteToDevNull", contents: "echo Hello > \(Path.null.str)", inputs: [], outputs: [], alwaysOutOfDate: true),
                                ]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT).join("myCryptoProject/subfolder/subsubfolder"), recursive: true)

            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw.txt")) { stream in
                stream <<< "Hello World!\n"
            }

            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/subfolder/rawFileInSubfolder.txt")) { stream in
                stream <<< "Hello World!\n"
            }

            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/subfolder/subsubfolder/rawFileInSubsubfolder.txt")) { stream in
                stream <<< "Hello World!\n"
            }

            let overriddenParameters = BuildParameters(configuration: "Debug")

            // Ensure content of checksum*.txt is 8ddd8be4b179a529afa5f2ffae4b9858 with no violation.
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("ChecksumFileInRootViaAbsolutePath"))) { task in
                    #expect(task.commandLine.first == "/usr/bin/sandbox-exec")

                    let path = task.outputPaths[0]
                    let checksum = try tester.fs.read(path).asString
                    #expect(checksum == "8ddd8be4b179a529afa5f2ffae4b9858\n")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("ChecksumFileInRootViaCD"))) { task in
                    #expect(task.commandLine.first == "/usr/bin/sandbox-exec")

                    let path = task.outputPaths[0]
                    let checksum = try tester.fs.read(path).asString
                    #expect(checksum == "8ddd8be4b179a529afa5f2ffae4b9858\n")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("ChecksumFileInSubfolder"))) { task in
                    #expect(task.commandLine.first == "/usr/bin/sandbox-exec")

                    let path = task.outputPaths[0]
                    let checksum = try tester.fs.read(path).asString
                    #expect(checksum == "8ddd8be4b179a529afa5f2ffae4b9858\n")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("ChecksumFileInSubsubfolder"))) { task in
                    #expect(task.commandLine.first == "/usr/bin/sandbox-exec")

                    let path = task.outputPaths[0]
                    let checksum = try tester.fs.read(path).asString
                    #expect(checksum == "8ddd8be4b179a529afa5f2ffae4b9858\n")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("Script Name With Spaces"))) { task in
                    #expect(task.commandLine.first == "/usr/bin/sandbox-exec")

                    let path = task.outputPaths[0]
                    let checksum = try tester.fs.read(path).asString
                    #expect(checksum == "8ddd8be4b179a529afa5f2ffae4b9858\n")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("buildTempDirAlias"))) { task in
                    let path = task.outputPaths[0]
                    let (value1, value2) = try tester.fs.read(path).asString.split("\n")
                    #expect(value1 == value2)
                }

                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("WriteToDevNull"))) { task in
                    #expect(task.commandLine.first == "/usr/bin/sandbox-exec")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("WriteToSlashTmp"))) { task in
                    let path = task.outputPaths[0]
                    let value = try tester.fs.read(path).asString
                    #expect(value == "Hello from \(tmpDirPath.str)")
                }
            }
        }
    }

    // The input file already exists, but instead of being listed explicitly,
    // USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES=YES and the parent directory is listed.
    //
    // myCryptoProject/
    //  |  raw.txt <-- written on disk (initial state)
    //  v
    // [TaskA]
    //  |
    //  v
    // checksum1.txt
    //
    @Test(.requireSDKs(.macOS))
    func directoryInputBasic() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("raw.txt"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                                "USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES": "YES"
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "Calculate Checksum Target",
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskA",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskA",
                                        contents:
                                            #"""
                                            find ./myCryptoProject # should not raise a violation because the entire directory is allowed in the profile
                                            cat "${SCRIPT_INPUT_FILE_0}/raw.txt" | md5 > "${SCRIPT_OUTPUT_FILE_0}"
                                            """#,
                                        inputs: ["$(SRCROOT)/myCryptoProject/"],
                                        outputs: ["$DERIVED_FILE_DIR/checksum1.txt"]),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw.txt")) { stream in
                stream <<< "Hello World!\n"
            }

            let overriddenParameters = BuildParameters(configuration: "Debug")

            // Clean build: Ensure content of checksum*.txt is 8ddd8be4b179a529afa5f2ffae4b9858 with no violation.
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS) { results in
                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("TaskA"))) { task in
                    #expect(task.commandLine.first == "/usr/bin/sandbox-exec")

                    let path = task.outputPaths[0].withoutTrailingSlash()
                    let checksum = try tester.fs.read(path).asString
                    #expect(checksum == "8ddd8be4b179a529afa5f2ffae4b9858\n")
                }
                results.checkNoDiagnostics()
            }

            // Null build
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS) { results in
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // Incremental build after input is modified
            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw.txt")) { stream in
                stream <<< "Hola Amigos\n"
            }

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS) { results in
                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("TaskA"))) { task in
                    let path = task.outputPaths[0].withoutTrailingSlash()
                    let checksum = try tester.fs.read(path).asString
                    #expect(checksum == "520236dcfeee6bd0b72868c5a2b86ff9\n")
                }
                results.checkNoDiagnostics()
            }
        }
    }


    // Some files are written to /tmp/raw/
    // TaskA reads /tmp/raw/ and produces /tmp/headers/
    // TaskB reads /tmp/headers/ and produces /tmp/headers-copy/
    // TaskC reads /tmp/headers-copy/libX.fake-h and produces /tmp/libX-from-TaskC.fake-h
    //
    // This test check many things at once and is intended for overall correctness check of all pieces.
    //
    // raw/
    //  |  libX.fake-h <-- written on disk (initial state)
    //  |  libY.fake-h <-- written on disk (initial state)
    //  |  libZ.fake-h <-- written on disk (initial state)
    //  v
    // TaskA (verbatim copy; mixed case)
    //  |
    //  v
    // headers/
    //  |  libX.fake-h
    //  |  libY.fake-h
    //  |  libZ.fake-h
    //  v
    // TaskB (modified copy; ALL CAPS)
    //  |
    //  v
    // headers-processed/
    //      libX.fake-h
    //  ,-- libY.fake-h (will be automatically amended to outputs of TaskB)
    //  |   libZ.fake-h
    //  v
    // [TaskC] (modified copy; all lower case)
    //  |
    //  v
    // libY-from-TaskC.fake-h
    //
    @Test(.requireSDKs(.macOS), .userDefaults(["PerformOwnershipAnalysis": "1"]))
    func directoryInputAndOutput() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestGroup("raw", children: [
                                    TestFile("libX.fake-h"),
                                    TestFile("libY.fake-h"),
                                    TestFile("libZ.fake-h"),
                                ])
                            ]
                        ),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                                "FUSE_BUILD_SCRIPT_PHASES": "YES",
                                "USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES": "YES",
                                "ALLOW_DISJOINTED_DIRECTORIES_AS_DEPENDENCIES": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "ALL",
                                dependencies: ["TargetC"]
                            ),
                            TestStandardTarget(
                                "TargetC",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskC",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskC",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            [ -f "${SCRIPT_INPUT_FILE_0}" ]
                                            [ ! -d "${SCRIPT_OUTPUT_FILE_0}" ]
                                            cat "${SCRIPT_INPUT_FILE_0}"
                                            cat "${SCRIPT_INPUT_FILE_0}" | tr A-Z a-z > "${SCRIPT_OUTPUT_FILE_0}"
                                            cat "${SCRIPT_OUTPUT_FILE_0}"
                                            """#,
                                        inputs: ["$(SHARED_DERIVED_FILE_DIR)/headers-processed/libY.fake-h"],
                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/libY-from-TaskC.fake-h"]),
                                ],
                                dependencies: ["TargetB"]
                            ),
                            TestStandardTarget(
                                "TargetB",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskB",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskB",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            mkdir -p "${SCRIPT_OUTPUT_FILE_0}"
                                            ls "${SCRIPT_INPUT_FILE_0}"
                                            for headerFile in ${SCRIPT_INPUT_FILE_0}/*.fake-h
                                            do
                                                outputFile=${SCRIPT_OUTPUT_FILE_0}/$(basename "$headerFile")
                                                cat "$headerFile"
                                                cat "$headerFile" | tr a-z A-Z > "$outputFile"
                                                cat $outputFile
                                            done
                                            """#,
                                        inputs: ["$(SHARED_DERIVED_FILE_DIR)/headers/"],
                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/headers-processed/"]),
                                ],
                                dependencies: ["TargetA"]
                            ),
                            TestStandardTarget(
                                "TargetA",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskA",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskA",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            mkdir -p "${SCRIPT_OUTPUT_FILE_0}"
                                            cd "${SCRIPT_INPUT_FILE_0}"
                                            
                                            for headerFile in ${SCRIPT_INPUT_FILE_0}/*.fake-h
                                            do
                                                cp "$headerFile" "${SCRIPT_OUTPUT_FILE_0}"/
                                            done
                                            
                                            ls "${SCRIPT_OUTPUT_FILE_0}"/
                                            
                                            cat "${SCRIPT_OUTPUT_FILE_0}"/*
                                            """#,
                                        inputs: ["$(SRCROOT)/myCryptoProject/raw/"], outputs: ["$(SHARED_DERIVED_FILE_DIR)/headers/"]),
                                ],
                                dependencies: ["Other"]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, continueBuildingAfterErrors: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let overriddenParameters = BuildParameters(configuration: "Debug")

            // Write initial files to disk
            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw/libX.fake-h")) { stream in
                stream <<< "Contents of libX.fake-h\n"
            }

            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw/libY.fake-h")) { stream in
                stream <<< "Contents of libY.fake-h\n"
            }

            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw/libZ.fake-h")) { stream in
                stream <<< "Contents of libZ.fake-h\n"
            }

            // Check clean build
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that build succeeds
                results.checkNoDiagnostics()

                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskA"), .matchRuleItemBasename("Script-TaskA.sh")) { _ in }

                let taskB = try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskB"), .matchRuleItemBasename("Script-TaskB.sh")) { task in
                    let dirname = task.outputPaths[0]
                    for processedFile in ["libX.fake-h", "libY.fake-h", "libZ.fake-h"] {
                        let value = try tester.fs.read(dirname.join(processedFile)).asString
                        #expect(value == "CONTENTS OF \(processedFile.uppercased())\n")
                    }

                    return task
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskC"), .matchRuleItemBasename("Script-TaskC.sh")) { taskC in
                    try results.checkTaskFollows(taskC, taskB)

                    let path = taskC.outputPaths[0].withoutTrailingSlash()
                    let value = try tester.fs.read(path).asString
                    #expect(value == "contents of liby.fake-h\n")
                }
            }

            // Check null build after first clean build
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.consumeTasksMatchingRuleTypes(["Gate"])
                results.checkNoTask()
            }

            // Modify raw/libY.fake-h
            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw/libY.fake-h")) { stream in
                stream <<< "Updated contents of libY.fake-h\n"
            }

            // Ensure changes to raw file are propagated
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that build succeeds
                results.checkNoDiagnostics()

                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskA"), .matchRuleItemBasename("Script-TaskA.sh")) { _ in }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskB"), .matchRuleItemBasename("Script-TaskB.sh")) { task in
                    let dirname = task.outputPaths[0]
                    let value = try tester.fs.read(dirname.join("libY.fake-h")).asString
                    #expect(value == "UPDATED CONTENTS OF LIBY.FAKE-H\n")
                }

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskC"), .matchRuleItemBasename("Script-TaskC.sh")) { task in
                    let path = task.outputPaths[0].withoutTrailingSlash()
                    let value = try tester.fs.read(path).asString
                    #expect(value == "updated contents of liby.fake-h\n")
                }
            }

            // Ensure null build is indeed null
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()
                results.consumeTasksMatchingRuleTypes(["Gate"])
                results.checkNoTask()
            }
        }
    }

    // No files are on disk
    // TaskAB produces /tmp/out/ directory with {a,b}.txt in it.
    // Contents of {a,b}.txt depend on an environment variables.
    // TaskC depends on /tmp/out/a.txt to produce /tmp/output.txt
    //
    // Note:
    //   without ChecksumOnlyFileSystem, a change to $B_DOT_TXT_PREFIX will trigger an unnecessary rebuild for TaskC
    //   because TaskAB will touch /tmp/out/a.txt even though its content is the same.
    //
    // $A_DOT_TXT_PREFIX
    //  | ,-- $B_DOT_TXT_PREFIX
    //  v v
    // [TaskAB]
    //  |
    //  v
    // out/
    //  ,- a.txt (content only depends on $A_DOT_TXT_PREFIX)
    //  |  b.txt (content only depends on $B_DOT_TXT_PREFIX)
    //  v
    // [TaskC]
    //  |
    //  v
    // output.txt
    //
    @Test(.requireSDKs(.macOS), .userDefaults(["PerformOwnershipAnalysis": "1"]))
    func downstreamTaskConsumeFileFromOutputDirectory() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "NO", // We try both cases in this test
                                "USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES": "YES",
                                "ALLOW_DISJOINTED_DIRECTORIES_AS_DEPENDENCIES": "YES",
                                "FUSE_BUILD_SCRIPT_PHASES": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "ALL",
                                dependencies: ["TargetAB", "TargetC"]
                            ),
                            TestStandardTarget(
                                "TargetC",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskC",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskC",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            [ -f "${SCRIPT_INPUT_FILE_0}" ]
                                            cat "${SCRIPT_INPUT_FILE_0}" | tr a-z A-Z > "${SCRIPT_OUTPUT_FILE_0}"
                                            """#,
                                        inputs: ["$(SHARED_DERIVED_FILE_DIR)/out/a.txt"],
                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/output.txt"]),
                                ],
                                dependencies: ["Other"]
                            ),
                            TestStandardTarget(
                                "TargetAB",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskAB",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskAB",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            mkdir -p "${SCRIPT_OUTPUT_FILE_0}"
                                            echo "$A_DOT_TXT_PREFIX: Output from TaskAB for a.txt!" > "${SCRIPT_OUTPUT_FILE_0}"/a.txt
                                            echo "$B_DOT_TXT_PREFIX: Output from TaskAB for b.txt!" > "${SCRIPT_OUTPUT_FILE_0}"/b.txt
                                            """#,
                                        inputs: [], outputs: ["$(SHARED_DERIVED_FILE_DIR)/out/"]),
                                ],
                                dependencies: ["Other"]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            for enableSandboxingInTest in ["YES", "NO"] {
                var overriddenParameters = BuildParameters(configuration: "Debug",
                                                           overrides: ["ENABLE_USER_SCRIPT_SANDBOXING": enableSandboxingInTest,
                                                                       "A_DOT_TXT_PREFIX": "A_PREFIX",
                                                                       "B_DOT_TXT_PREFIX": "B_PREFIX",
                                                                      ])

                try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                    // Check that build succeeds
                    results.checkNoDiagnostics()

                    results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskAB"), .matchRuleItemBasename("Script-TaskAB.sh")) { _ in }

                    try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskC"), .matchRuleItemBasename("Script-TaskC.sh")) { task in
                        let path = task.outputPaths[0].withoutTrailingSlash()
                        let value = try tester.fs.read(path).asString
                        #expect(value == "A_PREFIX: OUTPUT FROM TASKAB FOR A.TXT!\n")
                    }
                }

                // Null build
                try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                    // Check that build succeeds
                    results.checkNoDiagnostics()

                    results.consumeTasksMatchingRuleTypes(["Gate"])

                    results.checkNoTask()
                }

                // Change $A_DOT_TXT_PREFIX
                overriddenParameters = BuildParameters(configuration: "Debug",
                                                       overrides: ["ENABLE_USER_SCRIPT_SANDBOXING": enableSandboxingInTest,
                                                                   "A_DOT_TXT_PREFIX": "UPDATED_A_PREFIX",
                                                                   "B_DOT_TXT_PREFIX": "B_PREFIX",
                                                                  ])

                // Incremental build to reflect the change in environment variable
                try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                    // Check that build succeeds
                    results.checkNoDiagnostics()

                    results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskAB"), .matchRuleItemBasename("Script-TaskAB.sh")) { _ in }

                    try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskC"), .matchRuleItemBasename("Script-TaskC.sh")) { task in
                        let path = task.outputPaths[0].withoutTrailingSlash()
                        let value = try tester.fs.read(path).asString
                        #expect(value == "UPDATED_A_PREFIX: OUTPUT FROM TASKAB FOR A.TXT!\n")
                    }
                }

                // null build
                try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                    // Check that build succeeds
                    results.checkNoDiagnostics()

                    results.consumeTasksMatchingRuleTypes(["Gate"])

                    results.checkNoTask()
                }

                // Change $B_DOT_TXT_PREFIX
                overriddenParameters = BuildParameters(configuration: "Debug",
                                                       overrides: ["ENABLE_USER_SCRIPT_SANDBOXING": enableSandboxingInTest,
                                                                   "A_DOT_TXT_PREFIX": "UPDATED_A_PREFIX",
                                                                   "B_DOT_TXT_PREFIX": "UPDATED_B_PREFIX",
                                                                  ])

                // Swift Build cannot detect ahead of time that change to B_DOT_TXT_PREFIX will have no effect on the input of TaskC
                // In this case rescheduling TaskAB and TaskC due to change in environment variables is correct..
                //
                // As a consequence, the script in TaskAB will touch
                // out/a.txt (although preserves the content), and TaskC will be rescheduled to run.
                //
                // Even if we roll ChecksumOnlyFileSystem Swift Build will need to rerun TaskC
                // due to changes in environment variables
                try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                    // Check that build succeeds
                    results.checkNoDiagnostics()

                    results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskAB"), .matchRuleItemBasename("Script-TaskAB.sh")) { _ in }

                    try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskC"), .matchRuleItemBasename("Script-TaskC.sh")) { task in
                        let path = task.outputPaths[0].withoutTrailingSlash()
                        let value = try tester.fs.read(path).asString
                        #expect(value == "UPDATED_A_PREFIX: OUTPUT FROM TASKAB FOR A.TXT!\n")
                    }
                }
            }
        }
    }

    // No files are on disk
    // TaskA produces /tmp/out/ directory with a.txt in it. Contents of a.txt depend on an environment variable
    // TaskB depends on /tmp/out/a.txt to produce /tmp/output.txt
    // TaskC is declaring /tmp/out/b.txt as output dependency
    // This scenario is blocked and build should fail because TaskA is owner of /tmp/out.
    //
    // TaskA
    //  |
    //  v
    // out/
    //     a.txt
    //  ,- b.txt
    //  |  c.txt <-- [TaskC]
    //  v
    // TaskB
    //  |
    //  v
    // output.txt
    //
    @Test(.requireSDKs(.macOS), .userDefaults(["PerformOwnershipAnalysis": "1"]))
    func blockTaskWritingToOwnedDirectory() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "NO", // We test for both cases in this test
                                "USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES": "YES",
                                "ALLOW_DISJOINTED_DIRECTORIES_AS_DEPENDENCIES": "YES",
                                "FUSE_BUILD_SCRIPT_PHASES": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "ErroneousTaskWritingToDirectoryOwnedByOtherTask",
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskC",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskC",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            mkdir -p "${SCRIPT_OUTPUT_FILE_0}"
                                            echo "Output from TaskC.. This should be blocked" > "${SCRIPT_OUTPUT_FILE_0}"
                                            """#,
                                        inputs: [],
                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/out/c.txt"]),
                                    TestShellScriptBuildPhase(
                                        name: "TaskB",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskB",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            [ -f "${SCRIPT_INPUT_FILE_0}" ]
                                            cat "${SCRIPT_INPUT_FILE_0}" | tr a-z A-Z > "${SCRIPT_OUTPUT_FILE_0}"
                                            """#,
                                        inputs: ["$(SHARED_DERIVED_FILE_DIR)/out/a.txt"],
                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/output.txt"]),
                                    TestShellScriptBuildPhase(
                                        name: "TaskA",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskA",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            mkdir -p "${SCRIPT_OUTPUT_FILE_0}"
                                            echo "$A_DOT_TXT_PREFIX: Output from TaskA for a.txt!" > "${SCRIPT_OUTPUT_FILE_0}"/a.txt
                                            echo "$B_DOT_TXT_PREFIX: Output from TaskA for b.txt!" > "${SCRIPT_OUTPUT_FILE_0}"/b.txt
                                            """#,
                                        inputs: [], outputs: ["$(SHARED_DERIVED_FILE_DIR)/out/"]),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, continueBuildingAfterErrors: false)

            let overriddenParameters = BuildParameters(configuration: "Debug",
                                                       overrides: ["A_DOT_TXT_PREFIX": "A_PREFIX",
                                                                   "B_DOT_TXT_PREFIX": "B_PREFIX",
                                                                  ])

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                // Check that build fails
                results.checkError(
                    .and(.prefix("Multiple commands produce"),
                         .and(
                            .and(.contains("TaskC"), .contains("TaskA")),
                            .contains("c.txt"))))
                results.checkError("unable to load build file")
                results.checkNoDiagnostics()

                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkNoTask()
            }
        }
    }

    // TaskA and TaskB both enlist /tmp/out/ as output directory.
    //
    // [TaskA]
    //  |
    //  v
    // out/ <-- [TaskB]
    //  |
    //  v
    // [TaskC]
    //  |
    //  v
    // mock.txt
    //
    @Test(.requireSDKs(.macOS), .userDefaults(["PerformOwnershipAnalysis": "1"]))
    func blockMultipleOwnersWithinSameTarget() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES": "YES",
                                "ALLOW_DISJOINTED_DIRECTORIES_AS_DEPENDENCIES": "YES",
                                "FUSE_BUILD_SCRIPT_PHASES": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "ALL",
                                dependencies: ["TargetA", "TargetB", "TargetC"]
                            ),
                            TestStandardTarget(
                                "TargetC",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskC",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskC",
                                        contents:
                                            #"""
                                            # contents of the script are irrelevant to this test
                                            """#,
                                        inputs: ["$(SRCROOT)/out/"],
                                        outputs: ["$(SRCROOT)/mock.txt"]),
                                ],
                                dependencies: ["Other"]
                            ),
                            TestStandardTarget(
                                "TargetB",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskB",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskB",
                                        contents:
                                            #"""
                                            # contents of the script are irrelevant to this test
                                            """#,
                                        inputs: [],
                                        outputs: ["$(SRCROOT)/out/"]),
                                ],
                                dependencies: ["Other"]
                            ),
                            TestAggregateTarget(
                                "TargetA",
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskA",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskA",
                                        contents:
                                            #"""
                                            # contents of the script are irrelevant to this test
                                            """#,
                                        inputs: [],
                                        outputs: ["$(SRCROOT)/out/"])
                                ],
                                dependencies: ["Other"]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, continueBuildingAfterErrors: false)

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                // Check that build fails
                results.checkError(
                    .and(.prefix("Multiple commands produce"),
                         .and(
                            .and(.contains("TaskA"), .contains("TaskB")),
                            .contains("out/"))))
                results.checkWarning(.and(.prefix("duplicate output file"), .contains("Test/myCryptoProject/out")))
                results.checkError("unable to load build file")
                results.checkNoDiagnostics()

                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkNoTask()
            }
        }
    }

    // TaskA produces /tmp/out/a.txt
    // TaskB produces /tmp/out/b.txt
    // TaskC lists /tmp/out as dependency
    //
    // [TaskA] -----,
    //              |
    // out/         |
    //  |  a.txt <--'
    //  |  b.txt <-- [TaskB]
    //  v
    // [TaskC]
    //  |
    //  v
    // combined-a-and-b.txt
    //
    // ("a.txt" and "b.txt" should be added to mustScanAfterPaths of "out/")
    @Test(.requireSDKs(.macOS), .userDefaults(["PerformOwnershipAnalysis": "1"]))
    func twoTasksWritingToDirectoryOneTaskConsuming() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [TestFile("raw.txt")]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "NO", // We try both cases in this test
                                "USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES": "YES",
                                "ALLOW_DISJOINTED_DIRECTORIES_AS_DEPENDENCIES": "YES",
                                "FUSE_BUILD_SCRIPT_PHASES": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "ALL",
                                dependencies: ["TargetA", "TargetB", "TargetC"]
                            ),
                            TestStandardTarget(
                                "TargetB",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskB",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskB",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            echo "Output from TaskB for b.txt!" > "${SCRIPT_OUTPUT_FILE_0}"
                                            """#,
                                        inputs: [], outputs: ["$(SHARED_DERIVED_FILE_DIR)/out/b.txt"]),
                                ],
                                dependencies: ["Other"]
                            ),
                            TestStandardTarget(
                                "TargetA",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskA",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskA",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            cat "${SCRIPT_INPUT_FILE_0}" > "${SCRIPT_OUTPUT_FILE_0}"
                                            cat "${SCRIPT_OUTPUT_FILE_0}"
                                            """#,
                                        inputs: ["$(SRCROOT)/myCryptoProject/raw.txt"], outputs: ["$(SHARED_DERIVED_FILE_DIR)/out/a.txt"]),
                                ],
                                dependencies: ["Other"]
                            ),
                            TestStandardTarget(
                                "TargetC",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "TaskC",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "TaskC",
                                        contents:
                                            #"""
                                            set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            [ -d "${SCRIPT_INPUT_FILE_0}" ]
                                            cat "${SCRIPT_INPUT_FILE_0}"/* | tr a-z A-Z > "${SCRIPT_OUTPUT_FILE_0}"
                                            """#,
                                        inputs: ["$(SHARED_DERIVED_FILE_DIR)/out/"],
                                        outputs: ["$(SHARED_DERIVED_FILE_DIR)/combine-a-and-b.txt"]),
                                ],
                                dependencies: ["Other"]
                            ),
                        ])])

            for enableSandboxingInTest in ["YES", "NO"] {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
                let SRCROOT = tester.workspace.projects[0].sourceRoot.str

                let overriddenParameters = BuildParameters(configuration: "Debug", overrides: ["ENABLE_USER_SCRIPT_SANDBOXING": enableSandboxingInTest])

                try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw.txt")) { stream in
                    stream <<< "Output from TaskA for a.txt!\n"
                }

                try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                    // Check that build succeeds
                    results.checkNoDiagnostics()

                    results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskA"), .matchRuleItemBasename("Script-TaskA.sh")) { _ in }
                    results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskB"), .matchRuleItemBasename("Script-TaskB.sh")) { _ in }

                    try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskC"), .matchRuleItemBasename("Script-TaskC.sh")) { task in
                        let path = task.outputPaths[0].withoutTrailingSlash()
                        let value = try tester.fs.read(path).asString
                        #expect(value == "OUTPUT FROM TASKA FOR A.TXT!\nOUTPUT FROM TASKB FOR B.TXT!\n")
                    }
                }

                // First null build
                try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                    // Check that build succeeds
                    results.checkNoDiagnostics()
                    results.consumeTasksMatchingRuleTypes(["Gate"])
                    results.checkNoTask()
                }

                // Second null build
                try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                    // Check that build succeeds
                    results.checkNoDiagnostics()
                    results.consumeTasksMatchingRuleTypes(["Gate"])
                    results.checkNoTask()
                }

                // Incremental build after modifying input to TaskA (TaskB should not run)
                try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw.txt")) { stream in
                    stream <<< "Updated output from TaskA for a.txt!\n"
                }

                try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, persistent: true) { results in
                    // Check that build succeeds
                    results.checkNoDiagnostics()

                    results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskA"), .matchRuleItemBasename("Script-TaskA.sh")) { _ in }

                    try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItem("TaskC"), .matchRuleItemBasename("Script-TaskC.sh")) { task in
                        let path = task.outputPaths[0].withoutTrailingSlash()

                        let value = try tester.fs.read(path).asString
                        #expect(value == "UPDATED OUTPUT FROM TASKA FOR A.TXT!\nOUTPUT FROM TASKB FOR B.TXT!\n")
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .userDefaults(["PerformOwnershipAnalysis": "1"]))
    func modernBlockUndeclaredInputOutputFromDiskWhenRecursiveScriptInputIsOn() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("A.txt"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                                "USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES": "YES"
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "TargetWithUndeclaredInput",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "ScriptWithUndeclaredInput", shellPath: "/bin/bash", originalObjectID: "ScriptWithUndeclaredInput", contents: #"cat "$FAKE_PATH""#, inputs: [], outputs: []),
                                ]
                            ),
                            TestAggregateTarget(
                                "TargetWithUndeclaredOutput",
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "ScriptWithUndeclaredOutput",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "ScriptWithUndeclaredOutput",
                                        contents:
                                            #"""
                                            (set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            echo "Contents of the declared file" > "${DERIVED_FILE_DIR}/new-folder/declared.txt"
                                            cat "${DERIVED_FILE_DIR}/new-folder/declared.txt"
                                            echo "Non-violation" > "${DERIVED_FILE_DIR}/new-folder/undeclared.txt"
                                            echo "Violation" > "${DERIVED_FILE_DIR}/undeclared.txt"
                                            ) &> "${DERIVED_FILE_DIR}/new-folder/log.txt"
                                            """#,
                                        inputs: [],
                                        outputs: [ "$(DERIVED_FILE_DIR)/new-folder/",
                                                   "$(DERIVED_FILE_DIR)/new-folder/declared.txt",
                                                   "$(DERIVED_FILE_DIR)/new-folder/log.txt" ]
                                    )
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.fs.writeFileContents(Path(SRCROOT).join("aProject/A.txt")) { stream in
                stream <<< "int main() { return 0; }\n"
            }

            // Override FAKE_PATH with testWorkspace.sourceRoot.join("aProject/A.txt")
            let overriddenParameters = BuildParameters(configuration: "Debug",
                                                       overrides: ["FAKE_PATH": Path(SRCROOT).join("aProject/A.txt").str])

            // Note: the two user scripts are not dependent on each other.
            // We manually run each target in the test via `firstBuildRequest` and `secondBuildRequest`
            let firstBuildRequest = BuildRequest(parameters: overriddenParameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: overriddenParameters, target: tester.workspace.projects[0].targets[0])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, buildRequest: firstBuildRequest) { results in
                results.checkWarning(.contains("'ScriptWithUndeclaredInput' will be run during every build because it does not specify any outputs."))
                self.checkForFlakyViolations(results, #/file-read-data .*/aProject/A.txt .*/#)
                results.checkNoDiagnostics()
            }

            let secondBuildRequest = BuildRequest(parameters: overriddenParameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: overriddenParameters, target: tester.workspace.projects[0].targets[1])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, buildRequest: secondBuildRequest) { results in
                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("ScriptWithUndeclaredOutput"))) { task in
                    do {
                        let path = task.workingDirectory.join("build/aProject.build/Debug/TargetWithUndeclaredOutput.build/DerivedSources/new-folder/log.txt")
                        let output = try tester.fs.read(path).asString
                        let expectedOutput = try Regex<Substring>("""
                        \\+ set -o errexit
                        \\+ set -o nounset
                        \\+ set -o pipefail
                        \\+ echo 'Contents of the declared file'
                        \\+ cat .*
                        Contents of the declared file
                        \\+ echo Non-violation
                        \\+ echo Violation
                        .*/undeclared.txt: Operation not permitted
                        $
                        """)
                        XCTAssertMatch(output, .regex(expectedOutput))
                    }

                    do {
                        let path = task.workingDirectory.join("build/aProject.build/Debug/TargetWithUndeclaredOutput.build/DerivedSources/new-folder/undeclared.txt")
                        let output = try tester.fs.read(path).asString
                        let expectedOutput = "Non-violation\n"
                        #expect(output == expectedOutput)
                    }

                    self.checkForFlakyViolations(results, #/file-write-create .*/undeclared.txt .*/#)
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireXcode16())
    func legacyBlockUndeclaredInputOutputFromDiskWhenRecursiveScriptInputIsOn() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("A.txt"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                                "USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES": "YES"
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "TargetWithUndeclaredInput",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "ScriptWithUndeclaredInput", shellPath: "/bin/bash", originalObjectID: "ScriptWithUndeclaredInput", contents: #"cat "$FAKE_PATH""#, inputs: [], outputs: []),
                                ]
                            ),
                            TestAggregateTarget(
                                "TargetWithUndeclaredOutput",
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "ScriptWithUndeclaredOutput",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "ScriptWithUndeclaredOutput",
                                        contents:
                                            #"""
                                            (set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            echo "Contents of the declared file" > "${DERIVED_FILE_DIR}/new-folder/declared.txt"
                                            cat "${DERIVED_FILE_DIR}/new-folder/declared.txt"
                                            echo "Violation" > "${DERIVED_FILE_DIR}/new-folder/undeclared.txt"
                                            ) &> "${DERIVED_FILE_DIR}/new-folder/log.txt"
                                            """#,
                                        inputs: [],
                                        outputs: [ "$(DERIVED_FILE_DIR)/new-folder/",
                                                   "$(DERIVED_FILE_DIR)/new-folder/declared.txt",
                                                   "$(DERIVED_FILE_DIR)/new-folder/log.txt" ]
                                    )
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.fs.writeFileContents(Path(SRCROOT).join("aProject/A.txt")) { stream in
                stream <<< "int main() { return 0; }\n"
            }

            // Override FAKE_PATH with testWorkspace.sourceRoot.join("aProject/A.txt")
            let overriddenParameters = BuildParameters(configuration: "Debug",
                                                       overrides: ["FAKE_PATH": Path(SRCROOT).join("aProject/A.txt").str])

            // Note: the two user scripts are not dependent on each other.
            // We manually run each target in the test via `firstBuildRequest` and `secondBuildRequest`
            let firstBuildRequest = BuildRequest(parameters: overriddenParameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: overriddenParameters, target: tester.workspace.projects[0].targets[0])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, buildRequest: firstBuildRequest) { results in
                results.checkWarning(.contains("'ScriptWithUndeclaredInput' will be run during every build because it does not specify any outputs."))
                self.checkForFlakyViolations(results, #/file-read-data .*/aProject/A.txt .*/#)
                results.checkNoDiagnostics()
            }

            let secondBuildRequest = BuildRequest(parameters: overriddenParameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: overriddenParameters, target: tester.workspace.projects[0].targets[1])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, buildRequest: secondBuildRequest) { results in
                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("ScriptWithUndeclaredOutput"))) { task in
                    let path = task.workingDirectory.join("build/aProject.build/Debug/TargetWithUndeclaredOutput.build/DerivedSources/new-folder/log.txt")
                    let output = try tester.fs.read(path).asString
                    let expectedOutput = try Regex<Substring>("""
                    \\+ set -o errexit
                    \\+ set -o nounset
                    \\+ set -o pipefail
                    \\+ echo 'Contents of the declared file'
                    \\+ cat .*
                    Contents of the declared file
                    \\+ echo Violation
                    """)
                    XCTAssertMatch(output, .regex(expectedOutput))
                    self.checkForFlakyViolations(results, #/file-write-create .*/new-folder/undeclared.txt .*/#)
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func ensureMkdirSucceedsInDeclaredOutput() async throws {
        try await withTemporaryDirectory() { tmpDirPath async throws -> Void in
            let script = #"""
            set -o xtrace
            set -o errexit
            set -o nounset
            cd "${SRCROOT}"
            echo "File Zero" > "${SCRIPT_OUTPUT_FILE_0}"
            cd subFolder # Already exists because Swift Build creates ancestors of outputs before script execution
            echo "File One" > "${SCRIPT_OUTPUT_FILE_1}"
            """#

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myProjectWithPostProcessor",
                        groupTree: TestGroup(
                            "Sources",
                            children: []),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "TargetWithTwoOutputs",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "EnsureSubdirectoriesExist", shellPath: "/bin/bash", originalObjectID: "EnsureSubdirectoriesExist", contents: script, inputs: [], outputs: ["$(SRCROOT)/fileZero.txt", "$(SRCROOT)/subFolder/fileOne.txt"]),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                try results.checkTasks(.matchRuleType("PhaseScriptExecution")) { tasks in
                    let fileZero = try tester.fs.read(Path(SRCROOT).join("fileZero.txt")).asString
                    #expect(fileZero == "File Zero\n")

                    let fileOne = try tester.fs.read(Path(SRCROOT).join("subFolder/fileOne.txt")).asString
                    #expect(fileOne == "File One\n")
                }
            }
        }
    }

    /// This test is to ensure hardened build succeeds if
    /// a target fully and properly declares its input/output (via a xcfilelist)
    @Test(.requireSDKs(.macOS))
    func ensureProperlyDeclaredInputOutputViaXCFileListSucceeds() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("raw.txt"),
                                TestFile("in.xcfilelist"),
                                TestFile("out.xcfilelist"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "CalculateChecksumTarget",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "Run My Crypto", shellPath: "/bin/bash", originalObjectID: "RunMyCrypto", contents: #"set -e; cat "${FAKE_PATH_IN}" | md5 > "${DERIVED_FILE_DIR}/checksum.txt""#,
                                                              inputs: [],
                                                              inputFileLists: ["$(SRCROOT)/myCryptoProject/in.xcfilelist"],
                                                              outputs: [],
                                                              outputFileLists: ["$(SRCROOT)/myCryptoProject/out.xcfilelist"]
                                                             ),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/raw.txt")) { stream in
                stream <<< "Hello World from xcfilelist!\n"
            }

            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/in.xcfilelist")) { stream in
                stream <<< "$(SRCROOT)/myCryptoProject/raw.txt\n"

                // It's unfortunate that if we fail to declare the inputs properly here
                // the script will go on and calculate an empty checksum in the result.

                // TODO: we should get back to this scenario once better diagnostics is in place.
                // See rdar://86276021 (User script sandboxing: Emit list of violations as diagnostics).
            }

            try await tester.fs.writeFileContents(Path(SRCROOT).join("myCryptoProject/out.xcfilelist")) { stream in
                stream <<< "$(DERIVED_FILE_DIR)/checksum.txt\n"
            }

            let overriddenParameters = BuildParameters(configuration: "Debug",
                                                       overrides: ["FAKE_PATH_IN": Path(SRCROOT).join("myCryptoProject/raw.txt").str])

            // Ensure content of checksum.txt is 8422bdbdffd21972340e63e377d9dbcf with no violation.
            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                try results.checkTask(.matchRuleType("PhaseScriptExecution")) { task in
                    let path = task.workingDirectory.join("build/myCryptoProject.build/Debug/CalculateChecksumTarget.build/DerivedSources/checksum.txt")
                    let checksum = try tester.fs.read(path).asString
                    #expect(checksum == "8422bdbdffd21972340e63e377d9dbcf\n")
                }
            }
        }
    }

    /// "Undeclared input from disk"
    /// Read a source from the shell script, but not declare it as input of the shell-phase
    ///
    /// The problematic scenario:
    /// 1. Build
    /// 2. Modify “A.txt”
    /// 3. Rebuild did not rerun the script
    /// 4. Incorrect because “A.txt” has changed
    ///
    /// Expected: We want sandbox-exec to warn/fail that “A.txt” is accessed but not declared in the input file list.

    @Test(.requireSDKs(.macOS))
    func blockUndeclaredInputOrOutputFromDisk() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("A.txt"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "TargetWithUndeclaredInput",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "ScriptWithUndeclaredInput", shellPath: "/bin/bash", originalObjectID: "ScriptWithUndeclaredInput", contents: #"cat "$FAKE_PATH""#, inputs: [], outputs: []),
                                ]
                            ),
                            TestAggregateTarget(
                                "TargetWithUndeclaredOutput",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "ScriptWithUndeclaredOutput", shellPath: "/bin/bash", originalObjectID: "ScriptWithUndeclaredOutput", contents: #"touch "${SRCROOT}/undeclared-output.txt""#, inputs: [], outputs: []),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.fs.writeFileContents(Path(SRCROOT).join("aProject/undeclared-input.txt")) { stream in
                stream <<< "int main() { return 0; }\n"
            }

            // Override FAKE_PATH with testWorkspace.sourceRoot.join("aProject/undeclared-input.txt")
            let overriddenParameters = BuildParameters(configuration: "Debug",
                                                       overrides: ["FAKE_PATH": Path(SRCROOT).join("aProject/undeclared-input.txt").str])

            let firstBuildRequest = BuildRequest(parameters: overriddenParameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: overriddenParameters, target: tester.workspace.projects[0].targets[0])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, buildRequest: firstBuildRequest) { results in
                results.checkWarning(.contains("'ScriptWithUndeclaredInput' will be run during every build because it does not specify any outputs."))
                self.checkForFlakyViolations(results, #/file-read-data .*/aProject/undeclared-input.txt .*/#)

                results.checkNoDiagnostics()
            }

            let secondBuildRequest = BuildRequest(parameters: overriddenParameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: overriddenParameters, target: tester.workspace.projects[0].targets[1])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS, buildRequest: secondBuildRequest) { results in
                results.checkWarning(.contains("'ScriptWithUndeclaredOutput' will be run during every build because it does not specify any outputs."))
                self.checkForFlakyViolations(results, #/file-write-create .*/aProject/undeclared-output.txt .*/#)

                results.checkNoDiagnostics()
            }
        }
    }

    /// "Undeclared input from another phase"
    /// Read output of another (not necessarily previous) phase, without declaring that file as input dependency
    /// Because  there is no dependency relationship, phases may run concurrently and/or out of order.
    ///
    /// The problematic scenario:
    /// There are two targets: Target A and Target B (running in parallel; no dependency relationship)
    /// TargetA emits A.txt and simultaneously TargetB reads A.txt,
    /// however TargetB has not included TargetA as dependency.
    ///
    /// This is problematic because
    /// 1. If we run Target A, it may not trigger a rebuild for Target B
    /// 2. May be a data race (file is not written fully on disk, and tasks are running concurrently)
    ///
    /// Expected: When B reads “A.txt” we need to warn/error.

    @Test(.requireSDKs(.macOS))
    func blockUndeclaredInputFromAnotherPhase() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("A.txt"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ])],
                        targets: [
                            // `BuildOperationTester::checkBuild` implicitly runs only the first target.
                            TestAggregateTarget(
                                "ALL",
                                dependencies: ["TargetWithDeclaredOutput", "TargetReadUndeclaredInputFromDeclaredOutputOfOtherTarget"]
                            ),
                            TestStandardTarget(
                                "TargetWithDeclaredOutput",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "Run Me A", shellPath: "/bin/bash", originalObjectID: "RunMeA", contents: #"touch "${SCRIPT_OUTPUT_FILE_0}""#, inputs: [], outputs: ["$(SHARED_DERIVED_FILE_DIR)/A.txt"]),
                                ],
                                dependencies: ["Other"]
                            ),
                            TestStandardTarget(
                                "TargetReadUndeclaredInputFromDeclaredOutputOfOtherTarget",
                                type: .application,
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "ScriptReadUndeclaredInputFromDeclaredOutputOfOtherTarget", shellPath: "/bin/bash", originalObjectID: "ScriptReadUndeclaredInputFromDeclaredOutputOfOtherTarget", contents: #"cat "${SHARED_DERIVED_FILE_DIR}/A.txt""#, inputs: [], outputs: []),
                                ],
                                dependencies: ["Other"]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkWarning(.contains("'ScriptReadUndeclaredInputFromDeclaredOutputOfOtherTarget' will be run during every build because it does not specify any outputs."))

                self.checkForFlakyViolations(results, #/file-read-data .*/A.txt .*/#)
                results.checkNoDiagnostics()
            }
        }
    }

    /// "Declared dependency on undeclared artifact from another target"
    ///
    /// The problematic scenario:
    /// Target B depends on A.txt (and A.txt is listed as input dependency) but A.txt is emitted by Target A, and Target A has not listed it as output file
    /// Note that A.txt needs to be in SRCROOT.
    /// Current sandbox policy permits read/writes of undeclared dependencies outside of the source and build folders.
    ///
    /// This is problematic because
    /// 1. If we run Target A, it may not trigger a rebuild for Target B
    /// 2. May be a data race (file is not written fully on disk, and tasks are running concurrently)
    ///
    /// Expected: Target A should fail when it writes A.txt because it is not explicitly listed as output

    @Test(.requireSDKs(.macOS))
    func blockDeclaredDependencyOnUndeclaredEmissionFromAnotherTarget() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let sourceRoot = tmpDirPath.join("Test")
            let aDotTxtPath = sourceRoot.join("aProject/A.txt").str

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: sourceRoot,
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("A.txt"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "ALL",
                                dependencies: ["DummmyShellTargetA", "DummmyShellTargetB"]
                            ),
                            TestAggregateTarget(
                                "DummmyShellTargetA",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "EchoScript", shellPath: "/bin/bash", originalObjectID: "EchoScript", contents: "echo hello > \"\(aDotTxtPath)\"", inputs: [], outputs: []),
                                ]
                            ),
                            TestAggregateTarget(
                                "DummmyShellTargetB",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "CatScript", shellPath: "/bin/bash", originalObjectID: "CatScript", contents: #"cat "${SCRIPT_INPUT_FILE_0}""#, inputs: [aDotTxtPath], outputs: []),
                                ],
                                dependencies: ["DummmyShellTargetA"]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.fs.writeFileContents(Path(aDotTxtPath)) { stream in
                stream <<< "int main() { return 0; }\n"
            }

            try await tester.checkBuild(runDestination: .macOS) { results in
                results.checkWarning(.contains("'CatScript' will be run during every build because it does not specify any outputs."))
                results.checkWarning(.contains("'EchoScript' will be run during every build because it does not specify any outputs."))

                self.checkForFlakyViolations(results, #/file-write-data .*/aProject/A.txt .*/#)
                results.checkNoDiagnostics()
            }
        }
    }

    /// rdar://87776575 (Sandbox blocks getcwd() unexpectedly, which blocks Foundation.Data(contentsOf: relativePath))
    @Test(.requireSDKs(.macOS))
    func ensureFoundationDataWorksWithRelativePath() async throws {
        try await withTemporaryDirectory() { (tmpDirPath: Path) async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myFoundationProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Configs/subfolder/FeatureHiding.swift"),
                                TestFile("Configs/subfolder/FeatureHiding.xcconfig"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "FeatureHidingTarget",
                                buildPhases: [
                                    TestShellScriptBuildPhase(
                                        name: "RunFeatureHiding",
                                        shellPath: "/bin/bash",
                                        originalObjectID: "RunFeatureHiding",
                                        contents:
                                            """
                                            (set -o xtrace
                                            set -o errexit
                                            set -o nounset
                                            set -o pipefail
                                            export LLVM_PROFILE_FILE=\(Path.null.str)
                                            cd Configs/subfolder
                                            "$TOOLCHAIN_DIR/usr/bin/swiftc" FeatureHiding.swift -o \(tmpDirPath.str)/FeatureHiding 2> "$SCRIPT_OUTPUT_FILE_1"
                                            cp \(tmpDirPath.str)/FeatureHiding "$SCRIPT_OUTPUT_FILE_2"
                                            "$SCRIPT_OUTPUT_FILE_2" 2>> "$SCRIPT_OUTPUT_FILE_1"
                                            ) &> "$SCRIPT_OUTPUT_FILE_0"
                                            """,
                                        inputs: ["$(SRCROOT)/Configs/subfolder/FeatureHiding.swift", "$(SRCROOT)/Configs/subfolder/FeatureHiding.xcconfig"],
                                        outputs: ["$DERIVED_FILE_DIR/output.txt", "$DERIVED_FILE_DIR/swift_log.txt", "$DERIVED_FILE_DIR/FeatureHiding"]
                                    ),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT).join("Configs/subfolder"), recursive: true)

            try await tester.fs.writeFileContents(Path(SRCROOT).join("Configs/subfolder/FeatureHiding.swift")) { stream in
                let str = #"""
                #!/usr/bin/swift
                import Foundation

                public func getcwd() -> String? {
                    let cwd = getcwd(nil, Int(PATH_MAX))
                    if cwd == nil {
                       perror("getcwd")
                       return nil
                    }

                    defer { free(cwd) }
                    guard let path = String(validatingUTF8: cwd!) else { fatalError("could not parse utf8 from getcwd") }
                    return path
                }

                print("getcwd: \(getcwd() ?? "nil")")
                print("FileManager.default.currentDirectoryPath: \(FileManager.default.currentDirectoryPath)")
                print("NSHomeDirectory: \(NSHomeDirectory())")

                let relURL = URL(fileURLWithPath: "FeatureHiding.xcconfig")
                print("Data_contentsOf: \((try? Data(contentsOf: relURL))?.description ?? "nil")")
                """#
                stream <<< str
            }

            try await tester.fs.writeFileContents(Path(SRCROOT).join("Configs/subfolder/FeatureHiding.xcconfig")) { stream in
                stream <<< "The quick brown fox jumps over the lazy dog" // 43 bytes
            }

            let overriddenParameters = BuildParameters(configuration: "Debug")

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS) { results in
                try results.checkTask(.matchRuleType("PhaseScriptExecution")) { task in
                    let path = task.outputPaths[0]
                    let output = try tester.fs.read(path).asString
                    let expectedOutput = Regex {
                        #/\+ set -o nounset\n/#
                        #/\+ set -o pipefail\n/#
                        #/\+ export LLVM_PROFILE_FILE=/#
                        Regex<Substring>(verbatim: Path.null.str)
                        #/\n/#
                        #/\+ LLVM_PROFILE_FILE=/#
                        Regex<Substring>(verbatim: Path.null.str)
                        #/\n/#
                        #/\+ cd Configs/subfolder\n/#
                        #/\+ .*swiftc .*\n/#
                        #/\+ cp .*\n/#
                        #/\+ .*FeatureHiding\n/#
                        #/getcwd: /#
                        Regex<Substring>(verbatim: Path(SRCROOT).join("Configs/subfolder").str)
                        #/\n/#
                        #/FileManager.default.currentDirectoryPath: /#
                        Regex<Substring>(verbatim: Path(SRCROOT).join("Configs/subfolder").str)
                        #/\n/#
                        #/NSHomeDirectory: /#
                        Regex<Substring>(verbatim: NSHomeDirectory())
                        #/\n/#
                        #/Data_contentsOf: 43 bytes/#
                    }
                    XCTAssertMatch(output, .regex(expectedOutput))
                }
                results.checkNoDiagnostics()
            }
        }
    }

    /// PROJECT_DIR and SRCROOT mostly have the same value
    /// SRCROOT is overridable
    /// PROJECT_DIR is not an overridable value.
    /// This test ensures writing to PROJECT_DIR is blocked even when SRCROOT is overridden to a different path
    @Test(.requireSDKs(.macOS))
    func ensureProjectDirIsBlocked() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let SRCROOT = tmpDirPath.join("swbuild-test-testEnsureProjectDirIsBlocked").str

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myBlockedProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("blocked.txt"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                                "SRCROOT": SRCROOT
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "TargetA",
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "EnsureProjectDirIsBlocked", shellPath: "/bin/bash", originalObjectID: "EnsureProjectDirIsBlocked", contents: #"cat "${PROJECT_DIR}/blocked.txt""#, inputs: [], outputs: []),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)


            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS) { results in
                results.checkWarning(.contains("'EnsureProjectDirIsBlocked' will be run during every build because it does not specify any outputs."))

                self.checkForFlakyViolations(results, #/file-read-data .*/blocked.txt .*/#)
                results.checkNoDiagnostics()
            }
        }
    }


    @Test(.requireSDKs(.macOS))
    func ensureDerivedDataIsWritable() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: []),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                                "MY_DERIVED_DATA_DIR": "$(DERIVED_DATA_DIR)",
                            ])],
                        targets: [
                            TestAggregateTarget(
                                "Calculate Checksum Target",
                                buildPhases: [
                                    // Write and read to DERIVED_DATA_DIR should be allowed
                                    TestShellScriptBuildPhase(name: "ReadWriteToDerivedDataDir", shellPath: "/bin/bash", originalObjectID: "ReadWriteToDerivedDataDir", contents: #"""
                (set -o xtrace
                set -o errexit
                set -o nounset
                echo -n "Hello from DERIVED_DATA_DIR" > "${MY_DERIVED_DATA_DIR}/hello.txt"
                cat "${MY_DERIVED_DATA_DIR}/hello.txt") &> "${SCRIPT_OUTPUT_FILE_0}"
                """#, inputs: [], outputs: ["${DERIVED_FILE_DIR}/ReadWriteToDerivedDataDir.txt"], alwaysOutOfDate: true),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Note: this test fails if DerivedData is a subfolder of SRCROOT
            // For example let derivedData = Path("\(SRCROOT)/DerivedData") will fail.
            // This is an edge case that (for now) we are okay with not handling
            let derivedData = tmpDirPath.join("DerivedData")
            let arena = ArenaInfo.buildArena(derivedDataRoot: derivedData)
            let overriddenParameters = BuildParameters(configuration: "Debug", arena: arena)

            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                try results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchRuleItemPattern(.contains("WriteToDerivedDataDir"))) { task in
                    let path = task.outputPaths[0]
                    let value = try tester.fs.read(path).asString
                    #expect(value == """
                    + set -o errexit
                    + set -o nounset
                    + echo -n 'Hello from DERIVED_DATA_DIR'
                    + cat \(derivedData.str)/hello.txt
                    Hello from DERIVED_DATA_DIR
                    """)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func ensureSandboxingAppliesToBuildRules() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "myCryptoProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("raw.fake-neutral"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ])],
                        targets: [
                            TestStandardTarget(
                                "Calculate Checksum Target and a Very Very Very Very Very Very Very Very Very Very Very Very Very Very Very Very Very Long Description",
                                type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "raw.fake-neutral",
                                    ]),
                                ],
                                buildRules: [
                                    TestBuildRule(filePattern: "*.fake-neutral",
                                                  script: #"set -o errexit; cat "${SCRIPT_INPUT_FILE}" | md5 > "${SCRIPT_OUTPUT_FILE_0}""#,
                                                  outputs: ["$(DERIVED_FILES_DIR)/$(INPUT_FILE_NAME).md5"],
                                                  runOncePerArchitecture: false),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT), recursive: true)

            try await tester.fs.writeFileContents(Path(SRCROOT).join("raw.fake-neutral")) { stream in
                stream <<< "Hello World!\n"
            }

            let overriddenParameters = BuildParameters(configuration: "Debug")

            try await tester.checkBuild(parameters: overriddenParameters, runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                try results.checkTask(.matchRuleType("RuleScriptExecution")) { task in
                    #expect(task.commandLine.first == "/usr/bin/sandbox-exec")

                    let path = task.outputPaths[0]
                    let checksum = try tester.fs.read(path).asString
                    #expect(checksum == "8ddd8be4b179a529afa5f2ffae4b9858\n")
                }
                results.checkNoDiagnostics()
            }
        }
    }
}
