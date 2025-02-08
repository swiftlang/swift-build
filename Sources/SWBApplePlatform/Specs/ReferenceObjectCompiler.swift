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
public import SWBCore
public import SWBMacro

public struct DiscoveredReferenceObjectToolSpecInfo: DiscoveredCommandLineToolSpecInfo, Sendable {
    public let toolPath: Path
    public var toolVersion: Version?
}

public final class ReferenceObjectCompilerSpec : GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.referenceobject"

    public override var enableSandboxing: Bool {
        return true
    }

    override public func discoveredCommandLineToolSpecInfo(_ producer: any CommandProducer, _ scope: MacroEvaluationScope, _ delegate: any CoreClientTargetDiagnosticProducingDelegate) async -> (any DiscoveredCommandLineToolSpecInfo)? {
        let toolPath = resolveExecutablePath(producer, Path("referenceobjectc"))

        // Get the info from the global cache.
        do {
            return try await DiscoveredReferenceObjectToolSpecInfo.parseWhatStyleVersionInfo(producer, delegate, toolPath: toolPath) { versionInfo in
                DiscoveredReferenceObjectToolSpecInfo(toolPath: toolPath, toolVersion: versionInfo.version)
            }
        } catch {
            delegate.error(error)
            return nil
        }
    }
}
