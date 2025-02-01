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

@Suite(.requireHostOS(.macOS)) // `LSRegisterURL` only exists on macOS
fileprivate struct LSRegisterURLTests {
    @Test
    func diagnostics() async {
        func checkDiagnostics(_ commandLine: [String], commandResult: CommandResult, errors: [String], sourceLocation: SourceLocation = #_sourceLocation) async {
            let action = LSRegisterURLTaskAction()
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
            #expect(result == commandResult, sourceLocation: sourceLocation)
            #expect(outputDelegate.messages == errors.map { "error: \($0)" }, sourceLocation: sourceLocation)
        }

        await checkDiagnostics([], commandResult: .failed, errors: ["Invalid number of arguments"])
        await checkDiagnostics(["/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister", "-f", "-R", "-trusted", "foo"], commandResult: .succeeded, errors: [])
    }

    // FIXME: We should have some kind of test that we LSRegisterURL correctly. This probably makes more sense in a Quicklook test that actually verifies the end to end integration.

    @Test
    func failedRegister() async throws {
        let action = LSRegisterURLTaskAction()
        let task = Task(forTarget: nil, ruleInfo: [], commandLine: ["/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister", "-f", "-R", "-trusted", Path.null.str], workingDirectory: .root, outputs: [], action: action, execDescription: "")
        let executionDelegate = MockExecutionDelegate()
        let outputDelegate = MockTaskOutputDelegate()
        let result = await action.performTaskAction(task, dynamicExecutionDelegate: MockDynamicTaskExecutionDelegate(), executionDelegate: executionDelegate, clientDelegate: MockTaskExecutionClientDelegate(), outputDelegate: outputDelegate
        )
        #expect(result == .succeeded)
        #expect(outputDelegate.messages == [])
    }
}
