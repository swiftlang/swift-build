//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SWBUtil
import SWBProtocol
import Foundation

public final class BuildConfigurationFilter: ProjectModelItem, Hashable, Codable {

    /// The name of the build configuration
    public let buildConfiguration: String

    public init(buildConfiguration: String) {
        self.buildConfiguration = buildConfiguration
    }

    convenience init(_ model: SWBProtocol.BuildConfigurationFilter, _ pifLoader: PIFLoader) {
        self.init(buildConfiguration: model.buildConfiguration)
    }

    convenience init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        try self.init(
            buildConfiguration: Self.parseValueForKeyAsString("buildConfiguration", pifDict: pifDict)
        )
    }

    public var description: String {
        return "\(type(of: self)) <buildConfiguration:\(buildConfiguration)>"
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(buildConfiguration)
    }

    public static func ==(lhs: BuildConfigurationFilter, rhs: BuildConfigurationFilter) -> Bool {
        return lhs.buildConfiguration == rhs.buildConfiguration
    }
}

extension BuildConfigurationFilter: Comparable {
    public static func <(lhs: BuildConfigurationFilter, rhs: BuildConfigurationFilter) -> Bool {
        return lhs.buildConfiguration < rhs.buildConfiguration
    }

    public var comparisonString: String {
        return buildConfiguration
    }
}
