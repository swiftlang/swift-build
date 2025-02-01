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

public final class UniquingSerializationCoordinator {
    private var data: [AnyHashable: Int] = [:]

    public init() {
    }

    public func getOrInsert<T: Hashable>(_ x: T) -> Int? {
        if let existingKey = data[x] {
            return existingKey
        }

        data[x] = data.count
        return nil
    }
}

@available(*, unavailable)
extension UniquingSerializationCoordinator: Sendable { }

public final class UniquingDeserializationCoordinator {
    private var data: [Any] = []

    public init() {
    }

    public func addUnique<T>(_ x : T) {
        data.append(x)
    }

    public func getUnique<T>(at index: Int) throws -> T {
        // Should these errors be fatalErrors? Isn't it a programming error in deserialization logic if you use an out of bounds index or request the wrong type? No: correct code can trigger these conditions if the serialized data is malformed.

        guard index < data.count else { throw DeserializerError.deserializationFailed("Index \(index) out of bounds for unique \(T.self) deserialization") }
        let value = data[index]
        guard let valueT = value as? T else { throw DeserializerError.deserializationFailed("Could not convert \(value) to \(T.self)") }
        return valueT
    }
}

@available(*, unavailable)
extension UniquingDeserializationCoordinator: Sendable { }

public protocol UniquingSerializerDelegate: SerializerDelegate {
    var uniquingCoordinator: UniquingSerializationCoordinator { get }
}

public protocol UniquingDeserializerDelegate: DeserializerDelegate {
    var uniquingCoordinator: UniquingDeserializationCoordinator { get }
}

fileprivate struct UniqueSerializableWrapper<T: Serializable & Hashable>: Serializable {
    let value: T

    init(_ value: T) {
        self.value = value
    }

    func serialize<S: Serializer>(to serializer: S) {
        let coordinator = (serializer.delegate as! (any UniquingSerializerDelegate)).uniquingCoordinator

        serializer.serializeAggregate(2) {
            if let index = coordinator.getOrInsert(value) {
                serializer.serialize(1)
                serializer.serialize(index)
            }
            else {
                serializer.serialize(0)
                value.serialize(to: serializer)
            }
        }
    }

    init(from deserializer: any Deserializer) throws {
        let coordinator = (deserializer.delegate as! (any UniquingDeserializerDelegate)).uniquingCoordinator

        try deserializer.beginAggregate(2)

        let tag: Int = try deserializer.deserialize()
        switch tag {
        case 0:
            self.value = try deserializer.deserialize()
            coordinator.addUnique(self.value)

        case 1:
            let index: Int = try deserializer.deserialize()
            self.value = try coordinator.getUnique(at: index)

        default:
            throw DeserializerError.deserializationFailed("Unknown tag \(tag) for Ref<\(T.self)> deserialization")
        }
    }
}

public extension Serializer {
    func serializeUniquely<T: Serializable & Hashable>(_ x: T) {
        serialize(UniqueSerializableWrapper(x))
    }

    func serializeUniquely<T: Serializable & Hashable>(_ xOpt: T?) {
        if let x = xOpt {
            serializeUniquely(x)
        }
        else {
            serializeNil()
        }
    }
}

public extension Deserializer {
    func deserializeUniquely<T: Serializable & Hashable>() throws -> T {
        return try (deserialize() as UniqueSerializableWrapper<T>).value
    }

    func deserializeUniquely<T: Serializable & Hashable>() throws -> T? {
        if deserializeNil() {
            return nil
        }
        else {
            return try .some(self.deserializeUniquely() as T)
        }
    }
}
