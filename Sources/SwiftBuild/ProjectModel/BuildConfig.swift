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

import Foundation
import SWBProtocol

extension ProjectModel {
    /// A build configuration, which is a named collection of build settings.
    public struct BuildConfig: Sendable, Hashable, Identifiable {
        public let id: GUID
        public var name: String
        public var settings: BuildSettings
        public var impartedBuildProperties: ImpartedBuildProperties
        
        public init(id: GUID, name: String, settings: BuildSettings, impartedBuildSettings: BuildSettings = .init()) {
            precondition(!name.isEmpty)
            self.id = id
            self.name = name
            self.settings = settings
            self.impartedBuildProperties = ImpartedBuildProperties(settings: impartedBuildSettings)
        }
    }
}

extension ProjectModel.BuildConfig: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        self.name = try container.decode(String.self, forKey: .name)
        self.settings = try container.decode(ProjectModel.BuildSettings.self, forKey: .buildSettings)
        self.impartedBuildProperties = try container.decode(ProjectModel.ImpartedBuildProperties.self, forKey: .impartedBuildProperties)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .guid)
        try container.encode(name, forKey: .name)
        try container.encode(settings, forKey: .buildSettings)
        try container.encode(impartedBuildProperties, forKey: .impartedBuildProperties)
    }

    enum CodingKeys: String, CodingKey {
        case guid
        case name
        case buildSettings
        case impartedBuildProperties
    }
}

