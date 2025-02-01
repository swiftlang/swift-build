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
import Testing
import SWBCore
import SWBLibc
import SWBTaskExecution
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct RegisterExecutionPolicyExceptionTaskActionTests {
    @Test
    func diagnostics() async {
        func checkDiagnostics(_ commandLine: [String], errors: [String], sourceLocation: SourceLocation = #_sourceLocation) async {
            let action = RegisterExecutionPolicyExceptionTaskAction()
            let task = Task(forTarget: nil, ruleInfo: [], commandLine: commandLine, workingDirectory: .root, outputs: [], action: action, execDescription: "")
            let executionDelegate = MockExecutionDelegate()
            let outputDelegate = MockTaskOutputDelegate()
            let result = await action.performTaskAction(
                task,
                dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
                executionDelegate: executionDelegate,
                clientDelegate: MockTaskExecutionClientDelegate(),
                outputDelegate: outputDelegate
            )
            #expect(result == .failed, sourceLocation: sourceLocation)
            #expect(outputDelegate.messages == errors.map { "error: \($0)" }, sourceLocation: sourceLocation)
        }

        await checkDiagnostics([], errors: ["invalid number of arguments"])
        await checkDiagnostics(["bless", "foo", "bar"], errors: ["invalid number of arguments"])
    }

    @Test
    func failedRegister() async {
        let action = RegisterExecutionPolicyExceptionTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["register-execution-policy-exception", Path.null.str], workingDirectory: .root, outputs: [], action: action, execDescription: "")
        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(),
            executionDelegate: executionDelegate,
            clientDelegate: MockTaskExecutionClientDelegate(),
            outputDelegate: outputDelegate
        )
        #expect(result == .succeeded)
        #expect(outputDelegate.messages == [])
    }
}
