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
public import struct SWBProtocol.RunDestinationInfo
public import SWBMacro

/// An extension point for services.
public struct SettingsBuilderExtensionPoint: ExtensionPoint {
    public typealias ExtensionProtocol = SettingsBuilderExtension

    public static let name = "SettingsBuilderExtensionPoint"

    public init() {}
}

public protocol SettingsBuilderExtension {
    /// Provides a table of additional build properties overrides
    func addOverrides(fromEnvironment: [String:String], parameters: BuildParameters) throws -> [String:String]

    /// Provides a table of additional build settings builtin defaults
    func addBuiltinDefaults(fromEnvironment: [String:String], parameters: BuildParameters) throws -> [String:String]

    /// Provides a table of default settings for a product type.
    func addProductTypeDefaults(productType: ProductTypeSpec) -> [String: String]

    /// Provides a table of additional SDK settings
    func addSDKSettings(_ sdk: SDK, _ variant: SDKVariant?, _ sparseSDKs: [SDK]) throws -> [String : String]

    /// Provides a table of overriding SDK settings
    func addSDKOverridingSettings(_ sdk: SDK, _ variant: SDKVariant?, _ sparseSDKs: [SDK], specLookupContext: any SpecLookupContext) throws -> [String: String]

    /// Provides a table of default platform SDK settings
    func addPlatformSDKSettings(_ platform: Platform?, _ sdk: SDK, _ sdkVariant: SDKVariant?) -> [String: String]

    /// Provides a ByteString of the content of the xcconfig override file
    func xcconfigOverrideData(fromParameters: BuildParameters) -> ByteString

    // Provides a list of flags to configure testing plugins
    func getTargetTestingSwiftPluginFlags(_ scope: MacroEvaluationScope, toolchainRegistry: ToolchainRegistry, sdkRegistry: SDKRegistry, activeRunDestination: RunDestinationInfo?, project: Project?) -> [String]
    // Override valid architectures enforcement for a platform
    func shouldSkipPopulatingValidArchs(platform: Platform) -> Bool

    func shouldDisableXOJITPreviews(platformName: String, sdk: SDK?) -> Bool

    func overridingBuildSettings(_: MacroEvaluationScope, platform: Platform?, productType: ProductTypeSpec) -> [String: String]
}
