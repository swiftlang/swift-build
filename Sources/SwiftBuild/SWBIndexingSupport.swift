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

/// Delegation protocol for client-side things that relate to collecting indexing information.
public protocol SWBIndexingDelegate: SWBPlanningOperationDelegate {
}

// MARK: - Response Types

public struct SWBIndexingFileSettings: Sendable {
    public let sourceFileBuildInfos: [[String: SWBPropertyListItem]]

    init(sourceFileBuildInfos: [[String: SWBPropertyListItem]]) {
        self.sourceFileBuildInfos = sourceFileBuildInfos
    }
}

public struct SWBIndexingHeaderInfo: Sendable {
    public let productName: String
    public let copiedPathMap: [AbsolutePath: AbsolutePath]

    init(productName: String, copiedPathMap: [AbsolutePath: AbsolutePath]) {
        self.productName = productName
        self.copiedPathMap = copiedPathMap
    }
}

/// Response for `BuildDescriptionTargetInfoMsg` request.
public struct SWBBuildDescriptionTargetInfo: Sendable {
    /// List of target GUIDs for the targets covered by a build description.
    public let targetGUIDs: [String]

    init(targetGUIDs: [String]) {
        self.targetGUIDs = targetGUIDs
    }
}
