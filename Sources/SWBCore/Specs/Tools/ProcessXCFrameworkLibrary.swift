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

public import SWBUtil
import SWBMacro

public final class ProcessXCFrameworkLibrarySpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier: String = "com.apple.build-tasks.process-xcframework-library"

    public class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return ProcessXCFrameworkLibrarySpec(registry, proxy, execDescription: registry.internalMacroNamespace.parseString("Process $(InputFileName)"), ruleInfoTemplate: ["ProcessXCFramework", .input, .output], commandLineTemplate: [.execPath, .options])
    }

    public override func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        return "builtin-process-xcframework"
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, platform: String, environment: String?, outputDirectory copyLibraryToPath: Path, libraryPath: Path, expectedSignatures: [String]?) async {
        let xcframeworkPath = cbc.input.absolutePath
        let inputs: [any PlannedNode] = [delegate.createDirectoryTreeNode(xcframeworkPath)] + cbc.commandOrderingInputs

        var commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)
        commandLine.append(contentsOf: ["--xcframework", xcframeworkPath.str])

        // The platform and environment are needed to perform additional work for the xcframework processing.
        commandLine.append(contentsOf: ["--platform", platform])

        if let env = environment {
            commandLine.append(contentsOf: ["--environment", env])
        }

        // Use the calculated paths above to inform the process step what to copy instead of needing the action to perform the same work.
        commandLine.append(contentsOf: ["--target-path", copyLibraryToPath.str])

        // NOTE: This is allowed to be specified multiple times. When doing so, the validation will return a success if any match.
        for signature in expectedSignatures ?? [] {
            commandLine.append(contentsOf: ["--expected-signature", signature])
        }

        if cbc.scope.evaluate(BuiltinMacros.DISABLE_XCFRAMEWORK_SIGNATURE_VALIDATION) {
            commandLine.append("--skip-signature-validation")
        }

        let platformDisplayString = BuildVersion.Platform(platform: platform, environment: environment)?.displayName(infoLookup: cbc.producer) ?? ([platform, environment].compactMap { $0 }.joined(separator: "-"))
        let execDescription = "\(resolveExecutionDescription(cbc, delegate)) (\(platformDisplayString))"

        func lookup(_ declaration: MacroDeclaration) -> MacroExpression? {
            switch declaration {
            case BuiltinMacros.OutputPath:
                return cbc.scope.namespace.parseLiteralString(copyLibraryToPath.join(libraryPath).str)
            default:
                return nil
            }
        }

        delegate.createTask(type: self, ruleInfo: defaultRuleInfo(cbc, delegate, lookup: lookup) + [platform, environment].compactMap { $0 }, commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputs, outputs: cbc.outputs.map(delegate.createNode), action: delegate.taskActionCreationDelegate.createProcessXCFrameworkTask(), execDescription: execDescription, preparesForIndexing: true, enableSandboxing: enableSandboxing)
    }
}
