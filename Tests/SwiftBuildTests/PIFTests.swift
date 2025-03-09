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
import SwiftBuild
import SwiftBuildTestSupport

import SWBTestSupport
@_spi(Testing) import SWBUtil

@Suite(.requireHostOS(.macOS))
fileprivate struct PIFTests {
    /// Test some behaviors of sending incremental PIF files.
    @Test
    func sendPIFIncrementally() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                // Send a bad PIF.
                let lookups = LockedValue<[(SwiftBuildServicePIFObjectType, String)]>([])
                @Sendable func lookup(_ type: SwiftBuildServicePIFObjectType, _ signature: String) async throws -> SWBPropertyListItem {
                    lookups.withLock { $0.append((type, signature)) }
                    return .plArray([])
                }

                // We should get an error and one lookup.
                await #expect(performing: {
                    try await testSession.session.sendPIF(workspaceSignature: "FOOBAR", lookupObject: lookup)
                }, throws: { error in
                    // TODO: Check specifically for `PIFLoadingError.invalidObject`, but we lose the type information over the wire
                    (error as? SwiftBuildError)?.errorDescription?.contains("PIF object must be a dictionary") == true
                })
                #expect(lookups.withLock(\.count) == 1)

                // Perform the request again, it should do the lookup again.
                lookups.withLock { $0.removeAll() }
                await #expect(performing: {
                    try await testSession.session.sendPIF(workspaceSignature: "FOOBAR", lookupObject: lookup)
                }, throws: { error in
                    // TODO: Check specifically for `PIFLoadingError.invalidObject`, but we lose the type information over the wire
                    (error as? SwiftBuildError)?.errorDescription?.contains("PIF object must be a dictionary") == true
                })
                #expect(lookups.withLock(\.count) == 1)
            }
        }
    }

    @Test
    func sendPIFIncrementallyWithAuditing() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let workspace = TestWorkspace(
                    "testWorkspace",
                    sourceRoot: temporaryDirectory.path,
                    projects: [
                        TestProject("aProject",
                                    groupTree: TestGroup("foo"),
                                    targets: [TestStandardTarget("aTarget", type: .application)])
                    ])

                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let result = try await testSession.sendPIFIncrementally(workspace, auditWorkspace: workspace)
                #expect(!result.isEmpty)
            }
        }
    }

    @Test
    func sendPIFIncrementallyWithAuditingFailure() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = temporaryDirectory.path
                let workspace = TestWorkspace(
                    "testWorkspace",
                    sourceRoot: tmpDirPath,
                    projects: [])

                let auditWorkspace = TestWorkspace(
                    "testWorkspace",
                    sourceRoot: temporaryDirectory.path,
                    projects: [
                        TestProject("aProject",
                                    groupTree: TestGroup("foo"),
                                    targets: [TestStandardTarget("aTarget", type: .application)])
                    ])

                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                await #expect(throws: (any Error).self) {
                    try await testSession.sendPIFIncrementally(workspace, auditWorkspace: auditWorkspace)
                }
            }
        }
    }

    /// Tests that incremental PIF transfer with auditing fails correctly when there is a corrupt PIF.
    @Test
    func sendCorruptPIFIncrementallyWithAuditing() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let signature = "abc"
                let workspace = [[
                    "signature": .plString(signature),
                    "type": "workspace",
                    "contents": [:]
                ]] as SWBPropertyListItem

                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                await #expect(performing: {
                    try await testSession.session.sendPIF(workspaceSignature: signature, auditPIF: workspace, lookupObject: { (objectType, signature) async throws -> SWBPropertyListItem in
                        return workspace
                    })
                }, throws: { error in
                    "\(error)".contains("Required key 'guid' is missing in Workspace dictionary")
                })

                // Ensure that we properly cancelled the PIF transfer when the error was encountered, and that we get the same error as before, instead of an error that a transfer operation is still in progress
                await #expect(performing: {
                    try await testSession.session.sendPIF(workspaceSignature: signature, auditPIF: workspace, lookupObject: { (objectType, signature) async throws -> SWBPropertyListItem in
                        return workspace
                    })
                }, throws: { error in
                    "\(error)".contains("Required key 'guid' is missing in Workspace dictionary")
                })
            }
        }
    }

    /// Tests that incremental PIF transfer fails correctly when there is a corrupt PIF, but with multiple objects so that we do at least one round of incremental transfer.
    @Test
    func sendCorruptPIFIncrementallyMultipleObjects() async throws {
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let workspaceSignature = "abc"
                let projectSignature = "proj"

                let workspace = [
                    "signature": .plString(workspaceSignature),
                    "type": "workspace",
                    "contents": [
                        "guid": "W1",
                        "name": "WS",
                        "path": "/foo/bar",
                        "projects": [
                            .plString(projectSignature)
                        ],
                    ]
                ] as SWBPropertyListItem

                let project = [
                    "signature": .plString(projectSignature),
                    "type": "project",
                    "contents": [
                        "guid": "P1",
                        "path": "/bar/baz",
                        "groupTree": [
                            "guid": "G1",
                            "name": "G",
                            "type": "group",
                        ],
                        "targets": [],
                        "buildConfigurations": [],
                    ]
                ] as SWBPropertyListItem

                @Sendable func lookup(_ objectType: SwiftBuildServicePIFObjectType, _ signature: String) async throws -> SWBPropertyListItem {
                    switch signature {
                    case workspaceSignature:
                        return workspace
                    case projectSignature:
                        return project
                    default:
                        throw StubError.error("missing object \(signature)")
                    }
                }

                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                await #expect(performing: {
                    try await testSession.session.sendPIF(workspaceSignature: workspaceSignature, auditPIF: nil, lookupObject: lookup)
                }, throws: { error in
                    "\(error)".contains("unable to load transferred PIF: Required key 'defaultConfigurationName' is missing in Project dictionary")
                })
            }
        }
    }

    typealias LookupObject = (@Sendable (SwiftBuildServicePIFObjectType, String) async throws -> SWBPropertyListItem)

    /// Check incremental PIF transfer.
    @Test(.userDefaults(["EnablePluginManagerLogging": "0"]))
    func sessionPIFLoading() async throws {
        let service = try await SWBBuildService()

        let workspacePIFObject: SWBPropertyListItem = [
            "type": "workspace",
            "signature": "WORKSPACE@v11_",
            "contents": [
                "guid":        "some-workspace-guid",
                "name":        "aWorkspace",
                "path":        "/tmp/aWorkspace.xcworkspace/contents.xcworkspacedata",
                "projects":    ["PROJECT-A@v11_", "PROJECT-B@v11_"]
            ]
        ]
        let projectAPIFObject: SWBPropertyListItem = [
            "type": "project",
            "signature": "PROJECT-A@v11_",
            "contents": [
                "guid": "A_P",
                "path": "/tmp/SomeProject/aProject.xcodeproj",
                "groupTree": [
                    "guid": "A_G1",
                    "type": "group",
                    "name": "SomeFiles",
                    "sourceTree": "PROJECT_DIR",
                    "path": "/tmp/SomeProject/SomeFiles",
                ],
                "buildConfigurations": [[
                    "guid": "A_BC1",
                    "name": "Config1",
                    "buildSettings": [:]
                ]],
                "defaultConfigurationName": "Config1",
                "developmentRegion": "English",
                "targets": [],
            ]
        ]
        let projectBPIFObject: SWBPropertyListItem = [
            "type": "project",
            "signature": "PROJECT-B@v11_",
            "contents": [
                "guid": "B_P",
                "path": "/tmp/SomeProject/aProject.xcodeproj",
                "groupTree": [
                    "guid": "B_G1",
                    "type": "group",
                    "name": "SomeFiles",
                    "sourceTree": "PROJECT_DIR",
                    "path": "/tmp/SomeProject/SomeFiles",
                ],
                "buildConfigurations": [[
                    "guid": "B_BC1",
                    "name": "Config1",
                    "buildSettings": [:]
                ]],
                "defaultConfigurationName": "Config1",
                "developmentRegion": "English",
                "targets": [],
            ]
        ]

        // Send the initial PIF.
        let lookups = LockedValue<[String]>([])
        let lookupObject: LookupObject = { @Sendable (type, signature) async throws in
            lookups.withLock {
                $0.append(signature)
            }
            switch type {
            case .workspace:
                #expect(signature == "WORKSPACE@v11_")
                return workspacePIFObject
            case .project:
                if signature == "PROJECT-A@v11_" {
                    return projectAPIFObject
                }
                if signature == "PROJECT-B@v11_" {
                    return projectBPIFObject
                }
                Issue.record("unexpected lookup request")
            default:
                Issue.record("unexpected lookup request")
            }
            throw StubError.error("unexpected lookup request")
        }
        let (result, diagnostics) = await service.createSession(name: "MOCK", cachePath: nil)
        #expect(diagnostics.isEmpty)
        let session = try result.get()
        try await session.sendPIF(workspaceSignature: "WORKSPACE@v11_", lookupObject: lookupObject)
        #expect(lookups.withLock { $0.sorted() } == ["PROJECT-A@v11_", "PROJECT-B@v11_", "WORKSPACE@v11_"])
        lookups.withLock { $0.removeAll() }

        // Send again, with no change.
        try await session.sendPIF(workspaceSignature: "WORKSPACE@v11_", lookupObject: lookupObject)
        #expect(lookups.withLock { $0 } == [])

        // Close the session.
        try await session.close()
        await service.close()
    }

    /// Check PIF incremental cache.
    @Test(.userDefaults(["EnablePluginManagerLogging": "0"]))
    func sessionPIFCache() async throws {
        try await withTemporaryDirectory { tmpDir in
            try await withAsyncDeferrable { deferrable in
                let workspacePIFObject: SWBPropertyListItem = [
                    "type": "workspace",
                    "signature": "WORKSPACE@v11_",
                    "contents": [
                        "guid":        "some-workspace-guid",
                        "name":        "aWorkspace",
                        "path":        "/tmp/aWorkspace.xcworkspace/contents.xcworkspacedata",
                        "projects":    []
                    ]
                ]

                let tmpDirPath = tmpDir.str

                let service = try await SWBBuildService()
                await deferrable.addBlock {
                    await service.close()
                }

                let lookups = LockedValue<[String]>([])
                let lookupObject: LookupObject = { (type, signature) async throws in
                    lookups.withLock { $0.append(signature) }
                    switch type {
                    case .workspace:
                        assert(signature == "WORKSPACE@v11_")
                        return workspacePIFObject
                    default:
                        Issue.record("unexpected lookup request")
                        throw StubError.error("unexpected lookup request")
                    }
                }

                // Send the initial PIF.
                do {
                    let (result, diagnostics) = await service.createSession(name: "MOCK", cachePath: tmpDirPath)
                    #expect(diagnostics.isEmpty)
                    let session = try result.get()
                    await deferrable.addBlock {
                        await #expect(throws: Never.self) {
                            try await session.close()
                        }
                    }

                    try await session.sendPIF(workspaceSignature: "WORKSPACE@v11_", lookupObject: lookupObject)
                    #expect(lookups.withLock { $0 } == ["WORKSPACE@v11_"])
                    lookups.withLock { $0.removeAll() }
                }

                // Create a new session, and check we don't have to resend the PIF.
                do {
                    let (result, diagnostics) = await service.createSession(name: "MOCK", cachePath: tmpDirPath)
                    #expect(diagnostics.isEmpty)
                    let session = try result.get()
                    await deferrable.addBlock {
                        await #expect(throws: Never.self) {
                            try await session.close()
                        }
                    }

                    try await session.sendPIF(workspaceSignature: "WORKSPACE@v11_", lookupObject: lookupObject)
                    #expect(lookups.withLock { $0 } == [])
                }
            }
        }
    }
}
