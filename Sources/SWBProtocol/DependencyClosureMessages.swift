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

public struct ComputeDependencyClosureRequest: SessionMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = StringListResponse
    
    public static let name = "COMPUTE_DEPENDENCY_CLOSURE_REQUEST"

    public let sessionHandle: String
    public let targetGUIDs: [String]
    public let buildParameters: BuildParametersMessagePayload
    public let includeImplicitDependencies: Bool
    public let dependencyScope: DependencyScopeMessagePayload

    public init(sessionHandle: String, targetGUIDs: [String], buildParameters: BuildParametersMessagePayload, includeImplicitDependencies: Bool, dependencyScope: DependencyScopeMessagePayload) {
        self.sessionHandle = sessionHandle
        self.targetGUIDs = targetGUIDs
        self.buildParameters = buildParameters
        self.includeImplicitDependencies = includeImplicitDependencies
        self.dependencyScope = dependencyScope
    }

    enum CodingKeys: CodingKey {
        case sessionHandle
        case targetGUIDs
        case buildParameters
        case includeImplicitDependencies
        case dependencyScope
    }

    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<ComputeDependencyClosureRequest.CodingKeys> = try decoder.container(keyedBy: ComputeDependencyClosureRequest.CodingKeys.self)

        self.sessionHandle = try container.decode(String.self, forKey: ComputeDependencyClosureRequest.CodingKeys.sessionHandle)
        self.targetGUIDs = try container.decode([String].self, forKey: ComputeDependencyClosureRequest.CodingKeys.targetGUIDs)
        self.buildParameters = try container.decode(BuildParametersMessagePayload.self, forKey: ComputeDependencyClosureRequest.CodingKeys.buildParameters)
        self.includeImplicitDependencies = try container.decode(Bool.self, forKey: ComputeDependencyClosureRequest.CodingKeys.includeImplicitDependencies)
        self.dependencyScope = try container.decodeIfPresent(DependencyScopeMessagePayload.self, forKey: ComputeDependencyClosureRequest.CodingKeys.dependencyScope) ?? .workspace

    }

    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<ComputeDependencyClosureRequest.CodingKeys> = encoder.container(keyedBy: ComputeDependencyClosureRequest.CodingKeys.self)

        try container.encode(self.sessionHandle, forKey: ComputeDependencyClosureRequest.CodingKeys.sessionHandle)
        try container.encode(self.targetGUIDs, forKey: ComputeDependencyClosureRequest.CodingKeys.targetGUIDs)
        try container.encode(self.buildParameters, forKey: ComputeDependencyClosureRequest.CodingKeys.buildParameters)
        try container.encode(self.includeImplicitDependencies, forKey: ComputeDependencyClosureRequest.CodingKeys.includeImplicitDependencies)
        try container.encode(self.dependencyScope, forKey: ComputeDependencyClosureRequest.CodingKeys.dependencyScope)
    }
}

let dependencyClosureMessageTypes: [any Message.Type] = [
    ComputeDependencyClosureRequest.self
]
