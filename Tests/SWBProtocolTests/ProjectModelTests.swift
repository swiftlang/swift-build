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

import SWBProtocol
import SWBUtil
import Testing

/// Test that we are generating the expected errors for invalid/unexpected type codes when serializing various types.
@Suite fileprivate struct SWBProtocolUnexpectedTypecodeTests {
    @Test func buildableItemGUID() {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(2) {
            serializer.serialize(3 as Int)
            serializer.serializeNil()
        }

        let deserializer = MsgPackDeserializer(serializer.byteString)
        #expect { try deserializer.deserialize() as BuildFile.BuildableItemGUID } throws: { error in
            ((error as? DeserializerError)?.errorString == DeserializerError.unexpectedValue("Unexpected type code (3)").errorString)
        }
    }

    @Test func inputSpecifier() {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(2) {
            serializer.serialize(2 as Int)
            serializer.serializeNil()
        }

        let deserializer = MsgPackDeserializer(serializer.byteString)
        #expect { try deserializer.deserialize() as BuildRule.InputSpecifier } throws: { error in
            ((error as? DeserializerError)?.errorString == DeserializerError.unexpectedValue("Unexpected type code (2)").errorString)
        }
    }

    @Test func actionSpecifier() {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(2) {
            serializer.serialize(2 as Int)
            serializer.serializeNil()
        }

        let deserializer = MsgPackDeserializer(serializer.byteString)
        #expect { try deserializer.deserialize() as BuildRule.ActionSpecifier } throws: { error in
            ((error as? DeserializerError)?.errorString == DeserializerError.unexpectedValue("Unexpected type code (2)").errorString)
        }
    }

    @Test func macroExpressionSource() {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(2) {
            serializer.serialize(2 as Int)
            serializer.serializeNil()
        }

        let deserializer = MsgPackDeserializer(serializer.byteString)
        #expect { try deserializer.deserialize() as MacroExpressionSource } throws: { error in
            ((error as? DeserializerError)?.errorString == DeserializerError.unexpectedValue("Unexpected type code (2)").errorString)
        }
    }

    @Test func sourceTree() {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(2) {
            serializer.serialize(3 as Int)
            serializer.serializeNil()
        }

        let deserializer = MsgPackDeserializer(serializer.byteString)
        #expect { try deserializer.deserialize() as SourceTree } throws: { error in
            ((error as? DeserializerError)?.errorString == DeserializerError.unexpectedValue("Unexpected type code (3)").errorString)
        }

        #expect((SourceTree.absolute as (any CustomDebugStringConvertible)).debugDescription == ".absolute")
        #expect((SourceTree.groupRelative as (any CustomDebugStringConvertible)).debugDescription == ".groupRelative")
        #expect((SourceTree.buildSetting("SRCROOT") as (any CustomDebugStringConvertible)).debugDescription == ".buildSetting(SRCROOT)")
    }

    @Test func PIFObject() {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(2) {
            serializer.serialize(3 as Int)
            serializer.serializeNil()
        }

        let deserializer = MsgPackDeserializer(serializer.byteString)
        #expect { try deserializer.deserialize() as PIFObject } throws: { error in
            ((error as? DeserializerError)?.errorString == DeserializerError.unexpectedValue("Unexpected type code (3)").errorString)
        }
    }

    @Test func provisioningStyle() {
        #expect(ProvisioningStyle.fromString("automatic") == .automatic)
        #expect(ProvisioningStyle.fromString("Automatic") == .automatic)
        #expect(ProvisioningStyle.fromString("AUTOMATIC") == .automatic)

        #expect(ProvisioningStyle.fromString("manual") == .manual)
        #expect(ProvisioningStyle.fromString("Manual") == .manual)
        #expect(ProvisioningStyle.fromString("MANUAL") == .manual)

        #expect(ProvisioningStyle.fromString("anything else") == nil)
    }
}
