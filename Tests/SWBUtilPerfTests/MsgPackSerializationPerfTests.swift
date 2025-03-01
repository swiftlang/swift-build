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

import Testing
import SWBTestSupport
import SWBUtil

/// Performance tests for the MsgPackSerializer class.
///
/// These tests are not intended to compare the performance of serializing individual types of elements (there are many different breakdowns we should consider if we want to do that), but to provide a baseline for future performance improvement to the serializer.
@Suite(.performance)
fileprivate struct MsgPackSerializationPerfTests: PerfTests {
    private func serializeScalarData() -> MsgPackSerializer {
        let sz = MsgPackSerializer()
        sz.serialize(3 as Int)
        sz.serialize(0 as Int)
        sz.serialize(-3 as Int)
        sz.serialize(0 as UInt)
        sz.serialize(7 as UInt)
        sz.serialize(true)
        sz.serialize(false)
        sz.serialize(-5.3 as Float32)
        sz.serialize(0.0 as Float32)
        sz.serialize(2.47 as Float32)
        sz.serialize(-7.9 as Float64)
        sz.serialize(0.0 as Float64)
        sz.serialize(5.44 as Float64)
        return sz
    }

    @Test
    func serializingScalar_13Elements_X100000() async {
        let iterations = 100000

        await measure {
            for _ in 1...iterations
            {
                #expect(self.serializeScalarData() != nil)
            }
        }
    }

    @Test
    func deserializingScalar_13Elements_X100000() async throws {
        let iterations = 100000

        let sz = serializeScalarData()

        try await measure { () throws -> Void in
            for _ in 1...iterations {
                let dsz = MsgPackDeserializer(sz.byteString)
                #expect(try dsz.deserialize() == 3 as Int)
                #expect(try dsz.deserialize() == 0 as Int)
                #expect(try dsz.deserialize() == -3 as Int)
                #expect(try dsz.deserialize() == 0 as UInt)
                #expect(try dsz.deserialize() == 7 as UInt)
                #expect(try dsz.deserialize())
                #expect(try !dsz.deserialize())
                #expect(try dsz.deserialize() == -5.3 as Float32)
                #expect(try dsz.deserialize() == 0.0 as Float32)
                #expect(try dsz.deserialize() == 2.47 as Float32)
                #expect(try dsz.deserialize() == -7.9 as Float64)
                #expect(try dsz.deserialize() == 0.0 as Float64)
                #expect(try dsz.deserialize() == 5.44 as Float64)
            }
        }
    }

    private func serializeStringData() -> MsgPackSerializer {
        let sz = MsgPackSerializer()
        sz.serialize("foo")
        sz.serialize("bar")
        sz.serialize("baz")
        sz.serialize("quux")
        sz.serialize("")
        return sz
    }

    @Test
    func serializingString_5Elements_X100000() async {
        let iterations = 100000

        await measure {
            for _ in 1...iterations {
                #expect(self.serializeStringData() != nil)
            }
        }
    }

    @Test
    func deserializingString_5Elements_X100000() async throws {
        let iterations = 100000

        let sz = serializeStringData()

        try await measure { () throws -> Void in
            for _ in 1...iterations {
                let dsz = MsgPackDeserializer(sz.byteString)
                #expect(try dsz.deserialize() == "foo")
                #expect(try dsz.deserialize() == "bar")
                #expect(try dsz.deserialize() == "baz")
                #expect(try dsz.deserialize() == "quux")
                #expect(try dsz.deserialize() == "")
            }
        }
    }

    private func serializeArrayData() -> MsgPackSerializer
    {
        let sz = MsgPackSerializer()
        sz.serialize([-2, -1, 0, 1, 2] as [Int])
        sz.serialize([0, 1, 2, 3, 4] as [UInt])
        sz.serialize([false, true, true, false, true])
        sz.serialize([-2.3, -1.1, 0.0, 0.7, 1.8] as [Float32])
        sz.serialize([-1.93, -0.98, 0.0, 1.13, 2.41] as [Float64])
        sz.serialize(["foo", "bar", "baz", "quux", "nul"])
        return sz
    }

    @Test
    func serializingArray_5X5Elements_X100000() async {
        let iterations = 100000

        await measure {
            for _ in 1...iterations
            {
                #expect(self.serializeArrayData() != nil)
            }
        }
    }

    @Test
    func deserializingArray_5X5Elements_X100000() async throws {
        let iterations = 100000

        let sz = serializeArrayData()

        try await measure { () throws -> Void in
            for _ in 1...iterations {
                let dsz = MsgPackDeserializer(sz.byteString)
                #expect((try dsz.deserialize() as [Int]).count == 5)
                #expect((try dsz.deserialize() as [UInt]).count == 5)
                #expect((try dsz.deserialize() as [Bool]).count == 5)
                #expect((try dsz.deserialize() as [Float32]).count == 5)
                #expect((try dsz.deserialize() as [Float64]).count == 5)
                #expect((try dsz.deserialize() as [String]).count == 5)
            }
        }
    }

    private func serializeDictionaryData() -> MsgPackSerializer
    {
        let sz = MsgPackSerializer()
        sz.serialize(["minusone": -1, "zero": 0, "one": 1] as [String: Int])
        sz.serialize([-1.3: false, 0.0: true, 1.2: false] as [Float32: Bool])
        return sz
    }

    @Test
    func serializingDictionary_2X3Elements_X100000() async {
        let iterations = 100000

        await measure {
            for _ in 1...iterations {
                #expect(self.serializeDictionaryData() != nil)
            }
        }
    }

    @Test
    func deserializingDictionary_2X3Elements_X100000() async throws {
        let iterations = 100000

        let sz = serializeDictionaryData()

        try await measure { () throws -> Void in
            for _ in 1...iterations {
                let dsz = MsgPackDeserializer(sz.byteString)
                #expect((try dsz.deserialize() as [String: Int]).count == 3)
                #expect((try dsz.deserialize() as [Float32: Bool]).count == 3)
            }
        }
    }

    private func customElementData() -> [TestLogMessage] {
        var elements = [TestLogMessage]()
        for i in 1...100
        {
            let element = TestLogMessage(type: .error, message: "error: Message #\(i)")
            elements.append(element)
        }
        return elements
    }

    private func serializeCustomElementData(_ elements: [TestLogMessage]) -> MsgPackSerializer {
        let sz = MsgPackSerializer()
        for element in elements
        {
            sz.serialize(element)
        }
        return sz
    }

    @Test
    func serializingCustomElement_100Elements_X10000() async {
        let iterations = 10000

        let elements = customElementData()

        await measure
        {
            for _ in 1...iterations
            {
                #expect(self.serializeCustomElementData(elements) != nil)
            }
        }
    }

    @Test
    func deserializingCustomElement_100Elements_X10000() async throws {
        let iterations = 10000

        let elements = customElementData()
        let sz = serializeCustomElementData(elements)

        try await measure {
            for _ in 1...iterations {
                let dsz = MsgPackDeserializer(sz.byteString)
                for element in elements
                {
                    let dszElement = try dsz.deserialize() as TestLogMessage
                    #expect(dszElement.message == element.message)
                }
            }
        }
    }

    private func customElementHierarchy(_ numElements: UInt) -> TestLogHeader
    {
        // The top-level log element.
        let log = TestLogHeader("Log")

        // Add 100 framework targets, each with 100 source file compilations, each of which emits 100 warnings.
        for i in 1...numElements
        {
            let fwkTarget = TestLogHeader("Framework-\(i)")
            log.addEntry(fwkTarget)
            for j in 1...numElements
            {
                fwkTarget.addEntry(TestLogSection("Copy Foo_\(j).h"))

                let compile = TestLogSection("Compile Foo_\(j).m")
                for k in 1...numElements
                {
                    compile.addMessage(TestLogMessage(type: .warning, message: "Warning number \(k)"))
                }
                fwkTarget.addEntry(compile)
            }
            fwkTarget.addEntry(TestLogSection("Link Foo_\(i)"))
            fwkTarget.addEntry(TestLogSection("Touch Foo_\(i).framework"))
        }

        // Add an app target.
        let appTarget = TestLogHeader("App")
        log.addEntry(appTarget)
        let compile = TestLogSection("Compile Class.m")
        compile.addMessage(TestLogMessage(type: .error, message: "Something went wrong"))
        compile.addMessage(TestLogMessage(type: .error, message: "Something else went wrong"))
        appTarget.addEntry(compile)
        let link = TestLogSection("Link App")
        link.addMessage(TestLogMessage(type: .warning, message: "Couldn't find the right framework"))
        appTarget.addEntry(link)
        appTarget.addEntry(TestLogSection("Copy Framework into App"))
        appTarget.addEntry(TestLogSection("Touch App.app"))

        return log
    }

    private func serializeCustomElementHierarchy(_ log: TestLogHeader) -> MsgPackSerializer
    {
        let sz = MsgPackSerializer()
        sz.serialize(log)
        return sz
    }

    @Test
    func serializingCustomElementHierarchy_100X100X100Elements_X1() async {
        let iterations = 1

        let log = customElementHierarchy(100)
        var didEmitSerializedSize = false

        await measure {
            for _ in 1...iterations
            {
                let sz = self.serializeCustomElementHierarchy(log)
                if !didEmitSerializedSize
                {
                    let mb = Float64(sz.byteString.bytes.count) / (1000.0 * 1000.0)
                    perfPrint("Serialized \(mb) megabytes")
                    didEmitSerializedSize = true
                }
            }
        }
    }

    @Test
    func deserializingCustomElementHierarchy_100X100X100Elements_X1() async throws {
        let iterations = 1

        // Construct the log hierarchy.
        let log = customElementHierarchy(100)
        let sz = serializeCustomElementHierarchy(log)

        let mb = Float64(sz.byteString.bytes.count) / (1000.0 * 1000.0)
        perfPrint("Will deserialize \(mb) megabytes")

        try await measure {
            for _ in 1...iterations {
                let dsz = MsgPackDeserializer(sz.byteString)
                let dszLog = try dsz.deserialize() as TestLogHeader
                #expect(dszLog.title == log.title)
                #expect(dszLog.subsections.count == log.subsections.count)
            }
        }
    }
}


// MARK: Classes to test serializing a log structure


private class TestLogEntry: PolymorphicSerializable, Equatable {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(1)
        serializer.serialize(title)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.title = try deserializer.deserialize()
    }

    static let implementations: [SerializableTypeCode : any PolymorphicSerializable.Type] = [
        0: TestLogEntry.self,
        1: TestLogHeader.self,
        2: TestLogSection.self,
    ]

    func equals(_ other: TestLogEntry) -> Bool {
        return self.title == other.title
    }
}

private func ==(lhs: TestLogEntry, rhs: TestLogEntry) -> Bool {
    return lhs.equals(rhs)
}

private final class TestLogHeader: TestLogEntry {
    var subsections: [TestLogEntry]

    override init(_ title: String) {
        subsections = [TestLogEntry]()
        super.init(title)
    }

    func addEntry(_ entry: TestLogEntry) {
        subsections.append(entry)
    }

    override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(subsections)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.subsections = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    override func equals(_ other: TestLogEntry) -> Bool {
        guard super.equals(other) else { return false }
        if let otherHeader = other as? TestLogHeader
        {
            return subsections == otherHeader.subsections
        }
        return false
    }
}

private final class TestLogSection: TestLogEntry {
    var messages: [TestLogMessage]

    override init(_ title: String) {
        messages = [TestLogMessage]()
        super.init(title)
    }

    func addMessage(_ message: TestLogMessage) {
        messages.append(message)
    }

    override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(messages)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.messages = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    override func equals(_ other: TestLogEntry) -> Bool {
        guard super.equals(other) else { return false }
        if let otherSection = other as? TestLogSection
        {
            return messages == otherSection.messages
        }
        return false
    }
}

private enum TestLogMessageType: String {
    case error
    case warning
    case note
}

private final class TestLogMessage: Serializable, Equatable {
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

private func ==(lhs: TestLogMessage, rhs: TestLogMessage) -> Bool {
    return lhs.type == rhs.type && lhs.message == rhs.message
}
