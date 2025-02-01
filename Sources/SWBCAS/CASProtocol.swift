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

public protocol CASProtocol: Sendable {
    associatedtype Object: CASObjectProtocol
    typealias DataID = Object.DataID

    func store(object: Object) async throws -> DataID
    func load(id: DataID) async throws -> Object?
}

public protocol ActionCacheProtocol: Sendable {
    associatedtype DataID: Equatable, Sendable

    func cache(objectID: DataID, forKeyID key: DataID) async throws
    func lookupCachedObject(for keyID: DataID) async throws -> DataID?
}

public protocol CASObjectProtocol: Equatable, Sendable {
    associatedtype DataID: Equatable, Sendable

    var data: ByteString { get }
    var refs: [DataID] { get }

    init(data: ByteString, refs: [DataID])
}
