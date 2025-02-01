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
import Testing
import SWBUtil

@Suite fileprivate struct RegistryTests  {

    // Basic test class for use as a registry value.
    final class TestValueClass: Equatable, Sendable {
        let label: String
        init(label: String) {
            self.label = label
        }

        static func ==(lhs: TestValueClass, rhs: TestValueClass) -> Bool {
            return lhs.label == rhs.label
        }
    }

    @Test
    func registryFunctionality() {
        let registry = Registry<String,TestValueClass>()
        #expect(registry["missing"] == nil)

        // Do a lookup-and-insert of a key that shouldn't already be in the registry.
        let valueOne = TestValueClass(label: "one")
        var blockOneHasBeenCalled = false
        let lookedUpValueOne = registry.getOrInsert("111") { () -> TestValueClass in
            blockOneHasBeenCalled = true
            return valueOne
        }
        // Make sure the creator block was called, and that we found the right value.
        #expect(blockOneHasBeenCalled)
        #expect(lookedUpValueOne === valueOne)
        #expect(registry["111"] == valueOne)

        // Do a lookup-and-insert of another key that shouldn't already be in the registry.
        let valueTwo = TestValueClass(label: "two")
        var blockTwoHasBeenCalled = false
        let lookedUpValueTwo = registry.getOrInsert("222") { () -> TestValueClass in
            blockTwoHasBeenCalled = true
            return valueTwo
        }
        // Make sure the creator block was called, and that we found the right value.
        #expect(blockTwoHasBeenCalled)
        #expect(lookedUpValueTwo === valueTwo)

        // Do a lookup-and-insert of a key that should already be in the registry.
        let valueNotUsed = TestValueClass(label: "not-used")
        var blockNotUsedHasBeenCalled = false
        let lookedUpValueNotUsed = registry.getOrInsert("111") { () -> TestValueClass in
            blockNotUsedHasBeenCalled = true
            return valueNotUsed
        }
        // Make sure that we found the original value, and that the block wasn't called.
        #expect(lookedUpValueNotUsed === valueOne)
        #expect(!blockNotUsedHasBeenCalled)

        // Make sure insert works
        #expect(registry["999"] == nil)
        registry.insert("999", value: TestValueClass(label: "foo"))
        #expect(registry["999"] == TestValueClass(label: "foo"))
    }
}
