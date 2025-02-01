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

// For a description of how this feature works, see the `SWBBuildServiceSession.generateDocumentationInfo` documentation.

/// Delegation protocol for client-side things that relate to collecting documentation information.
public protocol SWBDocumentationDelegate: SWBPlanningOperationDelegate {
}

// MARK: - Response Types

/// Response for `GetDocumentationInfoMsg` request.
public struct SWBDocumentationInfo: Sendable {
    /// Information about the built documentation bundles for this request.
    public let builtDocumentationBundles: [SWBDocumentationBundleInfo]

    init(builtDocumentationBundles: [SWBDocumentationBundleInfo]) {
        self.builtDocumentationBundles = builtDocumentationBundles
    }
}

/// Information about built documentation and the path where it will be written.
public struct SWBDocumentationBundleInfo: Sendable {
    /// The output paths where the built documentation will be written.
    public let outputPath: String
    /// The identifier of the target associated with the documentation we're building.
    public let targetIdentifier: String?

    init(outputPath: String, targetIdentifier: String?) {
        self.outputPath = outputPath
        self.targetIdentifier = targetIdentifier
    }
}
