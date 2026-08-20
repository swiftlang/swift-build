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

/// Test that types which gained fields can still be deserialized from payloads produced by an older client-side framework.
@Suite fileprivate struct SWBProtocolLegacyDeserializationTests {
    @Test func customTask() throws {
        let task = CustomTask(
            commandLine: [],
            environment: [],
            workingDirectory: .string(""),
            executionDescription: .string(""),
            inputFilePaths: [],
            outputFilePaths: [],
            enableSandboxing: false,
            preparesForIndexing: false
        )
        let encodedTask = try JSONEncoder().encode(task)
        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encodedTask) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "platformFilters")

        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decodedTask = try JSONDecoder().decode(CustomTask.self, from: legacyData)

        #expect(decodedTask.platformFilters.isEmpty)
    }

    @Test func targetDependency() throws {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(3) {
            serializer.serialize("target-guid")                             // guid
            serializer.serialize("TargetName")                              // name
            serializer.serialize(Set([PlatformFilter(platform: "macos")]))  // platformFilters
        }

        let deserializer = MsgPackDeserializer(serializer.byteString)
        let dependency = try TargetDependency(fromLegacy: deserializer)

        #expect(dependency.guid == "target-guid")
        #expect(dependency.platformFilters.map(\.platform) == ["macos"])
        #expect(dependency.buildConfigurationFilters.isEmpty)
    }

    @Test func buildFile() throws {
        let serializer = MsgPackSerializer()
        serializer.serializeAggregate(14) {
            serializer.serialize("build-file-guid")                                        // guid
            serializer.serialize(BuildFile.BuildableItemGUID.reference(guid: "ref-guid"))  // buildableItemGUID
            serializer.serializeNil()                                                      // additionalArgs
            serializer.serialize(false)                                                    // decompress
            serializer.serializeNil()                                                      // headerVisibility
            serializer.serializeNil()                                                      // migCodegenFiles
            serializer.serialize(BuildFile.IntentsCodegenVisibility.noCodegen)             // intentsCodegenVisibility
            serializer.serialize(BuildFile.ResourceRule.process)                           // resourceRule
            serializer.serialize(false)                                                    // codeSignOnCopy
            serializer.serialize(false)                                                    // removeHeadersOnCopy
            serializer.serialize(false)                                                    // shouldLinkWeakly
            serializer.serialize(Set<String>())                                            // assetTags
            serializer.serialize(Set<PlatformFilter>())                                    // platformFilters
            serializer.serialize(true)                                                     // shouldWarnIfNoRuleToProcess
        }

        let deserializer = MsgPackDeserializer(serializer.byteString)
        let buildFile = try BuildFile(fromLegacy: deserializer)

        #expect(buildFile.guid == "build-file-guid")
        #expect(buildFile.shouldWarnIfNoRuleToProcess)
        #expect(buildFile.buildConfigurationFilters.isEmpty)
    }
}
