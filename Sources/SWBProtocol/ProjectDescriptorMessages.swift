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

public struct DescribeSchemesRequest: SessionChannelMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "SCHEME_DESCRIPTION_REQUESTED"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// Input data about available schemes.
    public let input: [SchemeInput]

    public init(sessionHandle: String, responseChannel: UInt64, input: [SchemeInput]) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.input = input
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.sessionHandle = try deserializer.deserialize()
        self.responseChannel = try deserializer.deserialize()
        self.input = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(3)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.responseChannel)
        serializer.serialize(self.input)
    }
}

public struct DescribeSchemesResponse: Message, Equatable {
    public static let name = "SCHEME_DESCRIPTION_RECEIVED"

    /// A serialized representation of the payload.
    public let schemes: [SchemeDescription]

    public init(schemes: [SchemeDescription]) {
        self.schemes = schemes
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.schemes = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.schemes)
    }
}

public struct DescribeProductsRequest: SessionChannelMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse
    
    public static let name = "PRODUCT_DESCRIPTION_REQUESTED"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// Input data about the action being evaluated.
    public let input: ActionInput

    /// Platform we are evaluating the given action for.
    public let platformName: String

    public init(sessionHandle: String, responseChannel: UInt64, input: ActionInput, platformName: String) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.input = input
        self.platformName = platformName
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.sessionHandle = try deserializer.deserialize()
        self.responseChannel = try deserializer.deserialize()
        self.input = try deserializer.deserialize()
        self.platformName = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(4)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.responseChannel)
        serializer.serialize(self.input)
        serializer.serialize(self.platformName)
    }
}

public struct DescribeProductsResponse: Message, Equatable {
    public static let name = "PRODUCT_DESCRIPTION_RECEIVED"

    /// A serialized representation of the payload.
    public let products: [ProductDescription]

    public init(products: [ProductDescription]) {
        self.products = products
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.products = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.products)
    }
}

public struct DescribeArchivableProductsRequest: SessionChannelMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "ARCHIVABLE_PRODUCTS_DESCRIPTION_REQUESTED"

    /// The identifier for the session to initiate the request in.
    public let sessionHandle: String

    /// The channel to communicate with the client on.
    public let responseChannel: UInt64

    /// Input data about available schemes.
    public let input: [SchemeInput]

    public init(sessionHandle: String, responseChannel: UInt64, input: [SchemeInput]) {
        self.sessionHandle = sessionHandle
        self.responseChannel = responseChannel
        self.input = input
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.sessionHandle = try deserializer.deserialize()
        self.responseChannel = try deserializer.deserialize()
        self.input = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(3)
        serializer.serialize(self.sessionHandle)
        serializer.serialize(self.responseChannel)
        serializer.serialize(self.input)
    }
}

public struct DescribeArchivableProductsResponse: Message, Equatable {
    public static let name = "ARCHIVABLE_PRODUCTS_DESCRIPTION_RECEIVED"

    /// A serialized representation of the payload.
    public let products: [ProductTupleDescription]

    public init(products: [ProductTupleDescription]) {
        self.products = products
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.products = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(self.products)
    }
}

let projectDescriptorMessageTypes: [any Message.Type] = [
    DescribeSchemesRequest.self,
    DescribeSchemesResponse.self,
    DescribeProductsRequest.self,
    DescribeProductsResponse.self,
    DescribeArchivableProductsRequest.self,
    DescribeArchivableProductsResponse.self,
]
