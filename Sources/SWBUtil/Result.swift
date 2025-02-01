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

private enum ResultType: Int, Serializable {
    case success = 0
    case failure = 1
}

extension Result: Serializable where Success: Serializable, Failure: Serializable {
    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(2) {
            switch self {
            case let .success(value):
                serializer.serialize(ResultType.success)
                serializer.serialize(value)
            case let .failure(error):
                serializer.serialize(ResultType.failure)
                serializer.serialize(error)
            }
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as ResultType {
        case .success:
            self = try .success(deserializer.deserialize())
        case .failure:
            self = try .failure(deserializer.deserialize())
        }
    }
}

extension Result {
    public static func catching(_ body: () async throws(Failure) -> Success) async -> Result {
        do {
            let result = try await body()
            return .success(result)
        } catch {
            return .failure(error)
        }
    }
}
