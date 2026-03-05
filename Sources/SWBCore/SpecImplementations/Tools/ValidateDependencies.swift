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

private import Foundation
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

        let jsonData: Data
        do {
            jsonData = try JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).encode(payload)
        } catch {
            delegate.error("Error serializing \(payload): \(error)")
            return
        }
        let signature = String(decoding: jsonData, as: UTF8.self)

        var outputs: [any PlannedNode] = [delegate.createVirtualNode("ValidateDependencies \(configuredTarget.guid)")]
        if cbc.scope.evaluate(BuiltinMacros.DUMP_DEPENDENCIES) {
            outputs.append(MakePlannedPathNode(cbc.scope.evaluate(BuiltinMacros.DUMP_DEPENDENCIES_OUTPUT_PATH)))
        }

        delegate.createTask(type: self, payload: payload, ruleInfo: ["ValidateDependencies"], additionalSignatureData: signature, commandLine: ["builtin-validate-dependencies"] + dependencyInfos.map { $0.path.str }, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: dependencyInfos + cbc.commandOrderingInputs, outputs: outputs, action: delegate.taskActionCreationDelegate.createValidateDependenciesTaskAction(), preparesForIndexing: false, enableSandboxing: false)
    }
}

public struct ValidateDependenciesPayload: TaskPayload, Sendable, SerializableCodable {
    public let moduleDependenciesContext: ModuleDependenciesContext?
    public let headerDependenciesContext: HeaderDependenciesContext?

    public let dumpDependencies: Bool
    public let dumpDependenciesOutputPath: String

    public let platformName: String?
    public let projectName: String?
    public let targetName: String

    public init(moduleDependenciesContext: ModuleDependenciesContext?, headerDependenciesContext: HeaderDependenciesContext?, dumpDependencies: Bool, dumpDependenciesOutputPath: String, platformName: String?, projectName: String?, targetName: String) {
        self.moduleDependenciesContext = moduleDependenciesContext
        self.headerDependenciesContext = headerDependenciesContext
        self.dumpDependencies = dumpDependencies
        self.dumpDependenciesOutputPath = dumpDependenciesOutputPath
        self.platformName = platformName
        self.projectName = projectName
        self.targetName = targetName
    }
}
