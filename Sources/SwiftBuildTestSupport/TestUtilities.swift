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

package import class Foundation.Bundle
package import struct Foundation.OperatingSystemVersion
package import struct Foundation.URL

import Testing

@_spi(Testing) package import SwiftBuild

package import class SWBCore.Core
package import struct SWBCore.UserPreferences
package import SWBTestSupport
package import SWBUtil

package enum TestSWBSessionError: Error {
    case unableToCreateSession(_ underlyingError: any Error, diagnostics: [SwiftBuildMessage.DiagnosticInfo])
    case unableToSendWorkspace(_ underlyingError: any Error)
    case pifTransferFailed(_ underlyingError: any Error)
}

/// Manages an `SWBBuildService` and `SWBBuildServiceSession` object which can be used to perform build operations.
package actor TestSWBSession {
    package nonisolated let tmpDir: NamedTemporaryDirectory
    package nonisolated let service: SWBBuildService
    package nonisolated let session: SWBBuildServiceSession
    package nonisolated let sessionDiagnostics: [SwiftBuildMessage.DiagnosticInfo]
    private var closed = false

    package init(connectionMode: SWBBuildServiceConnectionMode = .default, variant: SWBBuildServiceVariant = .default, temporaryDirectory: NamedTemporaryDirectory?) async throws {
        self.tmpDir = try temporaryDirectory ?? NamedTemporaryDirectory()
        // Construct the test session.
        self.service = try await SWBBuildService(connectionMode: connectionMode, variant: variant)
        let (result, sessionDiagnostics) = await service.createSession(name: #function, cachePath: tmpDir.path.str)
        self.sessionDiagnostics = sessionDiagnostics
        do {
            self.session = try result.get()
        } catch {
            await self.service.close()
            throw TestSWBSessionError.unableToCreateSession(error, diagnostics: sessionDiagnostics)
        }
    }

    deinit {
        if !closed {
            Issue.record("Session must be closed before being deallocated.")
        }
    }

    /// Closes the underlying session and service managed by this object.
    ///
    /// This method must be called before the object is deallocated.
    package nonisolated func close() async throws {
        let wasAlreadyClosed = await beginClose()
        if wasAlreadyClosed {
            return
        }

        // Capture the session closure in a Result so we can still close the service below before (potentially) throwing any error.
        let result = await Result.catching { try await session.close() }

        await service.close()

        _ = try result.get()
    }

    private func beginClose() -> Bool {
        if closed {
            return true
        }
        closed = true
        return false
    }

    /// Send a workspace to the session
    package func sendPIF(_ testWorkspace: TestWorkspace) async throws {
        // Send the workspace context.
        do {
            try await session.sendPIF(.init(testWorkspace.toObjects().propertyListItem))
        } catch {
            throw TestSWBSessionError.unableToSendWorkspace(error)
        }

        // Initialize mock session info.
        try await sendMockSessionInfo()
    }

    /// Send a workspace to the session, incrementally.
    ///
    /// - Returns: The signatures of all objects which were transferred.
    package func sendPIFIncrementally(_ testWorkspace: TestWorkspace, auditWorkspace: TestWorkspace? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> [String] {
        // Build a map of all the objects.
        let objects = LockedValue<[String: PropertyListItem]>([:])
        let pifObjects = try testWorkspace.toObjects()
        for object in pifObjects {
            guard let signature = object.dictValue?["signature"]?.stringValue else {
                throw StubError.error("Missing signature for PIF object")
            }
            objects.withLock { $0[signature] = object }
        }

        let auditPifObjects = try auditWorkspace?.toObjects()

        let transferredSignatures = LockedValue<[String]>([])
        do {
            // Send the workspace context.
            try await session.sendPIF(workspaceSignature: testWorkspace.signature, auditPIF: (auditPifObjects?.propertyListItem).map { try .init($0) }) { (objectType, signature) async throws -> SWBPropertyListItem in
                transferredSignatures.withLock { $0.append(signature) }
                guard let object = objects.withLock({ $0[signature] }) else {
                    throw StubError.error("unexpected incremental PIF request for \(signature)")
                }
                return try .init(object)
            }
        } catch {
            throw TestSWBSessionError.pifTransferFailed(error)
        }

        // Initialize mock session info.
        try await sendMockSessionInfo()

        return transferredSignatures.withLock { $0 }
    }

    private func sendMockSessionInfo() async throws {
        do {
            try await session.setUserPreferences(.defaultForTesting)
        } catch {
            throw TestSWBSessionError.unableToSendWorkspace(error)
        }

        do {
            try await session.setSystemInfo(.defaultForTesting)
        } catch {
            throw TestSWBSessionError.unableToSendWorkspace(error)
        }

        do {
            try await session.setUserInfo(.defaultForTesting)
        } catch {
            throw TestSWBSessionError.unableToSendWorkspace(error)
        }
    }

    /// Start a build operation and wait for it to complete, returning the event stream.
    @discardableResult package nonisolated func runBuildOperation(request: SWBBuildRequest, delegate: any SWBPlanningOperationDelegate) async throws -> [SwiftBuildMessage] {
        let operation = try await session.createBuildOperation(request: request, delegate: delegate)
        let events = try await operation.start()
        await operation.waitForCompletion()
        return await events.collect()
    }

    /// Start a build description creation operation and wait for it to complete, discarding the event stream.
    @discardableResult package nonisolated func runBuildDescriptionCreationOperation(request: SWBBuildRequest, delegate: any SWBPlanningOperationDelegate, checkNoErrors: Bool = true) async throws -> SwiftBuildMessage.ReportBuildDescriptionInfo {
        return try await runBuildDescriptionCreationOperation(request: request, delegate: delegate, checkNoErrors: checkNoErrors).1
    }

    /// Start a build description creation operation and wait for it to complete, discarding the event stream.
    @_disfavoredOverload @discardableResult package nonisolated func runBuildDescriptionCreationOperation(request: SWBBuildRequest, delegate: any SWBPlanningOperationDelegate, checkNoErrors: Bool = true) async throws -> ([SwiftBuildMessage], SwiftBuildMessage.ReportBuildDescriptionInfo) {
        let operation = try await session.createBuildOperationForBuildDescriptionOnly(request: request, delegate: delegate)
        let events = try await operation.start().collect()
        if checkNoErrors {
            for event in events {
                if case let .diagnostic(diagnostic) = event, diagnostic.kind == .error {
                    Issue.record(Comment(rawValue: LoggedDiagnostic(diagnostic).description))
                }
            }
        }
        await operation.waitForCompletion()
        guard let only = events.reportBuildDescriptionMessage else {
            throw StubError.error("Expected exactly one build description info event")
        }
        return (events, only)
    }
}

extension SWBBuildParameters {
    package init(action: String? = nil, configuration: String, activeRunDestination: SWBRunDestinationInfo? = nil, overrides: [String: String] = [:]) {
        self.init()
        if let action { self.action = action }
        self.configurationName = configuration
        self.activeRunDestination = activeRunDestination
        if !overrides.isEmpty {
            self.overrides.commandLine = SWBSettingsTable()
            for (key, value) in overrides {
                self.overrides.commandLine?.set(value: value, for: key)
            }
        }
    }
}

extension SWBRunDestinationInfo: _RunDestinationInfo {
}

extension SWBBuildService {
    /// Overload of `createSession` which supplies an inferior products path.
    package func createSession(name: String, developerPath: String? = nil, cachePath: String?) async -> (Result<SWBBuildServiceSession, any Error>, [SwiftBuildMessage.DiagnosticInfo]) {
        return await createSession(name: name, developerPath: developerPath, cachePath: cachePath, inferiorProductsPath: Core.inferiorProductsPath()?.str, environment: [:])
    }
}

extension SWBBuildServiceSession {
    package func setUserPreferences(_ userPreferences: UserPreferences) async throws {
        try await setUserPreferences(
            enableDebugActivityLogs: userPreferences.enableDebugActivityLogs,
            enableBuildDebugging: userPreferences.enableBuildDebugging,
            enableBuildSystemCaching: userPreferences.enableBuildSystemCaching,
            activityTextShorteningLevel: userPreferences.activityTextShorteningLevel.rawValue,
            usePerConfigurationBuildLocations: userPreferences.usePerConfigurationBuildLocations,
            allowsExternalToolExecution: userPreferences.allowsExternalToolExecution)
    }

    package func generateIndexingFileSettings(for request: SWBBuildRequest, targetID: String, delegate: any SWBIndexingDelegate) async throws -> SWBIndexingFileSettings {
        try await generateIndexingFileSettings(for: request, targetID: targetID, filePath: nil, outputPathOnly: false, delegate: delegate)
    }
}

extension SWBSystemInfo {
    package static let defaultForTesting = Self(
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 99, minorVersion: 99, patchVersion: 0),
        productBuildVersion: "99A1",
        nativeArchitecture: "x86_64")
}

extension SWBUserInfo {
    package static let defaultForTesting = {
        var env: [String: String] = [:]
        let homeDirectory: String
        #if os(Windows)
        homeDirectory = "C:\\Users\\exampleUser"
        env = ["PATH": "FOO;BAR;BAZ"]
        if let vcToolsInstallDir = getEnvironmentVariable("VCToolsInstallDir") {
            env["VCToolsInstallDir"] = vcToolsInstallDir
        }
        #else
        homeDirectory = "/Users/exampleUser"
        env = ["PATH": "FOO:BAR:BAZ"]
        #endif
        return Self(
            userName: "exampleUser",
            groupName: "exampleGroup",
            uid: 1234,
            gid: 5678,
            homeDirectory: homeDirectory,
            processEnvironment: env,
            buildSystemEnvironment: env)
    }()
}

extension URL {
    package static var swb_buildServicePluginsURL: URL? {
        let bundle = (SWBBuildServiceConnection.serviceExecutableURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()).map(Bundle.init(url:)) ?? nil
        return bundle?.builtInPlugInsURL
    }
}

// MARK: Copied from SWBPropertyList.swift because we can't expose methods which use implementation only types as SPI

extension SWBPropertyListItem {
    package init(_ propertyListItem: PropertyListItem) throws {
        switch propertyListItem {
        case let .plBool(value):
            self = .plBool(value)
        case let .plInt(value):
            self = .plInt(value)
        case let .plString(value):
            self = .plString(value)
        case let .plData(value):
            self = .plData(value)
        case let .plDate(value):
            self = .plDate(value)
        case let .plDouble(value):
            self = .plDouble(value)
        case let .plArray(value):
            self = try .plArray(value.map { try .init($0 ) })
        case let .plDict(value):
            self = try .plDict(value.mapValues { try .init($0) })
        case let .plOpaque(value):
            throw StubError.error("Invalid property list object: \(value)")
        }
    }

    package var propertyListItem: PropertyListItem {
        switch self {
        case let .plBool(value):
            return .plBool(value)
        case let .plInt(value):
            return .plInt(value)
        case let .plString(value):
            return .plString(value)
        case let .plData(value):
            return .plData(value)
        case let .plDate(value):
            return .plDate(value)
        case let .plDouble(value):
            return .plDouble(value)
        case let .plArray(value):
            return .plArray(value.map { $0.propertyListItem })
        case let .plDict(value):
            return .plDict(value.mapValues { $0.propertyListItem })
        @unknown default:
            preconditionFailure()
        }
    }
}
