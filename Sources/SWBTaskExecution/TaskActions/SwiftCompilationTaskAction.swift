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

import SWBUtil
import SWBLibc
public import SWBCore
import enum SWBLLBuild.BuildValueKind

public final class SwiftCompilationTaskAction: SwiftDriverJobSchedulingTaskAction {
    public override class var toolIdentifier: String {
        return "swift-driver-compilation"
    }

    public override func primaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        plannedBuild.compilationPlannedDriverJobs()
    }

    public override func untrackedPrimaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        plannedBuild.compilationRequirementsPlannedDriverJobs()
    }

    public override func secondaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        if driverPayload.eagerCompilationEnabled {
            return plannedBuild.afterCompilationPlannedDriverJobs() + plannedBuild.verificationPlannedDriverJobs()
        } else {
            return plannedBuild.verificationPlannedDriverJobs()
        }
    }

    public override func shouldReportSkippedJobs(driverPayload: SwiftDriverPayload) -> Bool {
        driverPayload.eagerCompilationEnabled
    }
}
