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
import SWBCore
import Foundation
import SWBTaskConstruction
import SWBTaskExecution

@PluginExtensionSystemActor public func initializePlugin(_ manager: PluginManager) {
    manager.register(UniversalPlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(UniversalPlatformTaskProducerExtension(), type: TaskProducerExtensionPoint.self)
    manager.register(UniversalPlatformTaskActionExtension(), type: TaskActionExtensionPoint.self)
}

struct UniversalPlatformSpecsExtension: SpecificationsExtension {
    func specificationClasses() -> [any SpecIdentifierType.Type] {
        [
            CopyPlistFileSpec.self,
            CopyStringsFileSpec.self,
            CppToolSpec.self,
            LexCompilerSpec.self,
            YaccCompilerSpec.self,
            TestEntryPointGenerationToolSpec.self,
        ]
    }

    func specificationImplementations() -> [any SpecImplementationType.Type] {
        [
            DiffToolSpec.self,
        ]
    }

    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBUniversalPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }

    // Allow locating the sole remaining `.xcbuildrules` file.
    func specificationSearchPaths(resourceSearchPaths: [Path]) -> [URL] {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBUniversalPlatform", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)?.resourceURL.map { [$0] } ?? []
    }
}

struct UniversalPlatformTaskProducerExtension: TaskProducerExtension {
    func createPreSetupTaskProducers(_ context: SWBTaskConstruction.TaskProducerContext) -> [any SWBTaskConstruction.TaskProducer] {
        []
    }

    struct TestEntryPointTaskProducerFactory: TaskProducerFactory {
        var name: String {
            "TestEntryPointTaskProducerFactory"
        }

        func createTaskProducer(_ context: SWBTaskConstruction.TargetTaskProducerContext, startPhaseNodes: [SWBCore.PlannedVirtualNode], endPhaseNode: SWBCore.PlannedVirtualNode) -> any SWBTaskConstruction.TaskProducer {
            TestEntryPointTaskProducer(context, phaseStartNodes: startPhaseNodes, phaseEndNode: endPhaseNode)
        }
    }

    var setupTaskProducers: [any SWBTaskConstruction.TaskProducerFactory] {
        [TestEntryPointTaskProducerFactory()]
    }

    var unorderedPostSetupTaskProducers: [any SWBTaskConstruction.TaskProducerFactory] { [] }

    var unorderedPostBuildPhasesTaskProducers: [any SWBTaskConstruction.TaskProducerFactory] { [] }

    var globalTaskProducers: [any SWBTaskConstruction.GlobalTaskProducerFactory] { [] }
}

struct UniversalPlatformTaskActionExtension: TaskActionExtension {
    var taskActionImplementations: [SWBUtil.SerializableTypeCode : any SWBUtil.PolymorphicSerializable.Type] {
        [41: TestEntryPointGenerationTaskAction.self]
    }
}
