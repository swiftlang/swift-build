//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

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
        let toolPath = self.resolveExecutablePath(producer, Path("clang-ssaf-linker"))

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
