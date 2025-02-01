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

import SWBUtil

public struct SWBUserInfo: Sendable {
    /// Returns a user info structure with values appropriate for the calling environment.
    ///
    /// The user, group, and home directory are based on the current user, and both environment dictionaries are set to those of the calling process's environment.
    public static let `default`: Self = {
        let processInfo = ProcessInfo.processInfo
        return Self(
            userName: processInfo.shortUserName,
            groupName: processInfo.shortGroupName,
            uid: processInfo.effectiveUserID,
            gid: processInfo.effectiveGroupID,
            homeDirectory: Path.homeDirectory.str,
            processEnvironment: processInfo.cleanEnvironment,
            buildSystemEnvironment: processInfo.cleanEnvironment)
    }()

    public let userName: String
    public let groupName: String
    public let uid: Int
    public let gid: Int
    public let homeDirectory: String
    public let processEnvironment: [String: String]
    public let buildSystemEnvironment: [String: String]

    public init(userName: String, groupName: String, uid: Int, gid: Int, homeDirectory: String, processEnvironment: [String: String], buildSystemEnvironment: [String: String]) {
        self.userName = userName
        self.groupName = groupName
        self.uid = uid
        self.gid = gid
        self.homeDirectory = homeDirectory
        self.processEnvironment = processEnvironment
        self.buildSystemEnvironment = buildSystemEnvironment
    }
}

extension SWBUserInfo {
    public func with(
        userName: String? = nil,
        groupName: String? = nil,
        uid: Int? = nil,
        gid: Int? = nil,
        homeDirectory: String? = nil,
        processEnvironment: [String: String]? = nil,
        buildSystemEnvironment: [String: String]? = nil
    ) -> Self {
        return Self(
            userName: userName ?? self.userName,
            groupName: groupName ?? self.groupName,
            uid: uid ?? self.uid,
            gid: gid ?? self.gid,
            homeDirectory: homeDirectory ?? self.homeDirectory,
            processEnvironment: processEnvironment ?? self.processEnvironment,
            buildSystemEnvironment: buildSystemEnvironment ?? self.buildSystemEnvironment
        )
    }
}
