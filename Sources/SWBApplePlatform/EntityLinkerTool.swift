//
//  EntityLinkerTool.swift
//  xcbuild
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Foundation
public import SWBUtil
public import SWBCore
public import SWBMacro


public final class EntityLinkerToolSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.entity-linker"
    required public init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec)
    }

    public struct DiscoveredEntityLinkerToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
        public let toolPath: Path
        public var toolVersion: Version?
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        let toolPath = self.resolveExecutablePath(producer, Path("entity-linker"))

        do {
            return try await DiscoveredEntityLinkerToolSpecInfo.parseProjectNameAndSourceVersionStyleVersionInfo(producer, delegate, commandLine: [toolPath.str, "version"]) { versionInfo in
                DiscoveredEntityLinkerToolSpecInfo(toolPath: toolPath, toolVersion: versionInfo.version)
            }
        } catch {
            delegate.error(error)
            return nil
        }
    }
}
