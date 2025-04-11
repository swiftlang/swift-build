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

import SWBProtocol
import SWBUtil
import SWBMacro

public final class ValidateDevelopmentAssets: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.validate-development-assets"

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return ValidateDevelopmentAssets(registry: registry)
    }

    public init(registry: SpecRegistry) {
        // FIXME: Clean up manual initialization of objects.
        let proxy = SpecProxy(identifier: Self.identifier, domain: "", path: Path(""), type: Self.self, classType: nil, basedOn: nil, data: ["ExecDescription": PropertyListItem("Validate development assets")], localizedStrings: nil)
        super.init(createSpecParser(for: proxy, registry: registry), nil, isGeneric: false)
    }

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: false)
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let projectDir = cbc.scope.evaluate(BuiltinMacros.PROJECT_DIR)
        let absolutePaths = cbc.scope.evaluate(BuiltinMacros.DEVELOPMENT_ASSET_PATHS).map { projectDir.join($0) }
        let ruleDisambiguator = cbc.scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).str

        // Depend on all of the development asset paths -- note that we don't need directory tree nodes, because we only care about the stat info of the file or directory itself (whether it exists); tracking contents is unnecessary.
        let inputDependencies = absolutePaths.map(delegate.createNode)
        let outputVirtualNode = delegate.createVirtualNode("ValidateDevelopmentAssets-\(ruleDisambiguator)")

        delegate.createTask(type: self, ruleInfo: ["ValidateDevelopmentAssets", ruleDisambiguator], commandLine: ["builtin-validate-development-assets", "--validate", cbc.scope.evaluate(BuiltinMacros.VALIDATE_DEVELOPMENT_ASSET_PATHS).rawValue] + absolutePaths.map(\.str), environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.commandOrderingInputs + inputDependencies, outputs: [outputVirtualNode], action: createTaskAction(cbc, delegate), execDescription: resolveExecutionDescription(cbc, delegate), preparesForIndexing: false, enableSandboxing: enableSandboxing)
    }

    public override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        delegate.taskActionCreationDelegate.createValidateDevelopmentAssetsTaskAction()
    }
}
