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
package import SWBProtocol
import SWBUtil
import SWBMacro

package struct ProjectPlanner {
    private let workspaceContext: WorkspaceContext
    private let buildRequestContext: BuildRequestContext

    package init(workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext) {
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
    }

    package func describeArchivableProducts(input: [SchemeInput]) -> [ProductTupleDescription] {
        return Array(Set(input.flatMap { scheme in
            return [scheme.analyze, scheme.archive, scheme.profile, scheme.run, scheme.test].flatMap { (input: ActionInput) -> [ProductTupleDescription] in
                let parameters = BuildParameters(action: input)
                return input.targetIdentifiers.flatMap { (targetIdentifier: String) -> [ProductTupleDescription] in
                    guard let target = workspaceContext.workspace.target(for: targetIdentifier) else { return [] }
                    let settings = buildRequestContext.getCachedSettings(parameters, target: target)
                    return settings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS).compactMap { supportedPlatform in
                        guard let platform = workspaceContext.core.platformRegistry.lookup(name: supportedPlatform) else { return nil }
                        let settings = buildRequestContext.getCachedSettings(BuildParameters(action: input, platform: platform), target: target)
                        let productName = settings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME)
                        let team = settings.globalScope.evaluate(BuiltinMacros.DEVELOPMENT_TEAM).nilIfEmpty
                        return ProductTupleDescription(
                            displayName: productName,
                            productName: productName,
                            productType: {
                                switch settings.globalScope.evaluate(BuiltinMacros.PRODUCT_TYPE) {
                                case "com.apple.product-type.application", "com.apple.product-type.application.watchapp2", "com.apple.product-type.application.on-demand-install-capable":
                                    return .app
                                case "com.apple.product-type.tool":
                                    return .tool
                                case "com.apple.product-type.framework", "com.apple.product-type.framework.static", "com.apple.product-type.library.dynamic", "com.apple.product-type.library.static":
                                    return .library
                                case "com.apple.product-type.watchkit2-extension":
                                    return .appex
                                case "com.apple.product-type.bundle.unit-test",
                                    "com.apple.product-type.bundle.ui-testing",
                                    "com.apple.product-type.bundle.multi-device-ui-testing":
                                    return .tests
                                default:
                                    return .none
                                }
                            }(),
                            identifier: target.guid,
                            team: team,
                            bundleIdentifier: settings.globalScope.evaluate(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER).nilIfEmpty,
                            destination: DestinationInfo(platformName: settings.globalScope.evaluate(BuiltinMacros.PLATFORM_DISPLAY_NAME), isSimulator: settings.globalScope.evaluate(BuiltinMacros.PLATFORM_NAME).hasSuffix("simulator")),
                            containingSchemes: [scheme.name],
                            iconPath: nil)
                    }
                }
            }
        }))
    }

    // TODO: This is a stub for testing, real implementation will be done in rdar://problem/56446029
    package func describeProducts(input: ActionInput, platform: Platform) -> [ProductDescription] {
        let parameters = BuildParameters(action: input, platform: platform)
        return input.targetIdentifiers.compactMap { targetIdentifier in
            guard let target = workspaceContext.workspace.target(for: targetIdentifier) else { return nil }
            let settings = buildRequestContext.getCachedSettings(parameters, target: target)
            let productName = settings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME)
            return try! ProductDescription(displayName: productName, productName: productName, identifier: productName, productType: .app, dependencies: nil, bundleIdentifier: nil, targetedDeviceFamilies: nil, deploymentTarget: Version("10.10"), marketingVersion: nil, buildVersion: nil, codesign: nil, team: nil, infoPlistPath: nil, iconPath: nil)
        }
    }

    // TODO: This is a stub for testing, real implementation will be done in rdar://problem/56446029
    package func describeSchemes(input: [SchemeInput]) -> [SchemeDescription] {
        return input.map { scheme in
            let actions = ActionsInfo(analyze: actionInfo(scheme.analyze),
                        archive: actionInfo(scheme.archive),
                        profile: actionInfo(scheme.profile),
                        run: actionInfo(scheme.run),
                        test: actionInfo(scheme.test))
            return SchemeDescription(name: scheme.name, disambiguatedName: scheme.name, isShared: scheme.isShared, isAutogenerated: scheme.isAutogenerated, actions: actions)
        }
    }

    private func actionInfo(_ input: ActionInput) -> ActionInfo {
        let parameters = BuildParameters(action: input)
        let products = input.targetIdentifiers.compactMap { (targetIdentifier: String) -> ProductInfo? in
            guard let target = workspaceContext.workspace.target(for: targetIdentifier) else { return nil }
            let settings = buildRequestContext.getCachedSettings(parameters, target: target)
            let displayName = settings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME)
            let destinations = supportedPlatforms(for: target, parameters: parameters).map { DestinationInfo(platformName: $0.name, isSimulator: $0.isSimulator) }
            return ProductInfo(displayName: displayName, identifier: targetIdentifier, supportedDestinations: destinations)
        }
        return ActionInfo(configurationName: input.configurationName, products: products, testPlans: [])
    }

    private func allTargets(for targetIdentifiers: [String], parameters: BuildParameters) -> [SWBCore.Target] {
        let topLevelTargets = targetIdentifiers.compactMap { workspaceContext.workspace.target(for: $0) }
        let result = transitiveClosure(topLevelTargets) {
            let settings = buildRequestContext.getCachedSettings(parameters, target: $0)
            let currentPlatformFilter = PlatformFilter(settings.globalScope)
            return $0.dependencies.compactMap {
                currentPlatformFilter.matches($0.platformFilters) ? workspaceContext.workspace.target(for: $0.guid) : nil
            }
        }
        return Array(result.0)
    }

    private func supportedPlatforms(for target: SWBCore.Target, parameters: BuildParameters) -> [Platform] {
        let settings = buildRequestContext.getCachedSettings(parameters, target: target)
        return settings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS).compactMap { workspaceContext.core.platformRegistry.lookup(identifier: $0) }
    }
}

private extension BuildParameters {
    init(action: ActionInput) {
        self.init(action: .build, configuration: action.configurationName, activeRunDestination: nil, activeArchitecture: nil, overrides: [:], commandLineOverrides: [:], commandLineConfigOverridesPath: nil, commandLineConfigOverrides: [:], environmentConfigOverridesPath: nil, environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)
    }

    init(action: ActionInput, platform: Platform) {
        let destination = Self.runDestination(for: platform)
        self.init(action: .build, configuration: action.configurationName, activeRunDestination: destination, activeArchitecture: destination.targetArchitecture, overrides: [:], commandLineOverrides: [:], commandLineConfigOverridesPath: nil, commandLineConfigOverrides: [:], environmentConfigOverridesPath: nil, environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)
    }

    private static func runDestination(for platform: Platform) -> RunDestinationInfo {
        // All relevant platforms define a preferredArch, so the undefined_arch fallback case should never happen
        // in practice, and indicates a serious issue occurred during plugin loading.
        let targetArchitecture = platform.preferredArch ?? "undefined_arch"
        return RunDestinationInfo(platform: platform.name, sdk: platform.name, sdkVariant: nil, targetArchitecture: targetArchitecture, supportedArchitectures: [targetArchitecture], disableOnlyActiveArch: false, hostTargetedPlatform: nil)
    }
}
