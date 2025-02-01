//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public typealias ByteStringArena = InterningArena<ByteString>
public typealias StringArena = InterningArena<String>

private let numberOfInternCalls = Statistic("InterningArena.numberOfInternCalls", "Number of calls to 'InterningArena.intern'")
private let numberOfItemsInterned = Statistic("InterningArena.numberOfItemsInterned", "Number of items interned in InterningArenas")

public class InterningArena<T: Hashable> {
    public struct Handle: Hashable, Sendable {
        fileprivate let value: UInt32

        fileprivate init(value: UInt32) {
            self.value = value
        }
    }
    private var uniquer: [T: Handle]? = [:]
    private var items: [T] = []

    public init() {}

    public func intern(_ item: T) -> Handle {
        assert(uniquer != nil, "api misuse: attempted to intern a string in a frozen arena")
        numberOfInternCalls.increment()
        if let existingHandle = uniquer?[item] {
            return existingHandle
        } else {
            numberOfItemsInterned.increment()
            let newHandle = Handle(value: UInt32(items.count))
            items.append(item)
            uniquer?[item] = newHandle
            return newHandle
        }
    }

    public func lookup(handle: Handle) -> T {
        return items[Int(handle.value)]
    }

    public func freeze() {
        uniquer = nil
    }
}

@available(*, unavailable)
extension InterningArena: Sendable { }
