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

/// Describes behavior when a source-generating file type is in the Resources phase
/// but the target has no Compile Sources phase.
public enum MissingSourcesPhaseBehavior: Sendable {
    /// Silently keep the file in Resources
    case keepInResources
    /// Emit a build error because the generated source cannot be compiled
    case error
}

/// Describes a file type that produces generated source code.
public struct SourceGeneratingFileType: Sendable {
    /// The file type identifier
    public let identifier: String
    /// What to do when the target has no Compile Sources phase
    public let missingSourcesPhaseBehavior: MissingSourcesPhaseBehavior

    public init(identifier: String, missingSourcesPhaseBehavior: MissingSourcesPhaseBehavior = .keepInResources) {
        self.identifier = identifier
        self.missingSourcesPhaseBehavior = missingSourcesPhaseBehavior
    }
}

public struct InputFileGroupingStrategyExtensionPoint: ExtensionPoint, Sendable {
    public typealias ExtensionProtocol = InputFileGroupingStrategyExtension

    public static let name = "InputFileGroupingStrategyExtensionPoint"

    public init() {}
}

public protocol InputFileGroupingStrategyExtension: Sendable {
    func groupingStrategies() -> [String: any InputFileGroupingStrategyFactory]
    func fileTypesProducingGeneratedSources(scope: MacroEvaluationScope) -> [String]
    func sourceGeneratingFileTypes(scope: MacroEvaluationScope) -> [SourceGeneratingFileType]
}

// Default implementation so existing conformers don't break
extension InputFileGroupingStrategyExtension {
    public func sourceGeneratingFileTypes(scope: MacroEvaluationScope) -> [SourceGeneratingFileType] {
        return fileTypesProducingGeneratedSources(scope: scope).map {
            SourceGeneratingFileType(identifier: $0, missingSourcesPhaseBehavior: .keepInResources)
        }
    }
}
