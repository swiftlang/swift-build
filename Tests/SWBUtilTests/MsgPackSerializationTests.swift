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
import SWBTestSupport
import SWBUtil

@Suite fileprivate struct MsgPackSerializationTests {
    /// Test serializing the various scalar built-in types.
    @Test
    func scalarValueSerialization() throws {
        enum IntRawValueType: Int, Serializable {
            case this = 0
            case that = 1
        }
        enum StringRawValueType: String, Serializable {
            case thisString = "this"
            case thatString = "that"
        }

        // Serialize!
        let sz = MsgPackSerializer()
        // Int
        sz.serialize(3)
        sz.serialize(0)
        sz.serialize(-27)
        sz.serialize(4029)
        sz.serialize(Int.min)
        sz.serialize(Int.max)
        // Bool
        sz.serialize(true)
        // UInt
        sz.serialize(6 as UInt)
        sz.serialize(0 as UInt)
        sz.serialize(82946 as UInt)
        sz.serialize(UInt.max)
        // Int32
        sz.serialize(Int32.min)
        sz.serialize(0 as Int32)
        sz.serialize(Int32.max)
        // UInt32
        sz.serialize(UInt32.min)
        sz.serialize(0 as UInt32)
        sz.serialize(UInt32.max)
        // Int64
        sz.serialize(Int64.min)
        sz.serialize(0 as Int64)
        sz.serialize(Int64.max)
        // UInt64
        sz.serialize(UInt64.min)
        sz.serialize(0 as UInt64)
        sz.serialize(UInt64.max)
        // Float32
        sz.serialize(0.7 as Float32)
        sz.serialize(0.0 as Float32)
        sz.serialize(-4.33 as Float32)
        sz.serialize(2.71828 as Float32)
        // Bool again
        sz.serialize(false)
        // Float64
        sz.serialize(6.1 as Float64)
        sz.serialize(0.0 as Float64)
        sz.serialize(-10.4 as Float64)
        sz.serialize(3.1415926535 as Float64)
        // String
        sz.serialize("Something")
        sz.serialize("")
        sz.serialize("Another String")
        // Byte array
        sz.serialize([UInt8]("Some bytes".utf8))
        sz.serialize([UInt8]("".utf8))
        // Array
        sz.serialize([1, 2, 3])
        sz.serialize([[1, 2], [], [3], [4, 5, 6]])
        // Enums
        sz.serialize(IntRawValueType.this)
        sz.serialize(IntRawValueType.that)
        sz.serialize(StringRawValueType.thisString)
        sz.serialize(StringRawValueType.thatString)
        // Range
        sz.serialize(Range(uncheckedBounds: (lower: 3, upper: 9)))
        sz.serialize(Range(uncheckedBounds: (lower: "a", upper: "k")))

        // Deserialize!
        let dsz = MsgPackDeserializer(sz.byteString)
        // Int
        #expect(try dsz.deserialize() == 3)
        #expect(try dsz.deserialize() == 0)
        #expect(try dsz.deserialize() == -27)
        #expect(try dsz.deserialize() == 4029)
        #expect(try dsz.deserialize() == Int.min)
        #expect(try dsz.deserialize() == Int.max)
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as Int
        }                  // Next element is not an Int
        // Bool
        #expect(try dsz.deserialize())
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as Bool
        }                 // Next element is not a Bool
        // UInt
        #expect(try dsz.deserialize() == 6 as UInt)
        #expect(try dsz.deserialize() == 0 as UInt)
        #expect(try dsz.deserialize() == 82946 as UInt)
        #expect(try dsz.deserialize() == UInt.max)
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as UInt
        }                 // Next element is not a UInt
        // Int32
        #expect(try dsz.deserialize() as Int32 == Int32.min)
        #expect(try dsz.deserialize() as Int32 == 0 as Int32)
        #expect(try dsz.deserialize() as Int32 == Int32.max)
        // UInt32
        #expect(try dsz.deserialize() as UInt32 == UInt32.min)
        #expect(try dsz.deserialize() as UInt32 == 0 as UInt32)
        #expect(try dsz.deserialize() as UInt32 == UInt32.max)
        // Int64
        #expect(try dsz.deserialize() as Int64 == Int64.min)
        #expect(try dsz.deserialize() as Int64 == 0 as Int64)
        #expect(try dsz.deserialize() as Int64 == Int64.max)
        // UInt64
        #expect(try dsz.deserialize() as UInt64 == UInt64.min)
        #expect(try dsz.deserialize() as UInt64 == 0 as UInt64)
        #expect(try dsz.deserialize() as UInt64 == UInt64.max)
        // Float32
        #expect(try dsz.deserialize() as Float32 == 0.7)
        #expect(try dsz.deserialize() as Float32 == 0.0)
        #expect(try dsz.deserialize() as Float32 == -4.33)
        #expect(try dsz.deserialize() as Float32 == 2.71828)
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as Float32
        }              // Next element is not a Float32
        // Bool again
        #expect(try !dsz.deserialize())
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as Bool
        }                 // Next element is not a Bool
        // Float64
        #expect(try dsz.deserialize() as Float64 == 6.1)
        #expect(try dsz.deserialize() as Float64 == 0.0)
        #expect(try dsz.deserialize() as Float64 == -10.4)
        #expect(try dsz.deserialize() as Float64 == 3.1415926535)
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as Float64
        }              // Next element is not a Float64
        // String
        #expect(try dsz.deserialize() == "Something")
        #expect(try dsz.deserialize() == "")
        #expect(try dsz.deserialize() == "Another String")
        // Byte array
        #expect(try dsz.deserialize() == [UInt8]("Some bytes".utf8))
        #expect(try dsz.deserialize() == [UInt8]("".utf8))
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as String
        }               // Next element is not a String
        // Array
        #expect(try dsz.deserialize() == [1, 2, 3])

        do {
            let arrays = try dsz.deserialize() as [[Int]]
            let expected = [[1, 2], [], [3], [4, 5, 6]]
            #expect(arrays.count == expected.count)
            #expect(!zip(arrays, expected).contains(where: { $0.0 != $0.1 }))
        }

        // Enums
        #expect(try dsz.deserialize() as IntRawValueType == .this)
        #expect(try dsz.deserialize() as IntRawValueType == .that)
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as IntRawValueType
        }      // Next element is not a IntRawValueType
        #expect(try dsz.deserialize() as StringRawValueType == .thisString)
        #expect(try dsz.deserialize() as StringRawValueType == .thatString)
        // Range
        #expect(try dsz.deserialize() as Range<Int> == Range(uncheckedBounds: (lower: 3, upper: 9)))
        #expect(try dsz.deserialize() as Range<String> == Range(uncheckedBounds: (lower: "a", upper: "k")))
    }

    /// Test serializing simple arrays.
    ///
    /// This also exercises the individual simple types' deserialization and init methods.
    @Test
    func simpleArraySerialization() throws {
        do
        {
            let array: [Int] = [13, 6, -6,-33231, 14, 242432, 0, -83]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(array)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszArray: [Int] = try dsz.deserialize()
            #expect(dszArray == array)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [Int]
            }                // Next element is not an Array
            // Nothing left to deserialize.
        }
        do
        {
            let array: [UInt] = [21, 7, 0, 3322, 1]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(array)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszArray: [UInt] = try dsz.deserialize()
            #expect(dszArray == array)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [UInt]
            }               // Next element is not an Array
            // Nothing left to deserialize.
        }
        do
        {
            let array: [Bool] = [true, true, false, true, false, false, false, false, false]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(array)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszArray: [Bool] = try dsz.deserialize()
            #expect(dszArray == array)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [Bool]
            }               // Next element is not an Array
            // Nothing left to deserialize.
        }
        do
        {
            let array: [Float32] = [19.0, -66.2, 1.9, 0, -0.00003, 34222.6]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(array)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszArray: [Float32] = try dsz.deserialize()
            #expect(dszArray == array)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [Float32]
            }               // Next element is not an Array
            // Nothing left to deserialize.
        }
        do
        {
            let array: [Float64] = [-2323.1, 44, 0.0, -0.999999991, 0.0000000072, 23222218, 3]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(array)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszArray: [Float64] = try dsz.deserialize()
            #expect(dszArray == array)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [Float64]
            }               // Next element is not an Array
            // Nothing left to deserialize.
        }
        do
        {
            let array = ["One thing", "Something else", "Anything", "", "Nothing"]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(array)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszArray: [String] = try dsz.deserialize()
            #expect(dszArray == array)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [String]
            }             // Next element is not an Array
            // Nothing left to deserialize.
        }
    }

    /// Test serializing simple dictionaries.
    @Test
    func stringToIntDictionarySerialization() throws {
        let dict = ["one": 1, "two": 2, "three": 3, "": 0]

        // Serialize!
        let sz = MsgPackSerializer()
        sz.serialize(dict)

        // Deserialize!
        let dsz = MsgPackDeserializer(sz.byteString)
        let dszDict: [String: Int] = try dsz.deserialize()
        #expect(dszDict == dict)
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as [String: Int]
        }        // Next element is not a Dictionary
    }

    /// Test serializing Range objects.
    @Test
    func simpleObjectSerialization() throws {
        do
        {
            let r1 = IntRange(uncheckedBounds: (0, 5))
            let r2 = IntRange(uncheckedBounds: (-16, -4))
            let r3 = IntRange(uncheckedBounds: (-6, 6))

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(r1)
            sz.serialize(r2)
            sz.serialize(r3)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            #expect(try dsz.deserialize() as IntRange == r1)
            #expect(try dsz.deserialize() as IntRange == r2)
            #expect(try dsz.deserialize() as IntRange == r3)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as IntRange
            }                 // Next element is not an IntRange
            // Nothing left to deserialize.
        }

        // Next serialize an array of Range objects.
        do
        {
            let array = [
                IntRange(uncheckedBounds: (-3, 2)),
                IntRange(uncheckedBounds: (14, 19)),
                IntRange(uncheckedBounds: (-9, 9)),
                IntRange(uncheckedBounds: (-42332, 8392239)),
                IntRange(uncheckedBounds: (-1, 0)),
            ]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(array)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszArray: [IntRange] = try dsz.deserialize()
            #expect(dszArray == array)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [IntRange]
            }               // Next element is not an Array
            // Nothing left to deserialize.
        }

        // Serialize a dictionary whose values are Range objects.
        do
        {
            let dict = [
                "one": IntRange(uncheckedBounds: (1, 4)),
                "two": IntRange(uncheckedBounds: (-13, -2)),
                "three": IntRange(uncheckedBounds: (-99, -3)),
                "infinity": IntRange(uncheckedBounds: (0, 43793218932)),
            ]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(dict)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszDict: [String: IntRange] = try dsz.deserialize()
            #expect(dszDict == dict)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [String: IntRange]
            }       // Next element is not a Dictionary
            // Nothing left to deserialize.
        }

        // Serialize a dictionary whose keys are Range objects.
        do
        {
            let dict = [
                IntRange(uncheckedBounds: (4, 9)): 13,
                IntRange(uncheckedBounds: (-6, 14)): 8,
                IntRange(uncheckedBounds: (0, 3)): 3,
            ]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(dict)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszDict: [IntRange: Int] = try dsz.deserialize()
            #expect(dszDict == dict)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [IntRange: Int]
            }          // Next element is not a Dictionary
            // Nothing left to deserialize.
        }
    }

    /// Test serializing polymorphic arrays.
    @Test
    func polymorphicArraySerialization() throws {
        let array = [
            A(name: "one"),
            B(name: "two", number: 21),
            C(name: "three", truth: true),
            A(name: "four"),
            C(name: "five", truth: false),
        ]

        // Serialize!
        let sz = MsgPackSerializer()
        sz.serialize(array)

        // Deserialize!
        let dsz = MsgPackDeserializer(sz.byteString)
        let dszArray: [A] = try dsz.deserialize()
        #expect(dszArray == array)
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as [A]
        }                  // Next element is not an Array
    }

    /// Test serializing dictionaries with polymorphic values.
    @Test
    func polymorphicDictionarySerialization() throws {
        do
        {
            let dict = [
                "one":      A(name: "one"),
                "two":      B(name: "two", number: 21),
                "three":    C(name: "three", truth: true),
                "four":     A(name: "four"),
                "five":     C(name: "five", truth: false),
            ]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(dict)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszDict: [String: A] = try dsz.deserialize()
            #expect(dszDict == dict)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [String: A]
            }      // Next element is not a Dictionary
            // Nothing left to deserialize.
        }

        // Keys are PolymorphicSerializable, values are Serializable.
        do
        {
            let dict = [
                A(name: "ten"): "tenth",
                B(name: "twenty", number: -27): "twentieth",
                C(name: "thirty", truth: true): "thirtieth",
                A(name: "forty"): "fortieth",
                C(name: "fifty", truth: false): "fiftieth",
            ]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(dict)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszDict: [A: String] = try dsz.deserialize()
            #expect(dszDict == dict)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [String: A]
            }      // Next element is not a Dictionary
            // Nothing left to deserialize.
        }

        // Keys and values are PolymorphicSerializable.
        do
        {
            let dict = [
                A(name: "umpteen"): C(name: "argl", truth: true),
                B(name: "vumpteen", number: 666): A(name: "bargl"),
                C(name: "wumpteen", truth: true): B(name: "cargyle", number: 0),
                A(name: "xumpteen"): B(name: "dargl", number: -13),
                C(name: "andsometimesy", truth: false): A(name: "eargl"),
                C(name: "zumpteen", truth: true): B(name: "finally", number: 42),
            ]

            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(dict)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszDict: [A: A] = try dsz.deserialize()
            #expect(dszDict == dict)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as [String: A]
            }      // Next element is not a Dictionary
            // Nothing left to deserialize.
        }
    }

    // Test serializing optional values.
    @Test
    func optionalSerialization() throws {
        var optionality = OptionalTester()
        do
        {
            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(optionality)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszOpt: OptionalTester = try dsz.deserialize()
            #expect(dszOpt == optionality)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as OptionalTester
            }       // Next element is not an OptionalTester
            // Nothing left to deserialize.
        }

        // Now set up data in some - but not all - of our test object's properties and try that.
        optionality.stringOne = "Some string!"
        optionality.arrayOne = [ 1, 1, 2, 3, 5, 8, 13, 21 ]
        optionality.dictOne = [ "a": 4, "b": 19, "c": 0, "dee": -5 ]
        optionality.objectOne = A(name: "ayyyy")
        optionality.objArrayOne = [ A(name: "aye"), B(name: "bee", number: 7) ]
        optionality.objDictOne = [ "yes": C(name: "see", truth: true), "no": C(name: "no see", truth: false), "maybe": A(name: "maybe not") ]
        optionality.objDictThree = [ A(name: "some"): 1, A(name: "none"): 0 ]
        optionality.objDictFive = [ A(name: "any"): B(name: "many", number: 46), C(name: "nany", truth: false): A(name: "nope") ]
        do
        {
            // Serialize!
            let sz = MsgPackSerializer()
            sz.serialize(optionality)

            // Deserialize!
            let dsz = MsgPackDeserializer(sz.byteString)
            let dszOpt: OptionalTester = try dsz.deserialize()
            #expect(dszOpt == optionality)
            #expect(throws: (any Error).self) {
                try dsz.deserialize() as OptionalTester
            }       // Next element is not an OptionalTester
            // Nothing left to deserialize.
        }
    }

    /// Test serializing a simple object.
    @Test
    func trivialObjectHierarchySerialization() throws {
        let msg = TestLogMessage(type: .error, message: "Something went wrong")

        // Serialize!
        let sz = MsgPackSerializer()
        sz.serialize(msg)

        // Deserialize!
        let dsz = MsgPackDeserializer(sz.byteString)
        let dszMsg: TestLogMessage = try dsz.deserialize()
        #expect(dszMsg == msg)
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as TestLogMessage
        }       // Next element is not a TestLogMessage
    }

    /// Test serializing our log objects.
    @Test
    func objectHierarchySerialization() throws {
        let log = TestLogHeader("Log")
        let fwkTarget = TestLogHeader("Framework")
        log.addEntry(fwkTarget)
        fwkTarget.addEntry(TestLogSection("Copy Foo.h"))
        fwkTarget.addEntry(TestLogSection("Compile Foo.m"))
        fwkTarget.addEntry(TestLogSection("Link Foo"))
        fwkTarget.addEntry(TestLogSection("Touch Foo.framework"))
        let appTarget = TestLogHeader("App")
        log.addEntry(appTarget)
        let compile = TestLogSection("Compile Class.m")
        compile.addMessage(TestLogMessage(type: .error, message: "Something went wrong"))
        appTarget.addEntry(compile)
        appTarget.addEntry(TestLogSection("Link App"))
        appTarget.addEntry(TestLogSection("Copy Framework into App"))
        appTarget.addEntry(TestLogSection("Touch App.app"))

        // Serialize!
        let sz = MsgPackSerializer()
        sz.serialize(log)

        // Deserialize!
        let dsz = MsgPackDeserializer(sz.byteString)
        let dszLog: TestLogHeader = try dsz.deserialize()
        #expect(dszLog == log)
        #expect(throws: (any Error).self) {
            try dsz.deserialize() as TestLogHeader
        }        // Next element is not a TestLogHeader
    }


    // Uniquing serialization

    let uniqueSerializationTestValue = (1..<10).map{ "\($0)" }.joined()

    class UniquingSerializerDelegateImpl: UniquingSerializerDelegate {
        let uniquingCoordinator = UniquingSerializationCoordinator()
    }

    class UniquingDeserializerDelegateImpl: UniquingDeserializerDelegate {
        let uniquingCoordinator = UniquingDeserializationCoordinator()
    }

    @Test
    func uniqueSerializationBasics() throws {
        let serializer = MsgPackSerializer(delegate: UniquingSerializerDelegateImpl())
        serializer.serializeAggregate(3) {
            serializer.serializeUniquely(uniqueSerializationTestValue)
            serializer.serialize(3)
            serializer.serializeUniquely(uniqueSerializationTestValue)
        }
        let serializedData = serializer.byteString

        let deserializer = MsgPackDeserializer(serializedData, delegate: UniquingDeserializerDelegateImpl())
        try deserializer.beginAggregate(3)
        #expect(try uniqueSerializationTestValue == deserializer.deserializeUniquely())
        #expect(try 3 == deserializer.deserialize())
        #expect(try uniqueSerializationTestValue == deserializer.deserializeUniquely())
    }

    @Test
    func uniqueSerializationSizeWin() {
        let value = (1..<1000).map{ "\($0)" }.joined()

        let s0 = MsgPackSerializer()
        s0.serialize(value)
        s0.serialize(value)
        let b0 = s0.byteString

        let s1 = MsgPackSerializer(delegate: UniquingSerializerDelegateImpl())
        s1.serializeUniquely(value)
        s1.serializeUniquely(value)
        let b1 = s1.byteString

        #expect(b0.count > b1.count)
    }
}


// MARK: Classes for testing simple objects.


private class IntRange: Serializable, Equatable, Hashable, Comparable
{
    let range: Range<Int>

    init(uncheckedBounds bounds: (lower: Int, upper: Int))
    {
        self.range = Range(uncheckedBounds: (bounds.lower, bounds.upper))
    }

    var lowerBound: Int { return self.range.lowerBound }
    var upperBound: Int { return self.range.upperBound }

    func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(2)
        serializer.serialize(lowerBound)
        serializer.serialize(upperBound)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(2)
        let lower: Int = try deserializer.deserialize()
        let upper: Int = try deserializer.deserialize()
        self.range = Range(uncheckedBounds: (lower, upper))
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(lowerBound)
        hasher.combine(upperBound)
    }

    static func < (lhs: IntRange, rhs: IntRange) -> Bool {
        return (lhs.lowerBound, lhs.upperBound) < (rhs.lowerBound, rhs.upperBound)
    }
}


private func ==(lhs: IntRange, rhs: IntRange) -> Bool
{
    return lhs.range == rhs.range
}


// MARK: Classes for testing polymorphic collections.


private class A: PolymorphicSerializable, Hashable, Comparable, Equatable, CustomStringConvertible
{
    let name: String

    init(name: String)
    {
        self.name = name
    }

    func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(1)
        serializer.serialize(name)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(1)
        self.name = try deserializer.deserialize()
    }

    static let implementations: [SerializableTypeCode : any PolymorphicSerializable.Type] = [
        0: A.self,
        1: B.self,
        2: C.self,
    ]

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    func equals(_ other: A) -> Bool
    {
        return self.name == other.name
    }

    static func < (lhs: A, rhs: A) -> Bool {
        return lhs.name < rhs.name
    }

    public var description: String { return "<A:\(name)>" }
}

private func ==(lhs: A, rhs: A) -> Bool
{
    return lhs.equals(rhs)
}

private final class B: A
{
    let number: Int

    init(name: String, number: Int)
    {
        self.number = number
        super.init(name: name)
    }

    override func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(2)
        serializer.serialize(number)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(2)
        self.number = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    public override func hash(into hasher: inout Hasher) {
        super.hash(into: &hasher)
        hasher.combine(number)
    }

    func equals(_ other: B) -> Bool
    {
        guard super.equals(other) else { return false }
        return self.number == other.number
    }

    public override var description: String { return "<B:\(name):\(number)>" }
}

private final class C: A
{
    let truth: Bool

    init(name: String, truth: Bool)
    {
        self.truth = truth
        super.init(name: name)
    }

    override func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(2)
        serializer.serialize(truth)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(2)
        self.truth = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    public override func hash(into hasher: inout Hasher) {
        super.hash(into: &hasher)
        hasher.combine(truth)
    }

    func equals(_ other: C) -> Bool
    {
        guard super.equals(other) else { return false }
        return self.truth == other.truth
    }

    public override var description: String { return "<C:\(name):\(truth)>" }
}


// MARK: Class to test serializing optional values.


private struct OptionalTester: Serializable, Equatable
{
    // Serializable?
    var stringOne: String?
    var stringTwo: String?

    // [Serializable]?
    var arrayOne: [Int]?
    var arrayTwo: [Int]?

    // [Serializable: Serializable]?
    var dictOne: [String: Int]?
    var dictTwo: [String: Int]?

    // PolymorphicSerializable?
    var objectOne: A?
    var objectTwo: A?

    // [PolymorphicSerializable]?
    var objArrayOne: [A]?
    var objArrayTwo: [A]?

    // [Serializable: PolymorphicSerializable]?
    var objDictOne: [String: A]?
    var objDictTwo: [String: A]?

    // [PolymorphicSerializable: Serializable]?
    var objDictThree: [A: Int]?
    var objDictFour: [A: Int]?

    // [PolymorphicSerializable: PolymorphicSerializable]?
    var objDictFive: [A: A]?
    var objDictSix: [A: A]?

    init(_ stringOne: String? = nil, _ stringTwo: String? = nil,
         _ arrayOne: [Int]? = nil, _ arrayTwo: [Int]? = nil,
         _ dictOne: [String: Int]? = nil, _ dictTwo: [String: Int]? = nil,
         _ objectOne: A? = nil, _ objectTwo: A? = nil,
         _ objArrayOne: [A]? = nil, _ objArrayTwo: [A]? = nil,
         _ objDictOne: [String: A]? = nil, _ objDictTwo: [String: A]? = nil,
         _ objDictThree: [A: Int]? = nil, _ objDictFour: [A: Int]? = nil,
         _ objDictFive: [A: A]? = nil, _ objDictSix: [A: A]? = nil
    )
    {
        self.stringOne = stringOne
        self.stringTwo = stringTwo
        self.arrayOne = arrayOne
        self.arrayTwo = arrayTwo
        self.dictOne = dictOne
        self.dictTwo = dictTwo
        self.objectOne = objectOne
        self.objectTwo = objectTwo
        self.objArrayOne = objArrayOne
        self.objArrayTwo = objArrayTwo
        self.objDictOne = objDictOne
        self.objDictTwo = objDictTwo
        self.objDictThree = objDictThree
        self.objDictFour = objDictFour
        self.objDictFive = objDictFive
        self.objDictSix = objDictSix
    }

    func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(16)
        serializer.serialize(stringOne)
        serializer.serialize(stringTwo)
        serializer.serialize(arrayOne)
        serializer.serialize(arrayTwo)
        serializer.serialize(dictOne)
        serializer.serialize(dictTwo)
        serializer.serialize(objectOne)
        serializer.serialize(objectTwo)
        serializer.serialize(objArrayOne)
        serializer.serialize(objArrayTwo)
        serializer.serialize(objDictOne)
        serializer.serialize(objDictTwo)
        serializer.serialize(objDictThree)
        serializer.serialize(objDictFour)
        serializer.serialize(objDictFive)
        serializer.serialize(objDictSix)
        serializer.endAggregate()
    }

    init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(16)
        self.stringOne = try deserializer.deserialize()
        self.stringTwo = try deserializer.deserialize()
        self.arrayOne = try deserializer.deserialize()
        self.arrayTwo = try deserializer.deserialize()
        self.dictOne = try deserializer.deserialize()
        self.dictTwo = try deserializer.deserialize()
        self.objectOne = try deserializer.deserialize()
        self.objectTwo = try deserializer.deserialize()
        self.objArrayOne = try deserializer.deserialize()
        self.objArrayTwo = try deserializer.deserialize()
        self.objDictOne = try deserializer.deserialize()
        self.objDictTwo = try deserializer.deserialize()
        self.objDictThree = try deserializer.deserialize()
        self.objDictFour = try deserializer.deserialize()
        self.objDictFive = try deserializer.deserialize()
        self.objDictSix = try deserializer.deserialize()
    }
}

private func ==(lhs: OptionalTester, rhs: OptionalTester) -> Bool
{
    func optionalArraysAreEqual<T: Equatable>(_ lhoa: [T]?, _ rhoa: [T]?) -> Bool
    {
        switch (lhoa, rhoa)
        {
        case let (lha?, rha?): return lha == rha
        case (.none, .none): return true
        default: return false
        }
    }

    func optionalDictionariesAreEqual<T, U: Equatable>(_ lhod: [T: U]?, _ rhod: [T: U]?) -> Bool
    {
        switch (lhod, rhod)
        {
        case let (lhd?, rhd?): return lhd == rhd
        case (.none, .none): return true
        default: return false
        }
    }

    guard lhs.stringOne == rhs.stringOne else { return false }
    guard lhs.stringTwo == rhs.stringTwo else { return false }
    guard optionalArraysAreEqual(lhs.arrayOne, rhs.arrayOne) else { return false }
    guard optionalArraysAreEqual(lhs.arrayTwo, rhs.arrayTwo) else { return false }
    guard optionalDictionariesAreEqual(lhs.dictOne, rhs.dictOne) else { return false }
    guard optionalDictionariesAreEqual(lhs.dictTwo, rhs.dictTwo) else { return false }
    guard lhs.objectOne == rhs.objectOne else { return false }
    guard lhs.objectTwo == rhs.objectTwo else { return false }
    guard optionalArraysAreEqual(lhs.objArrayOne, rhs.objArrayOne) else { return false }
    guard optionalArraysAreEqual(lhs.objArrayTwo, rhs.objArrayTwo) else { return false }
    guard optionalDictionariesAreEqual(lhs.objDictOne, rhs.objDictOne) else { return false }
    guard optionalDictionariesAreEqual(lhs.objDictTwo, rhs.objDictTwo) else { return false }
    guard optionalDictionariesAreEqual(lhs.objDictThree, rhs.objDictThree) else { return false }
    guard optionalDictionariesAreEqual(lhs.objDictFour, rhs.objDictFour) else { return false }
    guard optionalDictionariesAreEqual(lhs.objDictFive, rhs.objDictFive) else { return false }
    guard optionalDictionariesAreEqual(lhs.objDictSix, rhs.objDictSix) else { return false }
    return true
}


// MARK: Classes to test serializing custom objects.
// Conceptually this is a simple log hierarchy.
// FIXME: I would like to get a Dictionary in here too.


private class TestLogEntry: PolymorphicSerializable, Equatable
{
    let title: String

    init(_ title: String)
    {
        self.title = title
    }

    func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(1)
        serializer.serialize(title)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(1)
        self.title = try deserializer.deserialize()
    }

    static let implementations: [SerializableTypeCode : any PolymorphicSerializable.Type] = [
        0: TestLogEntry.self,
        1: TestLogHeader.self,
        2: TestLogSection.self,
    ]

    func equals(_ other: TestLogEntry) -> Bool
    {
        return self.title == other.title
    }
}

private func ==(lhs: TestLogEntry, rhs: TestLogEntry) -> Bool
{
    return lhs.equals(rhs)
}

private final class TestLogHeader: TestLogEntry
{
    var subsections: [TestLogEntry]

    override init(_ title: String)
    {
        subsections = [TestLogEntry]()
        super.init(title)
    }

    func addEntry(_ entry: TestLogEntry) { subsections.append(entry) }

    override func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(2)
        serializer.serialize(subsections)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(2)
        self.subsections = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    override func equals(_ other: TestLogEntry) -> Bool
    {
        guard super.equals(other) else { return false }
        if let otherHeader = other as? TestLogHeader
        {
            return subsections == otherHeader.subsections
        }
        return false
    }
}

private final class TestLogSection: TestLogEntry
{
    var messages: [TestLogMessage]

    override init(_ title: String)
    {
        messages = [TestLogMessage]()
        super.init(title)
    }

    func addMessage(_ message: TestLogMessage) { messages.append(message) }

    override func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(2)
        serializer.serialize(messages)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(2)
        self.messages = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    override func equals(_ other: TestLogEntry) -> Bool
    {
        guard super.equals(other) else { return false }
        if let otherSection = other as? TestLogSection
        {
            return messages == otherSection.messages
        }
        return false
    }
}

private enum TestLogMessageType: String
{
    case error
    case warning
    case note
}

private final class TestLogMessage: Serializable, Equatable
{
    let type: TestLogMessageType
    let message: String

    init(type: TestLogMessageType, message: String)
    {
        self.type = type
        self.message = message
    }

    func serialize<T: Serializer>(to serializer: T)
    {
        serializer.beginAggregate(2)
        serializer.serialize(type.rawValue)
        serializer.serialize(message)
        serializer.endAggregate()
    }

    init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(2)
        guard let type = TestLogMessageType(rawValue: try deserializer.deserialize()) else { throw DeserializerError.deserializationFailed("Invalid TestLogMessageType.") }
        self.type = type
        self.message = try deserializer.deserialize()
    }
}

private func ==(lhs: TestLogMessage, rhs: TestLogMessage) -> Bool
{
    return lhs.type == rhs.type && lhs.message == rhs.message
}
