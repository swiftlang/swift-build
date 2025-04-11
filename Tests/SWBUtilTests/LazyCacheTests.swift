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
import SWBUtil
import Testing
import Synchronization

@Suite fileprivate struct LazyCacheTests {
    @Test
    func lazyCache() async {
        final class Foo {
            private var expensiveStuff: [String] = []

            let barCache = LazyCache { (foo: Foo) -> [String] in
                foo.expensiveStuff.append("foo")
                foo.expensiveStuff.append("bar")
                foo.expensiveStuff.append("baz")
                return foo.expensiveStuff
            }

            var bar: [String] {
                return barCache.getValue(self)
            }
        }

        let foo = SWBMutex<Foo>(.init())
        _ = await (0..<100).concurrentMap(maximumParallelism: 100) { _ in
            #expect(foo.withLock { $0.bar } == ["foo", "bar", "baz"])
        }
        #expect(foo.withLock { $0.bar } == ["foo", "bar", "baz"])
    }

    @Test
    func lazyKeyValueCache() async {
        final class NumberStringifier: Sendable {
            private let numberStringsCache = LazyKeyValueCache<NumberStringifier, Int, String> { _, key in
                return "\(key)"
            }

            public func stringForNumber(value: Int) -> String {
                return numberStringsCache.getValue(self, forKey: value)
            }
        }

        let stringifier = NumberStringifier()
        _ = await (0..<1000).concurrentMap(maximumParallelism: 100) { i in
            #expect(stringifier.stringForNumber(value: i) == "\(i)")
        }
    }
}
