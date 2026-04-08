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

public import SWBCore
import SWBLibc
import SWBUtil

public final class SwiftCompilationVerificationTaskAction: SwiftDriverJobSchedulingTaskAction {
    public override class var toolIdentifier: String {
        "swift-driver-compilation-verification"
    }

    public override func primaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        plannedBuild.verificationPlannedDriverJobs()
    }

    public override func untrackedPrimaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        []
    }
}
