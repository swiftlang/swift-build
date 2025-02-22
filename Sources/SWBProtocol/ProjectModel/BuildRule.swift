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

public import SWBUtil

public struct BuildRule: Sendable {
    public enum InputSpecifier: Sendable {
        // FIXME: We should consider if we can deprecate the ability to expand macros in the patterns.
        case patterns(MacroExpressionSource)
        case fileType(identifier: String)
    }

    public enum ActionSpecifier: Sendable {
        case compiler(identifier: String)

        // See also: SWBCore.ProjectModel.BuildRule.BuildRuleActionSpecifier
        case shellScript(
            contents: String,
            inputs: [MacroExpressionSource],
            inputFileLists: [MacroExpressionSource],
            outputs: [ShellScriptOutputInfo],
            outputFileLists: [MacroExpressionSource],
            dependencyInfo: DependencyInfo?,
            runOncePerArchitecture: Bool)
    }

    public struct ShellScriptOutputInfo: Sendable {
        public let path: MacroExpressionSource
        public let additionalCompilerFlags: MacroExpressionSource?

        public init(path: MacroExpressionSource, additionalCompilerFlags: MacroExpressionSource?) {
            self.path = path
            self.additionalCompilerFlags = additionalCompilerFlags
        }
    }

    public let guid: String
    public let name: String
    public let inputSpecifier: InputSpecifier
    public let actionSpecifier: ActionSpecifier

    public init(guid: String, name: String, inputSpecifier: InputSpecifier, actionSpecifier: ActionSpecifier) {
        self.guid = guid
        self.name = name
        self.inputSpecifier = inputSpecifier
        self.actionSpecifier = actionSpecifier
    }
}

// MARK: SerializableCodable

extension BuildRule: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(guid)
            serializer.serialize(name)
            serializer.serialize(inputSpecifier)
            serializer.serialize(actionSpecifier)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.guid = try deserializer.deserialize()
        self.name = try deserializer.deserialize()
        self.inputSpecifier = try deserializer.deserialize()
        self.actionSpecifier = try deserializer.deserialize()
    }
}

extension BuildRule.InputSpecifier: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .patterns(let value):
                serializer.serialize(0 as Int)
                serializer.serialize(value)
            case .fileType(let identifier):
                serializer.serialize(1 as Int)
                serializer.serialize(identifier)
            }
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as Int {
        case 0:
            self = .patterns(try deserializer.deserialize())
        case 1:
            self = .fileType(identifier: try deserializer.deserialize())
        case let v:
            throw DeserializerError.unexpectedValue("Unexpected type code (\(v))")
        }
    }
}

extension BuildRule.ActionSpecifier: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            switch self {
            case .compiler(let identifier):
                serializer.serialize(0 as Int)
                serializer.serialize(identifier)
            case .shellScript(let contents, let inputs, let inputFileLists, let outputs, let outputFileLists, let dependencyInfo, let runOncePerArchitecture):
                serializer.serialize(1 as Int)
                serializer.serializeAggregate(7) {
                    serializer.serialize(contents)
                    serializer.serialize(inputs)
                    serializer.serialize(inputFileLists)
                    serializer.serialize(outputs)
                    serializer.serialize(outputFileLists)
                    serializer.serialize(dependencyInfo)
                    serializer.serialize(runOncePerArchitecture)
                }
            }
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        switch try deserializer.deserialize() as Int {
        case 0:
            self = .compiler(identifier: try deserializer.deserialize())
        case 1:
            try deserializer.beginAggregate(7)
            let contents: String = try deserializer.deserialize()
            let inputs: [MacroExpressionSource] = try deserializer.deserialize()
            let inputFileLists: [MacroExpressionSource] = try deserializer.deserialize()
            let outputs: [BuildRule.ShellScriptOutputInfo] = try deserializer.deserialize()
            let outputFileLists: [MacroExpressionSource] = try deserializer.deserialize()
            let dependencyInfo: DependencyInfo? = try deserializer.deserialize()
            let runOncePerArchitecture: Bool = try deserializer.deserialize()
            self = .shellScript(contents: contents, inputs: inputs, inputFileLists: inputFileLists, outputs: outputs, outputFileLists: outputFileLists, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
        case let v:
            throw DeserializerError.unexpectedValue("Unexpected type code (\(v))")
        }
    }
}

extension BuildRule.ShellScriptOutputInfo: PendingSerializableCodable {
    public func legacySerialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(path)
            serializer.serialize(additionalCompilerFlags)
        }
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.path = try deserializer.deserialize()
        self.additionalCompilerFlags = try deserializer.deserialize()
    }
}
