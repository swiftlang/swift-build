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

package import SWBCore
import SWBUtil
import SWBMacro
import SWBProtocol

/// Context of immutable data used to compute stale file removal identifiers for configured targets.
package protocol StaleFileRemovalContext {
    var workspaceContext: WorkspaceContext { get }
    var globalProductPlan: GlobalProductPlan { get }
}

extension StaleFileRemovalContext {
    /// Whether stale file removal is effectively enabled in this context.
    ///
    /// Stale file removal is enabled if the global flag is set on the build request, and is allowed by the build command.
    package var isStaleFileRemovalEnabled: Bool {
        let request = globalProductPlan.planRequest.buildRequest
        return request.enableStaleFileRemoval && request.buildCommand.shouldEnableStaleFileRemoval
    }

    /// Returns the stale file removal task identifier for the specified `ConfiguredTarget`.
    ///
    /// - returns: The stale file removal task identifier, or `nil` if stale file removal is disabled in this context, either globally or at the target level.
    package func staleFileRemovalTaskIdentifier(for configuredTarget: ConfiguredTarget?) -> String? {
        guard isStaleFileRemovalEnabled else {
            return nil
        }

        let settings = configuredTarget.map { configuredTarget in globalProductPlan.getTargetSettings(configuredTarget) } ?? globalProductPlan.getWorkspaceSettings()
        let scope = settings.globalScope

        // Skip stale file removal?
        if scope.evaluate(BuiltinMacros.DISABLE_STALE_FILE_REMOVAL) {
            return nil
        }

        var staleFileRemovalIdentifier = ""

        if let configuredTarget {
            let target = configuredTarget.target
            let project = workspaceContext.workspace.project(for: target)
            let defaultConfigurationName = project.defaultConfigurationName
            let configurationName = target.getEffectiveConfiguration(configuredTarget.parameters.configuration, defaultConfigurationName: project.isPackage ? (configuredTarget.parameters.packageConfigurationOverride ?? defaultConfigurationName) : defaultConfigurationName)?.name ?? ""
            // Use EFFECTIVE_PLATFORM_NAME to identify the platform, since we want stale file removal to mirror the actual build products directory name suffix (for example, Mac Catalyst and macOS build products are separate).
            // FIXME: Centralize this in TaskIdentifier somehow.
            let targetPlatform = scope.evaluate(BuiltinMacros.EFFECTIVE_PLATFORM_NAME).nilIfEmpty ?? settings.platform.map { "-\($0.name)" } ?? "-noplatform"
            staleFileRemovalIdentifier += "target-\(target.name)-\(target.guid)-\(configurationName)\(targetPlatform)"
        } else {
            staleFileRemovalIdentifier += "workspace"
            staleFileRemovalIdentifier += "-\(globalProductPlan.planRequest.buildRequest.parameters.configuration ?? "none")"
            if let destination = globalProductPlan.planRequest.buildRequest.parameters.activeRunDestination {
                staleFileRemovalIdentifier += "-\(destination.sdk)"
                if let variant = destination.sdkVariant {
                    staleFileRemovalIdentifier += "-\(variant)"
                }
            }
        }

        staleFileRemovalIdentifier += "-\(scope.evaluate(BuiltinMacros.ARCHS).sorted().map({ "-\($0)" }).joined())"

        // Need to check each of the sanitizers, since this is the logic that goes into the
        // Objects-\(sanitizerMode) outputs. This is necessary to avoid deleting files from the other
        // sanitizer modes. <rdar://57768179> for more info.
        if scope.evaluate(BuiltinMacros.ENABLE_ADDRESS_SANITIZER) {
            staleFileRemovalIdentifier += "-asan"
        }
        if scope.evaluate(BuiltinMacros.ENABLE_THREAD_SANITIZER) {
            staleFileRemovalIdentifier += "-tsan"
        }
        if scope.evaluate(BuiltinMacros.ENABLE_UNDEFINED_BEHAVIOR_SANITIZER) {
            staleFileRemovalIdentifier += "-ubsan"
        }

        // Add the build components to ensure the various styles of builds do not stomp on one another.
        staleFileRemovalIdentifier += scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).sorted().map({ "-\($0)" }).joined()
        staleFileRemovalIdentifier += "-stale-file-removal"

        return staleFileRemovalIdentifier
    }
}

extension BuildCommand {
    /// Returns if stale file removal should be enabled for this build command.
    package var shouldEnableStaleFileRemoval: Bool {
        // Do not run stale file removal for dynamic replacement previews.
        // Since intermediates during both are stored at another OBJROOT, stale file removal generates a lot warnings.
        // This is going to be fixed in rdar://problem/37332168 by considering the ROOT in llbuild.
        return self != .preview(style: .dynamicReplacement)
    }
}
