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

import Testing
import SWBTaskExecution

@Suite
fileprivate struct TaskActionConcurrentExecutionTests {
    /// A task action carrying per-execution mutable state must vend a distinct
    /// instance per build engine, so concurrent engines sharing a memoized
    /// action don't race on that state.
    @Test
    func statefulActionIsolatesPerExecution() throws {
        let shared = SwiftDriverCompilationRequirementTaskAction()

        let copy = try #require(shared.copyForConcurrentExecution(), "stateful action must vend a per-execution copy")
        #expect(copy !== shared)
        #expect(type(of: copy) == type(of: shared))

        // Every request yields a distinct instance.
        let other = try #require(shared.copyForConcurrentExecution())
        #expect(copy !== other)
    }

    /// A stateless task action is safe to share, so it opts out of copying.
    @Test
    func statelessActionIsShared() {
        let action = CreateBuildDirectoryTaskAction()
        #expect(action.copyForConcurrentExecution() == nil)
    }
}
