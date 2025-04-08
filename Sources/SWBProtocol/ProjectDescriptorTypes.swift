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

public struct SchemeInput: Equatable, Hashable, Serializable, Sendable {
    public let name: String
    public let isShared: Bool
    public let isAutogenerated: Bool

    public let analyze: ActionInput
    public let archive: ActionInput
    public let profile: ActionInput
    public let run: ActionInput
    public let test: ActionInput

    public init(name: String, isShared: Bool, isAutogenerated: Bool, analyze: ActionInput, archive: ActionInput, profile: ActionInput, run: ActionInput, test: ActionInput) {
        self.name = name
        self.isShared = isShared
        self.isAutogenerated = isAutogenerated
        self.analyze = analyze
        self.archive = archive
        self.profile = profile
        self.run = run
        self.test = test
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(8)
        self.name = try deserializer.deserialize()
        self.isShared = try deserializer.deserialize()
        self.isAutogenerated = try deserializer.deserialize()
        self.analyze = try deserializer.deserialize()
        self.archive = try deserializer.deserialize()
        self.profile = try deserializer.deserialize()
        self.run = try deserializer.deserialize()
        self.test = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(8)
        serializer.serialize(self.name)
        serializer.serialize(self.isShared)
        serializer.serialize(self.isAutogenerated)
        serializer.serialize(self.analyze)
        serializer.serialize(self.archive)
        serializer.serialize(self.profile)
        serializer.serialize(self.run)
        serializer.serialize(self.test)
    }
}

public struct ActionInput: Equatable, Hashable, Serializable, Sendable {
    public let configurationName: String
    public let targetIdentifiers: [String]

    public init(configurationName: String, targetIdentifiers: [String]) {
        self.configurationName = configurationName
        self.targetIdentifiers = targetIdentifiers
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.configurationName = try deserializer.deserialize()
        self.targetIdentifiers = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.configurationName)
        serializer.serialize(self.targetIdentifiers)
    }
}

/// Description of a scheme.
/// Scheme represents "what" (products) and "how" (configuration) of building.
public struct SchemeDescription: Codable, Equatable, Hashable, Serializable, Sendable {
    /// Human-readable name, show to users.
    public let name: String

    /// Disambiguated name. If the workspace closure contains more than one scheme of the same name,
    /// this will also contain the name of the container.
    /// Pass this to xcodebuild to ensure we always choose the right scheme.
    public let disambiguatedName: String

    /// Needed to know whether a job will see it when it checks out on the server.
    /// If not shared, client should offer to share+commit the scheme if user wants to use it for CI.
    public let isShared: Bool

    /// If the scheme is not actually present on disk, but is automatically
    /// generated by Xcode.
    public let isAutogenerated: Bool

    /// Actions with their metadata.
    public let actions: ActionsInfo

    public init(name: String, disambiguatedName: String, isShared: Bool, isAutogenerated: Bool, actions: ActionsInfo) {
        self.name = name
        self.disambiguatedName = disambiguatedName
        self.isShared = isShared
        self.isAutogenerated = isAutogenerated
        self.actions = actions
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        self.name = try deserializer.deserialize()
        self.disambiguatedName = try deserializer.deserialize()
        self.isShared = try deserializer.deserialize()
        self.isAutogenerated = try deserializer.deserialize()
        self.actions = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(5)
        serializer.serialize(self.name)
        serializer.serialize(self.disambiguatedName)
        serializer.serialize(self.isShared)
        serializer.serialize(self.isAutogenerated)
        serializer.serialize(self.actions)
    }
}

/// Describes a destination

/// Describes a reference to a Product, used in describeSchemes.
public struct ProductInfo: Codable, Equatable, Hashable, Serializable, Sendable {

    /// Human-readable name.
    public let displayName: String

    /// Identifier, used to reference the product in `describeProducts`.
    public let identifier: String

    /// Supported destinations.
    /// We need this here so that we can pass the right platform/destination into the second call.
    public let supportedDestinations: [DestinationInfo]

    public init(displayName: String, identifier: String, supportedDestinations: [DestinationInfo]) {
        self.displayName = displayName
        self.identifier = identifier
        self.supportedDestinations = supportedDestinations
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.displayName = try deserializer.deserialize()
        self.identifier = try deserializer.deserialize()
        self.supportedDestinations = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(3)
        serializer.serialize(self.displayName)
        serializer.serialize(self.identifier)
        serializer.serialize(self.supportedDestinations)
    }
}

/// Describes a reference to a Test Plan, used in describeSchemes
public struct TestPlanInfo: Codable, Equatable, Hashable, Serializable, Sendable {

    /// Human-readable name
    public let displayName: String

    public init(displayName: String) {
        self.displayName = displayName
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.displayName = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.displayName)
    }
}

/// Describes a destination.
public struct DestinationInfo: Codable, Equatable, Hashable, Comparable, Serializable, Sendable {

    /// Platform name
    public let platformName: String

    /// Whether destination represents a simulator.
    public let isSimulator: Bool

    public init(platformName: String, isSimulator: Bool) {
        self.platformName = platformName
        self.isSimulator = isSimulator
    }

    public static func <(lhs: DestinationInfo, rhs: DestinationInfo) -> Bool {
        return lhs.platformName.localizedCompare(rhs.platformName) == .orderedAscending
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.platformName = try deserializer.deserialize()
        self.isSimulator = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(self.platformName)
        serializer.serialize(self.isSimulator)
    }
}

/// Describes an action.
public struct ActionInfo: Codable, Equatable, Hashable, Serializable, Sendable {

    /// Build configuration.
    public let configurationName: String

    /// Products built for this action.
    public let products: [ProductInfo]

    /// Test plans associated with this action.
    public let testPlans: [TestPlanInfo]?

    public init(configurationName: String, products: [ProductInfo], testPlans: [TestPlanInfo]?) {
        self.configurationName = configurationName
        self.products = products
        self.testPlans = testPlans
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.configurationName = try deserializer.deserialize()
        self.products = try deserializer.deserialize()
        self.testPlans = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(3)
        serializer.serialize(self.configurationName)
        serializer.serialize(self.products)
        serializer.serialize(self.testPlans)
    }
}

/// Describes actions associated with the scheme.
public struct ActionsInfo: Codable, Equatable, Hashable, Serializable, Sendable {
    public let analyze: ActionInfo
    public let archive: ActionInfo
    public let profile: ActionInfo
    public let run: ActionInfo
    public let test: ActionInfo

    public init(analyze: ActionInfo, archive: ActionInfo, profile: ActionInfo, run: ActionInfo, test: ActionInfo) {
        self.analyze = analyze
        self.archive = archive
        self.profile = profile
        self.run = run
        self.test = test
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        self.analyze = try deserializer.deserialize()
        self.archive = try deserializer.deserialize()
        self.profile = try deserializer.deserialize()
        self.run = try deserializer.deserialize()
        self.test = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(5)
        serializer.serialize(self.analyze)
        serializer.serialize(self.archive)
        serializer.serialize(self.profile)
        serializer.serialize(self.run)
        serializer.serialize(self.test)
    }
}

/// ProductDescription represents an interesting build asset that the user can run or link.
/// Used in describeProducts.
public struct ProductDescription: Equatable, Hashable, Serializable, Sendable {

    /// Human-readable name of the product's Xcode target.
    public let displayName: String

    /// Product name, e.g. name of the app on the home screen, aka CFBundleName.
    public let productName: String

    /// Internal identifier in the project model.
    public let identifier: String

    public enum ProductType: Codable, Equatable, Hashable, Sendable {

        /// Aggregate target - not a product, but has products as dependencies.
        case none

        /// Application.
        case app

        /// Command line tool.
        case tool

        /// Library (framework or a static library).
        case library

        /// App extension.
        case appex

        /// Test bundle.
        case tests

        /// Unknown.
        case unknown(String)

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self.fromString(value)
        }

        public func encode(to encoder: any Encoder) throws {
            let value = self.asString()
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }

        public func asString() -> String {
            let value: String
            switch self {
            case .none:
                value = "none"
            case .app:
                value = "app"
            case .tool:
                value = "tool"
            case .library:
                value = "library"
            case .appex:
                value = "appex"
            case .tests:
                value = "tests"
            case .unknown(let raw):
                value = raw
            }
            return value
        }

        static func fromString(_ value: String) -> ProductType {
            switch value {
            case "none":
                return .none
            case "app":
                return .app
            case "tool":
                return .tool
            case "library":
                return .library
            case "appex":
                return .appex
            case "tests":
                return .tests
            default:
                return .unknown(value)
            }
        }
    }

    /// Product type. App/Library?
    public let productType: ProductType

    /// Dependent products (watch apps, app extensions)
    public let dependencies: [ProductDescription]?

    /// Bundle ID, aka CFBundleIdentifier.
    /// CLI tools might not have one.
    public let bundleIdentifier: String?

    public enum DeviceFamily: Codable, Equatable, Hashable, Sendable {
        case iPhone
        case iPad
        case appleTV
        case appleWatch
        case unknown(String)

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self.fromString(value)
        }

        public func encode(to encoder: any Encoder) throws {
            let value = self.asString()
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }

        public func asString() -> String {
            let value: String
            switch self {
            case .iPhone:
                value = "iPhone"
            case .iPad:
                value = "iPad"
            case .appleTV:
                value = "appleTV"
            case .appleWatch:
                value = "appleWatch"
            case .unknown(let raw):
                value = raw
            }
            return value
        }

        static func fromString(_ value: String) -> DeviceFamily {
            switch value {
            case "iPhone":
                return .iPhone
            case "iPad":
                return .iPad
            case "appleTV":
                return .appleTV
            case "appleWatch":
                return .appleWatch
            default:
                return .unknown(value)
            }
        }
    }

    /// iPhone/iPad/Apple TV
    public let targetedDeviceFamilies: [DeviceFamily]?

    /// Minimum OS version.
    public let deploymentTarget: Version

    /// Marketing version string, aka CFBundleShortVersionString.
    public let marketingVersion: String?

    /// Build version string, aka CFBundleVersion.
    /// CLI tools might not have one.
    public let buildVersion: String?

    /// Bitcode - no longer supported
    public let enableBitcode: Bool

    /// Codesigning
    public enum CodesignMode: Codable, Equatable, Hashable, Sendable {
        case automatic
        case manual
        case unknown(String)

        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self.fromString(value)
        }

        public func encode(to encoder: any Encoder) throws {
            let value = self.asString()
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }

        public func asString() -> String {
            let value: String
            switch self {
            case .automatic:
                value = "automatic"
            case .manual:
                value = "manual"
            case .unknown(let raw):
                value = raw
            }
            return value
        }

        static func fromString(_ value: String) -> CodesignMode {
            switch value {
            case "automatic":
                return .automatic
            case "manual":
                return .manual
            default:
                return .unknown(value)
            }
        }
    }
    public let codesign: CodesignMode?

    /// Development team
    public let team: String?

    /// Path to the Info.plist file
    /// Used to set the CFBundleVersion by CI
    /// This is not great and we should instead add a way to set
    /// the build version explicitly. Once we do that, this property
    /// will be removed.
    /// CLI tools might not have one.
    public let infoPlistPath: String?

    /// Path to an icon file, largest available size.
    /// Relative to SRCROOT (parent of the .xcodeproj/.xcworkspace).
    public let iconPath: String?

    public init(
        displayName: String,
        productName: String,
        identifier: String,
        productType: ProductType,
        dependencies: [ProductDescription]?,
        bundleIdentifier: String?,
        targetedDeviceFamilies: [DeviceFamily]?,
        deploymentTarget: Version,
        marketingVersion: String?,
        buildVersion: String?,
        codesign: CodesignMode?,
        team: String?,
        infoPlistPath: String?,
        iconPath: String?
        ) {
        self.displayName = displayName
        self.productName = productName
        self.identifier = identifier
        self.productType = productType
        self.dependencies = dependencies
        self.bundleIdentifier = bundleIdentifier
        self.targetedDeviceFamilies = targetedDeviceFamilies
        self.deploymentTarget = deploymentTarget
        self.marketingVersion = marketingVersion
        self.buildVersion = buildVersion
        self.enableBitcode = false
        self.codesign = codesign
        self.team = team
        self.infoPlistPath = infoPlistPath
        self.iconPath = iconPath
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(14)
        self.displayName = try deserializer.deserialize()
        self.productName = try deserializer.deserialize()
        self.identifier = try deserializer.deserialize()
        self.productType = try ProductType.fromString(deserializer.deserialize())
        self.dependencies = try deserializer.deserialize()
        self.bundleIdentifier = try deserializer.deserialize()
        let targetedDeviceFamilies: [String]? = try deserializer.deserialize()
        self.targetedDeviceFamilies = targetedDeviceFamilies?.map { DeviceFamily.fromString($0) }
        let deploymentTarget: String = try deserializer.deserialize()
        self.deploymentTarget = try Version(deploymentTarget)
        self.marketingVersion = try deserializer.deserialize()
        self.buildVersion = try deserializer.deserialize()
        self.enableBitcode = false
        let codesign: String? = try deserializer.deserialize()
        self.codesign = codesign.map { CodesignMode.fromString($0) }
        self.team = try deserializer.deserialize()
        self.infoPlistPath = try deserializer.deserialize()
        self.iconPath = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(14)
        serializer.serialize(self.displayName)
        serializer.serialize(self.productName)
        serializer.serialize(self.identifier)
        serializer.serialize(self.productType.asString())
        serializer.serialize(self.dependencies)
        serializer.serialize(self.bundleIdentifier)
        serializer.serialize(self.targetedDeviceFamilies?.map { $0.asString() })
        serializer.serialize(self.deploymentTarget.description)
        serializer.serialize(self.marketingVersion)
        serializer.serialize(self.buildVersion)
        serializer.serialize(self.codesign?.asString())
        serializer.serialize(self.team)
        serializer.serialize(self.infoPlistPath)
        serializer.serialize(self.iconPath)
    }
}

/// Tuple of product name + type + bundle ID + destination name.
/// AllProductsInProjectDescription can be used to search for all of these in a given project.
public struct ProductTupleDescription: Equatable, Hashable, Codable, Serializable, Sendable {
    public let displayName: String
    public let productName: String
    public let productType: ProductDescription.ProductType
    public let identifier: String
    public let team: String?
    public let bundleIdentifier: String?
    public let destination: DestinationInfo
    public let containingSchemes: [String]
    public let iconPath: String?

    public init(displayName: String, productName: String, productType: ProductDescription.ProductType, identifier: String, team: String?, bundleIdentifier: String?, destination: DestinationInfo, containingSchemes: [String], iconPath: String?) {
        self.displayName = displayName
        self.productName = productName
        self.productType = productType
        self.identifier = identifier
        self.team = team
        self.bundleIdentifier = bundleIdentifier
        self.destination = destination
        self.containingSchemes = containingSchemes
        self.iconPath = iconPath
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(9)
        self.displayName = try deserializer.deserialize()
        self.productName = try deserializer.deserialize()
        self.productType = try ProductDescription.ProductType.fromString(deserializer.deserialize())
        self.identifier = try deserializer.deserialize()
        self.team = try deserializer.deserialize()
        self.bundleIdentifier = try deserializer.deserialize()
        self.containingSchemes = try deserializer.deserialize()
        self.iconPath = try deserializer.deserialize()
        self.destination = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(9)
        serializer.serialize(self.displayName)
        serializer.serialize(self.productName)
        serializer.serialize(self.productType.asString())
        serializer.serialize(self.identifier)
        serializer.serialize(self.team)
        serializer.serialize(self.bundleIdentifier)
        serializer.serialize(self.containingSchemes)
        serializer.serialize(self.iconPath)
        serializer.serialize(self.destination)
    }
}
