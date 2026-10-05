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

public import SWBCore
import SWBLibc
import SWBUtil

/// Builds only a target's explicit module dependencies, without emitting the target's own module. Used when preparing a
/// target for indexing in the index build arena, where the index compile needs the dependencies but not the module.
final public class SwiftDriverExplicitModulesTaskAction: SwiftDriverJobSchedulingTaskAction {
    public override class var toolIdentifier: String {
        "swift-driver-explicit-modules"
    }

    public override func primaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        guard driverPayload.explicitModulesEnabled else { return [] }
        return plannedBuild.explicitModulesPlannedDriverJobs()[...]
    }

    public override func untrackedPrimaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        []
    }

    public override func copyForConcurrentExecution() -> TaskAction? {
        SwiftDriverExplicitModulesTaskAction()
    }
}
