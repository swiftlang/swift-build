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

public final class MergeInfoPlistSpec: CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        MergeInfoPlistSpec(registry, proxy, execDescription: registry.internalMacroNamespace.parseString("Merge preprocessed Info.plist variants"), ruleInfoTemplate: ["MergeInfoPlistFile", .output, .input], commandLineTemplate: [.execPath, .options, .output, .inputs])
    }

    public override func computeExecutablePath(_ cbc: CommandBuildContext) -> String {
        "builtin-mergeInfoPlist"
    }

    public override func evaluatedOutputs(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate) -> [(path: Path, isDirectory: Bool)]? {
        return [(path: cbc.output, isDirectory: false)]
    }

    public static let identifier = "com.apple.build-tools.merge-info-plist"

    public override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        delegate.taskActionCreationDelegate.createMergeInfoPlistTaskAction()
    }
}
