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

package import SWBTestSupport
@_spi(TestSupport) package import SWBUtil
package import SwiftBuild
import SWBProtocol
package import SWBCore
package import Testing
import Foundation

final package class CoreQualificationTester: Sendable {
    private let testWorkspace: TestWorkspace
    private let testSession: TestSWBSession
    private let fs: any FSProxy

    package init(_ testWorkspace: TestWorkspace, _ testSession: TestSWBSession, sendPIF: Bool = true, fs: any FSProxy = localFS) async throws {
        self.testWorkspace = testWorkspace
        self.testSession = testSession
        self.fs = fs
        if sendPIF {
            do {
                try await self.testSession.sendPIF(testWorkspace)
            } catch {
                throw error
            }
        }
    }

    package convenience init(_ testProject: TestProject, _ testSession: TestSWBSession, sendPIF: Bool = true, fs: any FSProxy = localFS) async throws {
        try await self.init(TestWorkspace("Test", sourceRoot: testProject.sourceRoot, projects: [testProject]), testSession, sendPIF: sendPIF, fs: fs)
    }

    package func invalidate() async throws {
    }

    package func checkBuild(_ buildParameters: SWBBuildParameters? = nil, _ buildRequest: SWBBuildRequest? = nil, delegate: (any SWBPlanningOperationDelegate)? = nil, sourceLocation: SourceLocation = #_sourceLocation, _ block: (CoreQualificationTesterResults) async throws -> Void) async throws {
        guard let project = testWorkspace.projects.first else {
            throw StubError.error("Workspace has no projects; explicitly specify target name to build")
        }
        guard let targetName = project.targets.first?.name else {
            throw StubError.error("Workspace has no targets; explicitly specify target name to build")
        }
        return try await checkBuild(buildParameters, buildRequest, target: targetName, project: project.name, delegate: delegate, sourceLocation: sourceLocation, block)
    }

    package func checkBuild(_ buildParameters: SWBBuildParameters? = nil, _ buildRequest: SWBBuildRequest? = nil, target: String, project: String? = nil, delegate: (any SWBPlanningOperationDelegate)? = nil, sourceLocation: SourceLocation = #_sourceLocation, _ block: (CoreQualificationTesterResults) async throws -> Void) async throws {
        let delegate = delegate ?? TestBuildOperationDelegate()

        var request = buildRequest ?? SWBBuildRequest()
        if let buildParameters {
            request.parameters = buildParameters
        }

        request.parameters.configurationName = request.parameters.configurationName ?? "Debug"
        request.add(target: SWBConfiguredTarget(guid: try testWorkspace.findTarget(name: target, project: project).guid, parameters: nil))

        let events = try await testSession.runBuildOperation(request: request, delegate: delegate)

        try await checkResults(events: events, block)
    }

    package func checkResults(events: [SwiftBuildMessage], sourceLocation: SourceLocation = #_sourceLocation, _ block: (CoreQualificationTesterResults) async throws -> Void) async throws {
        //try await XCTContext.runActivity(named: "Analyze Build Results") { activity in
            var loggedEvents: [String] = []
            var diagnostics: [LoggedDiagnostic] = []
            for event in events {
                switch event {
                case let .diagnostic(message):
                    diagnostics.append(.init(message))
                default:
                    break
                }
                try loggedEvents.append(String(decoding: JSONEncoder(outputFormatting: [.sortedKeys, .withoutEscapingSlashes]).encode(event), as: UTF8.self))
            }

            // TODO: <rdar://59432231> Longer term, we should find a way to share code with BuildOperationTester, which has a number of APIs for building up a human readable build transcript.
            //activity.attach(name: "Event Log", plistObject: loggedEvents)
            //activity.attach(name: "Diagnostics", plistObject: diagnostics.map { $0.description })
            //activity.attach(name: "Output", string: events.allOutput().bytes.unsafeStringValue)

            let results = CoreQualificationTesterResults(events: events, diagnostics: diagnostics, fs: fs)

            defer {
                let validationResults = results.validate(sourceLocation: sourceLocation)

                // Print the event log in the case of unchecked errors/warnings, which is useful on platforms where XCTAttachment doesn't exist
                if validationResults.hadUncheckedErrors || validationResults.hadUncheckedWarnings {
                    Issue.record("Build failed with unchecked errors and/or warnings; event log follows:\n\n\(loggedEvents.joined(separator: "\n"))", sourceLocation: sourceLocation)
                }
            }

            try await block(results)
        //}
    }
}

package struct LoggedDiagnostic: Equatable, CustomStringConvertible, Sendable {
    package let location: String?
    package let message: String
    package let type: SwiftBuildMessage.DiagnosticInfo.Kind
    package let targetID: String?
    package let taskSignature: String?
    package let childDiagnostics: [LoggedDiagnostic]

    init(_ info: SwiftBuildMessage.DiagnosticInfo) {
        self.message = info.message
        self.type = info.kind
        self.targetID = info.locationContext2.targetID?.description
        self.taskSignature = info.locationContext2.taskSignature

        if case let .path(path, .textual(line, column)) = info.location {
            switch (line, column) {
            case let (line, column?):
                self.location = "\(path):\(line):\(column)"
            case (let line, nil):
                self.location = "\(path):\(line)"
            }
        } else {
            self.location = nil
        }

        self.childDiagnostics = info.childDiagnostics.map { .init($0) }
    }

    package var description: String {
        return (["\(location.map { "\($0): " } ?? "")\(type.rawValue): \(message)"] + childDiagnostics.map { "\t\($0.description)" }).joined(separator: "\n")
    }
}

package final class CoreQualificationTesterResults: DiagnosticsCheckingResult, FileContentsCheckingResult, TasksCheckingResult {
    package typealias DiagnosticType = LoggedDiagnostic
    package var checkedErrors: Bool = false
    package var checkedWarnings: Bool = false
    package var checkedNotes: Bool = false
    package var checkedRemarks: Bool = false

    package func commandLine(_ task: SwiftBuildMessage.TaskStartedInfo) throws -> [String] {
        throw StubError.error("\(type(of: task)) does not have a command line")
    }

    package func getDiagnostics(_ forKind: CoreQualificationTesterResults.DiagnosticKind) -> [String] {
        return diagnostics.filter { $0.type.behavior == forKind }.compactMap { filterDiagnostic(message: $0.message) != nil ? $0.description : nil }
    }

    package func getDiagnosticMessage(_ pattern: SWBTestSupport.StringPattern, kind: DiagnosticKind, checkDiagnostic: (DiagnosticType) -> Bool) -> String? {
        for (index, event) in diagnostics.enumerated() {
            guard event.type.behavior == kind, case pattern = event.message, checkDiagnostic(event) else {
                continue
            }

            diagnostics.remove(at: index)

            return event.message
        }
        return nil
    }

    @available(*, deprecated)
    package func check(_ pattern: SWBTestSupport.StringPattern, kind: DiagnosticKind, failIfNotFound: Bool, file: StaticString, line: UInt, checkDiagnostic: (LoggedDiagnostic) -> Bool) -> Bool {
        check(pattern, kind: kind, failIfNotFound: failIfNotFound, sourceLocation: #_sourceLocation, checkDiagnostic: checkDiagnostic)
    }

    @available(*, deprecated)
    package func check(_ patterns: [SWBTestSupport.StringPattern], diagnostics: [String], kind: DiagnosticKind, failIfNotFound: Bool, file: StaticString, line: UInt) -> Bool {
        check(patterns, diagnostics: diagnostics, kind: kind, failIfNotFound: failIfNotFound, sourceLocation: #_sourceLocation)
    }

    package func check(_ pattern: StringPattern, kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation, checkDiagnostic: (DiagnosticType) -> Bool) -> Bool {
        let found = (getDiagnosticMessage(pattern, kind: kind, checkDiagnostic: checkDiagnostic) != nil)

        if !found, failIfNotFound {
            Issue.record("Unable to find \(kind.name): '\(pattern)' (other \(kind.name)s: \(getDiagnostics(kind)))", sourceLocation: sourceLocation)
        }
        return found
    }

    package func check(_ patterns: [StringPattern], diagnostics: [String], kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation) -> Bool {
        Issue.record("\(type(of: self)).check() for multiple patterns is not yet implemented", sourceLocation: sourceLocation)
        return false
    }

    package let fs: any FSProxy
    private let events: [SwiftBuildMessage]
    private let taskStartedMessages: [SwiftBuildMessage.TaskStartedInfo]
    private var diagnostics: [LoggedDiagnostic]
    package var uncheckedTasks: [SwiftBuildMessage.TaskStartedInfo]
    private var failedTasks: [SwiftBuildMessage.TaskStartedInfo]

    fileprivate init(events: [SwiftBuildMessage], diagnostics: [LoggedDiagnostic], fs: any FSProxy) {
        self.fs = fs
        self.events = events
        let taskStartedMessages = events.taskStartedMessages
        self.taskStartedMessages = taskStartedMessages
        self.diagnostics = diagnostics
        self.uncheckedTasks = taskStartedMessages
        self.failedTasks = events.flatMap { event in
            switch event {
            case let .taskComplete(message) where message.result == .failed:
                return taskStartedMessages.filter { $0.taskID == message.taskID }
            default:
                return []
            }
        }
    }

    package func checkNoFailedTasks(sourceLocation: SourceLocation = #_sourceLocation) {
        for failedTask in failedTasks.sorted(by: { $0.ruleInfo < $1.ruleInfo }) {
            Issue.record("Unexpected failing task: \(failedTask.ruleInfo)", sourceLocation: sourceLocation)
        }
    }

    package func checkTaskFailed(_ task: SwiftBuildMessage.TaskStartedInfo, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(failedTasks.contains(task), "Expected \(task) to fail but it did not", sourceLocation: sourceLocation)
    }

    package func checkSomeTasksFailed(_ tasks: [SwiftBuildMessage.TaskStartedInfo], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(failedTasks.contains(anyOf: tasks), "Expected one or more of \(tasks) to fail but they did not", sourceLocation: sourceLocation)
    }

    package func removeMatchedTask(_ task: SwiftBuildMessage.TaskStartedInfo) {
        for i in 0..<uncheckedTasks.count {
            if uncheckedTasks[i] == task {
                uncheckedTasks.remove(at: i)
                break
            }
        }
    }

    package func _match(_ task: SwiftBuildMessage.TaskStartedInfo, _ condition: SWBTestSupport.TaskCondition) -> Bool {
        switch condition {
        case .matchTarget, .matchTargetName, .matchCommandLineArgument, .matchCommandLineArgumentPattern:
            fatalError("not supported")
        case .matchRule, .matchRulePattern, .matchRuleType, .matchRuleItem, .matchRuleItemBasename, .matchRuleItemPattern:
            // FIXME: Change the API to use a rule info array directly
            var inQuotedString = false
            var ruleInfo: [String] = []
            var ruleItem = ""
            var it = task.ruleInfo.makeIterator()
            while let ch = it.next() {
                switch ch {
                case "\"" where inQuotedString:
                    inQuotedString = false
                    ruleInfo.append(ruleItem)
                    ruleItem = ""
                case "\"" where !inQuotedString:
                    inQuotedString = true
                case " " where !inQuotedString:
                    if !ruleItem.isEmpty {
                        ruleInfo.append(ruleItem)
                        ruleItem = ""
                    }
                case "\\" where !inQuotedString:
                    ruleItem = ruleItem + (it.next().map { String($0) } ?? "")
                default:
                    ruleItem = ruleItem + String(ch)
                }
            }
            if !ruleItem.isEmpty {
                ruleInfo.append(ruleItem)
            }
            return condition.match(target: nil, ruleInfo: ruleInfo, commandLine: [])
        }
    }

    package func _shouldPrecede(_ lhs: SwiftBuildMessage.TaskStartedInfo, _ rhs: SwiftBuildMessage.TaskStartedInfo) -> Bool {
        // FIXME: Order by target, like ExecutableTask.shouldPrecede?

        // Order these tasks by ruleInfo.
        return lhs.ruleInfo.lexicographicallyPrecedes(rhs.ruleInfo)
    }

    package func checkUniqueTaskSignatures(sourceLocation: SourceLocation = #_sourceLocation) {
        for (signature, tasks) in Dictionary(grouping: taskStartedMessages, by: { $0.taskSignature }) where tasks.count > 1 {
            Issue.record("unexpected task signature collision for signature '\(signature)': \(tasks)", sourceLocation: sourceLocation)
        }
    }
}

@available(*, unavailable)
extension CoreQualificationTesterResults: Sendable { }

package enum EntitlementsDestination: Sendable {
    case signed
    case simulated
}

extension FileContentsCheckingResult {
    package func checkFileExists(_ path: Path, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(fs.exists(path), "Expected file '\(path.str)' to exist, but it does not", sourceLocation: sourceLocation)
    }

    package func checkFileDoesNotExist(_ path: Path, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!fs.exists(path), "Expected file '\(path.str)' not to exist, but it does", sourceLocation: sourceLocation)
    }

    package func checkPropertyListContents<T>(_ path: Path, _ block: (PropertyListItem) throws -> T) throws -> T {
        return try block(PropertyList.fromBytes(fs.read(path).bytes))
    }

    package func checkNoEntitlements(_ destination: EntitlementsDestination, _ binaryPath: Path) async throws {
        try await checkEntitlements(destination, binaryPath) { slice, entitlements in
            #expect(entitlements == nil, "Expected no \(destination) entitlements for \(slice.arch) slice of '\(binaryPath.str)'.")
        }
    }

    package func checkEntitlements(_ destination: EntitlementsDestination, _ binaryPath: Path, _ block: ([String: PropertyListItem]?) throws -> Void) async throws {
        try await checkEntitlements(destination, binaryPath) { _, entitlements in
            try block(entitlements)
        }
    }

    package func checkEntitlements(_ destination: EntitlementsDestination, _ binaryPath: Path, _ block: (MachO.Slice, [String: PropertyListItem]?) throws -> Void) async throws {
        let xcode = try await InstalledXcode.currentlySelected()

        func processSlice(_ slice: MachO.Slice) async throws {
            let plist: PropertyListItem?
            switch destination {
            case .signed:
                let bytes = try await Array(xcode.xcrun(["/usr/bin/codesign", "-a", slice.arch, "-d", "--entitlements", ":-", binaryPath.str], redirectStderr: false).utf8)
                plist = try !bytes.isEmpty ? PropertyList.fromBytes(bytes) : nil
            case .simulated:
                // xcrun otool-classic [-arch arch] -X -s __TEXT __entitlements <path>
                plist = try slice.simulatedEntitlements()

                func validateDEREntitlements() async throws {
                    let derBytes = try slice.simulatedDEREntitlements()
                    if let plist {
                        let bytes = try #require(derBytes, "Expected both DER and plist entitlements but only plist entitlements were present.")
                        #expect(bytes.count > 0)

                        let osv = try ProcessInfo.processInfo.productBuildVersion()
                        switch (osv.major, osv.train) {
                        case (...20, _), (21, ..."E"):
                            return
                        case (21, "F") where osv.build < 52:
                            return
                        case (22, "A") where osv.build < 234:
                            return
                        default:
                            break
                        }

                        let derPlist: PropertyListItem = try await withTemporaryDirectory { path in
                            try localFS.write(path.join("in.der"), contents: ByteString(bytes))
                            try await runProcess(["/usr/bin/derq", "query", "-i", path.join("in.der").str, "-o", path.join("out.xml").str, "--xml"])
                            return try PropertyList.fromPath(path.join("out.xml"), fs: localFS)
                        }
                        #expect(plist == derPlist, "Expected both DER and plist entitlements to be equivalent")
                    } else {
                        #expect(derBytes == nil, "Expected both DER and plist entitlements but only DER entitlements were present.")
                    }
                }

                try await validateDEREntitlements()
            }

            guard plist != nil else {
                return try block(slice, nil)
            }

            guard case let .plDict(dict) = plist else {
                throw StubError.error("Entitlements property list must have a dictionary as its top-level item (in architecture: \(slice.arch)).")
            }

            return try block(slice, dict)
        }

        for slice in try MachO(data: fs.read(binaryPath)).slices() {
            try await processSlice(slice)
        }
    }
}

fileprivate extension SwiftBuildMessage.DiagnosticInfo.Kind {
    var behavior: Diagnostic.Behavior {
        switch self {
        case .error:
            return .error
        case .note:
            return .note
        case .warning:
            return .warning
        case .remark:
            return .remark
        #if !SWIFT_PACKAGE
        @unknown default:
            preconditionFailure("Unknown Behavior value")
        #endif
        }
    }
}

extension Array where Element == SwiftBuildMessage {
    package var reportBuildDescriptionMessage: SwiftBuildMessage.ReportBuildDescriptionInfo? {
        compactMap { event in
            switch event {
            case let .reportBuildDescription(message):
                return message
            default:
                return nil
            }
        }.only
    }

    package var taskStartedMessages: [SwiftBuildMessage.TaskStartedInfo] {
        compactMap { event in
            switch event {
            case let .taskStarted(message):
                return message
            default:
                return nil
            }
        }
    }

    package func allOutput() -> OutputByteStream {
        let consoleOutput = OutputByteStream()
        for event in self {
            switch event {
            case let .output(message):
                if let output = _filterDiagnostic(message: String(decoding: message.data, as: UTF8.self)) {
                    consoleOutput <<< output
                }
            default:
                break
            }
        }
        return consoleOutput
    }
}

extension CoreBasedTests {
    package func withTester(_ testWorkspace: TestWorkspace, _ testSession: TestSWBSession? = nil, sendPIF: Bool = true, fs: any FSProxy = localFS, userPreferences: UserPreferences? = nil, _ body: (CoreQualificationTester) async throws -> Void) async throws {
        try await withAsyncDeferrable { deferrable in
            let session: TestSWBSession
            if let testSession {
                session = testSession
            } else {
                let temporaryDirectory = try NamedTemporaryDirectory()
                await deferrable.addBlock {
                    do {
                        try temporaryDirectory.remove()
                    } catch {
                        Issue.record(error)
                    }
                }

                session = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    do {
                        try await session.close()
                    } catch {
                        Issue.record(error)
                    }
                }
            }
            let tester = try await CoreQualificationTester(testWorkspace, session, sendPIF: sendPIF, fs: fs)
            if let userPreferences {
                try await session.session.setUserPreferences(userPreferences)
            }
            await deferrable.addBlock {
                do {
                    try await tester.invalidate()
                } catch {
                    Issue.record(error)
                }
            }
            try await body(tester)
        }
    }

    package func withTester(_ testProject: TestProject, _ testSession: TestSWBSession? = nil, sendPIF: Bool = true, fs: any FSProxy = localFS, userPreferences: UserPreferences? = nil, _ body: (CoreQualificationTester) async throws -> Void) async throws {
        try await withAsyncDeferrable { deferrable in
            let session: TestSWBSession
            if let testSession {
                session = testSession
            } else {
                let temporaryDirectory = try NamedTemporaryDirectory()
                await deferrable.addBlock {
                    do {
                        try temporaryDirectory.remove()
                    } catch {
                        Issue.record(error)
                    }
                }

                session = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    do {
                        try await session.close()
                    } catch {
                        Issue.record(error)
                    }
                }
            }
            let tester = try await CoreQualificationTester(testProject, session, sendPIF: sendPIF, fs: fs)
            if let userPreferences {
                try await session.session.setUserPreferences(userPreferences)
            }
            await deferrable.addBlock {
                do {
                    try await tester.invalidate()
                } catch {
                    Issue.record(error)
                }
            }
            try await body(tester)
        }
    }
}

extension CoreBasedTests {
    package func XCTAssertLastBuildEvent(_ events: [SwiftBuildMessage]) {
        switch events.last {
        case .buildCompleted:
            break
        default:
            Issue.record("received event after 'build done' event")
        }
    }
}
