//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBUtil
import SWBMacro

public final class ProcessSDKImportsSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.process-sdk-imports"

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return ProcessSDKImportsSpec(registry: registry)
    }

    public init(registry: SpecRegistry) {
        let proxy = SpecProxy(identifier: Self.identifier, domain: "", path: Path(""), type: Self.self, classType: nil, basedOn: nil, data: ["ExecDescription": PropertyListItem("Process SDK imports $(OutputRelativePath)")], localizedStrings: nil)
        super.init(createSpecParser(for: proxy, registry: registry), nil, isGeneric: false)
    }

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: false)
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        fatalError("unexpected direct invocation")
    }

    public func createTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, ldSDKImportsPath: Path) async {
        let unlocalizedProductResourcesDir = cbc.scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(cbc.scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH)).normalize()
        let outputPath = unlocalizedProductResourcesDir.join(ldSDKImportsPath.basename)
        delegate.createTask(type: self, ruleInfo: ["ProcessSDKImports", ldSDKImportsPath.str], commandLine: ["builtin-process-sdk-imports", ldSDKImportsPath.str, outputPath.str], environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [MakePlannedPathNode(ldSDKImportsPath)] + cbc.commandOrderingInputs, outputs: [MakePlannedPathNode(outputPath)], action: delegate.taskActionCreationDelegate.createProcessSDKImportsTaskAction(), preparesForIndexing: false, enableSandboxing: false)
    }
}
