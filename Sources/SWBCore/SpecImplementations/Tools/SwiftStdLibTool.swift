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

import SWBUtil
public import SWBMacro

public final class SwiftStdLibToolSpec : GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.swift-stdlib-tool"

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    /// Construct a new task to run the Swift standard library tool.
    public func constructSwiftStdLibraryToolTask(_ cbc:CommandBuildContext, _ delegate: any TaskGenerationDelegate, foldersToScan: MacroStringListExpression?, filterForSwiftOS: Bool, backDeploySwiftConcurrency: Bool) async {
        precondition(cbc.outputs.isEmpty, "Unexpected output paths \(cbc.outputs.map { "'\($0.str)'" }) passed to \(type(of: self)).")

        let input = cbc.input

        let wrapperPathString = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.WRAPPER_NAME))
        let wrapperPathMacroExpression = cbc.scope.namespace.parseLiteralString(wrapperPathString.str)

        // Create a lookup closure for build setting overrides.
        let lookup: ((MacroDeclaration) -> MacroExpression?) =
        { macro in
            switch macro
            {
            case BuiltinMacros.SWIFT_STDLIB_TOOL_FOLDERS_TO_SCAN:
                return foldersToScan

            case BuiltinMacros.OutputPath, BuiltinMacros.OutputFile:
                return wrapperPathMacroExpression

            default:
                return nil
            }
        }

        // Compute the rule info.
        let ruleInfo = defaultRuleInfo(cbc, delegate, lookup: lookup)

        // Compute the command line.
        var commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate), lookup: lookup).map(\.asString)

        // Bitcode is no longer supported, but some old libraries may contain bitcode, so we continue to strip it when directed.
        if commandLine.contains("--strip-bitcode") {
            if let bitcodeStripToolPath = cbc.producer.toolchains.lazy.compactMap({ $0.executableSearchPaths.lookup(Path("bitcode_strip")) }).first {
                commandLine.append(contentsOf: ["--strip-bitcode-tool", bitcodeStripToolPath.str])
            }
        }

        // Create the environment to pass.
        // This includes computing the path to codesign_allocate to use for code signing the copied libraries.
        var environment: [String: String] = Dictionary(uniqueKeysWithValues: environmentFromSpec(cbc, delegate, lookup: lookup))
        environment.merge(CodesignToolSpec.computeCodeSigningEnvironment(cbc), uniquingKeysWith: { (_, second) in second })

        // Checking whether codesign is empty again is slightly redundant since computeExecutablePath from the codesign spec will do that,
        // but this way we don't add the environment variable override unless we're actually trying to override it.
        let codesign = Path(cbc.scope.evaluate(BuiltinMacros.CODESIGN))
        if !codesign.isEmpty {
            environment.merge(["CODESIGN": cbc.producer.codesignSpec.computeExecutablePath(cbc)], uniquingKeysWith: { (_, second) in second })
        }

        let action = delegate.taskActionCreationDelegate.createEmbedSwiftStdLibTaskAction()

        // FIXME: Force a virtual node as the output, we don't have a way to model this yet: <rdar://problem/28507165> Need accurate incremental dependency modeling of Swift stdlib tool

        let dependencyInfoFilePath = cbc.scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join("SwiftStdLibToolInputDependencies.dep").normalize()
        commandLine.append(contentsOf: ["--emit-dependency-info", dependencyInfoFilePath.str])

        if filterForSwiftOS {
            commandLine.append("--filter-for-swift-os")
        }

        if backDeploySwiftConcurrency {
            commandLine.append("--back-deploy-swift-concurrency")
        }

        let outputs = [delegate.createVirtualNode("CopySwiftStdlib \(wrapperPathString.str)")]

        delegate.createTask(type: self, dependencyData: .dependencyInfo(dependencyInfoFilePath), ruleInfo: ruleInfo, commandLine: commandLine, environment: EnvironmentBindings(environment.map { ($0, $1) }), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [ delegate.createNode(input.absolutePath) ], outputs: outputs, mustPrecede: [], action: action, execDescription: resolveExecutionDescription(cbc, delegate, lookup: lookup), enableSandboxing: enableSandboxing)
    }
}
