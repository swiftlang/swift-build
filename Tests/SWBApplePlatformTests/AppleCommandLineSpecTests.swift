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

import SWBApplePlatform
import Testing
import SWBCore
import SWBTestSupport
import SWBUtil
import SWBMacro

@Suite
fileprivate struct AppleCommandLineSpecTests: CoreBasedTests {
    @Test(.skipHostOS(.windows, "actool is Apple-only"))
    func assetCatalogCompilerOutputParser() async throws {
        let delegate = CapturingTaskParserDelegate()
        let task = OutputParserMockTask(basenames: [], exec: "actool")
        let core = try await getCore()
        let workspaceContext = try WorkspaceContext(core: core, workspace: TestWorkspace("test", projects: []).load(core), processExecutionCache: .sharedForTesting)
        let parser = AssetCatalogCompilerOutputParser(for: task, workspaceContext: workspaceContext, buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext), delegate: delegate, progressReporter: nil)
        parser.write(bytes: "foo bar\n")
        parser.write(bytes: "error: is an error\n")
        parser.write(bytes: "    error: is another error\n")
        parser.write(bytes: "NOT error: is not an error\n")
        parser.write(bytes: "file: error: an error, no line\n")
        parser.write(bytes: "file:1: error: an error, with line\n")
        parser.write(bytes: "file: warning: a warning\n")
        parser.write(bytes: "file: note: a note\n")
        parser.write(bytes: "file: note: a different note\n")
        parser.write(bytes: "file: notice: a notice, no line number\n")
        parser.write(bytes: "file:1: notice: a notice with a line number\n")
        parser.write(bytes: "file:some/relative/path: notice: a notice with an identifier\n")
        parser.write(bytes: "../file: error: an error, no line\n")
        parser.write(bytes: "../file:1: error: an error, with line\n")
        parser.write(bytes: "../file:some/relative/path: error: an error, with an identifier\n")
        parser.write(bytes: "../file: warning: a warning\n")
        parser.write(bytes: "../file: note: a note\n")
        parser.write(bytes: "../file: note: a different note\n")
        parser.write(bytes: "../file: notice: a notice, no line number\n")
        parser.write(bytes: "../file:1: notice: a notice with a line number\n")
        parser.write(bytes: "actool: warning: tool itself can have warnings\n")
        parser.write(bytes: "actool: this is just a note\n")
        parser.write(bytes: "/tmp/actool: this is a note too\n")
        parser.write(bytes: "swiftc: swiftc shouldn't be an error\n")
        parser.write(bytes: "\n")
        parser.write(bytes: " \n")
        parser.write(bytes: ":\n")
        parser.write(bytes: "a:\n")
        parser.close(result: nil)

        DiagnosticsEngineTester(delegate.diagnosticsEngine) { result in
            result.check(diagnostic: "is an error", behavior: .error)
            result.check(diagnostic: "is another error", behavior: .error)
            result.check(diagnostic: "an error, no line", behavior: .error, location: "/taskdir/file")
            result.check(diagnostic: "an error, with line", behavior: .error, location: "/taskdir/file:1")
            result.check(diagnostic: "a warning", behavior: .warning, location: "/taskdir/file")
            result.check(diagnostic: "a note", behavior: .note, location: "/taskdir/file")
            result.check(diagnostic: "a different note", behavior: .note, location: "/taskdir/file")
            result.check(diagnostic: "a notice, no line number", behavior: .note, location: "/taskdir/file")
            result.check(diagnostic: "a notice with a line number", behavior: .note, location: "/taskdir/file:1")
            result.check(diagnostic: "a notice with an identifier", behavior: .note, location: "/taskdir/file:some/relative/path")
            result.check(diagnostic: "an error, no line", behavior: .error, location: "/file")
            result.check(diagnostic: "an error, with line", behavior: .error, location: "/file:1")
            result.check(diagnostic: "an error, with an identifier", behavior: .error, location: "/file:some/relative/path")
            result.check(diagnostic: "a warning", behavior: .warning, location: "/file")
            result.check(diagnostic: "a note", behavior: .note, location: "/file")
            result.check(diagnostic: "a different note", behavior: .note, location: "/file")
            result.check(diagnostic: "a notice, no line number", behavior: .note, location: "/file")
            result.check(diagnostic: "a notice with a line number", behavior: .note, location: "/file:1")
            result.check(diagnostic: "tool itself can have warnings", behavior: .warning)
            result.check(diagnostic: "this is just a note", behavior: .note)
            result.check(diagnostic: "this is a note too", behavior: .note)
        }
    }

    @Test(.skipHostOS(.windows, "ibtool is Apple-only"))
    func interfaceBuilderCompilerOutputParser() async throws {
        let delegate = CapturingTaskParserDelegate()
        let task = OutputParserMockTask(basenames: [], exec: "ibtool")
        let core = try await getCore()
        let workspaceContext = try WorkspaceContext(core: core, workspace: TestWorkspace("test", projects: []).load(core), processExecutionCache: .sharedForTesting)
        let parser = InterfaceBuilderCompilerOutputParser(for: task, workspaceContext: workspaceContext, buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext), delegate: delegate, progressReporter: nil)
        parser.write(bytes: "foo bar\n")
        parser.write(bytes: "error: is an error\n")
        parser.write(bytes: "    error: is another error\n")
        parser.write(bytes: "NOT error: is not an error\n")
        parser.write(bytes: "file: error: an error, no line\n")
        parser.write(bytes: "file:1: error: an error, with line\n")
        parser.write(bytes: "file:abc-de-fgh: error: an error, with identifier\n")
        parser.write(bytes: "file: warning: a warning\n")
        parser.write(bytes: "file: note: a note\n")
        parser.write(bytes: "file: note: a different note\n")
        parser.write(bytes: "file: notice: a notice, no line number\n")
        parser.write(bytes: "file:1: notice: a notice with a line number\n")
        parser.write(bytes: "../file: error: an error, no line\n")
        parser.write(bytes: "../file:1: error: an error, with line\n")
        parser.write(bytes: "../file: warning: a warning\n")
        parser.write(bytes: "../file: note: a note\n")
        parser.write(bytes: "../file: note: a different note\n")
        parser.write(bytes: "../file: notice: a notice, no line number\n")
        parser.write(bytes: "../file:1: notice: a notice with a line number\n")
        parser.write(bytes: "../file:abc-de-fgh: notice: a notice with an identifier\n")
        parser.write(bytes: "ibtool: warning: tool itself can have warnings\n")
        parser.write(bytes: "ibtool: this is just a note\n")
        parser.write(bytes: "/tmp/ibtool: this is a note too\n")
        parser.write(bytes: "swiftc: swiftc shouldn't be an error\n")
        parser.write(bytes: "\n")
        parser.write(bytes: " \n")
        parser.write(bytes: ":\n")
        parser.write(bytes: "a:\n")
        parser.write(bytes: "../file:abc-de-fgh: notice: a notice with an identifier - [Some method] [9]\n")
        parser.close(result: nil)

        DiagnosticsEngineTester(delegate.diagnosticsEngine) { result in
            result.check(diagnostic: "is an error", behavior: .error)
            result.check(diagnostic: "is another error", behavior: .error)
            result.check(diagnostic: "an error, no line", behavior: .error, location: "/taskdir/file")
            result.check(diagnostic: "an error, with line", behavior: .error, location: "/taskdir/file:1")
            result.check(diagnostic: "an error, with identifier", behavior: .error, location: "/taskdir/file:abc-de-fgh")
            result.check(diagnostic: "a warning", behavior: .warning, location: "/taskdir/file")
            result.check(diagnostic: "a note", behavior: .note, location: "/taskdir/file")
            result.check(diagnostic: "a different note", behavior: .note, location: "/taskdir/file")
            result.check(diagnostic: "a notice, no line number", behavior: .note, location: "/taskdir/file")
            result.check(diagnostic: "a notice with a line number", behavior: .note, location: "/taskdir/file:1")
            result.check(diagnostic: "an error, no line", behavior: .error, location: "/file")
            result.check(diagnostic: "an error, with line", behavior: .error, location: "/file:1")
            result.check(diagnostic: "a warning", behavior: .warning, location: "/file")
            result.check(diagnostic: "a note", behavior: .note, location: "/file")
            result.check(diagnostic: "a different note", behavior: .note, location: "/file")
            result.check(diagnostic: "a notice, no line number", behavior: .note, location: "/file")
            result.check(diagnostic: "a notice with a line number", behavior: .note, location: "/file:1")
            result.check(diagnostic: "a notice with an identifier", behavior: .note, location: "/file:abc-de-fgh")
            result.check(diagnostic: "tool itself can have warnings", behavior: .warning)
            result.check(diagnostic: "this is just a note", behavior: .note)
            result.check(diagnostic: "this is a note too", behavior: .note)
            result.check(diagnostic: "a notice with an identifier - [Some method]", behavior: .note, location: "/file:abc-de-fgh")
        }
    }

    @Test
    func resMergerLinkerTaskConstruction() async throws {
        let core = try await getCore()
        let resMergerSpec: GenericLinkerSpec = try core.specRegistry.getSpec() as ResMergerLinkerSpec

        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(BuiltinMacros.REZ_COLLECTOR_DIR, literal: Path.root.join("rezCollectorDir").str)
        table.push(BuiltinMacros.PRODUCT_NAME, literal: "app")
        table.push(BuiltinMacros.TARGET_BUILD_DIR, literal: Path.root.join("targetBuildDir").str)
        table.push(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH, literal: "unlocalizedFolderPath")
        let scope = MacroEvaluationScope(table: table)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let cbc = CommandBuildContext(producer: producer, scope: scope, inputs: [], output: Path.root.join("tmp/directory"))

        await resMergerSpec.constructTasks(cbc, delegate)

        #expect(delegate.shellTasks.count == 2)

        do {
            // collector merge
            let task = try #require(delegate.shellTasks[safe: 0])

            #expect(task.ruleInfo == ["ResMergerCollector", Path.root.join("rezCollectorDir/app.rsrc").str])
            #expect(task.execDescription == "Merge resources into app.rsrc")
        }

        do {
            // product merge
            let task = try #require(delegate.shellTasks[safe: 1])

            #expect(task.ruleInfo == ["ResMergerProduct", Path.root.join("targetBuildDir/unlocalizedFolderPath/app.rsrc").str])
            #expect(task.execDescription == "Merge resources into app.rsrc")
        }
    }

    @Test(.skipHostOS(.windows)) // xcstringstool is Apple-specific
    func stringCatalogCompilerOutputParser() async throws {
        let delegate = CapturingTaskParserDelegate()
        let task = OutputParserMockTask(basenames: [], exec: "xcstringstool")
        let core = try await getCore()
        let workspaceContext = try WorkspaceContext(core: core, workspace: TestWorkspace("test", projects: []).load(core), processExecutionCache: .sharedForTesting)
        let parser = StringCatalogCompilerOutputParser(
            for: task,
            workspaceContext: workspaceContext,
            buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext),
            delegate: delegate,
            progressReporter: nil
        )
        parser.write(bytes: "/Users/user/Developer/RocketShip/Localizable.xcstrings: error: Referencing undefined substitution 'arg3' (en: Next meeting at %lld %lld)\n")
        parser.write(bytes: "/Users/user/Developer/RocketShip/Localizable.xcstrings: warning: Substitution 'arg1' was never referenced. To reference, use %#@arg1@ in some other string (en: Next meeting at %lld %lld|==|substitutions.arg1)\n")
        parser.write(bytes: "../Localizable (2).xcstrings: error: Referencing undefined substitution 'arg4' (en: Next meeting at %lld %lld)\n")
        parser.write(bytes: "../Localizable.xcstrings: error: Referencing undefined substitution 'arg5' (en: My key that contains (parens))\n")
        parser.write(bytes: "../Localizable (2).xcstrings: error: Referencing undefined substitution 'arg6' (es_419: My key that contains (fr: embedded))\n")
        parser.write(bytes: "../Localizable (2).xcstrings: error: Referencing undefined substitution 'arg6 (2)' (es_419: My key that contains (fr: embedded))\n")
        parser.close(result: nil)

        DiagnosticsEngineTester(delegate.diagnosticsEngine) { result in
            result.check(
                diagnostic: "Referencing undefined substitution 'arg3'",
                behavior: .error,
                location: "/Users/user/Developer/RocketShip/Localizable.xcstrings:en:Next meeting at %lld %lld"
            )

            result.check(
                diagnostic: "Substitution 'arg1' was never referenced. To reference, use %#@arg1@ in some other string",
                behavior: .warning,
                location: "/Users/user/Developer/RocketShip/Localizable.xcstrings:en:Next meeting at %lld %lld|==|substitutions.arg1"
            )

            result.check(
                diagnostic: "Referencing undefined substitution 'arg4'",
                behavior: .error,
                location: "/Localizable (2).xcstrings:en:Next meeting at %lld %lld"
            )

            result.check(
                diagnostic: "Referencing undefined substitution 'arg5'",
                behavior: .error,
                location: "/Localizable.xcstrings:en:My key that contains (parens)"
            )

            result.check(
                diagnostic: "Referencing undefined substitution 'arg6'",
                behavior: .error,
                location: "/Localizable (2).xcstrings:es_419:My key that contains (fr: embedded)"
            )

            result.check(
                diagnostic: "Referencing undefined substitution 'arg6 (2)'",
                behavior: .error,
                location: "/Localizable (2).xcstrings:es_419:My key that contains (fr: embedded)"
            )
        }
    }
}
