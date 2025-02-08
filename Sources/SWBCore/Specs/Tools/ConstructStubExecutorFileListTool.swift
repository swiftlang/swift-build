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

public final class ConstructStubExecutorFileListToolSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.construct-stub-executor-link-file-list"

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return ConstructStubExecutorFileListToolSpec(registry: registry)
    }

    public init(registry: SpecRegistry) {
        // FIXME: Clean up manual initialization of objects.
        let proxy = SpecProxy(
            identifier: Self.identifier,
            domain: "",
            path: Path(""),
            type: ConstructStubExecutorFileListToolSpec.self,
            classType: nil,
            basedOn: nil,
            data: ["ExecDescription": PropertyListItem("Create stub executor file list")],
            localizedStrings: nil
        )
        super.init(createSpecParser(for: proxy, registry: registry), nil, isGeneric: false)
    }

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: false)
    }

    public func constructStubExecutorLinkFileListTask(
        _ cbc: CommandBuildContext,
        _ delegate: any TaskGenerationDelegate,
        debugDylibPath: Path,
        stubExecutorLibraryPath: Path,
        stubExecutorLibraryWithSwiftEntryPointPath: Path
    ) async {
        let inputs: [any PlannedNode] = [
            delegate.createNode(stubExecutorLibraryPath.normalize()),
            delegate.createNode(stubExecutorLibraryWithSwiftEntryPointPath.normalize()),
            delegate.createNode(debugDylibPath.normalize()),
        ]
        let outputs: [any PlannedNode] = [delegate.createNode(cbc.output.normalize())]

        let commandLine = [
            "construct-stub-executor-link-file-list",
            debugDylibPath.str,
            stubExecutorLibraryPath.str,
            stubExecutorLibraryWithSwiftEntryPointPath.str,
            "--output", cbc.output.str
        ]

        delegate.createTask(
            type: self,
            ruleInfo: ["ConstructStubExecutorLinkFileList", cbc.output.str],
            commandLine: commandLine,
            environment: EnvironmentBindings(),
            workingDirectory: cbc.producer.defaultWorkingDirectory,
            inputs: inputs,
            outputs: outputs,
            action: delegate.taskActionCreationDelegate.createConstructStubExecutorInputFileListTaskAction(),
            execDescription: resolveExecutionDescription(cbc, delegate),
            enableSandboxing: enableSandboxing
        )
    }
}
