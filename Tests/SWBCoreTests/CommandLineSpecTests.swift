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
import enum SWBProtocol.ExternalToolResult
import struct SWBProtocol.BuildOperationTaskEnded
import SWBTaskExecution
import SWBMacro
@_spi(Testing) import SWBCore

@Suite fileprivate struct CommandLineSpecTests: CoreBasedTests {
    @Test(.skipHostOS(.windows, "output parsing on Windows needs a lot of work"))
    func genericOutputParser() async throws {
        let delegate = CapturingTaskParserDelegate()
        let task = OutputParserMockTask(basenames: ["ld", "yacc"], exec: "clang")
        let core = try await getCore()
        let workspaceContext = try WorkspaceContext(core: core, workspace: TestWorkspace("test", projects: []).load(core), processExecutionCache: .sharedForTesting)
        let parser = GenericOutputParser(for: task, workspaceContext: workspaceContext, buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext), delegate: delegate, progressReporter: nil)
        parser.write(bytes: "foo bar\n")
        parser.write(bytes: "error: is an error\n")
        parser.write(bytes: "    error: is another error\n")
        parser.write(bytes: "NOT error: is not an error\n")
        parser.write(bytes: "file: error: an error, no line\n")
        parser.write(bytes: "file:1: error: an error, with line\n")
        parser.write(bytes: "file:1:1: error: an error, with line & col\n")
        parser.write(bytes: "file:12:13: error: an error with 2 fixits\n")
        parser.write(bytes: "file:12:13-14:15: fixit: fixit \\\"#1\\u0022 text\n")
        parser.write(bytes: "file:16:17-18:19: fixit: fixit \\f#2 text\n")
        parser.write(bytes: "file: warning: a warning\n")
        parser.write(bytes: "file: note: a note\n")
        parser.write(bytes: "file: note: a different note\n")
        parser.write(bytes: "../file: error: an error, no line\n")
        parser.write(bytes: "../file:1: error: an error, with line\n")
        parser.write(bytes: "../file:1:1: error: an error, with line & col\n")
        parser.write(bytes: "../file:12:13: error: an error with 2 fixits\n")
        parser.write(bytes: "../file:12:13-14:15: fixit: fixit \\\"#1\\u0022 text\n")
        parser.write(bytes: "../file:16:17-18:19: fixit: fixit \\f#2 text\n")
        parser.write(bytes: "../file: warning: a warning\n")
        parser.write(bytes: "../file: note: a note\n")
        parser.write(bytes: "../file: note: a different note\n")
        parser.write(bytes: "ld: warning: linker can have warnings\n")
        parser.write(bytes: "ld: linker doesn't like you\n")
        parser.write(bytes: "/tmp/foo:/bar:/ld: linker with colons\n")
        parser.write(bytes: "yacc: yacc doesn't like you either\n")
        parser.write(bytes: "swiftc: swiftc shouldn't be an error\n")
        parser.write(bytes: "/tmp/clang: clang is angry\n")
        parser.write(bytes: "yacc : shouldn't match\n")
        parser.write(bytes: "snazzle.ypp:30.15-17: warning: symbol INT redeclared\n")
        parser.write(bytes: "snazzle.ypp:31.15-19: error: symbol FLOAT redeclared\n")
        parser.write(bytes: "snazzle.ypp:32.15-20: note: symbol STRING redeclared\n")
        parser.write(bytes: "\n")
        parser.write(bytes: " \n")
        parser.write(bytes: ":\n")
        parser.write(bytes: "a:\n")
        parser.write(bytes: "exprs.c:45:15:{45:8-45:14}{45:17-45:24}: error: invalid foobar...\n")
        parser.close(result: nil)

        DiagnosticsEngineTester(delegate.diagnosticsEngine) { result in
            result.check(diagnostic: "is an error", behavior: .error)
            result.check(diagnostic: "is another error", behavior: .error)
            result.check(diagnostic: "an error, no line", behavior: .error, location: "/taskdir/file")
            result.check(diagnostic: "an error, with line", behavior: .error, location: "/taskdir/file:1")
            result.check(diagnostic: "an error, with line & col", behavior: .error, location: "/taskdir/file:1:1")
            result.check(diagnostic: "an error with 2 fixits", behavior: .error, location: "/taskdir/file:12:13", fixItStrings: ["/taskdir/file:12:13-14:15: fixit: fixit \u{22}#1\u{22} text", "/taskdir/file:16:17-18:19: fixit: fixit \u{0c}#2 text"])
            result.check(diagnostic: "a warning", behavior: .warning, location: "/taskdir/file")
            result.check(diagnostic: "a note", behavior: .note, location: "/taskdir/file")
            result.check(diagnostic: "a different note", behavior: .note, location: "/taskdir/file")
            result.check(diagnostic: "an error, no line", behavior: .error, location: "/file")
            result.check(diagnostic: "an error, with line", behavior: .error, location: "/file:1")
            result.check(diagnostic: "an error, with line & col", behavior: .error, location: "/file:1:1")
            result.check(diagnostic: "an error with 2 fixits", behavior: .error, location: "/file:12:13", fixItStrings: ["/file:12:13-14:15: fixit: fixit \u{22}#1\u{22} text", "/file:16:17-18:19: fixit: fixit \u{0c}#2 text"])
            result.check(diagnostic: "a warning", behavior: .warning, location: "/file")
            result.check(diagnostic: "a note", behavior: .note, location: "/file")
            result.check(diagnostic: "a different note", behavior: .note, location: "/file")
            result.check(diagnostic: "linker can have warnings", behavior: .warning)
            result.check(diagnostic: "linker doesn't like you", behavior: .note)
            result.check(diagnostic: "linker with colons", behavior: .note)
            result.check(diagnostic: "yacc doesn't like you either", behavior: .note)
            result.check(diagnostic: "clang is angry", behavior: .note)
            result.check(diagnostic: "symbol INT redeclared", behavior: .warning)
            result.check(diagnostic: "symbol FLOAT redeclared", behavior: .error)
            result.check(diagnostic: "symbol STRING redeclared", behavior: .note)
            result.check(diagnostic: "invalid foobar...", behavior: .error)
        }
    }

    @Test(.skipHostOS(.windows, "output parsing needs some work"))
    func shellScriptOutputParser() async throws {
        let delegate = CapturingTaskParserDelegate()
        let task = OutputParserMockTask(basenames: ["ld", "yacc"], exec: "clang")
        let core = try await getCore()
        let workspaceContext = try WorkspaceContext(core: core, workspace: TestWorkspace("test", projects: []).load(core), processExecutionCache: .sharedForTesting)
        let parser = ShellScriptOutputParser(for: task, workspaceContext: workspaceContext, buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext), delegate: delegate, progressReporter: nil)
        parser.write(bytes: "make foo\n")
        parser.write(bytes: "Compile foo.c\n")
        parser.write(bytes: "file:1:1: warning: a warning with line and column numbers\n")
        parser.write(bytes: "../file:1:1: warning: a warning with line and column numbers\n")
        parser.write(bytes: "\n")
        parser.write(bytes: "Link bar\n")
        parser.write(bytes: "ld: warning: linker can have warnings\n")
        parser.write(bytes: "ld: linker doesn't like you\n")
        parser.write(bytes: "   some other kind of text\n")
        parser.write(bytes: ".\n")
        parser.close(result: nil)

        DiagnosticsEngineTester(delegate.diagnosticsEngine) { result in
            result.check(diagnostic: "make foo", behavior: .note)
            result.check(diagnostic: "Compile foo.c", behavior: .note)
            result.check(diagnostic: "a warning with line and column numbers", behavior: .warning, location: "/taskdir/file:1:1")
            result.check(diagnostic: "", behavior: .note)
            result.check(diagnostic: "Link bar", behavior: .note)
            result.check(diagnostic: "a warning with line and column numbers", behavior: .warning, location: "/file:1:1")
            result.check(diagnostic: "linker can have warnings", behavior: .warning)
            result.check(diagnostic: "   some other kind of text", behavior: .note)
            result.check(diagnostic: ".", behavior: .note)
            result.check(diagnostic: "linker doesn't like you", behavior: .note)
        }
    }

    @Test
    func ldLinkerOutputParser() async throws {
        let delegate = CapturingTaskParserDelegate()
        let task = OutputParserMockTask(basenames: ["ld"], exec: "clang")
        let core = try await getCore()
        let workspaceContext = try WorkspaceContext(core: core, workspace: TestWorkspace("test", projects: []).load(core), processExecutionCache: .sharedForTesting)
        let parser = LdLinkerOutputParser(for: task, workspaceContext: workspaceContext, buildRequestContext: BuildRequestContext(workspaceContext: workspaceContext), delegate: delegate, progressReporter: nil)
        parser.write(bytes: "ld: ṣómething bad happened\n")  // tests proper capitalization
        parser.write(bytes: "ld: warning: heed my warning, Hapless Traveller\n")  // tests proper capitalization
        parser.write(bytes: "Undefined symbols for architecture z80:\n")
        parser.write(bytes: "  \"_println\", referenced from:\n")
        parser.write(bytes: "      _main in main.o\n")
        parser.write(bytes: "  \"_scanln\", referenced from:\n")
        parser.write(bytes: "      _func1 in file1.o\n")
        parser.write(bytes: "      _func2 in file2.o\n")
        parser.write(bytes: "      _func3 in file3.o\n")
        parser.write(bytes: "  \"_missing\", referenced from:\n")
        parser.write(bytes: "     -u command line option\n")
        parser.write(bytes: "      ...\n")
        parser.write(bytes: "ld: symbol(s) not found for architecture z80\n")
        parser.write(bytes: "clang: error: linker command failed with exit code 1 (use -v to see invocation)\n")
        parser.close(result: nil)

        DiagnosticsEngineTester(delegate.diagnosticsEngine) { result in
            result.check(diagnostic: "Ṣómething bad happened", behavior: .error)
            result.check(diagnostic: "Heed my warning, Hapless Traveller", behavior: .warning)
            result.check(diagnostic: "Undefined symbol: _println", behavior: .error)
            result.check(diagnostic: "Undefined symbol: _scanln", behavior: .error)
            result.check(diagnostic: "Undefined symbol: _missing", behavior: .error)
            result.check(diagnostic: "Linker command failed with exit code 1 (use -v to see invocation)", behavior: .error)
        }
    }

    @Test(.requireHostOS(.macOS))
    func swiftTaskConstruction() async throws {
        let core = try await getCore()
        let swiftSpec = try core.specRegistry.getSpec() as SwiftCompilerSpec
        let headerSpec = try core.specRegistry.getSpec("com.apple.build-tools.swift-header-tool") as SwiftHeaderToolSpec

        let swiftCompilerPath = try await self.swiftCompilerPath

        // Create the mock table.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(BuiltinMacros.SWIFT_EXEC, literal: swiftCompilerPath.str)
        try await table.push(BuiltinMacros.TAPI_EXEC, literal: self.tapiToolPath.str)
        table.push(BuiltinMacros.COMPILER_WORKING_DIRECTORY, literal: Path.root.join("tmp/src").str)
        table.push(BuiltinMacros.TARGET_NAME, literal: "App1")
        let targetName = core.specRegistry.internalMacroNamespace.parseString("$(TARGET_NAME)")
        table.push(BuiltinMacros.SWIFT_MODULE_NAME, targetName)
        table.push(BuiltinMacros.PRODUCT_TYPE, literal: "com.apple.product-type.application")
        table.push(BuiltinMacros.CURRENT_ARCH, literal: "x86_64")
        table.push(BuiltinMacros.ARCHS, literal: ["x86_64"])
        table.push(BuiltinMacros.CURRENT_VARIANT, literal: "normal")
        table.push(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, literal: "macos")
        table.push(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME, literal: "MACOSX_DEPLOYMENT_TARGET")
        table.push(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET, literal: "10.11")
        table.push(BuiltinMacros.SWIFT_DEPLOYMENT_TARGET, core.specRegistry.internalMacroNamespace.parseString("$($(DEPLOYMENT_TARGET_SETTING_NAME))"))
        table.push(BuiltinMacros.SWIFT_TARGET_TRIPLE, core.specRegistry.internalMacroNamespace.parseString("$(CURRENT_ARCH)-apple-$(SWIFT_PLATFORM_TARGET_PREFIX)$(SWIFT_DEPLOYMENT_TARGET)$(LLVM_TARGET_TRIPLE_SUFFIX)"))
        table.push(BuiltinMacros.OBJECT_FILE_DIR, literal: Path.root.join("tmp/output/obj").str)
        table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, BuiltinMacros.namespace.parseString(Path.root.join("tmp/output/obj-normal/x86_64").str))
        table.push(BuiltinMacros.PER_ARCH_MODULE_FILE_DIR, BuiltinMacros.namespace.parseString(Path.root.join("tmp/output/obj-normal/x86_64").str))
        table.push(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS, literal: true)
        table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: Path.root.join("tmp/output/sym").str)
        let builtProductsDirList = core.specRegistry.internalMacroNamespace.parseStringList("$(BUILT_PRODUCTS_DIR)")
        table.push(BuiltinMacros.FRAMEWORK_SEARCH_PATHS, builtProductsDirList)
        table.push(BuiltinMacros.PRODUCT_TYPE, literal: "com.apple.product-type.framework")
        table.push(BuiltinMacros.PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS, literal: ["ProductTypeFwkPath"])
        table.push(BuiltinMacros.DERIVED_FILE_DIR, literal: Path.root.join("tmp/output/obj/DerivedFiles").str)
        table.push(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME, literal: "App1-Swift.h")
        table.push(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER, literal: true)
        table.push(BuiltinMacros.SWIFT_RESPONSE_FILE_PATH,  core.specRegistry.internalMacroNamespace.parseString("$(PER_ARCH_OBJECT_FILE_DIR)/$(TARGET_NAME).SwiftFileList"))
        table.push(BuiltinMacros.SWIFT_INSTALL_MODULE, literal: true)
        table.push(BuiltinMacros.SWIFT_INSTALL_MODULE_FOR_DEPLOYMENT, literal: true)
        table.push(BuiltinMacros.SWIFT_ENABLE_EMIT_CONST_VALUES, literal: true)
        table.push(BuiltinMacros.SWIFT_INSTALL_MODULE_ABI_DESCRIPTOR, literal: true)

        // remove in rdar://53000820
        table.push(BuiltinMacros.USE_SWIFT_RESPONSE_FILE, literal: true)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
        let inputFiles = [FileToBuild(absolutePath: Path.root.join("tmp/one.swift"), fileType: mockFileType), FileToBuild(absolutePath: Path.root.join("tmp/two.swift"), fileType: mockFileType)]
        let archSpec = try core.specRegistry.getSpec("x86_64", domain: "macosx") as ArchitectureSpec
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: inputFiles, currentArchSpec: archSpec, output: nil)
        await swiftSpec.constructTasks(cbc, delegate)
        headerSpec.constructSwiftHeaderToolTask(cbc, delegate, inputs: delegate.generatedSwiftObjectiveCHeaderFiles(), outputPath: Path("App1-Swift.h"))

        #expect(delegate.shellTasks.count == 8)

        // The Swift response file should be constructed
        do {
            let task = try #require(delegate.shellTasks[safe: 0])
            #expect(task.ruleInfo == ["WriteAuxiliaryFile", "/tmp/output/obj-normal/x86_64/App1.SwiftFileList"])
            #expect(task.execDescription == "Write App1.SwiftFileList (x86_64)")
        }

        // We should construct the output file map.
        do {
            let task = try #require(delegate.shellTasks[safe: 1])
            #expect(task.ruleInfo == ["WriteAuxiliaryFile", "/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json"])
            #expect(task.execDescription == "Write App1-OutputFileMap.json (x86_64)")
        }

        // Check the compile task.
        do {
            let task = try #require(delegate.shellTasks[safe: 2])
            #expect(task.ruleInfo == ["CompileSwiftSources", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
            #expect(task.execDescription == "Compile Swift source files (x86_64)")

            var additionalCommandLineArgs = [String]()
            if let swiftABIVersion = await (swiftSpec.discoveredCommandLineToolSpecInfo(producer, mockScope, delegate) as? DiscoveredSwiftCompilerToolSpecInfo)?.swiftABIVersion {
                additionalCommandLineArgs += ["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift-\(swiftABIVersion)"]
            }
            else {
                additionalCommandLineArgs += ["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"]
            }

            // FIXME: Temporary paper over expected output change.
            if task.commandLine.contains("-disable-bridging-pch") {
                task.checkCommandLine([swiftCompilerPath.str, "-disable-bridging-pch", "-module-name", "App1", "-Xfrontend", "-disable-all-autolinking", "@/tmp/output/obj-normal/x86_64/App1.SwiftFileList", "-target", "x86_64-apple-macos10.11", "-Xfrontend", "-no-serialize-debugging-options", "-F", "/tmp/output/sym", "-F", "ProductTypeFwkPath", "-c", "-j\(SwiftCompilerSpec.parallelismLevel)", "-disable-batch-mode", "-output-file-map", "/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json", "-parseable-output", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "/tmp/output/obj-normal/x86_64/App1.swiftmodule", "-Xcc", "-Iswift-overrides.hmap", "-Xcc", "-I/tmp/output/obj/DerivedFiles-normal/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles", "-emit-objc-header", "-emit-objc-header-path", "/tmp/output/obj-normal/x86_64/App1-Swift.h", "-working-directory", "/tmp/src"])
            } else {
                task.checkCommandLine([swiftCompilerPath.str, "-module-name", "App1", "@/tmp/output/obj-normal/x86_64/App1.SwiftFileList", "-target", "x86_64-apple-macos10.11", "-F", "/tmp/output/sym", "-F", "ProductTypeFwkPath", "-c", "-j\(SwiftCompilerSpec.parallelismLevel)", "-output-file-map", "/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json", "-parseable-output", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "/tmp/output/obj-normal/x86_64/App1.swiftmodule", "-Xcc", "-Iswift-overrides.hmap", "-Xcc", "-I/tmp/output/obj/DerivedFiles/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles", "-emit-objc-header", "-emit-objc-header-path", "/tmp/output/obj-normal/x86_64/App1-Swift.h", "-working-directory", "/tmp/src"] + additionalCommandLineArgs)
            }
            task.checkInputs([
                .path("/tmp/one.swift"),
                .path("/tmp/two.swift"),
                .path("/tmp/output/obj-normal/x86_64/App1.SwiftFileList"),
                .path("/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json")
            ])
            task.checkOutputs([
                .path("/tmp/output/obj-normal/x86_64/one.o"),
                .path("/tmp/output/obj-normal/x86_64/two.o"),
                .path("/tmp/output/obj-normal/x86_64/one.swiftconstvalues"),
                .path("/tmp/output/obj-normal/x86_64/two.swiftconstvalues"),
                .path("/tmp/output/obj-normal/x86_64/App1.swiftmodule"),
                .path("/tmp/output/obj-normal/x86_64/App1.swiftsourceinfo"),
                .path("/tmp/output/obj-normal/x86_64/App1.abi.json"),
                .path("/tmp/output/obj-normal/x86_64/App1-Swift.h"),
                .path("/tmp/output/obj-normal/x86_64/App1.swiftdoc")
            ])
        }

        // We should have copy commands to move the arch-specific outputs.
        do {
            let task = try #require(delegate.shellTasks[safe: 3])
            #expect(task.ruleInfo == ["Copy", "App1.swiftmodule/x86_64-apple-macos.swiftmodule", "/tmp/output/obj-normal/x86_64/App1.swiftmodule"])
            #expect(task.execDescription == "Copy App1.swiftmodule (x86_64)")
        }
        do {
            let task = try #require(delegate.shellTasks[safe: 4])
            #expect(task.ruleInfo == ["Copy", "App1.swiftmodule/x86_64-apple-macos.abi.json", "/tmp/output/obj-normal/x86_64/App1.abi.json"])
            #expect(task.execDescription == "Copy App1.abi.json (x86_64)")
        }
        do {
            let task = try #require(delegate.shellTasks[safe: 5])
            #expect(task.ruleInfo == ["Copy", "App1.swiftmodule/Project/x86_64-apple-macos.swiftsourceinfo", "/tmp/output/obj-normal/x86_64/App1.swiftsourceinfo"])
            #expect(task.execDescription == "Copy App1.swiftsourceinfo (x86_64)")
        }
        do {
            let task = try #require(delegate.shellTasks[safe: 6])
            #expect(task.ruleInfo == ["Copy", "App1.swiftmodule/x86_64-apple-macos.swiftdoc", "/tmp/output/obj-normal/x86_64/App1.swiftdoc"])
            #expect(task.execDescription == "Copy App1.swiftdoc (x86_64)")
        }
        do {
            let task = try #require(delegate.shellTasks[safe: 7])
            #expect(task.ruleInfo == ["SwiftMergeGeneratedHeaders", "App1-Swift.h", "/tmp/output/obj-normal/x86_64/App1-Swift.h"])
            #expect(task.execDescription == "Merge Objective-C generated interface headers")
        }

        // Check that we put the generated header in the right place, if not installing it.
        do {
            table.push(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER, literal: false)
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
            let inputFiles = [FileToBuild(absolutePath: Path.root.join("tmp/one.swift"), fileType: mockFileType), FileToBuild(absolutePath: Path.root.join("tmp/two.swift"), fileType: mockFileType)]
            let archSpec = try core.specRegistry.getSpec("x86_64", domain: "macosx") as ArchitectureSpec
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: inputFiles, currentArchSpec: archSpec, output: nil)
            await swiftSpec.constructTasks(cbc, delegate)
            headerSpec.constructSwiftHeaderToolTask(cbc, delegate, inputs: delegate.generatedSwiftObjectiveCHeaderFiles(), outputPath: Path.root.join("tmp/output/obj/DerivedFiles/App1-Swift.h"))
            do {
                let task = try #require(delegate.shellTasks[safe: 7])
                #expect(task.ruleInfo == ["SwiftMergeGeneratedHeaders", "/tmp/output/obj/DerivedFiles/App1-Swift.h", "/tmp/output/obj-normal/x86_64/App1-Swift.h"])
            }
        }
    }

    @Test(.requireHostOS(.macOS), .requireLLBuild(apiVersion: 12))
    func swiftTaskConstruction_integratedDriver() async throws {
        let core = try await getCore()
        let swiftSpec = try core.specRegistry.getSpec() as SwiftCompilerSpec
        let headerSpec = try core.specRegistry.getSpec("com.apple.build-tools.swift-header-tool") as SwiftHeaderToolSpec

        let swiftCompilerPath = try await self.swiftCompilerPath

        // Create the mock table.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(BuiltinMacros.SWIFT_EXEC, literal: swiftCompilerPath.str)
        try await table.push(BuiltinMacros.TAPI_EXEC, literal: self.tapiToolPath.str)
        table.push(BuiltinMacros.COMPILER_WORKING_DIRECTORY, literal: "/tmp/src")
        table.push(BuiltinMacros.TARGET_NAME, literal: "App1")
        let targetName = core.specRegistry.internalMacroNamespace.parseString("$(TARGET_NAME)")
        table.push(BuiltinMacros.PRODUCT_NAME, targetName)
        table.push(BuiltinMacros.SWIFT_MODULE_NAME, targetName)
        table.push(BuiltinMacros.PRODUCT_TYPE, literal: "com.apple.product-type.application")
        table.push(BuiltinMacros.CURRENT_ARCH, literal: "x86_64")
        table.push(BuiltinMacros.ARCHS, literal: ["x86_64"])
        table.push(BuiltinMacros.CURRENT_VARIANT, literal: "normal")
        table.push(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, literal: "macos")
        table.push(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME, literal: "MACOSX_DEPLOYMENT_TARGET")
        table.push(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET, literal: "10.11")
        table.push(BuiltinMacros.SWIFT_DEPLOYMENT_TARGET, core.specRegistry.internalMacroNamespace.parseString("$($(DEPLOYMENT_TARGET_SETTING_NAME))"))
        table.push(BuiltinMacros.SWIFT_TARGET_TRIPLE, core.specRegistry.internalMacroNamespace.parseString("$(CURRENT_ARCH)-apple-$(SWIFT_PLATFORM_TARGET_PREFIX)$(SWIFT_DEPLOYMENT_TARGET)$(LLVM_TARGET_TRIPLE_SUFFIX)"))
        table.push(BuiltinMacros.OBJECT_FILE_DIR, literal: "/tmp/output/obj")
        table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, BuiltinMacros.namespace.parseString("/tmp/output/obj-normal/x86_64"))
        table.push(BuiltinMacros.PER_ARCH_MODULE_FILE_DIR, BuiltinMacros.namespace.parseString("/tmp/output/obj-normal/x86_64"))
        table.push(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS, literal: true)
        table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: "/tmp/output/sym")
        let builtProductsDirList = core.specRegistry.internalMacroNamespace.parseStringList("$(BUILT_PRODUCTS_DIR)")
        table.push(BuiltinMacros.FRAMEWORK_SEARCH_PATHS, builtProductsDirList)
        table.push(BuiltinMacros.PRODUCT_TYPE, literal: "com.apple.product-type.framework")
        table.push(BuiltinMacros.PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS, literal: ["ProductTypeFwkPath"])
        table.push(BuiltinMacros.DERIVED_FILE_DIR, literal: "/tmp/output/obj/DerivedFiles")
        table.push(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME, literal: "App1-Swift.h")
        table.push(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER, literal: true)
        table.push(BuiltinMacros.SWIFT_RESPONSE_FILE_PATH,  core.specRegistry.internalMacroNamespace.parseString("$(PER_ARCH_OBJECT_FILE_DIR)/$(TARGET_NAME).SwiftFileList"))
        table.push(BuiltinMacros.SWIFT_INSTALL_MODULE, literal: true)
        table.push(BuiltinMacros.SWIFT_INSTALL_MODULE_FOR_DEPLOYMENT, literal: true)
        table.push(BuiltinMacros.SWIFT_USE_INTEGRATED_DRIVER, literal: true)
        table.push(BuiltinMacros.SWIFT_ENABLE_EMIT_CONST_VALUES, literal: true)
        table.push(BuiltinMacros.SWIFT_INSTALL_MODULE_ABI_DESCRIPTOR, literal: true)

        // remove in rdar://53000820
        table.push(BuiltinMacros.USE_SWIFT_RESPONSE_FILE, literal: true)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
        let inputFiles = [FileToBuild(absolutePath: Path.root.join("tmp/one.swift"), fileType: mockFileType), FileToBuild(absolutePath: Path.root.join("tmp/two.swift"), fileType: mockFileType)]
        let archSpec = try core.specRegistry.getSpec("x86_64", domain: "macosx") as ArchitectureSpec
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: inputFiles, currentArchSpec: archSpec, output: nil)
        await swiftSpec.constructTasks(cbc, delegate)
        headerSpec.constructSwiftHeaderToolTask(cbc, delegate, inputs: delegate.generatedSwiftObjectiveCHeaderFiles(), outputPath: Path("App1-Swift.h"))

        #expect(delegate.shellTasks.count == 9)

        // The Swift response file should be constructed
        do {
            let task = try #require(delegate.shellTasks[safe: 0])
            #expect(task.ruleInfo == ["WriteAuxiliaryFile", "/tmp/output/obj-normal/x86_64/App1.SwiftFileList"])
            #expect(task.execDescription == "Write App1.SwiftFileList (x86_64)")
        }

        // We should construct the output file map.
        do {
            let task = try #require(delegate.shellTasks[safe: 1])
            #expect(task.ruleInfo == ["WriteAuxiliaryFile", "/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json"])
            #expect(task.execDescription == "Write App1-OutputFileMap.json (x86_64)")
        }

        // Check the compilation requirements
        do {
            let task = try #require(delegate.shellTasks[safe: 2])
            #expect(task.ruleInfo == ["SwiftDriver Compilation Requirements", "App1", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
            #expect(task.execDescription == "Unblock downstream dependents of App1 (x86_64)")

            var additionalCommandLineArgs = [String]()
            if let swiftABIVersion = await (swiftSpec.discoveredCommandLineToolSpecInfo(producer, mockScope, delegate) as? DiscoveredSwiftCompilerToolSpecInfo)?.swiftABIVersion {
                additionalCommandLineArgs += ["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift-\(swiftABIVersion)"]
            }
            else {
                additionalCommandLineArgs += ["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"]
            }

            task.checkCommandLine(["builtin-Swift-Compilation-Requirements", "--", swiftCompilerPath.str, "-disable-bridging-pch", "-module-name", "App1", "-Xfrontend", "-disable-all-autolinking", "@/tmp/output/obj-normal/x86_64/App1.SwiftFileList", "-target", "x86_64-apple-macos10.11", "-Xfrontend", "-no-serialize-debugging-options", "-F", "/tmp/output/sym", "-F", "ProductTypeFwkPath", "-c", "-j\(SwiftCompilerSpec.parallelismLevel)", "-disable-batch-mode", "-output-file-map", "/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json", "-use-frontend-parseable-output", "-save-temps", "-no-color-diagnostics", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "/tmp/output/obj-normal/x86_64/App1.swiftmodule", "-Xcc", "-Iswift-overrides.hmap", "-Xcc", "-I/tmp/output/obj/DerivedFiles-normal/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles", "-emit-objc-header", "-emit-objc-header-path", "/tmp/output/obj-normal/x86_64/App1-Swift.h", "-working-directory", "/tmp/src", "-experimental-emit-module-separately", "-disable-cmo"])

            task.checkInputs([
                .path("/tmp/one.swift"),
                .path("/tmp/two.swift"),
                .path("/tmp/output/obj-normal/x86_64/App1.SwiftFileList"),
                .path("/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json"),
            ])
            task.checkOutputs([
                .path("/tmp/output/obj-normal/x86_64/App1 Swift Compilation Requirements Finished"),
                .path("/tmp/output/obj-normal/x86_64/App1.swiftmodule"),
                .path("/tmp/output/obj-normal/x86_64/App1.swiftsourceinfo"),
                .path("/tmp/output/obj-normal/x86_64/App1.abi.json"),
                .path("/tmp/output/obj-normal/x86_64/App1-Swift.h"),
                .path("/tmp/output/obj-normal/x86_64/App1.swiftdoc")
            ])
        }

        // Check the compilation
        do {
            let task = delegate.shellTasks[3]
            #expect(task.ruleInfo == ["SwiftDriver Compilation", "App1", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
            #expect(task.execDescription == "Compile App1 (x86_64)")

            var additionalCommandLineArgs = [String]()
            if let swiftABIVersion = await (swiftSpec.discoveredCommandLineToolSpecInfo(producer, mockScope, delegate) as? DiscoveredSwiftCompilerToolSpecInfo)?.swiftABIVersion {
                additionalCommandLineArgs += ["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift-\(swiftABIVersion)"]
            }
            else {
                additionalCommandLineArgs += ["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"]
            }

            task.checkCommandLine(["builtin-Swift-Compilation", "--", swiftCompilerPath.str, "-disable-bridging-pch", "-module-name", "App1", "-Xfrontend", "-disable-all-autolinking", "@/tmp/output/obj-normal/x86_64/App1.SwiftFileList", "-target", "x86_64-apple-macos10.11", "-Xfrontend", "-no-serialize-debugging-options", "-F", "/tmp/output/sym", "-F", "ProductTypeFwkPath", "-c", "-j\(SwiftCompilerSpec.parallelismLevel)", "-disable-batch-mode", "-output-file-map", "/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json", "-use-frontend-parseable-output", "-save-temps", "-no-color-diagnostics", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "/tmp/output/obj-normal/x86_64/App1.swiftmodule", "-Xcc", "-Iswift-overrides.hmap", "-Xcc", "-I/tmp/output/obj/DerivedFiles-normal/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles", "-emit-objc-header", "-emit-objc-header-path", "/tmp/output/obj-normal/x86_64/App1-Swift.h", "-working-directory", "/tmp/src", "-experimental-emit-module-separately", "-disable-cmo"])

            task.checkInputs([
                .path("/tmp/one.swift"),
                .path("/tmp/two.swift"),
                .path("/tmp/output/obj-normal/x86_64/App1.SwiftFileList"),
                .path("/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json"),
            ])
            task.checkOutputs([
                .path("/tmp/output/obj-normal/x86_64/App1 Swift Compilation Finished"),
                .path("/tmp/output/obj-normal/x86_64/one.o"),
                .path("/tmp/output/obj-normal/x86_64/two.o"),
                .path("/tmp/output/obj-normal/x86_64/one.swiftconstvalues"),
                .path("/tmp/output/obj-normal/x86_64/two.swiftconstvalues"),
            ])
        }

        // We should have copy commands to move the arch-specific outputs.
        do {
            let task = try #require(delegate.shellTasks[safe: 4])
            #expect(task.ruleInfo == ["Copy", "App1.swiftmodule/x86_64-apple-macos.swiftmodule", "/tmp/output/obj-normal/x86_64/App1.swiftmodule"])
            #expect(task.execDescription == "Copy App1.swiftmodule (x86_64)")
        }
        do {
            let task = try #require(delegate.shellTasks[safe: 5])
            #expect(task.ruleInfo == ["Copy", "App1.swiftmodule/x86_64-apple-macos.abi.json", "/tmp/output/obj-normal/x86_64/App1.abi.json"])
            #expect(task.execDescription == "Copy App1.abi.json (x86_64)")
        }
        do {
            let task = try #require(delegate.shellTasks[safe: 6])
            #expect(task.ruleInfo == ["Copy", "App1.swiftmodule/Project/x86_64-apple-macos.swiftsourceinfo", "/tmp/output/obj-normal/x86_64/App1.swiftsourceinfo"])
            #expect(task.execDescription == "Copy App1.swiftsourceinfo (x86_64)")
        }
        do {
            let task = try #require(delegate.shellTasks[safe: 7])
            #expect(task.ruleInfo == ["Copy", "App1.swiftmodule/x86_64-apple-macos.swiftdoc", "/tmp/output/obj-normal/x86_64/App1.swiftdoc"])
            #expect(task.execDescription == "Copy App1.swiftdoc (x86_64)")
        }
        do {
            let task = try #require(delegate.shellTasks[safe: 8])
            #expect(task.ruleInfo == ["SwiftMergeGeneratedHeaders", "App1-Swift.h", "/tmp/output/obj-normal/x86_64/App1-Swift.h"])
            #expect(task.execDescription == "Merge Objective-C generated interface headers")
        }

        // Check that we put the generated header in the right place, if not installing it.
        do {
            table.push(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER, literal: false)
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
            let inputFiles = [FileToBuild(absolutePath: Path.root.join("tmp/one.swift"), fileType: mockFileType), FileToBuild(absolutePath: Path.root.join("tmp/two.swift"), fileType: mockFileType)]
            let archSpec = try core.specRegistry.getSpec("x86_64", domain: "macosx") as ArchitectureSpec
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: inputFiles, currentArchSpec: archSpec, output: nil)
            await swiftSpec.constructTasks(cbc, delegate)
            headerSpec.constructSwiftHeaderToolTask(cbc, delegate, inputs: delegate.generatedSwiftObjectiveCHeaderFiles(), outputPath: Path.root.join("tmp/output/obj/DerivedFiles/App1-Swift.h"))
            do {
                let task = try #require(delegate.shellTasks[safe: 8])
                #expect(task.ruleInfo == ["SwiftMergeGeneratedHeaders", "/tmp/output/obj/DerivedFiles/App1-Swift.h", "/tmp/output/obj-normal/x86_64/App1-Swift.h"])
            }
        }
    }

    // remove in rdar://53000820
    @Test(.requireSDKs(.macOS))
    func swiftTaskConstructionWithoutResponseFile() async throws {
        let core = try await getCore()
        let swiftSpec = try core.specRegistry.getSpec() as SwiftCompilerSpec
        let headerSpec = try core.specRegistry.getSpec("com.apple.build-tools.swift-header-tool") as SwiftHeaderToolSpec

        let swiftCompilerPath = try await self.swiftCompilerPath

        // Create the mock table.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(BuiltinMacros.SWIFT_EXEC, literal: swiftCompilerPath.str)
        try await table.push(BuiltinMacros.TAPI_EXEC, literal: self.tapiToolPath.str)
        table.push(BuiltinMacros.COMPILER_WORKING_DIRECTORY, literal: "/tmp/src")
        table.push(BuiltinMacros.TARGET_NAME, literal: "App1")
        let targetName = core.specRegistry.internalMacroNamespace.parseString("$(TARGET_NAME)")
        table.push(BuiltinMacros.SWIFT_MODULE_NAME, targetName)
        table.push(BuiltinMacros.PRODUCT_TYPE, literal: "com.apple.product-type.application")
        table.push(BuiltinMacros.CURRENT_ARCH, literal: "x86_64")
        table.push(BuiltinMacros.ARCHS, literal: ["x86_64"])
        table.push(BuiltinMacros.CURRENT_VARIANT, literal: "normal")
        table.push(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, literal: "macos")
        table.push(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME, literal: "MACOSX_DEPLOYMENT_TARGET")
        table.push(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET, literal: "10.11")
        table.push(BuiltinMacros.SWIFT_DEPLOYMENT_TARGET, core.specRegistry.internalMacroNamespace.parseString("$($(DEPLOYMENT_TARGET_SETTING_NAME))"))
        table.push(BuiltinMacros.SWIFT_TARGET_TRIPLE, core.specRegistry.internalMacroNamespace.parseString("$(CURRENT_ARCH)-apple-$(SWIFT_PLATFORM_TARGET_PREFIX)$(SWIFT_DEPLOYMENT_TARGET)$(LLVM_TARGET_TRIPLE_SUFFIX)"))
        table.push(BuiltinMacros.OBJECT_FILE_DIR, literal: "/tmp/output/obj")
        table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, BuiltinMacros.namespace.parseString("/tmp/output/obj-normal/x86_64"))
        table.push(BuiltinMacros.PER_ARCH_MODULE_FILE_DIR, BuiltinMacros.namespace.parseString("/tmp/output/obj-normal/x86_64"))
        table.push(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS, literal: true)
        table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: "/tmp/output/sym")
        let builtProductsDirList = core.specRegistry.internalMacroNamespace.parseStringList("$(BUILT_PRODUCTS_DIR)")
        table.push(BuiltinMacros.FRAMEWORK_SEARCH_PATHS, builtProductsDirList)
        table.push(BuiltinMacros.PRODUCT_TYPE, literal: "com.apple.product-type.framework")
        table.push(BuiltinMacros.PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS, literal: ["ProductTypeFwkPath"])
        table.push(BuiltinMacros.DERIVED_FILE_DIR, literal: "/tmp/output/obj/DerivedFiles")
        table.push(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME, literal: "App1-Swift.h")
        table.push(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER, literal: true)
        table.push(BuiltinMacros.USE_SWIFT_RESPONSE_FILE, literal: false)
        table.push(BuiltinMacros.SWIFT_INSTALL_MODULE, literal: true)
        table.push(BuiltinMacros.SWIFT_ENABLE_EMIT_CONST_VALUES, literal: true)
        table.push(BuiltinMacros.SWIFT_INSTALL_MODULE_ABI_DESCRIPTOR, literal: true)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
        let inputFiles = [FileToBuild(absolutePath: Path.root.join("tmp/one.swift"), fileType: mockFileType), FileToBuild(absolutePath: Path.root.join("tmp/two.swift"), fileType: mockFileType)]
        let archSpec = try core.specRegistry.getSpec("x86_64", domain: "macosx") as ArchitectureSpec
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: inputFiles, currentArchSpec: archSpec, output: nil)
        await swiftSpec.constructTasks(cbc, delegate)
        headerSpec.constructSwiftHeaderToolTask(cbc, delegate, inputs: delegate.generatedSwiftObjectiveCHeaderFiles(), outputPath: Path("App1-Swift.h"))

        #expect(delegate.shellTasks.count == 7)

        // Check the compile task.
        do {
            let task = try #require(delegate.shellTasks[safe: 1])
            #expect(task.ruleInfo == ["CompileSwiftSources", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
            #expect(task.execDescription == "Compile Swift source files (x86_64)")

            var additionalCommandLineArgs = [String]()
            if let swiftABIVersion = await (swiftSpec.discoveredCommandLineToolSpecInfo(producer, mockScope, delegate) as? DiscoveredSwiftCompilerToolSpecInfo)?.swiftABIVersion {
                additionalCommandLineArgs += ["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift-\(swiftABIVersion)"]
            }
            else {
                additionalCommandLineArgs += ["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"]
            }

            // FIXME: Temporary paper over expected output change.
            if task.commandLine.contains("-disable-bridging-pch") {
                task.checkCommandLine([swiftCompilerPath.str, "-disable-bridging-pch", "-module-name", "App1", "-Xfrontend", "-disable-all-autolinking", "-target", "x86_64-apple-macos10.11", "-Xfrontend", "-no-serialize-debugging-options", "-F", "/tmp/output/sym", "-F", "ProductTypeFwkPath", "-c", "-j\(SwiftCompilerSpec.parallelismLevel)", "-disable-batch-mode", "-output-file-map", "/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json", "-parseable-output", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "/tmp/output/obj-normal/x86_64/App1.swiftmodule", "-Xcc", "-Iswift-overrides.hmap", "-Xcc", "-I/tmp/output/obj/DerivedFiles-normal/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles", "-emit-objc-header", "-emit-objc-header-path", "/tmp/output/obj-normal/x86_64/App1-Swift.h", "-working-directory", "/tmp/src", "/tmp/one.swift", "/tmp/two.swift"])
            } else {
                task.checkCommandLine([swiftCompilerPath.str, "-module-name", "App1", "-target", "x86_64-apple-macos10.11", "-F", "/tmp/output/sym", "-F", "ProductTypeFwkPath", "-c", "-j\(SwiftCompilerSpec.parallelismLevel)", "-output-file-map", "/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json", "-parseable-output", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "/tmp/output/obj-normal/x86_64/App1.swiftmodule", "-Xcc", "-Iswift-overrides.hmap", "-Xcc", "-I/tmp/output/obj/DerivedFiles/x86_64", "-Xcc", "-I/tmp/output/obj/DerivedFiles", "-emit-objc-header", "-emit-objc-header-path", "/tmp/output/obj-normal/x86_64/App1-Swift.h", "-working-directory", "/tmp/src"] + additionalCommandLineArgs + ["/tmp/one.swift", "/tmp/two.swift"])
            }
            task.checkInputs([
                .path("/tmp/one.swift"),
                .path("/tmp/two.swift"),
                .path("/tmp/output/obj-normal/x86_64/App1-OutputFileMap.json")
            ])
            task.checkOutputs([
                .path("/tmp/output/obj-normal/x86_64/one.o"),
                .path("/tmp/output/obj-normal/x86_64/two.o"),
                .path("/tmp/output/obj-normal/x86_64/one.swiftconstvalues"),
                .path("/tmp/output/obj-normal/x86_64/two.swiftconstvalues"),
                .path("/tmp/output/obj-normal/x86_64/App1.swiftmodule"),
                .path("/tmp/output/obj-normal/x86_64/App1.swiftsourceinfo"),
                .path("/tmp/output/obj-normal/x86_64/App1.abi.json"),
                .path("/tmp/output/obj-normal/x86_64/App1-Swift.h"),
                .path("/tmp/output/obj-normal/x86_64/App1.swiftdoc")
            ])
        }
    }

    @Test(.skipHostOS(.windows, "tmp/not-mainone.swift not in command line"))
    func singleFileSwiftTaskConstruction() async throws {
        let core = try await getCore()
        let swiftSpec = try core.specRegistry.getSpec() as SwiftCompilerSpec

        // Create the mock table.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        try await table.push(BuiltinMacros.SWIFT_EXEC, literal: self.swiftCompilerPath.str)
        if core.hostOperatingSystem == .macOS {
            try await table.push(BuiltinMacros.TAPI_EXEC, literal: self.tapiToolPath.str)
        }
        table.push(BuiltinMacros.TARGET_NAME, literal: "App1")
        table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: Path.root.join("build").str)
        table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, literal: Path.root.join("build/objects").str)
        table.push(BuiltinMacros.SWIFT_MODULE_NAME, literal: "MyModule")
        table.push(BuiltinMacros.SWIFT_RESPONSE_FILE_PATH,  core.specRegistry.internalMacroNamespace.parseString("$(PER_ARCH_OBJECT_FILE_DIR)/$(TARGET_NAME).SwiftFileList"))

        // remove in rdar://53000820
        table.push(BuiltinMacros.USE_SWIFT_RESPONSE_FILE, literal: true)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
        let inputFiles = [FileToBuild(absolutePath: Path.root.join("tmp/not-mainone.swift"), fileType: mockFileType)]
        let archSpec = try core.specRegistry.getSpec("x86_64", domain: "macosx") as ArchitectureSpec
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: inputFiles, currentArchSpec: archSpec, output: nil)
        await swiftSpec.constructTasks(cbc, delegate)

        // Get the Swift task itself.
        let tasks = delegate.shellTasks.filter { $0.ruleInfo[0] == "CompileSwiftSources" }
        #expect(tasks.count == 1)
        let swiftTask = try #require(tasks.only)
        #expect(swiftTask.execDescription == "Compile Swift source files")
        // Verify we passed -parse-as-library
        #expect(swiftTask.commandLine.contains("-parse-as-library"), "\(swiftTask.commandLine)")
        #expect(swiftTask.commandLine.contains(where: { $0.asString.replacingOccurrences(of: "\\", with: "/") == "@" + Path.root.join("build/objects/App1.SwiftFileList").str }), "\(swiftTask.commandLine)")
        #expect(!swiftTask.commandLine.contains(.literal(ByteString(encodingAsUTF8: Path.root.join("tmp/not-mainone.swift").str))), "\(swiftTask.commandLine)")

        // Check that we created the Swift response file
        #expect(delegate.shellTasks.contains { $0.ruleInfo == ["WriteAuxiliaryFile", "/build/objects/App1.SwiftFileList"] })
    }

    @Test
    func stripTaskConstruction() async throws {
        let core = try await getCore()
        let stripSpec = try core.specRegistry.getSpec("com.apple.build-tools.strip") as CommandLineToolSpec

        // Create the mock table.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("STRIP_STYLE") as? EnumMacroDeclaration<StripStyle>), literal: .debugging)
        table.push(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("STRIPFLAGS") as? StringListMacroDeclaration), literal: ["-foo", "-bar"])

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input"), fileType: mockFileType)], output: Path.root.join("tmp/output"))
        await stripSpec.constructTasks(cbc, delegate)

        // There should be exactly one shell task.
        #expect(delegate.shellTasks.count == 1)
        let task = try #require(delegate.shellTasks[safe: 0])
        #expect(task.ruleInfo == ["Strip", Path.root.join("tmp/input").str])
        #expect(task.execDescription == "Strip input")
        // FIXME: We aren't handling the list type correctly yet.
        task.checkCommandLine(["strip", "-S", "-foo", "-bar", Path.root.join("tmp/input").str])
    }

    @Test(.requireSDKs(.macOS))
    func swiftStdlibTool() async throws {
        let core = try await getCore()
        let stdlibTool = try core.specRegistry.getSpec("com.apple.build-tools.swift-stdlib-tool") as SwiftStdLibToolSpec
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(BuiltinMacros.CODESIGN_ALLOCATE, literal: "/path/to/codesign_allocate")
        table.push(BuiltinMacros.WRAPPER_NAME, literal: "wrapper")

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.application", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input"), fileType: mockFileType)], output: nil)

        // Check that task construction sets the correct env bindings.
        await stdlibTool.constructSwiftStdLibraryToolTask(cbc, delegate, foldersToScan: nil, filterForSwiftOS: false, backDeploySwiftConcurrency: false)
        #expect(delegate.shellTasks.count == 1)
        let task = try #require(delegate.shellTasks[safe: 0])
        #expect(task.environment.bindingsDictionary == ["CODESIGN_ALLOCATE": "/path/to/codesign_allocate"])
        #expect(task.execDescription == "Copy Swift standard libraries into wrapper")
    }

    @Test
    func dsymutilTaskConstruction() async throws {
        let core = try await getCore()
        let dsymutilSpec = try core.specRegistry.getSpec("com.apple.tools.dsymutil") as DsymutilToolSpec

        do {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("DSYMUTIL_VERBOSE") as? BooleanMacroDeclaration), literal: false)
            table.push(BuiltinMacros.DWARF_DSYM_FOLDER_PATH, literal: Path.root.join("tmp").str)
            table.push(BuiltinMacros.DWARF_DSYM_FILE_NAME, literal: "output.dSYM")

            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input"), fileType: mockFileType)], output: Path.root.join("tmp/output"))
            await dsymutilSpec.constructTasks(cbc, delegate, dsymBundle: Path.root.join("tmp/output.dSYM"))

            // There should be exactly one shell task.
            #expect(delegate.shellTasks.count == 1)
            let task = try #require(delegate.shellTasks[safe: 0])
            #expect(task.ruleInfo == ["GenerateDSYMFile", Path.root.join("tmp/output.dSYM").str, Path.root.join("tmp/input").str])
            #expect(task.execDescription == "Generate output.dSYM for input")

            task.checkCommandLine(["dsymutil", Path.root.join("tmp/input").str, "-o", Path.root.join("tmp/output.dSYM").str])
            // FIXME: Check the inputs and outputs.
        }

        do {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("DSYMUTIL_VERBOSE") as? BooleanMacroDeclaration), literal: true)
            table.push(BuiltinMacros.DWARF_DSYM_FOLDER_PATH, literal: "/tmp")
            table.push(BuiltinMacros.DWARF_DSYM_FILE_NAME, literal: "output.dSYM")

            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input"), fileType: mockFileType)], output: Path.root.join("tmp/output"))
            await dsymutilSpec.constructTasks(cbc, delegate, dsymBundle: Path.root.join("tmp/output.dSYM"))

            // There should be exactly one shell task.
            #expect(delegate.shellTasks.count == 1)
            let task = try #require(delegate.shellTasks[safe: 0])
            #expect(task.ruleInfo == ["GenerateDSYMFile", Path.root.join("tmp/output.dSYM").str, Path.root.join("tmp/input").str])
            #expect(task.execDescription == "Generate output.dSYM for input")
            task.checkCommandLine(["dsymutil", "--verbose", Path.root.join("tmp/input").str, "-o", Path.root.join("tmp/output.dSYM").str])
            // FIXME: Check the inputs and outputs.
        }
    }

    @Test(.skipHostOS(.windows, "prefix.h header path is coming over as tmp\\tmp\\prefix.h"), .requireSDKs(.macOS))
    func clangCompileTaskConstruction() async throws {
        let core = try await getCore()
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CommandLineToolSpec

        // Create the mock table.  We include all the defaults for the tool specification.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        for option in clangSpec.flattenedOrderedBuildOptions {
            guard let value = option.defaultValue else { continue }
            table.push(option.macro, value)
        }
        // We also add some other settings that are more contextual in nature.
        table.push(BuiltinMacros.CURRENT_ARCH, literal: "x86_64")
        table.push(BuiltinMacros.arch, literal: "x86_64")
        table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_VENDOR, literal: "apple")
        table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_OS_VERSION, BuiltinMacros.namespace.parseString("$(SWIFT_PLATFORM_TARGET_PREFIX)$($(DEPLOYMENT_TARGET_SETTING_NAME))"))
        table.push(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, literal: "macos")
        table.push(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME, literal: "MACOSX_DEPLOYMENT_TARGET")
        table.push(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET, literal: "13.0")
        table.push(BuiltinMacros.CURRENT_VARIANT, literal: "normal")
        table.push(BuiltinMacros.PRODUCT_NAME, literal: "Product")
        table.push(BuiltinMacros.TEMP_DIR, literal: Path.root.join("tmp").str)
        table.push(BuiltinMacros.PROJECT_TEMP_DIR, literal: Path.root.join("tmp/ptmp").str)
        table.push(BuiltinMacros.OBJECT_FILE_DIR, literal: Path.root.join("tmp/output/obj").str)
        table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: Path.root.join("tmp/output/sym").str)
        table.push(BuiltinMacros.GCC_PREFIX_HEADER, literal: "prefix.h")
        table.push(BuiltinMacros.DERIVED_FILE_DIR, literal: Path.root.join("tmp/derived").str)
        table.push(try core.specRegistry.internalMacroNamespace.declareUserDefinedMacro("PER_ARCH_CFLAGS_i386"), core.specRegistry.internalMacroNamespace.parseLiteralStringList(["-DX86.32"]))
        table.push(try core.specRegistry.internalMacroNamespace.declareUserDefinedMacro("PER_ARCH_CFLAGS_x86_64"), core.specRegistry.internalMacroNamespace.parseLiteralStringList(["-DX86.64"]))
        table.push(BuiltinMacros.PER_ARCH_CFLAGS, BuiltinMacros.namespace.parseStringList("$(PER_ARCH_CFLAGS_$(CURRENT_ARCH)"))
        table.push(try core.specRegistry.internalMacroNamespace.declareUserDefinedMacro("OTHER_CFLAGS_normal"), core.specRegistry.internalMacroNamespace.parseLiteralStringList(["-DFrom_OTHER_CFLAGS_normal"]))
        table.push(try core.specRegistry.internalMacroNamespace.declareUserDefinedMacro("OTHER_CFLAGS_profile"), core.specRegistry.internalMacroNamespace.parseLiteralStringList(["-DFrom_OTHER_CFLAGS_profile"]))
        table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, BuiltinMacros.namespace.parseString("$(OBJECT_FILE_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)"))
        table.push(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS, literal: true)
        table.push(BuiltinMacros.PER_VARIANT_CFLAGS, BuiltinMacros.namespace.parseStringList("$(OTHER_CFLAGS_$(CURRENT_VARIANT)"))
        table.push(BuiltinMacros.USE_HEADERMAP, literal: true)
        table.push(BuiltinMacros.HEADERMAP_USES_VFS, literal: true)
        table.push(BuiltinMacros.CLANG_ENABLE_MODULES, literal: true)
        table.push(try core.specRegistry.internalMacroNamespace.declareStringListMacro("GLOBAL_CFLAGS"), literal: ["-DFrom_GLOBAL_CFLAGS"])
        table.push(BuiltinMacros.GCC_GENERATE_PROFILING_CODE, literal: true)
        table.push(BuiltinMacros.GCC_PREPROCESSOR_DEFINITIONS_NOT_USED_IN_PRECOMPS, literal: ["defn1", "defn2"])
        table.push(BuiltinMacros.GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS, literal: ["-DFrom_GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS"])
        table.push(BuiltinMacros.PRODUCT_TYPE_HEADER_SEARCH_PATHS, literal: [Path.root.join("tmp/product/type/specific/header/search/path").str])
        table.push(BuiltinMacros.PRODUCT_TYPE_FRAMEWORK_SEARCH_PATHS, literal: [Path.root.join("tmp/product/type/specific/framework/search/path").str])
        table.push(BuiltinMacros.CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_COMMA, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_FLOAT_CONVERSION, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_IMPLICIT_FALLTHROUGH, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_NON_LITERAL_NULL_CONVERSION, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_OBJC_LITERAL_CONVERSION, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_STRICT_PROTOTYPES, literal: "")

        // Override CLANG_DEBUG_MODULES, to be independent of recent changes to the Clang.xcspec.
        table.push(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("CLANG_DEBUG_MODULES") as? BooleanMacroDeclaration), literal: false)

        // Turn off response files, so we can directly check arguments
        table.push(BuiltinMacros.CLANG_USE_RESPONSE_FILE, literal: false)

        // TODO: We could move this outside of this test and have other tests use it.
        /// Utility method to create a task and pass it to a checker block.
        func createTask(with table: MacroValueAssignmentTable, _ checkTask: ((inout PlannedTaskBuilder) -> Void), sourceLocation: SourceLocation = #_sourceLocation) async throws {
            // Create the delegate, scope, file type, etc.
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let mockFileType = try core.specRegistry.getSpec("sourcecode.c.c") as FileTypeSpec

            // Create the build context for the command.
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input.c"), fileType: mockFileType)], output: nil)

            // Ask the specification to construct the tasks.
            await clangSpec.constructTasks(cbc, delegate)

            guard var task = delegate.shellTasks.last, task.ruleInfo.first == "CompileC" else {
                Issue.record("Failed to find compile task")
                return
            }
            checkTask(&task)
        }

        try await createTask(with: table) { task in
            #expect(task.ruleInfo == ["CompileC", Path.root.join("tmp/output/obj-normal/x86_64/input.o").str, Path.root.join("tmp/input.c").str, "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0"])
            #expect(task.execDescription == "Compile input.c (x86_64)")
            #expect(clangSpec.interestingPath(for: Task(&task))?.str == Path.root.join("tmp/input.c").str)

            // Check to see that we got the command line we expected based on the inputs.
            task.checkCommandLine(["clang", "-x", "c", "-target", "x86_64-apple-macos13.0", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-fmodules", "-fmodules-prune-interval=86400", "-fmodules-prune-after=345600", "-fmodules-ignore-macro=defn1", "-fmodules-ignore-macro=defn2", "-Wnon-modular-include-in-framework-module", "-Werror=non-modular-include-in-framework-module", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-shorten-64-to-32", "-Wpointer-sign", "-Wno-newline-eof", "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-semicolon-before-method-body", "-iquote", Path.root.join("tmp/Product-generated-files.hmap").str, "-I\(Path.root.join("tmp/Product-own-target-headers.hmap").str)", "-I\(Path.root.join("tmp/Product-all-non-framework-target-headers.hmap").str)", "-ivfsoverlay", "/--VFS/all-product-headers.yaml", "-iquote", Path.root.join("tmp/Product-project-headers.hmap").str, "-I\(Path.root.join("tmp/product/type/specific/header/search/path").str)", "-I\(Path.root.join("tmp/derived-normal/x86_64").str)", "-I\(Path.root.join("tmp/derived/x86_64").str)", "-I\(Path.root.join("tmp/derived").str)", "-DX86.64", "-iframework", Path.root.join("tmp/product/type/specific/framework/search/path").str, "-DFrom_GLOBAL_CFLAGS", "-DFrom_OTHER_CFLAGS_normal", "-include", Path.root.join("tmp/prefix.h").str, "-Ddefn1", "-Ddefn2", "-DFrom_GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS", "-MMD", "-MT", "dependencies", "-MF", Path.root.join("tmp/output/obj-normal/x86_64/input.d").str, "--serialize-diagnostics", Path.root.join("tmp/output/obj-normal/x86_64/input.dia").str, "-c", Path.root.join("tmp/input.c").str, "-o", Path.root.join("tmp/output/obj-normal/x86_64/input.o").str])
            task.checkInputs([
                .path(Path.root.join("tmp/prefix.h").str),
                .path(Path.root.join("tmp/input.c").str)
            ])
            task.checkOutputs([
                .path(Path.root.join("tmp/output/obj-normal/x86_64/input.o").str)
            ])
            #expect(task.dependencyData != nil)
            #expect(task.payload != nil)
        }

        // Also test that setting ENABLE_DEFAULT_SEARCH_PATHS_IN_HEADER_SEARCH_PATHS to NO disables the default header search paths.
        table.push(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS_IN_HEADER_SEARCH_PATHS, literal: false)
        try await createTask(with: table) { task in
            #expect(task.ruleInfo == ["CompileC", Path.root.join("tmp/output/obj-normal/x86_64/input.o").str, Path.root.join("tmp/input.c").str, "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0"])
            #expect(task.execDescription == "Compile input.c (x86_64)")
            #expect(clangSpec.interestingPath(for: Task(&task))?.str == Path.root.join("tmp/input.c").str)

            // Check to see that we got the command line we expected based on the inputs.
            task.checkCommandLine(["clang", "-x", "c", "-target", "x86_64-apple-macos13.0", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-fmodules", "-fmodules-prune-interval=86400", "-fmodules-prune-after=345600", "-fmodules-ignore-macro=defn1", "-fmodules-ignore-macro=defn2", "-Wnon-modular-include-in-framework-module", "-Werror=non-modular-include-in-framework-module", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-shorten-64-to-32", "-Wpointer-sign", "-Wno-newline-eof", "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-semicolon-before-method-body", "-iquote", Path.root.join("tmp/Product-generated-files.hmap").str, "-I\(Path.root.join("tmp/Product-own-target-headers.hmap").str)", "-I\(Path.root.join("tmp/Product-all-non-framework-target-headers.hmap").str)", "-ivfsoverlay", "/--VFS/all-product-headers.yaml", "-iquote", Path.root.join("tmp/Product-project-headers.hmap").str, "-I\(Path.root.join("tmp/product/type/specific/header/search/path").str)", "-DX86.64", "-iframework", Path.root.join("tmp/product/type/specific/framework/search/path").str, "-DFrom_GLOBAL_CFLAGS", "-DFrom_OTHER_CFLAGS_normal", "-include", Path.root.join("tmp/prefix.h").str, "-Ddefn1", "-Ddefn2", "-DFrom_GCC_OTHER_CFLAGS_NOT_USED_IN_PRECOMPS", "-MMD", "-MT", "dependencies", "-MF", Path.root.join("tmp/output/obj-normal/x86_64/input.d").str, "--serialize-diagnostics", Path.root.join("tmp/output/obj-normal/x86_64/input.dia").str, "-c", Path.root.join("tmp/input.c").str, "-o", Path.root.join("tmp/output/obj-normal/x86_64/input.o").str])
            task.checkInputs([
                .path(Path.root.join("tmp/prefix.h").str),
                .path(Path.root.join("tmp/input.c").str)
            ])
            task.checkOutputs([
                .path(Path.root.join("tmp/output/obj-normal/x86_64/input.o").str)
            ])
            #expect(task.dependencyData != nil)
            #expect(task.payload != nil)
        }
    }

    @Test
    func clangCompileWithPrefixHeaderTaskConstruction() async throws {
        let core = try await getCore()
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CommandLineToolSpec

        // Create the mock table.  We include all the defaults for the tool specification.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        for option in clangSpec.flattenedOrderedBuildOptions {
            guard let value = option.defaultValue else { continue }
            table.push(option.macro, value)
        }
        // We also add some other settings that are more contextual in nature.
        table.push(BuiltinMacros.CURRENT_ARCH, literal: "x86_64")
        table.push(BuiltinMacros.arch, literal: "x86_64")
        table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_VENDOR, literal: "apple")
        table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_OS_VERSION, BuiltinMacros.namespace.parseString("$(SWIFT_PLATFORM_TARGET_PREFIX)$($(DEPLOYMENT_TARGET_SETTING_NAME))"))
        table.push(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, literal: "macos")
        table.push(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME, literal: "MACOSX_DEPLOYMENT_TARGET")
        table.push(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET, literal: "13.0")
        table.push(BuiltinMacros.CURRENT_VARIANT, literal: "normal")
        table.push(BuiltinMacros.PRODUCT_NAME, literal: "Product")
        table.push(BuiltinMacros.TEMP_DIR, literal: Path.root.join("tmp").str)
        table.push(BuiltinMacros.PROJECT_TEMP_DIR, literal: Path.root.join("tmp/ptmp").str)
        table.push(BuiltinMacros.OBJECT_FILE_DIR, literal: Path.root.join("tmp/output/obj").str)
        table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, BuiltinMacros.namespace.parseString("$(OBJECT_FILE_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)"))
        table.push(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS, literal: true)
        table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: Path.root.join("tmp/output/sym").str)
        table.push(BuiltinMacros.GCC_PREFIX_HEADER, literal: Path.root.join("tmp/prefix.h").str)
        table.push(BuiltinMacros.DERIVED_FILE_DIR, literal: Path.root.join("tmp/derived").str)
        table.push(BuiltinMacros.GCC_PRECOMPILE_PREFIX_HEADER, literal: true)
        table.push(BuiltinMacros.SHARED_PRECOMPS_DIR, literal: Path.root.join("tmp/precomps").str)
        table.push(BuiltinMacros.ALWAYS_SEARCH_USER_PATHS, literal: true)
        table.push(BuiltinMacros.CLANG_ENABLE_MODULES, literal: true)
        table.push(BuiltinMacros.CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_COMMA, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_FLOAT_CONVERSION, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_NON_LITERAL_NULL_CONVERSION, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_OBJC_LITERAL_CONVERSION, literal: "")
        table.push(BuiltinMacros.CLANG_WARN_STRICT_PROTOTYPES, literal: "")

        // Override CLANG_DEBUG_MODULES, to be independent of recent changes to the Clang.xcspec.
        table.push(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("CLANG_DEBUG_MODULES") as? BooleanMacroDeclaration), literal: false)

        // Turn off response files, so we can directly check arguments
        table.push(BuiltinMacros.CLANG_USE_RESPONSE_FILE, literal: false)

        // Create the delegate, scope, file type, etc.
        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("sourcecode.c.c") as FileTypeSpec

        // We need to construct multiple tasks to ensure that they correctly share one precompiled header
        let numCompileTasks = 2

        for compileTaskIndex in 0..<numCompileTasks {
            // Create the build context for the command.
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input-\(compileTaskIndex).c"), fileType: mockFileType)], output: nil)
            // Ask the specification to construct the tasks.
            await clangSpec.constructTasks(cbc, delegate)
        }

        // We should have one task for precompiling and `numCompileTasks` tasks for compiling
        #expect(delegate.shellTasks.count == 1 + numCompileTasks)

        let pchHash: String
        if core.hostOperatingSystem == .windows {
            // non-constant on Windows because Path.root may evaluate to any drive letter
            pchHash = String(ClangCompilerSpec.sharedPrecompiledHeaderSharingIdentifier(commandLine: [
                "clang.exe",
                "-x",
                "c",
                "-target",
                "x86_64-apple-macos13.0",
                "-fmodules",
                "-fpascal-strings",
                "-Os",
                "-fasm-blocks",
                "-iquote",
                Path.root.join("tmp/Product-generated-files.hmap").str,
                "-I\(Path.root.join("tmp/Product-own-target-headers.hmap").str)",
                "-I\(Path.root.join("tmp/Product-all-non-framework-target-headers.hmap").str)",
                "-ivfsoverlay",
                "\\--VFS\\all-product-headers.yaml",
                "-iquote",
                Path.root.join("tmp/Product-project-headers.hmap").str,
                "-I\(Path.root.join("tmp/derived-normal/x86_64").str)",
                "-I\(Path.root.join("tmp/derived/x86_64").str)",
                "-I\(Path.root.join("tmp/derived").str)",
                Path.root.join("tmp/prefix.h").str,
            ]).hashValue)
        } else {
            pchHash = "1041705040740768206"
        }

        // Check the precompilation task
        let precompileTask = delegate.shellTasks.first{ $0.ruleInfo.first! == "ProcessPCH" }!
        precompileTask.checkCommandLine([core.hostOperatingSystem.imageFormat.executableName(basename: "clang"), "-x", "c-header", "-target", "x86_64-apple-macos13.0", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-fmodules", "-fmodules-prune-interval=86400", "-fmodules-prune-after=345600", "-Wnon-modular-include-in-framework-module", "-Werror=non-modular-include-in-framework-module", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-shorten-64-to-32", "-Wpointer-sign", "-Wno-newline-eof", "-Wno-implicit-fallthrough", "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-semicolon-before-method-body", "-iquote", Path.root.join("tmp/Product-generated-files.hmap").str, "-I\(Path.root.join("tmp/Product-own-target-headers.hmap").str)", "-I\(Path.root.join("tmp/Product-all-non-framework-target-headers.hmap").str)", "-ivfsoverlay", Path("/--VFS/all-product-headers.yaml").str, "-iquote", Path.root.join("tmp/Product-project-headers.hmap").str, "-I\(Path.root.join("tmp/derived-normal/x86_64").str)", "-I\(Path.root.join("tmp/derived/x86_64").str)", "-I\(Path.root.join("tmp/derived").str)", "-c", Path.root.join("tmp/prefix.h").str, "-MD", "-MT", "dependencies", "-MF", "\(Path.root.join("tmp/precomps/SharedPrecompiledHeaders/\(pchHash)/prefix.h.d").str)", "-o", "\(Path.root.join("tmp/precomps/SharedPrecompiledHeaders/\(pchHash)/prefix.h.gch").str)", "--serialize-diagnostics", "\(Path.root.join("tmp/precomps/SharedPrecompiledHeaders/\(pchHash)/prefix.h.dia").str)"])
        #expect(precompileTask.ruleInfo == ["ProcessPCH", Path.root.join("tmp/precomps/SharedPrecompiledHeaders/\(pchHash)/prefix.h.gch").str, Path.root.join("tmp/prefix.h").str, "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0"])
        #expect(precompileTask.execDescription == "Precompile prefix.h (x86_64)")
        precompileTask.checkInputs([
            .path(Path.root.join("tmp/prefix.h").str)
        ])
        precompileTask.checkOutputs([
            .path(Path.root.join("tmp/precomps/SharedPrecompiledHeaders/\(pchHash)/prefix.h.gch").str)
        ])
        #expect(precompileTask.payload != nil)
        #expect(precompileTask.additionalOutput == ["Precompile of \'\(Path.root.join("tmp/prefix.h").str)\' required by \'\(Path.root.join("tmp/input-0.c").str)\'"])

        // Check the compile tasks
        for compileTaskIndex in 0..<numCompileTasks {
            let compileTask = delegate.shellTasks.first{ $0.ruleInfo.first! == "CompileC" && $0.inputs.contains{ $0.path.basename == "input-\(compileTaskIndex).c" } }!
            #expect(compileTask.ruleInfo == ["CompileC", Path.root.join("tmp/output/obj-normal/x86_64/input-\(compileTaskIndex).o").str, Path.root.join("tmp/input-\(compileTaskIndex).c").str, "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0"])
            #expect(compileTask.execDescription == "Compile input-\(compileTaskIndex).c (x86_64)")

            compileTask.checkCommandLine([core.hostOperatingSystem.imageFormat.executableName(basename: "clang"), "-x", "c", "-target", "x86_64-apple-macos13.0", "-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fno-color-diagnostics", "-fmodules", "-fmodules-prune-interval=86400", "-fmodules-prune-after=345600", "-Wnon-modular-include-in-framework-module", "-Werror=non-modular-include-in-framework-module", "-Wno-trigraphs", "-fpascal-strings", "-Os", "-Wno-missing-field-initializers", "-Wno-missing-prototypes", "-Wno-return-type", "-Wno-missing-braces", "-Wparentheses", "-Wswitch", "-Wno-unused-function", "-Wno-unused-label", "-Wno-unused-parameter", "-Wno-unused-variable", "-Wunused-value", "-Wno-empty-body", "-Wno-uninitialized", "-Wno-unknown-pragmas", "-Wno-shadow", "-Wno-four-char-constants", "-Wno-conversion", "-Wno-constant-conversion", "-Wno-int-conversion", "-Wno-bool-conversion", "-Wno-enum-conversion", "-Wno-shorten-64-to-32", "-Wpointer-sign", "-Wno-newline-eof", "-Wno-implicit-fallthrough", "-fasm-blocks", "-fstrict-aliasing", "-Wdeprecated-declarations", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-Wno-semicolon-before-method-body", "-iquote", Path.root.join("tmp/Product-generated-files.hmap").str, "-I\(Path.root.join("tmp/Product-own-target-headers.hmap").str)", "-I\(Path.root.join("tmp/Product-all-non-framework-target-headers.hmap").str)", "-ivfsoverlay", Path("/--VFS/all-product-headers.yaml").str, "-iquote", Path.root.join("tmp/Product-project-headers.hmap").str, "-I\(Path.root.join("tmp/derived-normal/x86_64").str)", "-I\(Path.root.join("tmp/derived/x86_64").str)", "-I\(Path.root.join("tmp/derived").str)", "-include", "\(Path.root.join("tmp/precomps/SharedPrecompiledHeaders/\(pchHash)/prefix.h").str)", "-MMD", "-MT", "dependencies", "-MF", "\(Path.root.join("tmp/output/obj-normal/x86_64/input-\(compileTaskIndex).d").str)", "--serialize-diagnostics", "\(Path.root.join("tmp/output/obj-normal/x86_64/input-\(compileTaskIndex).dia").str)", "-c", "\(Path.root.join("tmp/input-\(compileTaskIndex).c").str)", "-o", "\(Path.root.join("tmp/output/obj-normal/x86_64/input-\(compileTaskIndex).o").str)"])
            compileTask.checkInputs([
                .path(Path.root.join("tmp/precomps/SharedPrecompiledHeaders/\(pchHash)/prefix.h.gch").str),
                .path(Path.root.join("tmp/input-\(compileTaskIndex).c").str)
            ])
            compileTask.checkOutputs([
                .path(Path.root.join("tmp/output/obj-normal/x86_64/input-\(compileTaskIndex).o").str)
            ])
            #expect(compileTask.payload != nil)
        }
    }

    @Test
    func clangCompileTaskConstructionWithCXXModulesDisabled() async throws {
        let core = try await getCore()
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CommandLineToolSpec

        // Create the dummy table.  We include all the defaults for the tool specification.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        for option in clangSpec.flattenedOrderedBuildOptions {
            guard let value = option.defaultValue else { continue }
            table.push(option.macro, value)
        }
        // We also add some other settings that are more contextual in nature.
        table.push(BuiltinMacros.CURRENT_ARCH, literal: "x86_64")
        table.push(BuiltinMacros.arch, literal: "x86_64")
        table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_VENDOR, literal: "apple")
        table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_OS_VERSION, BuiltinMacros.namespace.parseString("$(SWIFT_PLATFORM_TARGET_PREFIX)$($(DEPLOYMENT_TARGET_SETTING_NAME))"))
        table.push(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, literal: "macos")
        table.push(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME, literal: "MACOSX_DEPLOYMENT_TARGET")
        table.push(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET, literal: "13.0")
        table.push(BuiltinMacros.CURRENT_VARIANT, literal: "normal")
        table.push(BuiltinMacros.PRODUCT_NAME, literal: "Product")
        table.push(BuiltinMacros.TEMP_DIR, literal: Path.root.join("tmp").str)
        table.push(BuiltinMacros.OBJECT_FILE_DIR, literal: Path.root.join("tmp/output/obj").str)
        table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, BuiltinMacros.namespace.parseString("$(OBJECT_FILE_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)"))
        table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: Path.root.join("tmp/output/sym").str)
        table.push(BuiltinMacros.ENABLE_DEFAULT_SEARCH_PATHS, literal: true)
        table.push(BuiltinMacros.CLANG_ENABLE_MODULES, literal: true)

        // Turn off response files, so we can directly check arguments
        table.push(BuiltinMacros.CLANG_USE_RESPONSE_FILE, literal: false)

        /// Utility method to create a task and pass it to a checker block.
        func createTask(with table: MacroValueAssignmentTable, spec: String, _ checkTask: ((inout PlannedTaskBuilder) -> Void),
                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
            // Create the delegate, scope, file type, etc.
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let dummyScope = MacroEvaluationScope(table: table)
            let dummyFileType = try core.specRegistry.getSpec(spec) as FileTypeSpec

            let fileSuffix = spec.hasSuffix("objcpp") ? ".mm" : ".m"
            // Create the build context for the command.
            let cbc = CommandBuildContext(producer: producer, scope: dummyScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input" + fileSuffix), fileType: dummyFileType)], output: nil)

            // Ask the specification to construct the tasks.
            await clangSpec.constructTasks(cbc, delegate)

            guard var task = delegate.shellTasks.last, task.ruleInfo.first == "CompileC" else {
                Issue.record("Failed to find compile task")
                return
            }
            checkTask(&task)
        }

        try await createTask(with: table, spec: "sourcecode.cpp.objcpp") { task in
            #expect(task.ruleInfo == ["CompileC", Path.root.join("tmp/output/obj-normal/x86_64/input.o").str, Path.root.join("tmp/input.mm").str, "normal", "x86_64", "objective-c++", "com.apple.compilers.llvm.clang.1_0"])
            #expect(task.execDescription == "Compile input.mm (x86_64)")
            #expect(clangSpec.interestingPath(for: Task(&task))?.str == Path.root.join("tmp/input.mm").str)

            task.checkCommandLineMatches(["-fmodules", .anySequence, "-fno-cxx-modules", .anySequence])
            task.checkCommandLineDoesNotContain("-fcxx-modules")

            task.checkInputs([
                .path(Path.root.join("tmp/input.mm").str)
            ])
            task.checkOutputs([
                .path(Path.root.join("tmp/output/obj-normal/x86_64/input.o").str)
            ])
            #expect(task.dependencyData != nil)
            #expect(task.payload != nil)
        }

        // Validate that the presence of -fcxx-modules shows up **after** the disablement flag.
        table.push(BuiltinMacros.OTHER_CPLUSPLUSFLAGS, literal: ["-fcxx-modules"])
        try await createTask(with: table, spec: "sourcecode.cpp.objcpp") { task in
            #expect(task.ruleInfo == ["CompileC", Path.root.join("tmp/output/obj-normal/x86_64/input.o").str, Path.root.join("tmp/input.mm").str, "normal", "x86_64", "objective-c++", "com.apple.compilers.llvm.clang.1_0"])
            #expect(task.execDescription == "Compile input.mm (x86_64)")
            task.checkCommandLineMatches(["-fmodules", .anySequence, "-fno-cxx-modules", .anySequence, "-fcxx-modules"])
        }

        try await createTask(with: table, spec: "sourcecode.c.objc") { task in
            #expect(task.ruleInfo == ["CompileC", Path.root.join("tmp/output/obj-normal/x86_64/input.o").str, Path.root.join("tmp/input.m").str, "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0"])
            #expect(task.execDescription == "Compile input.m (x86_64)")
            #expect(clangSpec.interestingPath(for: Task(&task))?.str == Path.root.join("tmp/input.m").str)

            task.checkCommandLineContains("-fmodules")
            task.checkCommandLineDoesNotContain("-fno-cxx-modules")
        }
    }


    /// Check that C_COMPILER_LAUNCHER is honored.
    @Test(.skipHostOS(.windows, "output file is coming out as tmp\\input.o (non-absolute)"))
    func cCompilerLauncher() async throws {
        let core = try await getCore()
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CommandLineToolSpec

        // Create the mock table.  We include all the defaults for the tool specification.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(BuiltinMacros.C_COMPILER_LAUNCHER, literal: "foo")

        // Create the delegate, scope, file type, etc.
        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("sourcecode.c") as FileTypeSpec

        // Create the build context for the command.
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input.c"), fileType: mockFileType)], output: nil)

        // Ask the specification to construct the tasks.
        await clangSpec.constructTasks(cbc, delegate)

        // There should be exactly one shell task.
        #expect(delegate.shellTasks.count == 1)
        let task = try #require(delegate.shellTasks[safe: 0])
        #expect(task.ruleInfo == ["CompileC", Path.root.join("tmp/input.o").str, Path.root.join("tmp/input.c").str, "", "", "c", "com.apple.compilers.llvm.clang.1_0"])
        #expect(task.execDescription == "Compile input.c")

        // Check to see that we got the command line we expected based on the inputs.
        task.checkCommandLineMatches([.equal("foo"), .equal("clang"), .anySequence])
    }

    @Test
    func cppLanguageStandard() async throws {
        let core = try await getCore()
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CommandLineToolSpec
        let mockFileType = try core.specRegistry.getSpec("sourcecode.cpp.cpp") as FileTypeSpec
        let langStandardMacro = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("CLANG_CXX_LANGUAGE_STANDARD") as? StringMacroDeclaration)

        let macroFlagMapping = [
            "c++0x": ["-std=c++11"],
            "c++11": ["-std=c++11"],
            "c++14": ["-std=c++1y", "-std=c++14"],
            "c++20": ["-std=c++20"],
            "gnu++20": ["-std=gnu++20"],
        ]

        for (macro, flags) in macroFlagMapping {

            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(langStandardMacro, literal: macro)
            let mockScope = MacroEvaluationScope(table: table)
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input.cpp"), fileType: mockFileType)], output: nil)

            await clangSpec.constructTasks(cbc, delegate)

            #expect(delegate.shellTasks.count == 1)
            let task = try #require(delegate.shellTasks[safe: 0])
            #expect(task.execDescription == "Compile input.cpp")
            guard let stdArg = task.commandLine.filter({ $0.asString.hasPrefix("-std") }).first?.asString else {
                Issue.record("unable to find -std=? argument in \(delegate.shellTasks.map{ $0.commandLine })")
                continue
            }
            #expect(flags.contains(stdArg), "unexpected -std flag '\(stdArg)' (not in \(flags))")
        }
    }

    @Test
    func compilerPathOverrides() async throws {
        let core = try await getCore()
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CommandLineToolSpec
        let fileTypes = [
            ".c": try core.specRegistry.getSpec("sourcecode.c.c") as FileTypeSpec,
            ".cpp": try core.specRegistry.getSpec("sourcecode.cpp.cpp") as FileTypeSpec,
            ".m": try core.specRegistry.getSpec("sourcecode.c.objc") as FileTypeSpec,
            ".mm": try core.specRegistry.getSpec("sourcecode.cpp.objcpp") as FileTypeSpec
        ]

        // Check with just CC.
        do {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.CC, literal: "SomeCCompiler")
            let mockScope = MacroEvaluationScope(table: table)

            // Create the build context for the command.
            for (name, expected) in [("file.c", "SomeCCompiler"), ("file.m", "SomeCCompiler"), ("file.cpp", "SomeCCompiler"), ("file.mm", "SomeCCompiler")] {
                let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
                let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
                let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/\(name)"), fileType: fileTypes[Path(name).fileSuffix]!)], output: nil)
                await clangSpec.constructTasks(cbc, delegate)
                #expect(delegate.shellTasks.count == 1)
                #expect(delegate.shellTasks[safe: 0]?.commandLine[safe: 0]?.asString == expected)
            }
        }

        // Check with CC & CPLUSPLUS.
        do {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.CC, literal: "SomeCCompiler")
            table.push(BuiltinMacros.CPLUSPLUS, literal: "SomeC++Compiler")
            let mockScope = MacroEvaluationScope(table: table)

            // Create the build context for the command.
            for (name, expected) in [("file.c", "SomeCCompiler"), ("file.m", "SomeCCompiler"), ("file.cpp", "SomeC++Compiler"), ("file.mm", "SomeC++Compiler")] {
                let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
                let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
                let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/\(name)"), fileType: fileTypes[Path(name).fileSuffix]!)], output: nil)
                await clangSpec.constructTasks(cbc, delegate)
                #expect(delegate.shellTasks.count == 1)
                #expect(delegate.shellTasks[safe: 0]?.commandLine[safe: 0]?.asString == expected)
            }
        }

        // Check with CC & CPLUSPLUS & OBJC & OBJCPLUSLUS.
        do {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.CC, literal: "SomeCCompiler")
            table.push(BuiltinMacros.CPLUSPLUS, literal: "SomeC++Compiler")
            table.push(BuiltinMacros.OBJCC, literal: "SomeObjCCompiler")
            table.push(BuiltinMacros.OBJCPLUSPLUS, literal: "SomeObjC++Compiler")
            let mockScope = MacroEvaluationScope(table: table)

            // Create the build context for the command.
            for (name, expected) in [("file.c", "SomeCCompiler"), ("file.m", "SomeObjCCompiler"), ("file.cpp", "SomeC++Compiler"), ("file.mm", "SomeObjC++Compiler")] {
                let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
                let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
                let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/\(name)"), fileType: fileTypes[Path(name).fileSuffix]!)], output: nil)
                await clangSpec.constructTasks(cbc, delegate)
                #expect(delegate.shellTasks.count == 1)
                #expect(delegate.shellTasks[safe: 0]?.commandLine[safe: 0]?.asString == expected)
            }
        }
    }

    @Test
    func linkerTaskConstruction() async throws {
        let core = try await getCore()
        let linkerSpec: LinkerSpec = try core.specRegistry.getSpec() as LdLinkerSpec

        // Create the mock table.
        // Since these tests don't use any of the default settings, we need to push any defaults needed for the test here.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(BuiltinMacros.arch, literal: "x86_64")
        table.push(BuiltinMacros.variant, literal: "normal")
        table.push(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("LD_RUNPATH_SEARCH_PATHS") as? StringListMacroDeclaration), literal: ["rpath1"])
        table.push(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("LD_EXPORT_SYMBOLS") as? BooleanMacroDeclaration), literal: true)
        try table.push(core.specRegistry.internalMacroNamespace.declareStringMacro("DYNAMIC_LIBRARY_EXTENSION") as StringMacroDeclaration, literal: "dylib")
        try table.push(core.specRegistry.internalMacroNamespace.declareBooleanMacro("_DISCOVER_COMMAND_LINE_LINKER_INPUTS") as BooleanMacroDeclaration, literal: true)
        try table.push(core.specRegistry.internalMacroNamespace.declareBooleanMacro("_DISCOVER_COMMAND_LINE_LINKER_INPUTS_INCLUDE_WL") as BooleanMacroDeclaration, literal: true)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/obj/normal/x86_64/file1.o"), fileType: mockFileType)], output: Path.root.join("tmp/obj/normal/x86_64/output"))

        // Test all permutations of library kind, linkage mode and search path usage, except for object files.
        func generateLibrarySpecifiers(kind: LinkerSpec.LibrarySpecifier.Kind) -> [LinkerSpec.LibrarySpecifier] {
            var result = [LinkerSpec.LibrarySpecifier]()
            for useSearchPaths in [true, false] {
                let searchPathString = useSearchPaths ? "search" : "abs"
                for mode in LinkerSpec.LibrarySpecifier.Mode.allCases {
                    let suffix = "_\(mode)_\(searchPathString)"
                    let filePath: Path
                    switch kind {
                    case .static:
                        filePath = Path.root.join("usr/lib/libfoo\(suffix).a")
                    case .dynamic:
                        filePath = Path.root.join("usr/lib/libbar\(suffix).dylib")
                    case .textBased:
                        filePath = Path.root.join("usr/lib/libbaz\(suffix).tbd")
                    case .framework:
                        filePath = Path.root.join("tmp/Foo\(suffix).framework")
                    case .object:
                        continue
                    }
                    result.append(LinkerSpec.LibrarySpecifier(kind: kind, path: filePath, mode: mode, useSearchPaths: useSearchPaths, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]))
                }
            }
            return result
        }
        var libraries = [LinkerSpec.LibrarySpecifier]()
        for kind in LinkerSpec.LibrarySpecifier.Kind.allCases {
            libraries.append(contentsOf: generateLibrarySpecifiers(kind: kind))
        }
        // This is a no-op because object files get added in the SourcesTaskProducer, but we want to confirm that this is the case.
        libraries.append(LinkerSpec.LibrarySpecifier(kind: .object, path: Path.root.join("tmp/Bar.o"), mode: .normal, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]))

        await linkerSpec.constructLinkerTasks(cbc, delegate, libraries: libraries, usedTools: [:])

        // There should be exactly one shell task.
        #expect(delegate.shellTasks.count == 1)
        let task = try #require(delegate.shellTasks[safe: 0])
        #expect(task.ruleInfo == ["Ld", Path.root.join("tmp/obj/normal/x86_64/output").str, "normal", "x86_64"])
        #expect(task.execDescription == "Link output")
        // FIXME: This still has a lot of issues.
        task.checkCommandLine([
            core.hostOperatingSystem.imageFormat.executableName(basename: "clang"), "-Xlinker", "-rpath", "-Xlinker", "rpath1", "-nostdlib",
            "-lfoo_normal_search", "-lfoo_reexport_search", "-lfoo_merge_search", "-lfoo_reexport_merge_search", "-weak-lfoo_weak_search", Path.root.join("usr/lib/libfoo_normal_abs.a").str, Path.root.join("usr/lib/libfoo_reexport_abs.a").str, Path.root.join("usr/lib/libfoo_merge_abs.a").str, Path.root.join("usr/lib/libfoo_reexport_merge_abs.a").str, "-weak_library", Path.root.join("usr/lib/libfoo_weak_abs.a").str,
            "-lbar_normal_search", "-Xlinker", "-reexport-lbar_reexport_search", "-Xlinker", "-merge-lbar_merge_search", "-Xlinker", "-no_merge-lbar_reexport_merge_search", "-weak-lbar_weak_search", Path.root.join("usr/lib/libbar_normal_abs.dylib").str, "-Xlinker", "-reexport_library", "-Xlinker", Path.root.join("usr/lib/libbar_reexport_abs.dylib").str, "-Xlinker", "-merge_library", "-Xlinker", Path.root.join("usr/lib/libbar_merge_abs.dylib").str, "-Xlinker", "-no_merge_library", "-Xlinker", Path.root.join("usr/lib/libbar_reexport_merge_abs.dylib").str, "-weak_library", Path.root.join("usr/lib/libbar_weak_abs.dylib").str,
            "-lbaz_normal_search", "-lbaz_reexport_search", "-lbaz_merge_search", "-lbaz_reexport_merge_search", "-weak-lbaz_weak_search", Path.root.join("usr/lib/libbaz_normal_abs.tbd").str, Path.root.join("usr/lib/libbaz_reexport_abs.tbd").str, Path.root.join("usr/lib/libbaz_merge_abs.tbd").str, Path.root.join("usr/lib/libbaz_reexport_merge_abs.tbd").str, "-weak_library", Path.root.join("usr/lib/libbaz_weak_abs.tbd").str,
            "-framework", "Foo_normal_search", "-Xlinker", "-reexport_framework", "-Xlinker", "Foo_reexport_search", "-Xlinker", "-merge_framework", "-Xlinker", "Foo_merge_search", "-Xlinker", "-no_merge_framework", "-Xlinker", "Foo_reexport_merge_search", "-weak_framework", "Foo_weak_search", Path.root.join("tmp/Foo_normal_abs.framework/Foo_normal_abs").str, "-Xlinker", "-reexport_library", "-Xlinker", Path.root.join("tmp/Foo_reexport_abs.framework/Foo_reexport_abs").str, "-Xlinker", "-merge_library", "-Xlinker", Path.root.join("tmp/Foo_merge_abs.framework/Foo_merge_abs").str, "-Xlinker", "-no_merge_library", "-Xlinker", Path.root.join("tmp/Foo_reexport_merge_abs.framework/Foo_reexport_merge_abs").str, "-weak_library", Path.root.join("tmp/Foo_weak_abs.framework/Foo_weak_abs").str,
            "-o", Path.root.join("tmp/obj/normal/x86_64/output").str])
        // FIXME: The input here should really be the link file list.
        if SWBFeatureFlag.enableLinkerInputsFromLibrarySpecifiers.value {
            task.checkInputs([
                .path(Path.root.join("tmp/obj/normal/x86_64/file1.o").str),
                .path(Path.root.join("usr/lib/libfoo_normal_abs.a").str),
                .path(Path.root.join("usr/lib/libfoo_reexport_abs.a").str),
                .path(Path.root.join("usr/lib/libfoo_merge_abs.a").str),
                .path(Path.root.join("usr/lib/libfoo_reexport_merge_abs.a").str),
                .path(Path.root.join("usr/lib/libfoo_weak_abs.a").str),
                .path(Path.root.join("usr/lib/libbar_normal_abs.dylib").str),
                .path(Path.root.join("usr/lib/libbar_reexport_abs.dylib").str),
                .path(Path.root.join("usr/lib/libbar_merge_abs.dylib").str),
                .path(Path.root.join("usr/lib/libbar_reexport_merge_abs.dylib").str),
                .path(Path.root.join("usr/lib/libbar_weak_abs.dylib").str),
                .path(Path.root.join("usr/lib/libbaz_normal_abs.tbd").str),
                .path(Path.root.join("usr/lib/libbaz_reexport_abs.tbd").str),
                .path(Path.root.join("usr/lib/libbaz_merge_abs.tbd").str),
                .path(Path.root.join("usr/lib/libbaz_reexport_merge_abs.tbd").str),
                .path(Path.root.join("usr/lib/libbaz_weak_abs.tbd").str),
                .path(Path.root.join("tmp/Foo_normal_abs.framework/Foo_normal_abs").str),
                .path(Path.root.join("tmp/Foo_reexport_abs.framework").str),
                .path(Path.root.join("tmp/Foo_merge_abs.framework").str),
                .path(Path.root.join("tmp/Foo_reexport_merge_abs.framework").str),
                .path(Path.root.join("tmp/Foo_weak_abs.framework/Foo_weak_abs").str),
            ])
        } else {
            // FIXME: We aren't detecting "loose" libraries from the command line, e.g. absolute paths to files otherwise unadorned by some command line flag.
            task.checkInputs([
                .path(Path.root.join("tmp/obj/normal/x86_64/file1.o").str),
                .path(Path.root.join("usr/lib/libfoo_weak_abs.a").str),
                .path(Path.root.join("usr/lib/libbar_reexport_abs.dylib").str),
                .path(Path.root.join("usr/lib/libbar_merge_abs.dylib").str),
                .path(Path.root.join("usr/lib/libbar_reexport_merge_abs.dylib").str),
                .path(Path.root.join("usr/lib/libbar_weak_abs.dylib").str),
                .path(Path.root.join("usr/lib/libbaz_weak_abs.tbd").str),
                .path(Path.root.join("tmp/Foo_reexport_abs.framework/Foo_reexport_abs").str),
                .path(Path.root.join("tmp/Foo_merge_abs.framework/Foo_merge_abs").str),
                .path(Path.root.join("tmp/Foo_reexport_merge_abs.framework/Foo_reexport_merge_abs").str),
                .path(Path.root.join("tmp/Foo_weak_abs.framework/Foo_weak_abs").str),
            ])
        }
        task.checkOutputs([
            .path(Path.root.join("tmp/obj/normal/x86_64/output").str)
        ])
    }

    /// Tests for individual linker build settings.
    @Test
    func linkerBuildSettings() async throws {
        let core = try await getCore()
        let linkerSpec: LinkerSpec = try core.specRegistry.getSpec() as LdLinkerSpec
        let variant = "normal"
        let arch = "arm64"

        // Create the mock table.
        var baseTable = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        baseTable.push(BuiltinMacros.arch, literal: arch)
        baseTable.push(BuiltinMacros.variant, literal: variant)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec

        /// Utility method to add the setting to the table, create a task with the table, and call a checker block.
        func createAndCheckLinkerTask(_ name: String, type: MacroDeclaration.Type, value: String, check: (PlannedTaskBuilder) async throws -> Void) async throws {
            var table = MacroValueAssignmentTable(namespace: baseTable.namespace)
            table.pushContentsOf(baseTable)
            let macro = table.namespace.lookupOrDeclareMacro(type.self, name)
            let expr = table.namespace.parseString(value)
            table.push(macro, expr)

            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/obj/\(variant)/\(arch)/file1.o"), fileType: mockFileType)], output: Path.root.join("tmp/obj/\(variant)/\(arch)/output"))
            await linkerSpec.constructLinkerTasks(cbc, delegate, libraries: [], usedTools: [:])

            // There should be exactly one shell task.
            #expect(delegate.shellTasks.count == 1)
            let task = try #require(delegate.shellTasks[safe: 0])
            try await check(task)
        }

        try await createAndCheckLinkerTask("LD_EXPORT_SYMBOLS", type: StringMacroDeclaration.self, value: "YES") { task in
            task.checkCommandLineDoesNotContain("-no_exported_symbols")
        }
        try await createAndCheckLinkerTask("LD_EXPORT_SYMBOLS", type: StringMacroDeclaration.self, value: "NO") { task in
            task.checkCommandLineContains(["-Xlinker", "-no_exported_symbols"])
        }

        try await createAndCheckLinkerTask("LD_SHARED_CACHE_ELIGIBLE", type: StringMacroDeclaration.self, value: "Automatic") { task in
            task.checkCommandLineDoesNotContain("-not_for_dyld_shared_cache")
            task.checkCommandLineDoesNotContain("-no_shared_cache_eligible")
        }
        try await createAndCheckLinkerTask("LD_SHARED_CACHE_ELIGIBLE", type: StringMacroDeclaration.self, value: "NO") { task in
            task.checkCommandLineContains(["-Xlinker", "-not_for_dyld_shared_cache"])
            task.checkCommandLineContains(["-Xlinker", "-no_shared_cache_eligible"])
        }
    }

    /// Test that we pass `-no_adhoc_codesign` to the linker in the expected scenarios:
    /// - When we have a signing identity.
    /// - But never when running `ld -r`.
    @Test
    func linkerAdHocSigningOptions() async throws {
        let core = try await getCore()
        let linkerSpec: LinkerSpec = try core.specRegistry.getSpec() as LdLinkerSpec

        // Create the mock table, which will get re-used across the tests.We include all the defaults for the tool specification.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        for option in linkerSpec.flattenedOrderedBuildOptions {
            guard let value = option.defaultValue else { continue }
            table.push(option.macro, value)
        }

        table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_VENDOR, literal: "apple")
        table.push(BuiltinMacros.LLVM_TARGET_TRIPLE_OS_VERSION, BuiltinMacros.namespace.parseString("$(SWIFT_PLATFORM_TARGET_PREFIX)$($(DEPLOYMENT_TARGET_SETTING_NAME))"))
        table.push(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX, literal: "macos")
        table.push(BuiltinMacros.DEPLOYMENT_TARGET_SETTING_NAME, literal: "MACOSX_DEPLOYMENT_TARGET")
        table.push(BuiltinMacros.MACOSX_DEPLOYMENT_TARGET, literal: "13.0")
        table.push(BuiltinMacros.variant, literal: "normal")
        table.push(BuiltinMacros.MACH_O_TYPE, literal: "dylib")

        // Construct data we can re-use across the tests.
        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let mockFileType: FileTypeSpec = try core.specRegistry.getSpec("file")

        // Test linking for different macOS archs with a signing identity.
        // Presently we disable ad-hoc code signing always when we have a signing identity.
        for arch in ["x86_64", "arm64"] {
            table.push(BuiltinMacros.CURRENT_ARCH, literal: arch)
            table.push(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY, literal: "-")

            // Construct the task.
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/obj/normal/\(arch)/file1.o"), fileType: mockFileType)], output: Path.root.join("tmp/obj/normal/\(arch)/output"))
            await linkerSpec.constructLinkerTasks(cbc, delegate, libraries: [], usedTools: [:])

            // Check the results.
            let task = try #require(delegate.shellTasks.only)
            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-macos13.0"])
            task.checkCommandLineContainsUninterrupted(["-Xlinker", "-no_adhoc_codesign"])
        }

        // Test linking for different macOS archs without a signing identity - we should not disable here.
        for arch in ["x86_64", "arm64"] {
            table.push(BuiltinMacros.CURRENT_ARCH, literal: arch)
            table.push(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY, literal: "")

            // Construct the task.
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/obj/normal/\(arch)/file1.o"), fileType: mockFileType)], output: Path.root.join("tmp/obj/normal/\(arch)/output"))
            await linkerSpec.constructLinkerTasks(cbc, delegate, libraries: [], usedTools: [:])

            // Check the results.
            let task = try #require(delegate.shellTasks.only)
            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-macos13.0"])
            task.checkCommandLineDoesNotContain("-no_adhoc_codesign")
        }

        // Test linking an object file using 'ld -r' - we should not disable here.
        for arch in ["x86_64", "arm64"] {
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.objfile", platform: "macosx")

            table.push(BuiltinMacros.CURRENT_ARCH, literal: arch)
            table.push(BuiltinMacros.MACH_O_TYPE, literal: "mh_object")
            table.push(BuiltinMacros.EXPANDED_CODE_SIGN_IDENTITY, literal: "-")

            // Construct the task.
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/obj/normal/\(arch)/file1.o"), fileType: mockFileType)], output: Path.root.join("tmp/obj/normal/\(arch)/output.o"))
            await linkerSpec.constructLinkerTasks(cbc, delegate, libraries: [], usedTools: [:])

            // Check the results.
            let task = try #require(delegate.shellTasks.only)
            task.checkCommandLineContains(["-r"])
            task.checkCommandLineContainsUninterrupted(["-target", "\(arch)-apple-macos13.0"])
            task.checkCommandLineDoesNotContain("-no_adhoc_codesign")
        }
    }

    @Test
    func libtoolTaskConstruction() async throws {
        let core = try await getCore()
        let librarianSpec: LinkerSpec = try core.specRegistry.getSpec() as LibtoolLinkerSpec

        // Create the mock table.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("LIBTOOL") as? PathMacroDeclaration), literal: "libtool")
        table.push(BuiltinMacros.LIBTOOL_USE_RESPONSE_FILE, literal: true)
        table.push(BuiltinMacros.arch, literal: "x86_64")
        table.push(BuiltinMacros.variant, literal: "normal")

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.library.static", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockScope = MacroEvaluationScope(table: table)
        let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
        let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/obj/normal/x86_64/file1.o"), fileType: mockFileType)], output: Path.root.join("tmp/obj/normal/x86_64/output"))
        let libraries = [
            LinkerSpec.LibrarySpecifier(kind: .static, path: Path.root.join("usr/lib/libfoo1.a"), mode: .normal, useSearchPaths: true, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .static, path: Path.root.join("usr/lib/libfoo2.a"), mode: .weak, useSearchPaths: true, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .static, path: Path.root.join("usr/lib/libfoo3.a"), mode: .normal, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .static, path: Path.root.join("usr/lib/libfoo4.a"), mode: .weak, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),

            LinkerSpec.LibrarySpecifier(kind: .dynamic, path: Path.root.join("usr/lib/libbar1.dylib"), mode: .normal, useSearchPaths: true, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .dynamic, path: Path.root.join("usr/lib/libbar2.dylib"), mode: .weak, useSearchPaths: true, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .dynamic, path: Path.root.join("usr/lib/libbar3.dylib"), mode: .normal, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .dynamic, path: Path.root.join("usr/lib/libbar4.dylib"), mode: .weak, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),

            LinkerSpec.LibrarySpecifier(kind: .textBased, path: Path.root.join("usr/lib/libbaz1.tbd"), mode: .normal, useSearchPaths: true, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .textBased, path: Path.root.join("usr/lib/libbaz2.tbd"), mode: .weak, useSearchPaths: true, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .textBased, path: Path.root.join("usr/lib/libbaz3.tbd"), mode: .normal, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .textBased, path: Path.root.join("usr/lib/libbaz4.tbd"), mode: .weak, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),

            LinkerSpec.LibrarySpecifier(kind: .framework, path: Path.root.join("tmp/Foo1.framework"), mode: .normal, useSearchPaths: true, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .framework, path: Path.root.join("tmp/Foo2.framework"), mode: .weak, useSearchPaths: true, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .framework, path: Path.root.join("tmp/Foo3.framework"), mode: .normal, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
            LinkerSpec.LibrarySpecifier(kind: .framework, path: Path.root.join("tmp/Foo4.framework"), mode: .weak, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),

            // This is a no-op because object files get added in the SourcesTaskProducer, but we want to confirm that this is the case.
            LinkerSpec.LibrarySpecifier(kind: .object, path: Path.root.join("tmp/Bar.o"), mode: .normal, useSearchPaths: false, swiftModulePaths: [:], swiftModuleAdditionalLinkerArgResponseFilePaths: [:]),
        ]
        await librarianSpec.constructLinkerTasks(cbc, delegate, libraries: libraries, usedTools: [:])

        // There should be exactly one shell task.
        #expect(delegate.shellTasks.count == 1)
        let task = try #require(delegate.shellTasks[safe: 0])
        #expect(task.ruleInfo == ["Libtool", Path.root.join("tmp/obj/normal/x86_64/output").str, "normal", "x86_64"])
        #expect(task.execDescription == "Create static library output")
        // FIXME: This still has a lot of issues.
        task.checkCommandLine([
            "libtool", "-static", "-arch_only", "x86_64",
            // libtool doesn't support weak linkage, so libraries and frameworks marked as weak are passed normally
            "-lfoo1", "-lfoo2", Path.root.join("usr/lib/libfoo3.a").str, Path.root.join("usr/lib/libfoo4.a").str,
            // dylibs are not passed
            // tbd files are not passed
            "-framework", "Foo1", "-framework", "Foo2", Path.root.join("tmp/Foo3.framework/Foo3").str, Path.root.join("tmp/Foo4.framework/Foo4").str,
            "-o", Path.root.join("tmp/obj/normal/x86_64/output").str])
        // FIXME: The input here should really be the link file list.
        task.checkInputs([
            .path(Path.root.join("tmp/obj/normal/x86_64/file1.o").str),
            .path(Path.root.join("usr/lib/libfoo3.a").str),
            .path(Path.root.join("usr/lib/libfoo4.a").str)
        ])
        task.checkOutputs([
            .path(Path.root.join("tmp/obj/normal/x86_64/output").str)
        ])
    }

    @Test
    func linkerPathOverrides() async throws {
        let core = try await getCore()
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CommandLineToolSpec
        let spec: LinkerSpec = try core.specRegistry.getSpec() as LdLinkerSpec
        let fileTypes = [
            ".c": try core.specRegistry.getSpec("sourcecode.c.c") as FileTypeSpec,
            ".cpp": try core.specRegistry.getSpec("sourcecode.cpp.cpp") as FileTypeSpec,
        ]

        func check(name: String, expectedLinker: String, macros: [StringMacroDeclaration: String], sourceLocation: SourceLocation = #_sourceLocation) async throws {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            for (macro, value) in macros {
                table.push(macro, literal: value)
            }
            // We have to push this manually, since we do not have a real Setting's constructed scope.
            table.push(BuiltinMacros.PER_ARCH_LD, BuiltinMacros.namespace.parseString("$(LD_$(CURRENT_ARCH))"))
            table.push(BuiltinMacros.PER_ARCH_LDPLUSPLUS, BuiltinMacros.namespace.parseString("$(LDPLUSPLUS_$(CURRENT_ARCH))"))
            let mockScope = MacroEvaluationScope(table: table)

            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [], output: .null)
            await spec.constructLinkerTasks(cbc, delegate, libraries: [], usedTools: [clangSpec: Set([fileTypes[Path(name).fileSuffix]!])])
            #expect(delegate.shellTasks.count == 1)
            #expect(delegate.shellTasks[safe: 0]?.commandLine[safe: 0]?.asString == expectedLinker)
        }

        // Check with just LD.
        for (name, expected) in [("file.c", "SomeCLinker"), ("file.cpp", "clang++")] {
            try await check(name: name, expectedLinker: expected, macros: [
                BuiltinMacros.LD: "SomeCLinker"
                // NOTE: One wonders whether this shouldn't change the C++ linker.
            ])
        }

        // Check with LD & LDPLUSPLUS.
        for (name, expected) in [("file.c", "SomeCLinker"), ("file.cpp", "SomeC++Linker")] {
            try await check(name: name, expectedLinker: expected, macros: [
                BuiltinMacros.LD: "SomeCLinker",
                BuiltinMacros.LDPLUSPLUS: "SomeC++Linker"
            ])
        }

        // Check with arch specific LD.
        for (name, expected) in [("file.c", "SomeCLinker_x86_64"), ("file.cpp", "SomeC++Linker_x86_64")] {
            try await check(name: name, expectedLinker: expected, macros: [
                BuiltinMacros.CURRENT_ARCH: "x86_64",
                try core.specRegistry.internalMacroNamespace.declareStringMacro("LD_x86_64"): "SomeCLinker_x86_64",
                try core.specRegistry.internalMacroNamespace.declareStringMacro("LDPLUSPLUS_x86_64"): "SomeC++Linker_x86_64"
            ])
        }
    }

    /// Test the `AdditionalLinkerArgs` property of compiler build options.
    ///
    /// Previously this used `CLANG_CXX_LIBRARY` which exercised `<<otherwise>>`and `$(value)` behavior in the property, but that setting has been deprecated and there is presently no other setting which uses those behaviors.
    @Test
    func additionalLinkerArgs() async throws {
        let core = try await getCore()
        let linkerSpec: LinkerSpec = try core.specRegistry.getSpec() as LdLinkerSpec
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CommandLineToolSpec
        let objcFileTypeSpec = try core.specRegistry.getSpec("sourcecode.c.objc") as FileTypeSpec
        let macroName = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("LLVM_LTO") as? StringMacroDeclaration)

        let macroValues = [
            "",
            "YES",
            "YES_THIN",
            "NO",
        ]

        for value in macroValues {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(BuiltinMacros.arch, literal: "arm64e")
            table.push(BuiltinMacros.variant, literal: "normal")
            table.push(macroName, literal: value)
            let mockScope = MacroEvaluationScope(table: table)
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/obj/normal/arm64e/file1.o"), fileType: objcFileTypeSpec)], output: Path.root.join("tmp/obj/normal/arm64e/output"))

            await linkerSpec.constructLinkerTasks(cbc, delegate, libraries: [], usedTools: [clangSpec: Set([objcFileTypeSpec])])

            #expect(delegate.shellTasks.count == 1)
            let flag = "-flto=thin"
            if value == "YES_THIN" {
                // For 'YES_THIN' there should be additional linker args.
                #expect(delegate.shellTasks[safe: 0]?.commandLine.contains(.literal(ByteString(encodingAsUTF8: flag))) ?? false, "linker command line does not contain \(flag)")
                // We're not checking the other stuff that's added by YES_THIN.
            }
            else {
                // For all other values, there should not be additional linker args.
                #expect((delegate.shellTasks[safe: 0]?.commandLine.contains(.literal(ByteString(encodingAsUTF8: flag))) ?? false) == false, "linker command line unexpectedly contains \(flag)")
            }
        }
    }

    @Test
    func copyTaskConstruction() async throws {
        let core = try await getCore()
        let copySpec = try core.specRegistry.getSpec() as CopyToolSpec

        // Create the mock table. Note that the defaults from the spec are *not* added to this table.
        var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        table.push(BuiltinMacros.REMOVE_SVN_FROM_RESOURCES, literal: true)
        table.push(BuiltinMacros.REMOVE_HG_FROM_RESOURCES, literal: true)
        table.push(BuiltinMacros.PBXCP_STRIP_UNSIGNED_BINARIES, literal: true)

        do {
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/file-to-copy"), fileType: mockFileType)], output: Path.root.join("tmp/dst/file-to-copy"))
            await copySpec.constructCopyTasks(cbc, delegate)

            // There should be exactly one shell task.
            #expect(delegate.shellTasks.count == 1)
            let task = try #require(delegate.shellTasks[safe: 0])
            #expect(task.ruleInfo == ["Copy", Path.root.join("tmp/dst/file-to-copy").str, Path.root.join("tmp/file-to-copy").str])
            #expect(task.execDescription == "Copy file-to-copy")
            // FIXME: Implement.
            task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", ".svn", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-tool", "strip", "-resolve-src-symlinks", Path.root.join("tmp/file-to-copy").str, Path.root.join("tmp/dst").str])
            task.checkInputs([.path(Path.root.join("tmp/file-to-copy").str)])
            task.checkOutputs([.path(Path.root.join("tmp/dst/file-to-copy").str)])
        }

        do {
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/file-to-copy"), fileType: mockFileType)], output: Path.root.join("tmp/dst/file-to-copy"))
            await copySpec.constructCopyTasks(cbc, delegate, removeHeaderDirectories: true)

            // There should be exactly one shell task.
            #expect(delegate.shellTasks.count == 1)
            let task = try #require(delegate.shellTasks[safe: 0])
            #expect(task.ruleInfo == ["Copy", Path.root.join("tmp/dst/file-to-copy").str, Path.root.join("tmp/file-to-copy").str])
            #expect(task.execDescription == "Copy file-to-copy")
            // FIXME: Implement.
            task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", ".svn", "-exclude", ".hg", "-exclude", "Headers", "-exclude", "PrivateHeaders", "-exclude", "Modules", "-exclude", "*.tbd", "-strip-unsigned-binaries", "-strip-tool", "strip", "-resolve-src-symlinks", Path.root.join("tmp/file-to-copy").str, Path.root.join("tmp/dst").str])
            task.checkInputs([.path(Path.root.join("tmp/file-to-copy").str)])
            task.checkOutputs([.path(Path.root.join("tmp/dst/file-to-copy").str)])
        }

        do {
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let mockScope = MacroEvaluationScope(table: table)
            let mockFileType = try core.specRegistry.getSpec("file") as FileTypeSpec
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/file-to-copy"), fileType: mockFileType)], output: Path.root.join("tmp/dst/file-to-copy"))
            await copySpec.constructCopyTasks(cbc, delegate, ignoreMissingInputs: true)

            // There should be exactly one shell task.
            #expect(delegate.shellTasks.count == 1)
            let task = try #require(delegate.shellTasks[safe: 0])
            #expect(task.ruleInfo == ["Copy", Path.root.join("tmp/dst/file-to-copy").str, Path.root.join("tmp/file-to-copy").str])
            #expect(task.execDescription == "Copy file-to-copy")
            // FIXME: Implement.
            task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", ".svn", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-tool", "strip", "-resolve-src-symlinks", "-ignore-missing-inputs", Path.root.join("tmp/file-to-copy").str, Path.root.join("tmp/dst").str])
            task.checkInputs([.path(Path.root.join("tmp/file-to-copy").str)])
            task.checkOutputs([.path(Path.root.join("tmp/dst/file-to-copy").str)])
        }
    }

    @Test
    func touchTaskConstruction() async throws {
        let core = try await getCore()
        let touchSpec = try #require(core.specRegistry.getSpec("com.apple.tools.touch") as? CommandLineToolSpec)

        let table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        let scope = MacroEvaluationScope(table: table)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let mockFileType = try #require(core.specRegistry.getSpec("file") as? FileTypeSpec)
        let cbc = CommandBuildContext(producer: producer, scope: scope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input"), fileType: mockFileType)])
        await touchSpec.constructTasks(cbc, delegate)

        // There should be exactly one shell task.
        #expect(delegate.shellTasks.count == 1)
        let task = try #require(delegate.shellTasks[safe: 0])
        #expect(task.ruleInfo == ["Touch", Path.root.join("tmp/input").str])
        #expect(task.execDescription == "Touch input")
        if core.hostOperatingSystem == .windows {
            let commandShellPath = try #require(getEnvironmentVariable("ComSpec"), "Can't determine path to cmd.exe because the ComSpec environment variable is not set")
            task.checkCommandLine([commandShellPath, "/c", "copy /b \"\(Path.root.join("tmp/input").str)\" +,,"])
        } else {
            task.checkCommandLine(["/usr/bin/touch", "-c", Path.root.join("tmp/input").str])
        }
        #expect(task.execDescription == "Touch input")
    }

    @Test
    func symlinkTaskConstruction() async throws {
        let core = try await getCore()
        let symlinkSpec = try #require(core.specRegistry.getSpec("com.apple.tools.symlink") as? SymlinkToolSpec)

        let table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        let scope = MacroEvaluationScope(table: table)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let cbc = CommandBuildContext(producer: producer, scope: scope, inputs: [], output: Path.root.join("tmp/symlink"))
        symlinkSpec.constructSymlinkTask(cbc, delegate, toPath: Path.root.join("tmp/original"))

        // There should be exactly one shell task.
        #expect(delegate.shellTasks.count == 1)
        let task = try #require(delegate.shellTasks[safe: 0])
        #expect(task.ruleInfo == ["SymLink", Path.root.join("tmp/symlink").str, Path.root.join("tmp/original").str])
        task.checkCommandLine(["/bin/ln", "-sfh", Path.root.join("tmp/original").str, Path.root.join("tmp/symlink").str])
        #expect(task.execDescription == "Make symlink symlink")
    }

    @Test
    func mkdirTaskConstruction() async throws {
        let core = try await getCore()
        let mkdirSpec = try #require(core.specRegistry.getSpec("com.apple.tools.mkdir") as? MkdirToolSpec)

        let table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
        let scope = MacroEvaluationScope(table: table)

        let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
        let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
        let cbc = CommandBuildContext(producer: producer, scope: scope, inputs: [], output: Path.root.join("tmp/directory"))
        await mkdirSpec.constructTasks(cbc, delegate)

        // There should be exactly one shell task.
        #expect(delegate.shellTasks.count == 1)
        let task = try #require(delegate.shellTasks[safe: 0])
        #expect(task.ruleInfo == ["MkDir", Path.root.join("tmp/directory").str])
        task.checkCommandLine(["/bin/mkdir", "-p", Path.root.join("tmp/directory").str])
        #expect(task.execDescription == "Create directory directory")
    }

    @Test(.skipHostOS(.windows, "Optional(\"$(TARGET_BUILD_DIR)\")\") is not equal to (\"Optional(\"\")"))
    func inputOutputLookup() async throws {
        func test(macro: MacroDeclaration, numberOfInputs: Int = 0, output: Bool = false, expectation: String, expectedErrors: [String] = [], expectedNotes: [String] = [], macrosToPush: [MacroDeclaration] = [], sourceLocation: SourceLocation = #_sourceLocation) async throws {

            // any spec is fine, we're testing the lookup function
            let delegate = TestingCoreDelegate()
            let core = try await Self.makeCore(simulatedInferiorProductsPath: nil, delegate)
            let spec: CommandLineToolSpec = try core.specRegistry.getSpec("com.apple.tools.touch")

            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let namespace = BuiltinMacros.namespace
            var table = MacroValueAssignmentTable(namespace: namespace)
            for macro in macrosToPush {
                table.push(macro, namespace.parseLiteralString(Path.root.join("tmp").str))
            }
            let scope = MacroEvaluationScope(table: table)
            let mockFileType = try #require(core.specRegistry.getSpec("file") as? FileTypeSpec)
            let cbc = CommandBuildContext(producer: producer, scope: scope, inputs: (0..<numberOfInputs).map({ FileToBuild(absolutePath: Path.root.join("tmp/file\($0 + 1).c"), fileType: mockFileType) }), output: output ? Path.root.join("tmp/output.c") : nil)
            #expect(spec.lookup(macro, cbc, core.delegate)?.asLiteralString == expectation)

            func formattedDiagnostics(_ behavior: Diagnostic.Behavior) -> [String] {
                return delegate.diagnostics.compactMap { element -> String? in
                    guard element.behavior == behavior else { return nil }
                    return element.formatLocalizedDescription(.messageOnly)
                }
            }

            #expect(formattedDiagnostics(.error) == expectedErrors)
            #expect(formattedDiagnostics(.note) == expectedNotes)
        }

        // test input file error check
        for macro in [BuiltinMacros.InputFile, BuiltinMacros.InputFilePath, BuiltinMacros.InputPath, BuiltinMacros.InputFileDir, BuiltinMacros.InputFileName, BuiltinMacros.InputFileBase, BuiltinMacros.InputFileRegionPathComponent, BuiltinMacros.InputFileRelativePath, BuiltinMacros.InputFileSuffix] {
            try await test(macro: macro, numberOfInputs: 0, expectation: "", expectedErrors: ["Unexpected use of \(macro.name) in a task with no inputs in spec com.apple.tools.touch."])
        }

        for macro in [BuiltinMacros.OutputFileBase, BuiltinMacros.OutputPath, BuiltinMacros.OutputFile] {
            try await test(macro: macro, output: false, expectation: "", expectedErrors: ["Unexpected use of \(macro.name) in a task with no outputs in spec com.apple.tools.touch."])
        }

        // FIXME: It would be better to report 'Unexpected use of OutputRelativePath' here.
        try await test(macro: BuiltinMacros.OutputRelativePath, output: false, expectation: "", expectedErrors: ["Unexpected use of OutputPath in a task with no outputs in spec com.apple.tools.touch."])

        // input file macros
        try await test(macro: BuiltinMacros.InputFile, numberOfInputs: 1, expectation: Path.root.join("tmp/file1.c").str)
        try await test(macro: BuiltinMacros.InputFile, numberOfInputs: 2, expectation: Path.root.join("tmp/file1.c").str)
        try await test(macro: BuiltinMacros.InputFile, numberOfInputs: 2_000, expectation: Path.root.join("tmp/file1.c").str)
        try await test(macro: BuiltinMacros.InputFilePath, numberOfInputs: 1, expectation: Path.root.join("tmp/file1.c").str)
        try await test(macro: BuiltinMacros.InputPath, numberOfInputs: 1, expectation: Path.root.join("tmp/file1.c").str)
        try await test(macro: BuiltinMacros.InputFileDir, numberOfInputs: 1, expectation: Path.root.join("tmp").str)
        try await test(macro: BuiltinMacros.InputFileName, numberOfInputs: 1, expectation: "file1.c")
        try await test(macro: BuiltinMacros.InputFileBase, numberOfInputs: 1, expectation: "file1")
        // region path component falls back to "" if no region path component
        try await test(macro: BuiltinMacros.InputFileRegionPathComponent, numberOfInputs: 1, expectation: "")
        // FIXME: Implement properly. rdar://problem/58833499
        try await test(macro: BuiltinMacros.InputFileRelativePath, numberOfInputs: 1, expectation: Path.root.join("tmp/file1.c").str)
        try await test(macro: BuiltinMacros.InputFileSuffix, numberOfInputs: 1, expectation: ".c")
        try await test(macro: BuiltinMacros.InputFileTextEncoding, numberOfInputs: 1, expectation: "")

        try await test(macro: BuiltinMacros.OutputFileBase, output: true, expectation: "output")
        try await test(macro: BuiltinMacros.OutputPath, output: true, expectation: Path.root.join("tmp/output.c").str)
        try await test(macro: BuiltinMacros.OutputFile, output: true, expectation: Path.root.join("tmp/output.c").str)
        try await test(macro: BuiltinMacros.OutputRelativePath, output: true, expectation: Path.root.join("tmp/output.c").str)
        try await test(macro: BuiltinMacros.OutputRelativePath, output: true, expectation: "$(DERIVED_DATA_DIR)/output.c", macrosToPush: [BuiltinMacros.DERIVED_DATA_DIR])
        try await test(macro: BuiltinMacros.OutputRelativePath, output: true, expectation: "$(SYMROOT)/output.c", macrosToPush: [BuiltinMacros.SYMROOT])
        try await test(macro: BuiltinMacros.OutputRelativePath, output: true, expectation: "$(OBJROOT)/output.c", macrosToPush: [BuiltinMacros.OBJROOT])
        try await test(macro: BuiltinMacros.OutputRelativePath, output: true, expectation: "$(OBJROOT)/output.c", macrosToPush: [BuiltinMacros.OBJROOT, BuiltinMacros.DERIVED_DATA_DIR])

        // we're not mocking those to test actual results but check for no diagnostics
        try await test(macro: BuiltinMacros.ProductResourcesDir, numberOfInputs: 1, output: true, expectation: "")
        try await test(macro: BuiltinMacros.TempResourcesDir, numberOfInputs: 1, output: true, expectation: "")
        try await test(macro: BuiltinMacros.UnlocalizedProductResourcesDir, numberOfInputs: 1, output: true, expectation: "")
        try await test(macro: BuiltinMacros.build_file_compiler_flags, numberOfInputs: 1, expectation: "")
    }

    @Test
    func clangDepscanPrefixMap() async throws {
        let core = try await getCore()
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CommandLineToolSpec
        let mockFileType = try core.specRegistry.getSpec("sourcecode.cpp.cpp") as FileTypeSpec
        let enableCompileCache = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("CLANG_ENABLE_COMPILE_CACHE") as? BooleanMacroDeclaration)
        let enablePrefixMap = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("CLANG_ENABLE_PREFIX_MAPPING") as? BooleanMacroDeclaration)
        let prefixMaps = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("CLANG_OTHER_PREFIX_MAPPINGS") as? StringListMacroDeclaration)
        let devDir = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("DEVELOPER_DIR") as? PathMacroDeclaration)

        func test(caching: Bool, prefixMapping: Bool, extraMaps: [String], completion: ([String]) throws -> Void) async throws {
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            table.push(enableCompileCache, literal: caching)
            table.push(enablePrefixMap, literal: prefixMapping)
            table.push(prefixMaps, literal: extraMaps)
            table.push(devDir, literal: "/Xcode.app/Contents/Developer")
            let mockScope = MacroEvaluationScope(table: table)
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input.cpp"), fileType: mockFileType)], output: nil)
            await clangSpec.constructTasks(cbc, delegate)

            #expect(delegate.shellTasks.count == 1)
            let task = try #require(delegate.shellTasks[safe: 0])
            #expect(task.execDescription == "Compile input.cpp")
            let prefixMaps = task.commandLine.map(\.asString).filter { $0.starts(with: "-fdepscan-prefix-map") }
            try completion(prefixMaps)
        }

        try await test(caching: false, prefixMapping: true, extraMaps: ["/a=/b"], completion: { args in
            #expect(args == [])
        })
        try await test(caching: true, prefixMapping: false, extraMaps: ["/a=/b"], completion: { args in
            #expect(args == [])
        })
        try await test(caching: true, prefixMapping: true, extraMaps: [], completion: { args in
            #expect(args == [
                "-fdepscan-prefix-map-sdk=/^sdk",
                "-fdepscan-prefix-map-toolchain=/^toolchain",
                "-fdepscan-prefix-map=/Xcode.app/Contents/Developer=/^xcode",
            ])
        })
        try await test(caching: true, prefixMapping: true, extraMaps: ["/a=/b", "/c=/d"], completion: { args in
            #expect(args == [
                "-fdepscan-prefix-map-sdk=/^sdk",
                "-fdepscan-prefix-map-toolchain=/^toolchain",
                "-fdepscan-prefix-map=/Xcode.app/Contents/Developer=/^xcode",
                "-fdepscan-prefix-map=/a=/b",
                "-fdepscan-prefix-map=/c=/d",
            ])
        })
    }

    @Test
    func swiftCachingPrefixMap() async throws {
        let core = try await getCore()
        let swiftSpec = try core.specRegistry.getSpec("com.apple.xcode.tools.swift.compiler") as CompilerSpec

        let mockFileType = try core.specRegistry.getSpec("sourcecode.swift") as FileTypeSpec
        let enableCompileCache = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("SWIFT_ENABLE_COMPILE_CACHE") as? BooleanMacroDeclaration)
        let enablePrefixMap = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("SWIFT_ENABLE_PREFIX_MAPPING") as? BooleanMacroDeclaration)
        let prefixMaps = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("SWIFT_OTHER_PREFIX_MAPPINGS") as? StringListMacroDeclaration)
        let devDir = try #require(core.specRegistry.internalMacroNamespace.lookupMacroDeclaration("DEVELOPER_DIR") as? PathMacroDeclaration)

        func test(caching: Bool, prefixMapping: Bool, extraMaps: [String], completion: ([String]) throws -> Void) async throws {
            // Create the mock table.
            var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
            try await table.push(BuiltinMacros.SWIFT_EXEC, literal: self.swiftCompilerPath.str)
            if core.hostOperatingSystem == .macOS {
                try await table.push(BuiltinMacros.TAPI_EXEC, literal: self.tapiToolPath.str)
            }
            table.push(BuiltinMacros.TARGET_NAME, literal: "App1")
            table.push(BuiltinMacros.BUILT_PRODUCTS_DIR, literal: Path.root.join("build").str)
            table.push(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR, literal: Path.root.join("build/objects").str)
            table.push(BuiltinMacros.SWIFT_MODULE_NAME, literal: "MyModule")
            table.push(BuiltinMacros.SWIFT_RESPONSE_FILE_PATH,  core.specRegistry.internalMacroNamespace.parseString("$(PER_ARCH_OBJECT_FILE_DIR)/$(TARGET_NAME).SwiftFileList"))

            // remove in rdar://53000820
            table.push(BuiltinMacros.USE_SWIFT_RESPONSE_FILE, literal: true)
            table.push(enableCompileCache, literal: caching)
            table.push(enablePrefixMap, literal: prefixMapping)
            table.push(prefixMaps, literal: extraMaps)
            table.push(devDir, literal: "/Xcode.app/Contents/Developer")
            let mockScope = MacroEvaluationScope(table: table)
            let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
            let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
            let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/input.swift"), fileType: mockFileType)], output: nil)
            await swiftSpec.constructTasks(cbc, delegate)

            // Get the Swift task itself.
            let tasks = delegate.shellTasks.filter { $0.ruleInfo[0] == "CompileSwiftSources" }
            #expect(tasks.count == 1)
            let swiftTask = try #require(tasks.first)
            #expect(swiftTask.execDescription == "Compile Swift source files")
            var previousArgIsPrefixMap = false
            let prefixMaps = swiftTask.commandLine.map(\.asString).filter {
                let isPrefixMap = $0.starts(with: "-scanner-prefix-map")
                let shouldAdd = isPrefixMap || previousArgIsPrefixMap
                previousArgIsPrefixMap = isPrefixMap
                return shouldAdd
            }
            try completion(prefixMaps)
        }

        try await test(caching: false, prefixMapping: true, extraMaps: ["/a=/b"], completion: { args in
            #expect(args == [])
        })
        try await test(caching: true, prefixMapping: false, extraMaps: ["/a=/b"], completion: { args in
            #expect(args == [])
        })
        try await test(caching: true, prefixMapping: true, extraMaps: [], completion: { args in
            #expect(args == [
                "-scanner-prefix-map-sdk", "/^sdk",
                "-scanner-prefix-map-toolchain", "/^toolchain",
                "-scanner-prefix-map", "/Xcode.app/Contents/Developer=/^xcode",
            ])
        })
        try await test(caching: true, prefixMapping: true, extraMaps: ["/a=/b", "/c=/d"], completion: { args in
            #expect(args == [
                "-scanner-prefix-map-sdk", "/^sdk",
                "-scanner-prefix-map-toolchain", "/^toolchain",
                "-scanner-prefix-map", "/Xcode.app/Contents/Developer=/^xcode",
                "-scanner-prefix-map", "/a=/b",
                "-scanner-prefix-map", "/c=/d",
            ])
        })
    }

}


// MARK: CommandLineSpecSimulatedTests

@Suite fileprivate struct CommandLineSpecSimulatedTests: CoreBasedTests {
    struct DiscoveredThingToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
        public let toolPath: Path
        public let toolVersion: Version?

        func hasFeature(_ feature: String) -> Bool {
            return feature.starts(with: "test-feature")
        }
    }

    final class ThingToolSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
        static let identifier = "com.apple.compilers.thing_processor"

        override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
            return DiscoveredThingToolSpecInfo(toolPath: Path("thing"), toolVersion: Version(9, 0, 3))
        }
    }

    // Write the test data to the temporary directory.
    static private func writeTestData(to dir: Path, fs: any FSProxy) async throws {
        let options: [[String: PropertyListItem]] = [
            // A setting which always emits an option.
            [
                "Name": "THING_ALWAYS",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "CommandLineFlag": "-always",
            ],

            // Options to test supported version ranges.
            [
                "Name": "THING_RECENTLY_ADDED",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "SupportedVersionRanges": [ "9.0.0" ],
                "CommandLineFlag": "-recently_added",
            ],
            [
                "Name": "THING_JUST_ADDED",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "SupportedVersionRanges": [ "9.0.3" ],
                "CommandLineFlag": "-just_added",
            ],
            [
                "Name": "THING_NOT_YET_ADDED",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "SupportedVersionRanges": [ "9.2.0" ],
                "CommandLineFlag": "-not_yet_added",
            ],
            [
                "Name": "THING_RECENTLY_ADDED_RANGE",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "SupportedVersionRanges": [ ["9.0.2", "9.1.99"], "9.2.2" ],
                "CommandLineFlag": "-recently_added_range",
            ],
            [
                "Name": "THING_NOT_YET_ADDED_RANGE",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "SupportedVersionRanges": [ ["9.1.2", "9.1.99"], "9.3.2" ],
                "CommandLineFlag": "-not_yet_added_range",
            ],

            // Options to test feature flags.
            [
                "Name": "THING_BEHIND_ONE_EXISTING_FLAG",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "FeatureFlags": "test-feature",
                "CommandLineFlag": "-feature_exists",
            ],
            [
                "Name": "THING_BEHIND_MULTIPLE_EXISTING_FLAGS",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "FeatureFlags": [ "test-feature", "test-feature-2" ],
                "CommandLineFlag": "-feature2_exists",
            ],
            [
                "Name": "THING_BEHIND_MISSING_FLAG",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "FeatureFlags": "missing-test-feature",
                "CommandLineFlag": "-missing_feature",
            ],
            [
                "Name": "THING_BEHIND_MISSING_FLAGS",
                "Type": "Boolean",
                "DefaultValue": "YES",
                "FeatureFlags": [ "test-feature", "missing-test-feature" ],
                "CommandLineFlag": "-missing_features",
            ],
        ]

        let thingSpecData: [[String: PropertyListItem]] = [
            // The tool spec will get loaded as a GenericCommandLineToolSpec.
            [
                "Identifier": .plString(ThingToolSpec.identifier),
                "Type": "Tool",
                "Name": "Thing Compiler",
                "Description": "Thing Compiler",
                "CommandLine": "thing [options] [input] -o [output]",
                "RuleName": "Thingify $(InputFile)",
                "InputFileTypes": [
                    "file.thing",
                ],
                "Outputs": [
                    "$(ProductResourcesDir)/$(InputFileBase).something",
                    "$(UnlocalizedProductResourcesDir)/$(InputFileRegionPathComponent)$(InputFileBase).somethingelse"
                ],
                "SynthesizeBuildRule": "YES",
                "Options": PropertyListItem(options)
            ],
            // The input file type.
            [
                "Identifier": "file.thing",
                "Type": "FileType",
                "BasedOn": "text",
                "Extensions": ["thing"],
            ],
        ]
        try await fs.writePlist(dir.join("Thing.xcspec"), thingSpecData)
    }

    @Test
    func simulatedCommandLineToolSpec() async throws {
        let fs = localFS
        try await withTemporaryDirectory(fs: fs) { tmpDir in
            try await Self.writeTestData(to: tmpDir.path, fs: fs)

            let core = try await Self.makeCore(registerExtraPlugins: { pluginManager in
                struct TestPlugin: SpecificationsExtension {
                    func specificationClasses() -> [any SpecIdentifierType.Type] {
                        [ThingToolSpec.self]
                    }
                }
                pluginManager.register(TestPlugin(), type: SpecificationsExtensionPoint.self)
            }, simulatedInferiorProductsPath: tmpDir.path)

            do {
                // Get the tool spec.
                let thingSpec = try core.specRegistry.getSpec(ThingToolSpec.identifier) as ThingToolSpec

                // Create a table with the unioned tool defaults, and any other values we want to add.
                var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
                table.pushContentsOf(core.coreSettings.unionedToolDefaults(domain: "").table)
                // Push other settings into the table here as desired.

                // Construct the task.
                let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
                let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
                let mockScope = MacroEvaluationScope(table: table)
                let mockFileType = try core.specRegistry.getSpec("file.thing") as FileTypeSpec
                let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/file.thing"), fileType: mockFileType)], output: Path.root.join("tmp/dst/file.something"), resourcesDir: Path.root.join("tmp/dst"), unlocalizedResourcesDir: Path.root.join("tmp/dst"))
                await thingSpec.constructTasks(cbc, delegate)

                // There should be exactly one task task.
                guard let task = delegate.shellTasks.first else {
                    Issue.record("No tasks were created")
                    return
                }
                #expect(task.ruleInfo == ["Thingify", Path.root.join("tmp/file.thing").str])
                task.checkCommandLine([             "thing",
                                                    // Options
                                                    "-always",
                                                    "-recently_added",
                                                    "-just_added",
                                                    "-recently_added_range",
                                                    "-feature_exists",
                                                    "-feature2_exists",
                                                    // Inputs and outputs
                                                    Path.root.join("tmp/file.thing").str,
                                                    "-o",
                                                    Path.root.join("tmp/dst/file.something").str,
                                      ])
                task.checkInputs([
                    .path(Path.root.join("tmp/file.thing").str)
                ])
                task.checkOutputs([
                    .path(Path.root.join("tmp/dst/file.something").str),
                    .path(Path.root.join("tmp/dst/file.somethingelse").str)
                ])
            }

            do {
                // Get the tool spec.
                let thingSpec = try core.specRegistry.getSpec(ThingToolSpec.identifier) as ThingToolSpec

                // Create a table with the unioned tool defaults, and any other values we want to add.
                var table = MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
                table.pushContentsOf(core.coreSettings.unionedToolDefaults(domain: "").table)
                // Push other settings into the table here as desired.

                // Construct the task.
                let producer = try MockCommandProducer(core: core, productTypeIdentifier: "com.apple.product-type.framework", platform: "macosx")
                let delegate = try CapturingTaskGenerationDelegate(producer: producer, userPreferences: .defaultForTesting)
                let mockScope = MacroEvaluationScope(table: table)
                let mockFileType = try core.specRegistry.getSpec("file.thing") as FileTypeSpec
                let cbc = CommandBuildContext(producer: producer, scope: mockScope, inputs: [FileToBuild(absolutePath: Path.root.join("tmp/file.thing"), fileType: mockFileType, regionVariantName: "en")], output: Path.root.join("tmp/dst/file.something"), resourcesDir: Path.root.join("tmp/dst/en.lproj"), unlocalizedResourcesDir: Path.root.join("tmp/dst"))
                await thingSpec.constructTasks(cbc, delegate)

                // There should be exactly one task task.
                guard let task = delegate.shellTasks.first else {
                    Issue.record("No tasks were created")
                    return
                }
                #expect(task.ruleInfo == ["Thingify", Path.root.join("tmp/file.thing").str])
                task.checkCommandLine([
                    "thing",
                    // Options
                    "-always",
                    "-recently_added",
                    "-just_added",
                    "-recently_added_range",
                    "-feature_exists",
                    "-feature2_exists",
                    // Inputs and outputs
                    Path.root.join("tmp/file.thing").str,
                    "-o",
                    Path.root.join("tmp/dst/en.lproj/file.something").str,
                ])
                task.checkInputs([
                    .path(Path.root.join("tmp/file.thing").str)
                ])
                task.checkOutputs([
                    .path(Path.root.join("tmp/dst/en.lproj/file.something").str),
                    .path(Path.root.join("tmp/dst/en.lproj/file.somethingelse").str)
                ])
            }
        }
    }
}
