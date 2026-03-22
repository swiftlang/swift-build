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

import SWBProtocol

public struct SWBBuildTargetInfo: Sendable, Equatable {
    public let sdkName: String
    public let platformName: String
    public let sdkVariant: String?
    public let deploymentTargetSettingName: String?
    public let deploymentTarget: String?

    public init(sdkName: String, platformName: String, sdkVariant: String?, deploymentTargetSettingName: String?, deploymentTarget: String?) {
        self.sdkName = sdkName
        self.platformName = platformName
        self.sdkVariant = sdkVariant
        self.deploymentTargetSettingName = deploymentTargetSettingName
        self.deploymentTarget = deploymentTarget
    }

    init(_ response: BuildTargetInfoResponse) {
        self.sdkName = response.sdkName
        self.platformName = response.platformName
        self.sdkVariant = response.sdkVariant
        self.deploymentTargetSettingName = response.deploymentTargetSettingName
        self.deploymentTarget = response.deploymentTarget
    }
}
