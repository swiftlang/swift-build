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

public struct ComputeDependencyGraphRequest: SessionMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = DependencyGraphResponse

    public static let name = "COMPUTE_DEPENDENCY_GRAPH_REQUEST"

    public let sessionHandle: String
    public let targetGUIDs: [TargetGUID]
    public let buildParameters: BuildParametersMessagePayload
    public let includeImplicitDependencies: Bool
    public let dependencyScope: DependencyScopeMessagePayload

    public init(sessionHandle: String, targetGUIDs: [TargetGUID], buildParameters: BuildParametersMessagePayload, includeImplicitDependencies: Bool, dependencyScope: DependencyScopeMessagePayload) {
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
        let container: KeyedDecodingContainer<ComputeDependencyGraphRequest.CodingKeys> = try decoder.container(keyedBy: ComputeDependencyGraphRequest.CodingKeys.self)

        self.sessionHandle = try container.decode(String.self, forKey: ComputeDependencyGraphRequest.CodingKeys.sessionHandle)
        self.targetGUIDs = try container.decode([TargetGUID].self, forKey: ComputeDependencyGraphRequest.CodingKeys.targetGUIDs)
        self.buildParameters = try container.decode(BuildParametersMessagePayload.self, forKey: ComputeDependencyGraphRequest.CodingKeys.buildParameters)
        self.includeImplicitDependencies = try container.decode(Bool.self, forKey: ComputeDependencyGraphRequest.CodingKeys.includeImplicitDependencies)
        self.dependencyScope = try container.decodeIfPresent(DependencyScopeMessagePayload.self, forKey: ComputeDependencyGraphRequest.CodingKeys.dependencyScope) ?? .workspace

    }

    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<ComputeDependencyGraphRequest.CodingKeys> = encoder.container(keyedBy: ComputeDependencyGraphRequest.CodingKeys.self)

        try container.encode(self.sessionHandle, forKey: ComputeDependencyGraphRequest.CodingKeys.sessionHandle)
        try container.encode(self.targetGUIDs, forKey: ComputeDependencyGraphRequest.CodingKeys.targetGUIDs)
        try container.encode(self.buildParameters, forKey: ComputeDependencyGraphRequest.CodingKeys.buildParameters)
        try container.encode(self.includeImplicitDependencies, forKey: ComputeDependencyGraphRequest.CodingKeys.includeImplicitDependencies)
        try container.encode(self.dependencyScope, forKey: ComputeDependencyGraphRequest.CodingKeys.dependencyScope)
    }
}

public struct DependencyGraphResponse: Message, SerializableCodable, Equatable {
    public static let name = "DEPENDENCY_GRAPH_RESPONSE"

    public let adjacencyList: [TargetGUID: [TargetGUID]]

    public init(adjacencyList: [TargetGUID: [TargetGUID]]) {
        self.adjacencyList = adjacencyList
    }
}


// MARK: Getting declared dependency info


public struct DumpBuildDependencyInfoRequest: SessionChannelBuildMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = VoidResponse
    
    public static let name = "DUMP_BUILD_DEPENDENCY_INFO_REQUEST"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// The request to use to compute the build dependency info to dump.
    public let request: BuildRequestMessagePayload

    /// The path to which the build dependency info should be dumped.
    public let outputPath: String

    public init(sessionHandle: String, responseChannel: UInt64, request: BuildRequestMessagePayload, outputPath: String) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.request = request
        self.outputPath = outputPath
    }
}


// MARK: Registering messages

let dependencyGraphMessageTypes: [any Message.Type] = [
    ComputeDependencyGraphRequest.self,
    DependencyGraphResponse.self,
    DumpBuildDependencyInfoRequest.self,
]
