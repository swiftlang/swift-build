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

import Foundation
import SWBCore
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct ClangModuleVerifierTaskTests: CoreBasedTests {
    func generateInput(fs: any FSProxy, commandLine: [String]) async throws -> (CommandResult, MockTaskOutputDelegate) {
        let action = ClangModuleVerifierInputGeneratorTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "Generate Module Verifier Input")
        let executionDelegate = try await MockExecutionDelegate(fs: fs, core: getCore())
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        return (result, outputDelegate)
    }

    @Test
    func inputGenerationCommandLineErrors() async throws {
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: [])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: no input framework specified"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: no input framework specified"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework", "--asdf"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: unknown argument '--asdf'"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: missing required argument --language"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework", "--language"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: missing argument to --language"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework", "--language", "rust"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: unrecognized language 'rust'"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework", "--language", "c"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: missing required argument --main-output"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework", "--language", "c", "--main-output"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: missing argument to --main-output"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework", "--language", "c", "--main-output", "/m"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: missing required argument --header-output"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework", "--language", "c", "--main-output", "/m", "--header-output"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: missing argument to --header-output"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework", "--language", "c", "--main-output", "/m", "--header-output", "/h"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: missing required argument --module-map-output"])
        }
        do {
            let (result, outputDelegate) = try await generateInput(fs: PseudoFS(), commandLine: ["exe", "/foo.framework", "--language", "c", "--main-output", "/m", "--header-output", "/h", "--module-map-output"])
            #expect(result == .failed)
            #expect(outputDelegate.errors == ["error: missing argument to --module-map-output"])
        }
    }

    @Test
    func inputGenerationBasic() async throws {
        try await withTemporaryDirectory(fs: localFS) { tmp in
            try localFS.createDirectory(tmp.join("A.framework/Modules"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/Headers"), recursive: true)
            try localFS.write(tmp.join("A.framework/Headers/A.h"), contents: "")
            try localFS.write(tmp.join("A.framework/Headers/B.h"), contents: "")
            try localFS.write(tmp.join("A.framework/Modules/module.modulemap"), contents: """
            framework module A {
                umbrella header "A.h"
            }
            """)

            do {
                let (result, outputDelegate) = try await generateInput(fs: localFS, commandLine: [
                    "exe",
                    tmp.join("A.framework").str,
                    "--language", "c",
                    "--main-output", tmp.join("Test.c").str,
                    "--header-output", tmp.join("Test.h").str,
                    "--module-map-output", tmp.join("Test.modulemap").str
                ])

                #expect(result == .succeeded)
                #expect(outputDelegate.messages == [])

                #expect(try localFS.read(tmp.join("Test.c")) == """
                #include <Test/Test.h>
                """)
                #expect(try localFS.read(tmp.join("Test.h")) == """
                #include <A/A.h>
                #include <A/B.h>

                """)
                #expect(try localFS.read(tmp.join("Test.modulemap")) == """
                framework module Test {
                    umbrella header "Test.h"

                    export *
                    module * { export * }
                }
                """)
            }
            do {
                let (result, outputDelegate) = try await generateInput(fs: localFS, commandLine: [
                    "exe",
                    tmp.join("A.framework").str,
                    "--language", "objective-c++",
                    "--main-output", tmp.join("Test.c").str,
                    "--header-output", tmp.join("Test.h").str,
                    "--module-map-output", tmp.join("Test.modulemap").str
                ])

                #expect(result == .succeeded)
                #expect(outputDelegate.messages == [])

                #expect(try localFS.read(tmp.join("Test.c")) == """
                #import <Test/Test.h>
                """)
                #expect(try localFS.read(tmp.join("Test.h")) == """
                #import <A/A.h>
                #import <A/B.h>

                """)
                #expect(try localFS.read(tmp.join("Test.modulemap")) == """
                framework module Test {
                    umbrella header "Test.h"

                    export *
                    module * { export * }
                }
                """)
            }
        }
    }

    @Test
    func inputGenerationPrivate() async throws {
        try await withTemporaryDirectory(fs: localFS) { tmp in
            try localFS.createDirectory(tmp.join("A.framework/Modules"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/Headers"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/PrivateHeaders"), recursive: true)
            try localFS.write(tmp.join("A.framework/Headers/A.h"), contents: "")
            try localFS.write(tmp.join("A.framework/PrivateHeaders/B.h"), contents: "")
            try localFS.write(tmp.join("A.framework/Modules/module.modulemap"), contents: """
            framework module A {
                header "A.h"
            }
            """)
            try localFS.write(tmp.join("A.framework/Modules/module.private.modulemap"), contents: """
            framework module A_Private {
                header "B.h"
            }
            """)

            let (result, outputDelegate) = try await generateInput(fs: localFS, commandLine: [
                "exe",
                tmp.join("A.framework").str,
                "--language", "c",
                "--main-output", tmp.join("Test.c").str,
                "--header-output", tmp.join("Test.h").str,
                "--module-map-output", tmp.join("Test.modulemap").str
            ])

            #expect(result == .succeeded)
            #expect(outputDelegate.messages == [])

            #expect(try localFS.read(tmp.join("Test.c")) == """
            #include <Test/Test.h>
            """)
            #expect(try localFS.read(tmp.join("Test.h")) == """
            #include <A/A.h>

            // Private
            #include <A/B.h>

            """)
            #expect(try localFS.read(tmp.join("Test.modulemap")) == """
            framework module Test {
                umbrella header "Test.h"

                export *
                module * { export * }
            }
            """)
        }
    }

    @Test
    func inputGenerationNoPrivateMap() async throws {
        try await withTemporaryDirectory(fs: localFS) { tmp in
            try localFS.createDirectory(tmp.join("A.framework/Modules"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/Headers"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/PrivateHeaders"), recursive: true)
            try localFS.write(tmp.join("A.framework/Headers/A.h"), contents: "")
            try localFS.write(tmp.join("A.framework/PrivateHeaders/B.h"), contents: "")
            try localFS.write(tmp.join("A.framework/Modules/module.modulemap"), contents: """
            framework module A {
                header "A.h"
            }
            """)

            let (result, outputDelegate) = try await generateInput(fs: localFS, commandLine: [
                "exe",
                tmp.join("A.framework").str,
                "--language", "c",
                "--main-output", tmp.join("Test.c").str,
                "--header-output", tmp.join("Test.h").str,
                "--module-map-output", tmp.join("Test.modulemap").str
            ])

            #expect(result == .succeeded)
            #expect(try localFS.read(tmp.join("Test.h")) == """
                #include <A/A.h>

                """)
            #expect(outputDelegate.warnings == [
                "warning: \(tmp.join("A.framework/Modules/module.private.modulemap").str): module map is missing; there are private headers but no module map"
            ])
        }
    }

    @Test
    func inputGenerationNoPublicMap() async throws {
        try await withTemporaryDirectory(fs: localFS) { tmp in
            try localFS.createDirectory(tmp.join("A.framework/Modules"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/Headers"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/PrivateHeaders"), recursive: true)
            try localFS.write(tmp.join("A.framework/Headers/A.h"), contents: "")
            try localFS.write(tmp.join("A.framework/PrivateHeaders/B.h"), contents: "")
            try localFS.write(tmp.join("A.framework/Modules/module.private.modulemap"), contents: """
                framework module A_Private {
                  header "B.h"
                }
                """)

            let (result, outputDelegate) = try await generateInput(fs: localFS, commandLine: [
                "exe",
                tmp.join("A.framework").str,
                "--language", "c",
                "--main-output", tmp.join("Test.c").str,
                "--header-output", tmp.join("Test.h").str,
                "--module-map-output", tmp.join("Test.modulemap").str
            ])

            #expect(result == .succeeded)
            #expect(try localFS.read(tmp.join("Test.h")) == """
                // Private
                #include <A/B.h>

                """)
            #expect(outputDelegate.warnings == [
                "warning: \(tmp.join("A.framework/Modules/module.modulemap").str): module map is missing; there are public headers but no module map"
            ])
        }
    }

    @Test
    func moduleMapFileVerifier() async throws {
        try await withTemporaryDirectory(fs: localFS) { tmp in
            try localFS.createDirectory(tmp.join("A.framework/Modules"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/Headers"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/PrivateHeaders"), recursive: true)
            try localFS.write(tmp.join("A.framework/Headers/A.h"), contents: "")
            try localFS.write(tmp.join("A.framework/PrivateHeaders/Priv.h"), contents: "")
            try localFS.write(tmp.join("A.framework/Modules/module.modulemap"), contents: """
            framework module A {
            }
            """)

            let (result, outputDelegate) = try await generateInput(fs: localFS, commandLine: [
                "exe",
                tmp.join("A.framework").str,
                "--language", "c",
                "--main-output", tmp.join("Test.c").str,
                "--header-output", tmp.join("Test.h").str,
                "--module-map-output", tmp.join("Test.modulemap").str
            ])

            #expect(result == .failed)
            #expect(outputDelegate.errors == [
                "error: \(tmp.join("A.framework/Modules/module.modulemap").str): module map does not declare a module"
            ])
            #expect(outputDelegate.warnings == [
                "warning: \(tmp.join("A.framework/Modules/module.private.modulemap").str): module map is missing; there are private headers but no module map"
            ])
        }
        try await withTemporaryDirectory(fs: localFS) { tmp in
            try localFS.createDirectory(tmp.join("A.framework/Modules"), recursive: true)
            try localFS.createDirectory(tmp.join("A.framework/Headers"), recursive: true)
            try localFS.write(tmp.join("A.framework/Modules/module.private.modulemap"), contents: """
            framework module A {
                module Sub {}
            }
            """)

            let (result, outputDelegate) = try await generateInput(fs: localFS, commandLine: [
                "exe",
                tmp.join("A.framework").str,
                "--language", "c",
                "--main-output", tmp.join("Test.c").str,
                "--header-output", tmp.join("Test.h").str,
                "--module-map-output", tmp.join("Test.modulemap").str
            ])

            #expect(result == .failed)
            #expect(outputDelegate.errors == [
                "error: \(tmp.join("A.framework/Modules/module.private.modulemap").str): private module exists but no private headers"
            ])
            #expect(outputDelegate.warnings == [])
        }
    }
}
