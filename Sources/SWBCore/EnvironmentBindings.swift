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

/// A custom data structure for representing an ordered task environment.
///
/// We almost never inspect the environment, so we make a space/size tradeoff by compactly storing the environment.
public struct EnvironmentBindings: Sendable {
    /// The bindings are stored as one contiguous string
    public let bindings: [(String, String)]

    public var bindingsDictionary: [String: String] {
        var dict = [String: String]()
        for (key, value) in bindings {
            dict[key] = value
        }
        return dict
    }

    /// Create an empty binding map.
    public init() {
        self.bindings = []
    }

    public init(_ bindings: [(String, String)]) {
        self.bindings = bindings
    }

    public init(_ bindings: [String: String]) {
        self.bindings = bindings.map { ($0, $1) }.sorted(by: { $0.0 < $1.0 })
    }

    /// Add a signature of the bindings into the given context.
    public func computeSignature(into ctx: InsecureHashContext) {
        for (variable, val) in bindings {
            // The signature computation should record the variable name and value data, and the positions which divide them.
            ctx.add(string: variable)
            ctx.add(number: 0)
            ctx.add(string: val)
            ctx.add(number: 0)
        }
    }
}

extension EnvironmentBindings: Equatable {
    public static func ==(lhs: EnvironmentBindings, rhs: EnvironmentBindings) -> Bool {
        return lhs.bindingsDictionary == rhs.bindingsDictionary
    }
}

/// Serialization
extension EnvironmentBindings: Serializable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(bindings.map { $0.0 })
        serializer.serialize(bindings.map { $0.1 })
        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.bindings = Array(zip(try deserializer.deserialize(), try deserializer.deserialize()))
    }
}
