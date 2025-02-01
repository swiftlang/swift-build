//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
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

@PluginExtensionSystemActor public func initializePlugin(_ manager: PluginManager) {
    manager.register(ApplePlatformSpecsExtension(), type: SpecificationsExtensionPoint.self)
    manager.register(ActoolInputFileGroupingStrategyExtension(), type: InputFileGroupingStrategyExtensionPoint.self)
    manager.register(ImageScaleFactorsInputFileGroupingStrategyExtension(), type: InputFileGroupingStrategyExtensionPoint.self)
    manager.register(LocalizationInputFileGroupingStrategyExtension(), type: InputFileGroupingStrategyExtensionPoint.self)
    manager.register(XCStringsInputFileGroupingStrategyExtension(), type: InputFileGroupingStrategyExtensionPoint.self)
    manager.register(TaskProducersExtension(), type: TaskProducerExtensionPoint.self)
    manager.register(MacCatalystInfoExtension(), type: SDKVariantInfoExtensionPoint.self)
}

struct TaskProducersExtension: TaskProducerExtension {

    func createPreSetupTaskProducers(_ context: TaskProducerContext) -> [any TaskProducer] {
        [DevelopmentAssetsTaskProducer(context)]
    }

    var setupTaskProducers: [any TaskProducerFactory] {
        [RealityAssetsTaskProducerFactory()]
    }

    var unorderedPostSetupTaskProducers: [any TaskProducerFactory] {
        [StubBinaryTaskProducerFactory()]
    }

    var globalTaskProducers: [any GlobalTaskProducerFactory] {
        [StubBinaryTaskProducerFactory()]
    }
}

struct StubBinaryTaskProducerFactory: TaskProducerFactory, GlobalTaskProducerFactory {
    var name: String {
        "StubBinaryTaskProducer"
    }

    func createTaskProducer(_ context: TargetTaskProducerContext, startPhaseNodes: [PlannedVirtualNode], endPhaseNode: PlannedVirtualNode) -> any TaskProducer {
        StubBinaryTaskProducer(context, phaseStartNodes: startPhaseNodes, phaseEndNode: endPhaseNode)
    }

    func createGlobalTaskProducer(_ globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) -> any TaskProducer {
        GlobalStubBinaryTaskProducer(context: globalContext, targetContexts: targetContexts)
    }
}

struct RealityAssetsTaskProducerFactory: TaskProducerFactory {
    var name: String {
        "RealityAssetsTaskProducer"
    }

    func createTaskProducer(_ context: TargetTaskProducerContext, startPhaseNodes: [PlannedVirtualNode], endPhaseNode: PlannedVirtualNode) -> any TaskProducer {
        RealityAssetsTaskProducer(context, phaseStartNodes: startPhaseNodes, phaseEndNode: endPhaseNode)
    }
}

struct ApplePlatformSpecsExtension: SpecificationsExtension {
    func specificationClasses() -> [any SpecIdentifierType.Type] {
        [
            ActoolCompilerSpec.self,
            CoreDataModelCompilerSpec.self,
            CoreMLCompilerSpec.self,
            CopyTiffFileSpec.self,
            CopyXCAppExtensionPointsFileSpec.self,
            DittoToolSpec.self,
            IBStoryboardLinkerCompilerSpec.self,
            IIGCompilerSpec.self,
            IbtoolCompilerSpecNIB.self,
            IbtoolCompilerSpecStoryboard.self,
            InstrumentsPackageBuilderSpec.self,
            IntentsCompilerSpec.self,
            MetalCompilerSpec.self,
            MetalLinkerSpec.self,
            MigCompilerSpec.self,
            OpenCLCompilerSpec.self,
            RealityAssetsCompilerSpec.self,
            ReferenceObjectCompilerSpec.self,
            ResMergerLinkerSpec.self,
            SceneKitToolSpec.self,
            XCStringsCompilerSpec.self,
        ]
    }

    func specificationFiles() -> Bundle? {
        .module
    }

    func specificationDomains() -> [String : [String]] {
        var mappings = [
            "macosx": ["darwin"],
            "driverkit": ["darwin"],
            "embedded-shared": ["darwin"],
            "embedded": ["embedded-shared"],
            "embedded-simulator": ["embedded-shared"],
        ]
        for platform in ["iphone", "appletv", "watch", "xr"] {
            mappings["\(platform)os"] = ["\(platform)os-shared", "embedded"]
            mappings["\(platform)simulator"] = ["\(platform)os-shared", "embedded-simulator"]
        }
        return mappings
    }
}

struct ActoolInputFileGroupingStrategyExtension: InputFileGroupingStrategyExtension {
    func groupingStrategies() -> [String: any InputFileGroupingStrategyFactory] {
        struct Factory: InputFileGroupingStrategyFactory {
            func makeStrategy(specIdentifier: String) -> any InputFileGroupingStrategy {
                ActoolInputFileGroupingStrategy(groupIdentifier: specIdentifier)
            }
        }
        return ["actool": Factory()]
    }
}

struct ImageScaleFactorsInputFileGroupingStrategyExtension: InputFileGroupingStrategyExtension {
    func groupingStrategies() -> [String: any InputFileGroupingStrategyFactory] {
        struct Factory: InputFileGroupingStrategyFactory {
            func makeStrategy(specIdentifier: String) -> any InputFileGroupingStrategy {
                ImageScaleFactorsInputFileGroupingStrategy(toolName: specIdentifier)
            }
        }
        return ["image-scale-factors": Factory()]
    }
}

struct LocalizationInputFileGroupingStrategyExtension: InputFileGroupingStrategyExtension {
    func groupingStrategies() -> [String: any InputFileGroupingStrategyFactory] {
        struct Factory: InputFileGroupingStrategyFactory {
            func makeStrategy(specIdentifier: String) -> any InputFileGroupingStrategy {
                LocalizationInputFileGroupingStrategy(toolName: specIdentifier)
            }
        }
        return ["region": Factory()]
    }
}

struct XCStringsInputFileGroupingStrategyExtension: InputFileGroupingStrategyExtension {
    func groupingStrategies() -> [String: any InputFileGroupingStrategyFactory] {
        struct Factory: InputFileGroupingStrategyFactory {
            func makeStrategy(specIdentifier: String) -> any InputFileGroupingStrategy {
                XCStringsInputFileGroupingStrategy(toolName: specIdentifier)
            }
        }
        return ["xcstrings": Factory()]
    }
}
