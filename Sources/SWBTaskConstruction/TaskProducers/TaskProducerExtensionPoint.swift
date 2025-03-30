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

package import SWBCore
import SWBUtil

package struct TaskProducerExtensionPoint: ExtensionPoint, Sendable {
    package typealias ExtensionProtocol = TaskProducerExtension

    package static let name = "TaskProducerExtensionPoint"

    package init() {}
}

package protocol TaskProducerExtension: Sendable {
    func createPreSetupTaskProducers(_ context: TaskProducerContext) -> [any TaskProducer]

    var setupTaskProducers: [any TaskProducerFactory] { get }
    var unorderedPostSetupTaskProducers: [any TaskProducerFactory] { get }
    var unorderedPostBuildPhasesTaskProducers: [any TaskProducerFactory] { get }
    var globalTaskProducers: [any GlobalTaskProducerFactory] { get }
}

package protocol TaskProducerFactory: Sendable {
    var name: String { get }

    func createTaskProducer(_ context: TargetTaskProducerContext, startPhaseNodes: [PlannedVirtualNode], endPhaseNode: PlannedVirtualNode) -> any TaskProducer
}

package protocol GlobalTaskProducerFactory: Sendable {
    func createGlobalTaskProducer(_ globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) -> any TaskProducer
}
