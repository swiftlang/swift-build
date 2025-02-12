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

public struct TaskActionExtensionPoint: ExtensionPoint {
    public typealias ExtensionProtocol = TaskActionExtension

    public static let name = "TaskActionExtensionPoint"

    package init() {}

    // MARK: - actual extension point

    package static func taskActionImplementations(pluginManager: PluginManager) throws -> [SerializableTypeCode: any PolymorphicSerializable.Type] {
        return try pluginManager.extensions(of: Self.self).reduce([:], { implementations, ext in
            for (code, _) in ext.taskActionImplementations where implementations[code] != nil {
                throw StubError.error("Multiple implementations for task action implementation type code: \(code)")
            }
            return implementations.addingContents(of: ext.taskActionImplementations)
        })
    }
}

public protocol TaskActionExtension: Sendable {
    /// Provides a dictionary of additional task action implementations.
    var taskActionImplementations: [SerializableTypeCode: any PolymorphicSerializable.Type] { get }
}
