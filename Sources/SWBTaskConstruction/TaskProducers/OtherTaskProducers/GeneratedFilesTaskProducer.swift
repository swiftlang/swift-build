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

import SWBCore
import SWBUtil
import SWBMacro

final class GeneratedFilesTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return [.immediate, .unsignedProductRequirement]
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        var tasks: [any PlannedTask] = []

        // Don't generate these files if no product is produced.
        //
        // FIXME: This should really be phrased in terms of a concrete check against the produced executable (a provisional task), not a phase check.
        if context.willProduceProduct(scope) {
            await addCodeSignProvisioningProfileTasks(scope, &tasks)
            await addCodeSignEntitlementsTasks(scope, &tasks)
        }

        return tasks
    }

    /// Add the provisioning profile tasks, if necessary.
    private func addCodeSignProvisioningProfileTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        guard let profile = self.context.signingSettings?.profile else { return }

        // Construct the task.
        await appendGeneratedTasks(&tasks) { delegate in
            await context.productPackagingSpec.constructProductProvisioningProfileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: profile.input)], output: profile.output), delegate)
        }
    }

    /// Add the entitlements processing tasks, if necessary.
    private func addCodeSignEntitlementsTasks(_ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) async {
        func addEntitlementsTask(entitlements: Settings.SigningSettings.Entitlements, entitlementsVariant: EntitlementsVariant) async {
            let fileName: String
            switch entitlementsVariant {
            case .signed:
                fileName = "Entitlements.plist"
            case .simulated:
                fileName = "Entitlements-Simulated.plist"
            }

            // FIXME: <rdar://problem/29117572> Right now we need to create a fake auxiliary file to use as the input.  Once in-process tasks have signatures, we should use those here instead.
            let input = scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join(fileName)

            // Construct the task.
            await appendGeneratedTasks(&tasks) { delegate in
                await context.productPackagingSpec.constructProductEntitlementsTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: input)], output: entitlements.output), delegate, entitlementsVariant, fs: context.workspaceContext.fs)

                delegate.createTask(type: context.productPackagingSpec, ruleInfo: ["ProcessProductPackagingDER", entitlements.output.str, entitlements.outputDer.str], commandLine: ["/usr/bin/derq", "query", "-f", "xml", "-i", entitlements.output.str, "-o", entitlements.outputDer.str, "--raw"], environment: EnvironmentBindings([:]), workingDirectory: context.defaultWorkingDirectory, inputs: [delegate.createNode(entitlements.output)], outputs: [delegate.createNode(entitlements.outputDer)], action: delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: context.userPreferences), execDescription: "Generate DER entitlements", enableSandboxing: context.productPackagingSpec.enableSandboxing)
            }
        }

        if let signedEntitlements = context.signingSettings?.signedEntitlements {
            await addEntitlementsTask(entitlements: signedEntitlements, entitlementsVariant: .signed)
        }

        if let simulatedEntitlements = context.signingSettings?.simulatedEntitlements {
            await addEntitlementsTask(entitlements: simulatedEntitlements, entitlementsVariant: .simulated)
        }
    }
}
