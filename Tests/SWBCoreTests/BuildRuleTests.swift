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

import Testing
import SWBTestSupport
import SWBUtil
@_spi(Testing) import SWBCore
import SWBMacro

/// Unit tests of build rules and rule matching.
@Suite fileprivate struct BuildRuleTests: CoreBasedTests {
    @Test
    func basicRuleLookup() async throws {
        let core = try await getCore()
        // Create a set of rules.  We’ll use a couple of helper functions for creating the rules.
        var rules = Array<(any BuildRuleCondition,any BuildRuleAction)>()
        func MakeNamePatternConditionTaskActionRule(_ namePattern: String, _ compilerSpecIdent: String) throws -> (any BuildRuleCondition, any BuildRuleAction) {
            return (BuildRuleFileNameCondition(namePatterns: [core.specRegistry.internalMacroNamespace.parseString(namePattern)]), BuildRuleTaskAction(toolSpec: try core.specRegistry.getSpec(compilerSpecIdent) as CommandLineToolSpec))
        }
        func MakeNamePatternConditionScriptActionRule(_ namePattern: String, _ scriptSource: String) throws -> (any BuildRuleCondition, any BuildRuleAction) {
            return (BuildRuleFileNameCondition(namePatterns: [core.specRegistry.internalMacroNamespace.parseString(namePattern)]), BuildRuleScriptAction(guid: "BR\(scriptSource)", name: "BR\(scriptSource)", interpreterPath: "/bin/sh:", scriptSource: scriptSource, inputFiles: [], inputFileLists: [], outputFiles: [], outputFileLists: [], dependencyInfo: nil, runOncePerArchitecture: true, runDuringInstallAPI: false, runDuringInstallHeaders: false))
        }
        func MakeFileTypeConditionTaskActionRule(_ fileTypeIdent: String, _ compilerSpecIdent: String) throws -> (any BuildRuleCondition, any BuildRuleAction) {
            return (BuildRuleFileTypeCondition(fileType: try core.specRegistry.getSpec(fileTypeIdent) as FileTypeSpec), BuildRuleTaskAction(toolSpec: try core.specRegistry.getSpec(compilerSpecIdent) as CommandLineToolSpec))
        }
        func MakeFileTypeConditionScriptActionRule(_ fileTypeIdent: String, _ scriptSource: String) throws -> (any BuildRuleCondition, any BuildRuleAction) {
            return (BuildRuleFileTypeCondition(fileType: try core.specRegistry.getSpec(fileTypeIdent) as FileTypeSpec), BuildRuleScriptAction(guid: "BR\(scriptSource)", name: "BR\(scriptSource)", interpreterPath: "/bin/sh:", scriptSource: scriptSource, inputFiles: [], inputFileLists: [], outputFiles: [], outputFileLists: [], dependencyInfo: nil, runOncePerArchitecture: true, runDuringInstallAPI: false, runDuringInstallHeaders: false))
        }
        rules.append(try MakeNamePatternConditionTaskActionRule("*.c", "com.apple.compilers.llvm.clang.1_0"))
        rules.append(try MakeNamePatternConditionScriptActionRule("*.tiff", "pwd"))
        rules.append(try MakeNamePatternConditionScriptActionRule("*.h", "pwd"))
        rules.append(try MakeFileTypeConditionTaskActionRule("sourcecode.c.objc", "com.apple.compilers.llvm.clang.1_0"))
        rules.append(try MakeFileTypeConditionScriptActionRule("sourcecode.c.objc", "echo"))
        let ruleSet = BasicBuildRuleSet(rules: rules)

        // Create some matchable entities.
        let hFile = FileToBuild(absolutePath: Path.root.join("foo.h"), fileType: try core.specRegistry.getSpec(SpecRegistry.headerFileTypeIdentifiers.first!) as FileTypeSpec)
        let cFile = FileToBuild(absolutePath: Path.root.join("foo.c"), fileType: try core.specRegistry.getSpec("sourcecode.c.c") as FileTypeSpec)
        let pngFile = FileToBuild(absolutePath: Path.root.join("bar.png"), fileType: try core.specRegistry.getSpec("sourcecode.c.c") as FileTypeSpec)

        // Create a scope for evaluation.
        let table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        let scope = MacroEvaluationScope(table: table)

        // Match the rules against the rule set.
        let _ = ruleSet.match(hFile, scope)
        let cAction = ruleSet.match(cFile, scope)
        #expect(cAction.action != nil)
        #expect(cAction.diagnostics.isEmpty)
        let pngAction = ruleSet.match(pngFile, scope)
        #expect(pngAction.action == nil)
        #expect(cAction.diagnostics.isEmpty)
    }

    @Test
    func noDiagnosticForMultipleScriptRulesMatchedToSameInput() async throws {
        let core = try await getCore()
        let table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        let scope = MacroEvaluationScope(table: table)

        // Create 2 script rules that process the same input to force a conflict.
        var rules = Array<(any BuildRuleCondition, any BuildRuleAction)>()
        let rule1 = try core.createShellScriptBuildRule("rule1", "Custom Rule 1", .patterns([scope.namespace.parseLiteralString("*.out")]), "", [], [], [(scope.namespace.parseLiteralString("out1"), nil)], [], nil, false, scope: scope)
        let rule2 = try core.createShellScriptBuildRule("rule2", "Custom Rule 2", .patterns([scope.namespace.parseLiteralString("*.out")]), "", [], [], [(scope.namespace.parseLiteralString("out2"), nil)], [], nil, false, scope: scope)

        rules.append(rule1)
        rules.append(rule2)

        let ruleSet = BasicBuildRuleSet(rules: rules)
        let textSpec = try #require(core.specRegistry.getSpec("text") as? FileTypeSpec)
        let textFile = FileToBuild(absolutePath: Path.root.join("tmp/foo.out"), fileType: textSpec)

        let result = ruleSet.match(textFile, scope)

        // Check that there is a single diagnostic and that it matches the expected one.
        #expect(result.diagnostics.count == 0)
    }

    @Test
    func diagnosticForDisambiguatingMultipleScriptRulesMatchedToSameInput() async throws {
        let core = try await getCore()
        let table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        let scope = MacroEvaluationScope(table: table)

        // Create 2 script rules that process the same input to force a conflict.
        var rules = Array<(any BuildRuleCondition, any BuildRuleAction)>()
        let rule1 = try core.createShellScriptBuildRule("rule1", "Custom Rule 1", .patterns([scope.namespace.parseLiteralString("*.out")]), "", [], [], [(scope.namespace.parseLiteralString("out1"), nil)], [], nil, false, scope: scope)
        let rule2 = try core.createShellScriptBuildRule("rule2", "Custom Rule 2", .patterns([scope.namespace.parseLiteralString("*.out")]), "", [], [], [(scope.namespace.parseLiteralString("out2"), nil)], [], nil, false, scope: scope)

        rules.append(rule1)
        rules.append(rule2)

        func testDiagnostic(enableDebugActivityLogs: Bool) throws {
            let ruleSet = DisambiguatingBuildRuleSet(rules: rules, enableDebugActivityLogs: enableDebugActivityLogs)
            let textSpec = try core.specRegistry.getSpec("text") as FileTypeSpec
            let textFilePath = Path.root.join("tmp/foo.out")
            let textFile = FileToBuild(absolutePath: textFilePath, fileType: textSpec)

            let result = ruleSet.match(textFile, scope)

            // Check that there is a single diagnostic and that it matches the expected one.
            #expect(result.diagnostics == [
                .init(behavior: enableDebugActivityLogs ? .warning : .note, message: [
                    "Multiple rules matching input \'\(textFilePath.str)\':",
                    "Custom Rule 1",
                    "Custom Rule 2",
                    "",
                    "Applying first matching rule \'Custom Rule 1\'",
                ].joined(separator: "\n"))
            ])
        }

        try testDiagnostic(enableDebugActivityLogs: true)
        try testDiagnostic(enableDebugActivityLogs: false)
    }

    @Test
    func noDiagnosticForMultipleScriptRulesMatchedToSameInputAtDifferentLevels() async throws {
        let core = try await getCore()
        let table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        let scope = MacroEvaluationScope(table: table)

        // Create 2 script rules that process the same input to force a conflict.
        let rule1 = try core.createShellScriptBuildRule("rule1", "Custom Rule 1", .patterns([scope.namespace.parseLiteralString("*.out")]), "", [], [], [(scope.namespace.parseLiteralString("out1"), nil)], [], nil, false, scope: scope)
        let rule2 = try core.createShellScriptBuildRule("rule2", "Custom Rule 2", .patterns([scope.namespace.parseLiteralString("*.out")]), "", [], [], [(scope.namespace.parseLiteralString("out2"), nil)], [], nil, false, scope: scope)

        let ruleSet = LeveledBuildRuleSet(ruleSets: [
            BasicBuildRuleSet(rules: [rule1]),
            BasicBuildRuleSet(rules: [rule2]),
        ])
        let textSpec = try core.specRegistry.getSpec("text") as FileTypeSpec
        let textFile = FileToBuild(absolutePath: Path.root.join("tmp/foo.out"), fileType: textSpec)

        let result = ruleSet.match(textFile, scope)

        #expect(result.diagnostics.count == 0)
    }
}
