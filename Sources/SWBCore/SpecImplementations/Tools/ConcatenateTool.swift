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

public final class ConcatenateToolSpec : CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.concatenate"

    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return self.init(registry, proxy,
                         execDescription: registry.internalMacroNamespace.parseString("Concatenating to $(OutputRelativePath)"),
                         ruleInfoTemplate: ["Concatenate", .output, .inputs],
                         commandLineTemplate: [.execPath, .output, .inputs])
    }

    public override func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        return "builtin-concatenate"
    }

    public override func evaluatedOutputs(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate) -> [(path: Path, isDirectory: Bool)]? {
        return [(path: cbc.output, isDirectory: false)]
    }

    public override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        return delegate.taskActionCreationDelegate.createConcatenateTaskAction()
    }
}
