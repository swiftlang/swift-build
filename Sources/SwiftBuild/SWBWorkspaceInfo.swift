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

import Foundation

import SWBProtocol

public struct SWBWorkspaceInfo: Sendable {
    public let targetInfos: [SWBTargetInfo]
}

public struct SWBTargetInfo: Sendable {
    public let guid: String
    public let targetName: String
    public let projectName: String
}

extension SWBWorkspaceInfo {
    init(_ workspaceInfo: WorkspaceInfoResponse.WorkspaceInfo) {
        self = .init(targetInfos: workspaceInfo.targetInfos.map { .init(guid: $0.guid, targetName: $0.targetName, projectName: $0.projectName) })
    }
}
