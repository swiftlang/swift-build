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

// FIXME: Workaround: <rdar://problem/26249252> Unable to prefer my own type over NS renamed types
import struct SWBUtil.OrderedSet

@Suite fileprivate struct OrderedSetTests {
    @Test
    func orderedSetBasicFunctionality() {
        var set = OrderedSet<String>()
        #expect(set.isEmpty)
        #expect(set.elements == [])
        #expect(set.first == nil)
        #expect(set.last == nil)

        // Create a new set with some strings.
        set = OrderedSet(["one", "two", "three"])
        #expect(!set.isEmpty)
        #expect(set.count == 3)
        #expect(set[0] == "one")
        #expect(set[1] == "two")
        #expect(set[2] == "three")
        #expect(set.elements == ["one", "two", "three"])
        #expect(set.first == "one")
        #expect(set.last == "three")

        // Try adding the same item again - the set should be unchanged.
        #expect(!set.append("two").inserted)
        #expect(set.count == 3)
        #expect(set[0] == "one")
        #expect(set[1] == "two")
        #expect(set[2] == "three")

        // Remove the last element.
        let three = set.removeLast()
        #expect(set.count == 2)
        #expect(set[0] == "one")
        #expect(set[1] == "two")
        #expect(three == "three")

        // Add some more elements
        #expect(set.append("four").inserted)
        #expect(set.append("five").inserted)
        #expect(set.append("six").inserted)
        #expect(set.count == 5)
        #expect(set[0] == "one")
        #expect(set[1] == "two")
        #expect(set[2] == "four")
        #expect(set[3] == "five")
        #expect(set[4] == "six")
        #expect(set == OrderedSet(["one", "two", "four", "five", "six"]))
        #expect(set.elements == ["one", "two", "four", "five", "six"])
        #expect(set.first == "one")
        #expect(set.last == "six")

        // Remove an item from the middle.
        let four = set.remove(at: 2)
        #expect(set.count == 4)
        #expect(set[0] == "one")
        #expect(set[1] == "two")
        #expect(set[2] == "five")
        #expect(set[3] == "six")
        #expect(four == "four")

        // Insert an item at an index.
        set.insert("seven", at: 3)
        #expect(set.count == 5)
        #expect(set[0] == "one")
        #expect(set[1] == "two")
        #expect(set[2] == "five")
        #expect(set[3] == "seven")
        #expect(set[4] == "six")
        #expect(set == OrderedSet(["one", "two", "five", "seven", "six"]))
        #expect(set.elements == ["one", "two", "five", "seven", "six"])

        // Move an item by inserting it anew at a different index.
        _ = set.firstIndex(of: "one").map { set.remove(at: $0) }
        set.insert("one", at: 4)
        _ = set.firstIndex(of: "six").map { set.remove(at: $0) }
        set.insert("six", at: 1)
        #expect(set.count == 5)
        #expect(set[0] == "two")
        #expect(set[1] == "six")
        #expect(set[2] == "five")
        #expect(set[3] == "seven")
        #expect(set[4] == "one")
        #expect(set == OrderedSet(["two", "six", "five", "seven", "one"]))
        #expect(set.elements == ["two", "six", "five", "seven", "one"])
        #expect(set.first == "two")
        #expect(set.last == "one")

        // Check membership.
        #expect(set.contains("one"))
        #expect(set.contains("two"))
        #expect(!set.contains("three"))
        #expect(!set.contains("four"))
        #expect(set.contains("five"))
        #expect(set.contains("six"))
        #expect(set.contains("seven"))

        // Check indexOf.
        #expect(set.firstIndex(of: "one") == 4)
        #expect(set.firstIndex(of: "two") == 0)
        #expect(set.firstIndex(of: "three") == nil)
        #expect(set.firstIndex(of: "four") == nil)
        #expect(set.firstIndex(of: "five") == 2)
        #expect(set.firstIndex(of: "six") == 1)
        #expect(set.firstIndex(of: "seven") == 3)

        // Iterate over the objects and add them to an array.
        var array = [String]()
        for str in set
        {
            array.append(str)
        }
        #expect(array == ["two", "six", "five", "seven", "one"])
        #expect(array == set.elements)

        // Remove all the objects.
        set.removeAll(keepingCapacity: true)
        #expect(set.count == 0)
        #expect(set.isEmpty)
        #expect(set.elements == [])
    }

    @Test
    func append() {
        var set = OrderedSet<String>()
        #expect(set.isEmpty)

        set.append("one")
        #expect(set.elements == ["one"])

        set.append(contentsOf: ["two", "three"])
        #expect(set.elements == ["one", "two", "three"])

        set.append(contentsOf: OrderedSet(["four", "five"]))
        #expect(set.elements == ["one", "two", "three", "four", "five"])

        set.append(contentsOf: ["two", "four", "six"])
        #expect(set.elements == ["one", "two", "three", "four", "five", "six"])

        #expect(OrderedSet(["one", "two"]).appending(contentsOf: OrderedSet(["three", "four", "five"])).elements == ["one", "two", "three", "four", "five"])
        #expect(OrderedSet(["one", "two"]).appending(contentsOf: OrderedSet(["one", "four", "five"])).elements == ["one", "two", "four", "five"])
        #expect(OrderedSet(["one", "two"]).appending(contentsOf: ["three", "four", "five"]).elements == ["one", "two", "three", "four", "five"])
        #expect(OrderedSet(["one", "two"]).appending(contentsOf: ["one", "four", "five"]).elements == ["one", "two", "four", "five"])
    }

    @Test
    func subtraction() {
        var employees = OrderedSet(["Alicia", "Bethany", "Chris", "Diana", "Eric"])
        let neighbors = OrderedSet(["Bethany", "Eric", "Forlani", "Greta"])

        let nonNeighbors = employees.subtracting(neighbors)
        #expect(nonNeighbors == OrderedSet(["Alicia", "Chris", "Diana"]))

        employees.subtract(neighbors)
        #expect(employees == OrderedSet(["Alicia", "Chris", "Diana"]))
    }

    @Test
    func conversion() {
        #expect(Set(OrderedSet(arrayLiteral: "Alicia", "Bethany", "Chris", "Diana", "Eric")) == Set(["Alicia", "Bethany", "Chris", "Diana", "Eric"]))
    }

    @Test
    func arrayLiteralConversion() {
        let employees: OrderedSet<String> = ["Alicia", "Bethany", "Chris", "Diana", "Eric"]
        let neighbors: OrderedSet<String> = ["Bethany", "Eric", "Forlani", "Greta"]
        let empty: OrderedSet<String> = []

        #expect(employees.elements == ["Alicia", "Bethany", "Chris", "Diana", "Eric"])
        #expect(neighbors.elements == ["Bethany", "Eric", "Forlani", "Greta"])
        #expect(empty.elements == [])
    }
}
