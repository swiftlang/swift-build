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

public final class SignatureCollectionSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.signature-collection"

    public class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return SignatureCollectionSpec(registry, proxy, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, platform: String, platformVariant: String?, libraryPath: Path) {
        let outputPath = cbc.output

        var commandLine = ["builtin-collectSignature"]
        commandLine.append(contentsOf: ["--input", cbc.input.absolutePath.str, "--output", outputPath.str, "--info", "platform", platform, "--info", "library", libraryPath.basename])
        if let platformVariant {
            commandLine.append(contentsOf: ["--info", "platformVariant", platformVariant])
        }

        let action = delegate.taskActionCreationDelegate.createSignatureCollectionTaskAction()
        delegate.createTask(type: self, ruleInfo: ["SignatureCollection", outputPath.str], commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.inputs.map({ $0.absolutePath }), outputs: [outputPath], action: action, execDescription: "Signature \(outputPath.basename)", enableSandboxing: enableSandboxing)
    }
}
