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

public final class ValidateDependenciesSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.validate-dependencies"

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return ValidateDependenciesSpec(registry: registry)
    }

    public init(registry: SpecRegistry) {
        let proxy = SpecProxy(identifier: Self.identifier, domain: "", path: Path(""), type: Self.self, classType: nil, basedOn: nil, data: ["ExecDescription": PropertyListItem("Validate dependencies")], localizedStrings: nil)
        super.init(createSpecParser(for: proxy, registry: registry), nil, isGeneric: false)
    }

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: false)
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        fatalError("unexpected direct invocation")
    }

    public override var payloadType: (any TaskPayload.Type)? { return ValidateDependenciesPayload.self }

    public func createTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, dependencyInfos: [PlannedPathNode], payload: ValidateDependenciesPayload) async {
        guard let configuredTarget = cbc.producer.configuredTarget else {
            return
        }
        let output =  delegate.createVirtualNode("ValidateDependencies \(configuredTarget.guid)")
        delegate.createTask(type: self, payload: payload, ruleInfo: ["ValidateDependencies"], commandLine: ["builtin-validate-dependencies"] + dependencyInfos.map { $0.path.str }, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: dependencyInfos + cbc.commandOrderingInputs, outputs: [output], action: delegate.taskActionCreationDelegate.createValidateDependenciesTaskAction(), preparesForIndexing: false, enableSandboxing: false)
    }
}

public struct ValidateDependenciesPayload: TaskPayload, Sendable, SerializableCodable {
    public let moduleDependenciesContext: ModuleDependenciesContext

    public init(moduleDependenciesContext: ModuleDependenciesContext) {
        self.moduleDependenciesContext = moduleDependenciesContext
    }
}
