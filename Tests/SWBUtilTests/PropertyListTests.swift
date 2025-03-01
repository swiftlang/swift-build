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

@Suite fileprivate struct PropertyListTests {
    func parseAndTestPropertyList(_ data: String, check: (PropertyListItem) -> Void) throws {
        // Parse the property list.
        let plist = try PropertyList.fromString(data)

        check(plist)
    }

    @Test
    func comparison() {
        do {
            let a = PropertyListItem.plArray([PropertyListItem.plBool(true), PropertyListItem.plInt(1), PropertyListItem.plString("1"), PropertyListItem.plData([0xAA]), PropertyListItem.plDict(["a": .plInt(1)])])
            let b = PropertyListItem.plArray([PropertyListItem.plBool(true), PropertyListItem.plInt(1), PropertyListItem.plString("1"), PropertyListItem.plData([0xAA]), PropertyListItem.plDict(["a": .plInt(1)])])
            #expect(a == b)
        }
        #expect(PropertyListItem.plBool(false) != PropertyListItem.plBool(true))
        #expect(PropertyListItem.plInt(1) != PropertyListItem.plBool(true))
        #expect(PropertyListItem.plInt(1) != PropertyListItem.plString("0"))
        #expect(PropertyListItem.plString("a") != PropertyListItem.plInt(0))
        #expect(PropertyListItem.plData([0xAA]) != PropertyListItem.plInt(0))
        #expect(PropertyListItem.plDate(Date()) != PropertyListItem.plInt(0))
        #expect(PropertyListItem.plArray([]) != PropertyListItem.plInt(0))
        #expect(PropertyListItem.plDict([:]) != PropertyListItem.plInt(0))
    }

    @Test
    func loadingBasics() throws {
        try parseAndTestPropertyList("{ a = aValue; b = (1, 2); }") {
            guard case .plDict(let items) = $0 else {
                Issue.record()
                return
            }
            guard case .plString("aValue")? = items["a"] else {
                Issue.record()
                return
            }
            guard case .plArray(let bItems)? = items["b"] else {
                Issue.record()
                return
            }
            #expect(bItems == [PropertyListItem.plString("1"), PropertyListItem.plString("2")])
        }

        // Check that we can load property lists from JSON.
        let plist = try PropertyList.fromJSONData(Array<UInt8>("{ \"a\":\"aValue\", \"b\": [\"1\", \"2\"] }".utf8))
        guard case .plDict(let items) = plist else {
            Issue.record()
            return
        }
        guard case .plString("aValue")? = items["a"] else {
            Issue.record()
            return
        }
        guard case .plArray(let bItems)? = items["b"] else {
            Issue.record()
            return
        }
        #expect(bItems == [PropertyListItem.plString("1"), PropertyListItem.plString("2")])

        // Check that we can load scalars
        let plist2 = try PropertyList.fromStringWithFormat("<plist><dict><key>a</key><real>3.14</real><key>b</key><true/><key>i</key><integer>1</integer></dict></plist>").propertyList
        guard case .plDict(let items2) = plist2 else {
            Issue.record()
            return
        }
        guard case .plDouble(3.14)? = items2["a"] else {
            Issue.record()
            return
        }
        guard case .plBool(true)? = items2["b"] else {
            Issue.record()
            return
        }
        guard case .plInt(1)? = items2["i"] else {
            Issue.record()
            return
        }

        if try ProcessInfo.processInfo.hostOperatingSystem() != .macOS {
            // remainder crashes on Linux
            return
        }

        // Empty input is not a valid plist
        #expect {
            try PropertyList.fromString("")
        } throws: { error in
            error as? PropertyListConversionError == PropertyListConversionError.invalidStream
        }

        // ...but an otherwise empty plist with only a comment, is an empty dictionary
        #expect(try PropertyList.fromString(" /* this will have things in it soon */ ") == PropertyListItem.plDict([:]))
    }

    @Test
    func loadingData() throws {
        try parseAndTestPropertyList("{ a = <AABBCCDD>; }") {
            guard case .plDict(let items) = $0 else {
                Issue.record()
                return
            }
            guard case .plData(let bytes)? = items["a"] else {
                Issue.record()
                return
            }
            #expect(bytes == [0xAA, 0xBB, 0xCC, 0xDD])
        }
    }

    @Test
    func loadingDate() throws {
        let plist = try PropertyList.fromStringWithFormat("<plist><dict><key>CreatedDate</key><date>2016-11-15T19:54:27Z</date></dict></plist>").propertyList
        guard case .plDict(let items) = plist else {
            Issue.record()
            return
        }
        guard case .plDate(Date(timeIntervalSinceReferenceDate: 500932467))? = items["CreatedDate"] else {
            Issue.record()
            return
        }
    }

    @Test
    func loadingJSONFile() throws {
        let fs = localFS
        try withTemporaryDirectory(fs: fs) { tmpDir in
            let itemPath = tmpDir.join("\(#function).json")
            try #"{"a":1,"b":["c"]}"#.write(to: URL(fileURLWithPath: itemPath.str), atomically: true, encoding: .utf8)

            let asJSON = try PropertyList.fromJSONFileAtPath(itemPath, fs: fs)
            guard case .plDict(let items) = asJSON else { fatalError("unexpected result") }
            guard case .plInt(1)? = items["a"] else { fatalError("unexpected result") }
            guard case .plArray(let arrayItems)? = items["b"], arrayItems.count == 1 else { fatalError("unexpected result") }
            guard case .plString("c") = arrayItems[0] else { fatalError("unexpected result") }
        }
    }

    @Test
    func JSONEncoding() throws {
        func asJSON(_ item: PropertyListItem) throws -> ByteString { return try item.asJSONFragment() }
        #expect(try asJSON(.plBool(true)) == "true")
        #expect(try asJSON(.plBool(false)) == "false")
        #expect(try asJSON(.plInt(1)) == "1")
        #expect(try asJSON(.plString("hi")) == "\"hi\"")
        #expect(try asJSON(.plArray([.plString("hi"), .plString("world")])) == "[\"hi\",\"world\"]")
        #expect(try asJSON(.plDict(["hi": .plString("world")])) == "{\"hi\":\"world\"}")
    }

    @Test
    func JSONDictEncoding() throws {
        func asJSON(_ item: PropertyListItem) throws -> ByteString { return try item.asJSONFragment() }
        #expect(try asJSON(.plDict(["ho": .plString("world"), "hi": .plString("world")])) == "{\"hi\":\"world\",\"ho\":\"world\"}")
    }

    @Test
    func JSONStringEncoding() throws {
        func asJSON(_ item: PropertyListItem) throws -> ByteString { return try item.asJSONFragment() }
        #expect(try asJSON(.plString("a'\"\\")) == "\"a'\\\"\\\\\"")
        #expect(try asJSON(.plString("\u{0008}")) == "\"\\b\"")
        #expect(try asJSON(.plString("\u{000C}")) == "\"\\f\"")
        #expect(try asJSON(.plString("\n")) == "\"\\n\"")
        #expect(try asJSON(.plString("\r")) == "\"\\r\"")
        #expect(try asJSON(.plString("\t")) == "\"\\t\"")
        #expect(try asJSON(.plString("\u{0001}")) == "\"\\u0001\"")
    }

    @Test
    func convertingToBytes() throws {
        let plistString = "{ a = aValue; b = (1, 2); c = { x = something; y = otherthing; a = b; }; d = <AABBCCDD>; }"
        let plist = try PropertyList.fromString(plistString)

        // Convert it to bytes in XML format.  Then convert it back to a PropertyListItem hierarchy and make sure it looks kosher.
        do {
            let bytes: [UInt8]
            do {
                bytes = try plist.asBytes(.xml)
            }
            catch {
                Issue.record()
                return
            }

            guard let string = String(data: Data(bytes) as Data, encoding: String.Encoding.utf8) else {
                Issue.record()
                return
            }
            guard let (readPlist, readFormat) = try? PropertyList.fromStringWithFormat(string) else {
                Issue.record()
                return
            }
            #expect(readPlist == plist)
            #expect(readFormat == .xml)
        }

        do {
            // Convert it to bytes in Binary format.  Then convert it back to a PropertyListItem hierarchy and make sure it looks kosher.
            let bytes: [UInt8]
            do {
                bytes = try plist.asBytes(.binary)
            }
            catch {
                Issue.record()
                return
            }

            guard let (readPlist, readFormat) = try? PropertyList.fromBytesWithFormat(bytes) else {
                Issue.record()
                return
            }
            #expect(readPlist == plist)
            #expect(readFormat == .binary)
        }
    }

    @Test
    func isEmpty() {
        #expect(PropertyListItem.plBool(false).isEmpty)
        #expect(PropertyListItem.plInt(0).isEmpty)
        #expect(PropertyListItem.plString("").isEmpty)
        #expect(PropertyListItem.plData(ByteString().bytes).isEmpty)
        #expect(PropertyListItem.plArray([]).isEmpty)
        #expect(PropertyListItem.plDict([:]).isEmpty)

        #expect(!PropertyListItem.plBool(true).isEmpty)
        #expect(!PropertyListItem.plInt(1).isEmpty)
        #expect(!PropertyListItem.plString("foo").isEmpty)
        #expect(!PropertyListItem.plData(ByteString(encodingAsUTF8: "foobar").bytes).isEmpty)
        #expect(!PropertyListItem.plDate(Date()).isEmpty)
        #expect(!PropertyListItem.plArray([.plString("bar")]).isEmpty)
        #expect(!PropertyListItem.plDict(["baz": .plString("quux")]).isEmpty)
    }

    /// Test the ***Value properties which return a value of the expected type, or nil if it is anything else.
    @Test
    func valueProperties() throws {
        let date = Date()
        let plist: PropertyListItem = .plDict([
            "str": .plString("aValue"),
            "int": .plInt(1),
            "zero": .plInt(0),
            "trueStr": .plString("YES"),
            "falseStr": .plString("NO"),
            "trueInt": .plInt(42),
            "falseInt": .plInt(0),
            "trueBool": .plBool(true),
            "falseBool": .plBool(false),
            "date": .plDate(date),
            "float": .plDouble(13.2),
            "array": .plArray([.plString("a"), .plString("b"), .plString("c")]),
            "arrayMulti": .plArray([.plBool(true), .plString("b"), .plInt(3)]),
            "dict": .plDict(["x": .plString("something"), "y": .plString("otherthing")]),
            "data": .plData([0xAA, 0xBB, 0xCC, 0xDD]),
        ])

        guard let dict = plist.dictValue else {
            Issue.record("Property list is not a dictionary")
            return
        }

        // Check that the values are as expected.
        #expect(dict["str"]?.stringValue == "aValue")
        #expect(dict["int"]?.intValue == 1)
        #expect(dict["int"]?.looselyTypedBoolValue ?? false == true)
        #expect(dict["zero"]?.looselyTypedBoolValue ?? true == false)

        #expect(dict["trueStr"]?.boolValue == nil)
        #expect(dict["falseStr"]?.boolValue == nil)
        #expect(dict["trueInt"]?.boolValue == nil)
        #expect(dict["falseInt"]?.boolValue == nil)
        #expect(dict["trueBool"]?.boolValue == true)
        #expect(dict["falseBool"]?.boolValue == false)

        #expect(dict["trueStr"]?.looselyTypedBoolValue == true)
        #expect(dict["falseStr"]?.looselyTypedBoolValue == false)
        #expect(dict["trueInt"]?.looselyTypedBoolValue == true)
        #expect(dict["falseInt"]?.looselyTypedBoolValue == false)
        #expect(dict["trueBool"]?.looselyTypedBoolValue == true)
        #expect(dict["falseBool"]?.looselyTypedBoolValue == false)

        #expect(dict["date"]?.dateValue == date)
        #expect(dict["float"]?.floatValue == 13.2)
        #expect(dict["array"]?.arrayValue?.compactMap({ $0.stringValue }) ?? [] == ["a", "b", "c"])
        #expect(dict["array"]?.stringArrayValue ?? [] == ["a", "b", "c"])
        #expect(dict["dict"]?.dictValue ?? [:] == ["x": .plString("something"), "y": .plString("otherthing")])
        #expect(dict["data"]?.dataValue ?? [] == [0xAA, 0xBB, 0xCC, 0xDD])

        // Check that trying to get another value from a type returns nil.
        // Note that strings and ints will never return nil for looselyTypedBoolValue.
        #expect(dict["str"]?.boolValue == nil)
        #expect(dict["str"]?.intValue == nil)
        #expect(dict["str"]?.dateValue == nil)
        #expect(dict["str"]?.floatValue == nil)
        #expect(dict["str"]?.arrayValue == nil)
        #expect(dict["str"]?.stringArrayValue == nil)
        #expect(dict["str"]?.dictValue == nil)
        #expect(dict["str"]?.dataValue == nil)
        #expect(dict["int"]?.boolValue == nil)
        #expect(dict["int"]?.dateValue == nil)
        #expect(dict["int"]?.floatValue == nil)
        #expect(dict["int"]?.stringValue == nil)
        #expect(dict["int"]?.arrayValue == nil)
        #expect(dict["int"]?.stringArrayValue == nil)
        #expect(dict["int"]?.dictValue == nil)
        #expect(dict["int"]?.dataValue == nil)
        #expect(dict["date"]?.stringValue == nil)
        #expect(dict["date"]?.intValue == nil)
        #expect(dict["date"]?.floatValue == nil)
        #expect(dict["date"]?.boolValue == nil)
        #expect(dict["date"]?.looselyTypedBoolValue == nil)
        #expect(dict["date"]?.arrayValue == nil)
        #expect(dict["date"]?.stringArrayValue == nil)
        #expect(dict["date"]?.dictValue == nil)
        #expect(dict["date"]?.dataValue == nil)
        #expect(dict["float"]?.stringValue == nil)
        #expect(dict["float"]?.intValue == nil)
        #expect(dict["float"]?.boolValue == nil)
        #expect(dict["float"]?.looselyTypedBoolValue == nil)
        #expect(dict["float"]?.dateValue == nil)
        #expect(dict["float"]?.arrayValue == nil)
        #expect(dict["float"]?.stringArrayValue == nil)
        #expect(dict["float"]?.dictValue == nil)
        #expect(dict["float"]?.dataValue == nil)
        #expect(dict["array"]?.stringValue == nil)
        #expect(dict["array"]?.intValue == nil)
        #expect(dict["array"]?.boolValue == nil)
        #expect(dict["array"]?.looselyTypedBoolValue == nil)
        #expect(dict["array"]?.dateValue == nil)
        #expect(dict["array"]?.floatValue == nil)
        #expect(dict["array"]?.dictValue == nil)
        #expect(dict["array"]?.dataValue == nil)
        #expect(dict["arrayMulti"]?.stringValue == nil)
        #expect(dict["arrayMulti"]?.stringArrayValue == nil)
        #expect(dict["arrayMulti"]?.intValue == nil)
        #expect(dict["arrayMulti"]?.boolValue == nil)
        #expect(dict["arrayMulti"]?.looselyTypedBoolValue == nil)
        #expect(dict["arrayMulti"]?.dateValue == nil)
        #expect(dict["arrayMulti"]?.floatValue == nil)
        #expect(dict["arrayMulti"]?.dictValue == nil)
        #expect(dict["arrayMulti"]?.dataValue == nil)
        #expect(dict["dict"]?.stringValue == nil)
        #expect(dict["dict"]?.intValue == nil)
        #expect(dict["dict"]?.boolValue == nil)
        #expect(dict["dict"]?.looselyTypedBoolValue == nil)
        #expect(dict["dict"]?.dateValue == nil)
        #expect(dict["dict"]?.floatValue == nil)
        #expect(dict["dict"]?.arrayValue == nil)
        #expect(dict["dict"]?.stringArrayValue == nil)
        #expect(dict["dict"]?.dataValue == nil)
        #expect(dict["data"]?.stringValue == nil)
        #expect(dict["data"]?.intValue == nil)
        #expect(dict["data"]?.boolValue == nil)
        #expect(dict["data"]?.looselyTypedBoolValue == nil)
        #expect(dict["data"]?.dateValue == nil)
        #expect(dict["data"]?.floatValue == nil)
        #expect(dict["data"]?.arrayValue == nil)
        #expect(dict["data"]?.stringArrayValue == nil)
        #expect(dict["data"]?.dictValue == nil)
    }

    @Test
    func concreteBooleans() {
        let date = Date()
        let plist: PropertyListItem = .plDict([
            "str": .plString("aValue"),
            "int": .plInt(1),
            "zero": .plInt(0),
            "trueStr": .plString("YES"),
            "falseStr": .plString("NO"),
            "trueInt": .plInt(42),
            "falseInt": .plInt(0),
            "trueBool": .plBool(true),
            "falseBool": .plBool(false),
            "date": .plDate(date),
            "float": .plDouble(13.2),
            "array": .plArray([.plString("a"), .plString("b"), .plString("c")]),
            "arrayMulti": .plArray([.plBool(true), .plString("b"), .plInt(3)]),
            "dict": .plDict(["x": .plString("something"), "y": .plString("otherthing"), "z": .plString("YES")]),
            "data": .plData([0xAA, 0xBB, 0xCC, 0xDD]),
        ])

        let plistRealBools: PropertyListItem = .plDict([
            "str": .plString("aValue"),
            "int": .plInt(1),
            "zero": .plInt(0),
            "trueStr": .plBool(true),
            "falseStr": .plBool(false),
            "trueInt": .plInt(42),
            "falseInt": .plBool(false),
            "trueBool": .plBool(true),
            "falseBool": .plBool(false),
            "date": .plDate(date),
            "float": .plDouble(13.2),
            "array": .plArray([.plString("a"), .plString("b"), .plString("c")]),
            "arrayMulti": .plArray([.plBool(true), .plString("b"), .plInt(3)]),
            "dict": .plDict(["x": .plString("something"), "y": .plString("otherthing"), "z": .plBool(true)]),
            "data": .plData([0xAA, 0xBB, 0xCC, 0xDD]),
        ])

        let justABool: PropertyListItem = .plBool(true)

        #expect(plist == plist.withConcreteBooleans(forKeys: []))
        #expect(plist == plist.withConcreteBooleans(forKeys: ["foo"]))
        #expect(plistRealBools == plist.withConcreteBooleans(forKeys: ["trueStr", "falseStr", "falseInt", "z"]))
        #expect(justABool == justABool.withConcreteBooleans(forKeys: []))
    }

    @Test
    func deterministicDescription() {
        let emptyPlist: PropertyListItem = .plDict([:])
        #expect(emptyPlist.deterministicDescription == "PLDict<[:]>")

        let simpleDictPlist: PropertyListItem = .plDict([
            "a": .plBool(true),
            "c": .plBool(false),
            "g": .plBool(true),
            "bogus": .plBool(true),
        ])
        #expect(simpleDictPlist.deterministicDescription == "PLDict<[\"a\": true, \"bogus\": true, \"c\": false, \"g\": true]>")

        let heterogeneousPlistDict: PropertyListItem = .plDict([
            "bool": .plBool(true),
            "int": .plInt(6),
            "double": .plDouble(5.3),
            "array": .plArray([
                .plString("foo"),
                .plString("bar")
            ]),
            "dict": .plDict([
                "bar": .plString("trap!"),
                "ack": .plString("It's a"),
            ]),
        ])
        #expect(heterogeneousPlistDict.deterministicDescription == "PLDict<[\"array\": PLArray<[\"foo\", \"bar\"]>, \"bool\": true, \"dict\": PLDict<[\"ack\": \"It's a\", \"bar\": \"trap!\"]>, \"double\": 5.3, \"int\": 6]>")

        // Make sure we call deterministicDescription recursively on arrays and dictionaries.
        let nestedPlistDict: PropertyListItem = .plDict([
            "array": .plArray([
                .plDict([
                    "x": .plInt(3),
                    "m": .plInt(2),
                    "d": .plDict([
                        "z": .plInt(2),
                        "a": .plInt(1),
                    ])
                ]),
                .plArray([
                    .plDict([
                        "n": .plInt(1),
                        "s": .plInt(3),
                        "q": .plInt(2),
                    ]),
                ]),
            ]),
        ])
        #expect(nestedPlistDict.deterministicDescription == "PLDict<[\"array\": PLArray<[PLDict<[\"d\": PLDict<[\"a\": 1, \"z\": 2]>, \"m\": 2, \"x\": 3]>, PLArray<[PLDict<[\"n\": 1, \"q\": 2, \"s\": 3]>]>]>]>")
    }

    @Test
    func propertyListConversionErrorEquatableErrorType() {
        let e1: PropertyListConversionError = .fileError(SWBUtil.POSIXError(1, "test", "hi", "bye"))
        let e2: PropertyListConversionError = .fileError(SWBUtil.POSIXError(1, "test", "hi", "bye"))
        let e3: PropertyListConversionError = .fileError(SWBUtil.POSIXError(2))
        let e4: PropertyListConversionError = .fileError(SWBUtil.POSIXError(2))

        #expect(e1 == e2)
        #expect(e1 != e3)
        #expect(e3 == e4)
    }

    @Test
    func keyPaths() {
        #expect(PropertyListItem.plDict([:])[PropertyListKeyPath([])] == [])

        let infoPlist = PropertyListItem.plDict([
            "NSAppTransportSecurity": .plDict([
                "NSExceptionDomains": .plDict([
                    "apple.com": .plDict([
                        "NSExceptionMinimumTLSVersion": .plString("TLSv1.3")
                    ]),
                    "localhost": .plDict([
                        "NSExceptionMinimumTLSVersion": .plString("TLSv1.2")
                    ])
                ])
            ])
        ])

        let tlsVersionKeyPath = PropertyListKeyPath(.dict(.equal("NSAppTransportSecurity")), .dict(.equal("NSExceptionDomains")), .dict(.any), .any(.equal("NSExceptionMinimumTLSVersion")))

        do {
            let result = infoPlist[tlsVersionKeyPath]
            #expect(result[safe: 0]?.actualKeyPath == ["NSAppTransportSecurity", "NSExceptionDomains", "apple.com", "NSExceptionMinimumTLSVersion"])
            #expect(result[safe: 0]?.value == .plString("TLSv1.3"))
            #expect(result[safe: 1]?.actualKeyPath == ["NSAppTransportSecurity", "NSExceptionDomains", "localhost", "NSExceptionMinimumTLSVersion"])
            #expect(result[safe: 1]?.value == .plString("TLSv1.2"))
        }
    }

    @Test(.requireHostOS(.macOS))
    func deterministicBinarySerialization() throws {
        let plistString = "{ a = aValue; b = (1, 2); c = { x = something; y = otherthing; a = b; }; d = <AABBCCDD>; }"
        let plist = try PropertyList.fromString(plistString)

        let bytes = try plist.asBytes(.binary)

        let plist2 = try PropertyList.fromBytes(bytes)

        #expect(try plist2.asBytes(.binary) == bytes)
    }
}
