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
import SWBProtocol
import Foundation

/// Provides a generic mechanism to provide project model items to be filterable for a given platform.
public final class PlatformFilter: ProjectModelItem, Hashable, Codable {

    /// The name of the platform, as defined in the LC_BUILD_VERSION info. e.g. macos, ios, etc...
    public let platform: String

    /// Invert the filter
    public let exclude: Bool

    /// The name of the environment, as defined in the LC_BUILD_VERSION info. e.g. simulator, maccatalyst, etc...
    public let environment: String

    /// Initializes a new filter instance.
    public init(platform: String, exclude: Bool = false, environment: String = "") {
        self.platform = platform
        self.exclude = exclude

        // Rev-lock until we update the LLVM target environment to use maccatalyst
        self.environment = environment == "maccatalyst" ? "macabi" : environment
    }

    convenience init(_ model: SWBProtocol.PlatformFilter, _ pifLoader: PIFLoader) {
        self.init(platform: model.platform, environment: model.environment)
    }

    convenience init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        try self.init(
            platform: Self.parseValueForKeyAsString("platform", pifDict: pifDict),
            exclude: Self.parseValueForKeyAsBool("exclude", pifDict: pifDict, defaultValue: false),
            environment: Self.parseOptionalValueForKeyAsString("environment", pifDict: pifDict) ?? ""
        )
    }

    public var description: String {
        return "\(type(of: self)) <platform:\(platform)>" + (!environment.isEmpty ? " <environment:\(environment)>" : "")
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(platform)
        hasher.combine(exclude)
        hasher.combine(environment)
    }

    public static func ==(lhs: PlatformFilter, rhs: PlatformFilter) -> Bool {
        return lhs.platform == rhs.platform && lhs.exclude == rhs.exclude && lhs.environment == rhs.environment
    }
}

extension PlatformFilter: Comparable {
    public static func <(lhs: PlatformFilter, rhs: PlatformFilter) -> Bool {
        return lhs.comparisonString < rhs.comparisonString
    }

    public var comparisonString: String {
        return (exclude ? "!" : "") + platform + (!environment.isEmpty ? "-\(environment)" : "")
    }
}

extension PlatformFilter {
    static func fromBuildConditionParameterString(_ string: String) -> Set<PlatformFilter> {
        return Set(string.components(separatedBy: ";").compactMap {
            let parameters = $0.components(separatedBy: "-")
            let exclude = parameters[0].first == "!"
            let platform = exclude ? String(parameters[0].dropFirst(1)) : parameters[0]
            switch parameters.count {
            case 1:
                return PlatformFilter(platform: platform, exclude: exclude)
            case 2:
                return PlatformFilter(platform: platform, exclude: exclude, environment: parameters[1])
            default:
                return nil
            }
        })
    }
}
