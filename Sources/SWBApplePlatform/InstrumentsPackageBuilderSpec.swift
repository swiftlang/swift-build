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
public import SWBCore
import SWBMacro

public final class InstrumentsPackageBuilderSpec: GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.instruments-package-builder"

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // This tool is only used to generate the product for an Instruments Package target.
        // Copy the cbc with an additional virtual node as an output for postprocessing mutating tasks to use to find this task.
        var orderingOutputs: [any PlannedNode] = []

        orderingOutputs.append(contentsOf: evaluatedOutputs(cbc, delegate)?.map({ output in
            delegate.createVirtualNode("BuildInstrumentsPackage \(output.path.str)")
        }) ?? [])

        let dependencyData: DependencyDataStyle?
        let infoFilePath = cbc.scope.evaluate(BuiltinMacros.INSTRUMENTS_PACKAGE_BUILDER_DEPENDENCY_INFO_FILE)
        if !infoFilePath.isEmpty {
            orderingOutputs.append(delegate.createNode(infoFilePath))
            orderingOutputs.append(delegate.createDirectoryTreeNode(infoFilePath.dirname.join("instrumentbuilder-tmp")))
            dependencyData = .dependencyInfo(infoFilePath)
        } else {
            dependencyData = nil
        }

        let cbc = CommandBuildContext(producer: cbc.producer, scope: cbc.scope, inputs: cbc.inputs, isPreferredArch: cbc.isPreferredArch, outputs: cbc.outputs, commandOrderingInputs: cbc.commandOrderingInputs, commandOrderingOutputs: cbc.commandOrderingOutputs + orderingOutputs, buildPhaseInfo: cbc.buildPhaseInfo, resourcesDir: cbc.resourcesDir, tmpResourcesDir: cbc.tmpResourcesDir, unlocalizedResourcesDir: cbc.unlocalizedResourcesDir)

        await super.constructTasks(cbc, delegate, specialArgs: [], dependencyData: dependencyData)
    }
}
