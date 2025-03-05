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
public import SWBMacro

public final class SwiftHeaderToolSpec : CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.swift-header-tool"

    public override func resolveExecutionDescription(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> String {
        "Merge Objective-C generated interface headers"
    }

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return SwiftHeaderToolSpec(registry, proxy, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // FIXME: We should ensure this cannot happen.
        fatalError("unexpected direct invocation")
    }

    /// Construct a new task to run the Swift header tool.
    public func constructSwiftHeaderToolTask(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, inputs: [String: Path], outputPath: Path, mustPrecede: [any PlannedTask] = []) {
        let inputPaths = inputs.values.sorted()
        let commandLine = ["builtin-swiftHeaderTool"] + (!cbc.producer.isApplePlatform ? ["-single"] : []) + inputs.sorted(byKey: <).flatMap { (arch, path) in ["-arch", arch, path.str] } + ["-o", outputPath.str]
        delegate.createTask(type: self, ruleInfo: ["SwiftMergeGeneratedHeaders", outputPath.str] + inputPaths.map { $0.str }, commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: inputPaths, outputs: [outputPath], mustPrecede: mustPrecede, action: delegate.taskActionCreationDelegate.createSwiftHeaderToolTaskAction(), execDescription: resolveExecutionDescription(cbc, delegate), preparesForIndexing: true, enableSandboxing: enableSandboxing, additionalTaskOrderingOptions: [.compilationRequirement, .blockedByTargetHeaders])
    }
}
