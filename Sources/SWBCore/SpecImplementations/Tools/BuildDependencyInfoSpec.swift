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

public final class BuildDependencyInfoSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.tools.build-dependency-info"

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return Self.init(registry: registry)
    }

    public init(registry: SpecRegistry) {
        let proxy = SpecProxy(identifier: Self.identifier, domain: "", path: Path(""), type: Self.self, classType: nil, basedOn: nil, data: ["ExecDescription": PropertyListItem("Merging build dependency info")], localizedStrings: nil)
        super.init(createSpecParser(for: proxy, registry: registry), nil, isGeneric: false)
    }

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec, isGeneric: false)
    }

    override public func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        fatalError("unexpected direct invocation")
    }

    public func createTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate, dumpDependencyPaths: [Path]) async {
        delegate.createTask(type: self, ruleInfo: ["BuildDependencyInfo"], commandLine: ["builtin-build-dependency-info"] + dumpDependencyPaths.map { $0.str }, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: dumpDependencyPaths, outputs: [cbc.output], action: delegate.taskActionCreationDelegate.createBuildDependencyInfoTaskAction(), preparesForIndexing: false, enableSandboxing: false)
    }
}
