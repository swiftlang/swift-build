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
import SWBMacro

public final class CreateBuildDirectorySpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.create-build-directory"

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return CreateBuildDirectorySpec(registry: registry)
    }

    public init(registry: SpecRegistry) {
        // FIXME: Clean up manual initialization of objects.
        let proxy = SpecProxy(identifier: "com.apple.tools.create-build-directory", domain: "", path: Path(""), type: CreateBuildDirectorySpec.self, classType: nil, basedOn: nil, data: ["ExecDescription": PropertyListItem("Create build directory $(OutputRelativePath)")], localizedStrings: nil)
        super.init(createSpecParser(for: proxy, registry: registry), nil, isGeneric: false)
    }

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: false)
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        fatalError("unexpected direct invocation")
    }

    public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, buildDirectoryNode: PlannedPathNode) {
        let buildDirectoryVirtualNode = delegate.createVirtualNode("CreateBuildDirectory-\(buildDirectoryNode.path.str)")
        let execDescription = resolveExecutionDescription(cbc, delegate) { decl in
            switch decl {
            case BuiltinMacros.OutputPath, BuiltinMacros.OutputFile:
                return cbc.scope.namespace.parseLiteralString(buildDirectoryNode.path.str)
            default: return nil
            }
        }
        delegate.createTask(type: self, ruleInfo: ["CreateBuildDirectory", buildDirectoryNode.path.str], commandLine: ["builtin-create-build-directory", buildDirectoryNode.path.str], environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: cbc.commandOrderingInputs, outputs: [buildDirectoryVirtualNode, buildDirectoryNode], action: delegate.taskActionCreationDelegate.createBuildDirectoryTaskAction(), execDescription: execDescription, preparesForIndexing: true, enableSandboxing: enableSandboxing)
    }
}
