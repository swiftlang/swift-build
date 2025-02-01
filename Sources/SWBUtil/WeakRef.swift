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

public struct WeakRef<T> {
    private weak var _instance: AnyObject?
    public var instance: T? { _instance as! T? }

    public init(_ instance: T) {
        self._instance = instance as AnyObject
    }
}

extension WeakRef: @unchecked Sendable where T: Sendable {}
