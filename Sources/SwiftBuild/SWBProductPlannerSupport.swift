//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Request Types

public struct SWBActionInput: Sendable {
    public let configurationName: String
    public let targetIdentifiers: [String]

    public init(configurationName: String, targetIdentifiers: [String]) {
        self.configurationName = configurationName
        self.targetIdentifiers = targetIdentifiers
    }
}

public struct SWBSchemeInput: Sendable {
    public let name: String
    public let isShared: Bool
    public let isAutogenerated: Bool

    public let analyze: SWBActionInput
    public let archive: SWBActionInput
    public let profile: SWBActionInput
    public let run: SWBActionInput
    public let test: SWBActionInput

    public init(name: String, isShared: Bool, isAutogenerated: Bool, analyze: SWBActionInput, archive: SWBActionInput, profile: SWBActionInput, run: SWBActionInput, test: SWBActionInput) {
        self.name = name
        self.isShared = isShared
        self.isAutogenerated = isAutogenerated
        self.analyze = analyze
        self.archive = archive
        self.profile = profile
        self.run = run
        self.test = test
    }
}

// MARK: - Response Types

public struct SWBSchemeDescription: Equatable, Sendable {
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
    public let actions: SWBActionsInfo

    public init(name: String, disambiguatedName: String, isShared: Bool, isAutogenerated: Bool, actions: SWBActionsInfo) {
        self.name = name
        self.disambiguatedName = disambiguatedName
        self.isShared = isShared
        self.isAutogenerated = isAutogenerated
        self.actions = actions
    }
}

/// Describes actions associated with the scheme.
public struct SWBActionsInfo: Equatable, Sendable {
    public let analyze: SWBActionInfo
    public let archive: SWBActionInfo
    public let profile: SWBActionInfo
    public let run: SWBActionInfo
    public let test: SWBActionInfo

    public init(analyze: SWBActionInfo, archive: SWBActionInfo, profile: SWBActionInfo, run: SWBActionInfo, test: SWBActionInfo) {
        self.analyze = analyze
        self.archive = archive
        self.profile = profile
        self.run = run
        self.test = test
    }
}

/// ProductDescription represents an interesting build asset that the user can run or link.
/// Used in describeProducts.
public struct SWBProductDescription: Equatable, Sendable {
    /// Human-readable name of the product's Xcode target.
    public let displayName: String

    /// Product name, e.g. name of the app on the home screen, aka CFBundleName.
    public let productName: String

    /// Internal identifier in the project model.
    public let identifier: String

    public enum ProductType: Hashable, Sendable {
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
    public let dependencies: [SWBProductDescription]?

    /// Bundle ID, aka CFBundleIdentifier.
    /// CLI tools might not have one.
    public let bundleIdentifier: String?

    public enum DeviceFamily: Equatable, Sendable {
        case iPhone
        case iPad
        case appleTV
        case appleWatch
        case unknown(String)

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
    public let deploymentTarget: String

    /// Marketing version string, aka CFBundleShortVersionString.
    public let marketingVersion: String?

    /// Build version string, aka CFBundleVersion.
    /// CLI tools might not have one.
    public let buildVersion: String?

    /// Bitcode
    public let enableBitcode: Bool

    /// Codesigning
    public enum CodesignMode: Equatable, Sendable {
        case automatic
        case manual
        case unknown(String)

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

    public init(displayName: String, productName: String, identifier: String, productType: SWBProductDescription.ProductType, dependencies: [SWBProductDescription]?, bundleIdentifier: String?, targetedDeviceFamilies: [SWBProductDescription.DeviceFamily]?, deploymentTarget: String, marketingVersion: String?, buildVersion: String?, enableBitcode: Bool, codesign: SWBProductDescription.CodesignMode?, team: String?, infoPlistPath: String?, iconPath: String?) {
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
        self.enableBitcode = enableBitcode
        self.codesign = codesign
        self.team = team
        self.infoPlistPath = infoPlistPath
        self.iconPath = iconPath
    }
}

/// Describes a destination.
public struct SWBDestinationInfo: Hashable, Sendable {
    /// Platform name
    public let platformName: String

    /// Whether destination represents a simulator.
    public let isSimulator: Bool

    public init(platformName: String, isSimulator: Bool) {
        self.platformName = platformName
        self.isSimulator = isSimulator
    }
}

/// Describes an action.
public struct SWBActionInfo: Equatable, Sendable {
    /// Build configuration.
    public let configurationName: String

    /// Products built for this action.
    public let products: [SWBProductInfo]

    /// Test plans associated with this action.
    public let testPlans: [SWBTestPlanInfo]?

    public init(configurationName: String, products: [SWBProductInfo], testPlans: [SWBTestPlanInfo]?) {
        self.configurationName = configurationName
        self.products = products
        self.testPlans = testPlans
    }
}

/// Describes a reference to a Test Plan, used in describeSchemes
public struct SWBTestPlanInfo: Equatable, Sendable {
    /// Human-readable name
    public let displayName: String
}

/// Describes a reference to a Product, used in describeSchemes.
public struct SWBProductInfo: Equatable, Sendable {
    /// Human-readable name.
    public let displayName: String

    /// Identifier, used to reference the product in `describeProducts`.
    public let identifier: String

    /// Supported destinations.
    /// We need this here so that we can pass the right platform/destination into the second call.
    public let supportedDestinations: [SWBDestinationInfo]

    public init(displayName: String, identifier: String, supportedDestinations: [SWBDestinationInfo]) {
        self.displayName = displayName
        self.identifier = identifier
        self.supportedDestinations = supportedDestinations
    }
}

/// Tuple of product name + type + bundle ID + destination name.
/// AllProductsInProjectDescription can be used to search for all of these in a given project.
public struct SWBProductTupleDescription: Hashable, Sendable {
    public let displayName: String
    public let productName: String
    public let productType: SWBProductDescription.ProductType
    public let identifier: String
    public let team: String?
    public let bundleIdentifier: String?
    public let destination: SWBDestinationInfo
    public let containingSchemes: [String]
    public let iconPath: String?

    public init(displayName: String, productName: String, productType: SWBProductDescription.ProductType, identifier: String, team: String?, bundleIdentifier: String?, destination: SWBDestinationInfo, containingSchemes: [String], iconPath: String?) {
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
}
