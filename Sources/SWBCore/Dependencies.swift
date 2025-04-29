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
public import SWBMacro

// Needed to resolve BuiltinMacros … why?
import SWBCore

import Foundation

// Global/target dependency settings
public struct DependencySettings : Serializable, Sendable, Encodable {
    public let dependencies: OrderedSet<String>
    public let verification: Bool


    public init(_ scope: MacroEvaluationScope) {
        self.init(
            dependencies: scope.evaluate(BuiltinMacros.DEPENDENCIES),
            verification: scope.evaluate(BuiltinMacros.DEPENDENCIES_VERIFICATION)
        )
    }

    public init(
        dependencies: [String],
        verification: Bool
    ) {
        self.dependencies = OrderedSet(dependencies)
        self.verification = verification
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(dependencies)
            serializer.serialize(verification)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.dependencies = try deserializer.deserialize()
        self.verification = try deserializer.deserialize()
    }

}

// Task-specific settings
public struct TaskDependencySettings : Serializable, Sendable, Encodable {

    public let traceFile: Path
    public let dependencySettings: DependencySettings

    init(traceFile: Path, dependencySettings: DependencySettings) {
        assert(!traceFile.isEmpty, "traceFile should never be empty")
        self.traceFile = traceFile
        self.dependencySettings = dependencySettings
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(traceFile)
            serializer.serialize(dependencySettings)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.traceFile = try deserializer.deserialize()
        self.dependencySettings = try deserializer.deserialize()
    }

    func signatureData() -> String {
        return "verify:\(dependencySettings.verification),deps:\(dependencySettings.dependencies.joined(separator: ":"))"
    }

}

// Protocol for task payloads
public protocol TaskDependencySettingsPayload {
    var taskDependencySettings: TaskDependencySettings? { get }
}
