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

public enum ProjectModel: Sendable {}

extension ProjectModel {
    /// The type used for identifying PIF objects.
    public struct GUID: ExpressibleByStringInterpolation, Hashable, Sendable, Codable {
        public private(set) var value: String

        public init(_ value: String) {
            self.value = value
        }

        public init(stringLiteral value: StringLiteralType) {
            self.value = value
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.value = try container.decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.value)
        }
    }

    enum Error: Swift.Error {
        case duplicatedTargetIdentifier(targetIdentifier: GUID, targetName: String, productName: String)
        case emptyTargetIdentifier(targetName: String, productName: String)
        case emptyTargetName(targetIdentifier: GUID, productName: String)
    }

    /// This is used as part of the signature for the high-level PIF objects, to ensure that changes to the PIF schema are represented by the objects which do not use a content-based signature scheme (workspaces and projects, currently).
    public static var pifEncodingSchemaVersion: Int {
        return PIFObject.supportedPIFEncodingSchemaVersion
    }

    public struct XTag<S, T>: Sendable, Hashable where T: Sendable & Hashable {
        var value: T
    }
    public typealias Tag<S> = XTag<S, GUID>

    @dynamicMemberLookup
    public protocol Common {
        associatedtype Delegate
        var common: Delegate { get set }
    }

    /// Signature for a function to create an instance with a default GUID provided.
    public typealias CreateFn<T> = (GUID) -> T
}

extension ProjectModel.Common {
    public subscript<T>(dynamicMember keyPath: KeyPath<Delegate, T>) -> T {
        _read {
            yield common[keyPath: keyPath]
        }
    }
    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Delegate, T>) -> T {
        _read {
            yield common[keyPath: keyPath]
        }
        _modify {
            yield &common[keyPath: keyPath]
        }
    }
}

extension Array where Element: Identifiable {
    subscript(id id: Element.ID) -> Element {
        get {
            first(where: { $0.id == id })!
        }
        set {
            self[firstIndex(where: { $0.id == id })!] = newValue
        }
    }

}
