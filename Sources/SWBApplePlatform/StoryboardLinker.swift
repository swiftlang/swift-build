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
public import SWBCore
public import SWBMacro

public final class IBStoryboardLinkerCompilerSpec : GenericCompilerSpec, SpecIdentifierType, IbtoolCompilerSupport, @unchecked Sendable {
    public static let identifier = "com.apple.xcode.tools.ibtool.storyboard.linker"

    /// Override to compute the special arguments.
    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        var specialArgs = [String]()

        specialArgs += targetDeviceArguments(cbc, delegate)
        specialArgs += minimumDeploymentTargetArguments(cbc, delegate)

        await constructTasks(cbc, delegate, specialArgs: specialArgs)
    }

    /// Disregard the outputs from the command build content and define appropriate outputs here.
    public override func evaluatedOutputs(_ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate) -> [(path: Path, isDirectory: Bool)]? {
        guard let resourcesDir = cbc.resourcesDir, let tmpResourcesDir = cbc.tmpResourcesDir else {
            // FIXME: There's no way to emit any errors here.
            return nil
        }

        // On watchOS, the output filenames are constant.
        // Not all outputs are necessarily emitted, depending on the content.
        var outputs = [(Path, Bool)]()
        if cbc.producer.platform?.familyName == "watchOS" {
            outputs = [
                "Interface.plist",
                "Interface-glance.plist",
                "Interface-notification.plist"
            ].map { (resourcesDir.join($0), false) }
        }
        else {
            // Otherwise compute default values based on the inputs.
            for input in cbc.inputs.map({ $0.absolutePath }) {
                let subpath = input.relativeSubpath(from: tmpResourcesDir) ?? input.basename
                outputs.append((resourcesDir.join(subpath), true))
            }
        }
        return outputs
    }

    public override func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        do {
            return try await discoveredIbtoolToolInfo(producer, delegate, at: self.resolveExecutablePath(producer, scope.ibtoolExecutablePath()))
        } catch {
            delegate.error(error)
            return nil
        }
    }
}
