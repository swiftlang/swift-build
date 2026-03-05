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
#if !os(iOS)
import Foundation
import Testing
@_spi(Testing) import SwiftBuild
import SwiftBuildTestSupport
import SWBBuildService
import SWBCore
import SWBUtil
import SWBTestSupport
import SWBProtocol
import BuildServerProtocol
import LanguageServerProtocol
import LanguageServerProtocolTransport
import Synchronization
import SKLogging

final fileprivate class CollectingMessageHandler: MessageHandler {

    let notifications: SWBMutex<[any NotificationType]> = .init([])

    func handle(_ notification: some NotificationType) {
        notifications.withLock {
            $0.append(notification)
        }
    }

    func handle<Request>(_ request: Request, id: RequestID, reply: @escaping @Sendable (LSPResult<Request.Response>) -> Void) where Request : RequestType {}
}

extension Connection {
    fileprivate func send<Request: RequestType>(_ request: Request) async throws -> Request.Response {
        return try await withCheckedThrowingContinuation { continuation in
            _ = send(request, reply: { response in
                switch response {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            })
        }
    }
}

fileprivate func withBuildServerConnection(setup: (Path) async throws -> (TestWorkspace, SWBBuildRequest), body: (any Connection, CollectingMessageHandler, Path) async throws -> Void) async throws {
    try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
        try await withAsyncDeferrable { deferrable in
            let tmpDir = temporaryDirectory.path
            let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
            await deferrable.addBlock {
                await #expect(throws: Never.self) {
                    try await testSession.close()
                }
            }

            let (workspace, request) = try await setup(tmpDir)
            try await testSession.sendPIF(workspace)

            let connectionToServer = LocalConnection(receiverName: "server")
            let connectionToClient = LocalConnection(receiverName: "client")
            let buildServer = SWBBuildServer(session: testSession.session, buildRequest: request, connectionToClient: connectionToClient, exitHandler: { _ in })
            let collectingMessageHandler = CollectingMessageHandler()

            connectionToServer.start(handler: buildServer)
            connectionToClient.start(handler: collectingMessageHandler)
            _ = try await connectionToServer.send(
                InitializeBuildRequest(
                    displayName: "test-bsp-client",
                    version: "1.0.0",
                    bspVersion: "2.2.0",
                    rootUri: URI(URL(filePath: tmpDir.str)),
                    capabilities: .init(languageIds: [.swift, .c, .objective_c, .cpp, .objective_cpp])
                )
            )
            connectionToServer.send(OnBuildInitializedNotification())
            _ = try await connectionToServer.send(WorkspaceWaitForBuildSystemUpdatesRequest())

            try await body(connectionToServer, collectingMessageHandler, tmpDir)

            _ = try await connectionToServer.send(BuildShutdownRequest())
            connectionToServer.send(OnBuildExitNotification())
            connectionToServer.close()
        }
    }
}

@Suite
fileprivate struct BuildServerTests: CoreBasedTests {
    init() {
        LoggingScope.configureDefaultLoggingSubsystem("org.swift.swift-build-tests")
    }

    @Test(.requireSDKs(.host))
    func workspaceTargets() async throws {
        try await withBuildServerConnection(setup: { tmpDir in
            let testWorkspace = TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        defaultConfigurationName: "Debug",
                        groupTree: TestGroup(
                            "Foo",
                            children: [
                                TestFile("a.swift"),
                                TestFile("b.swift"),
                                TestFile("c.swift")
                            ]
                        ),
                        targets: [
                            TestStandardTarget(
                                "Target",
                                type: .dynamicLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [:])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "a.swift"
                                    ])
                                ]
                            ),
                            TestStandardTarget(
                                "Target2",
                                type: .dynamicLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "BUILD_SERVER_PROTOCOL_TARGET_TAGS": "dependency"
                                    ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "b.swift"
                                    ])
                                ]
                            ),
                            TestStandardTarget(
                                "Tests",
                                type: .unitTest,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "BUILD_SERVER_PROTOCOL_TARGET_TAGS": "test"
                                    ])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "c.swift"
                                    ])
                                ],
                                dependencies: [
                                    "Target",
                                    "Target2"
                                ]
                            )
                        ]
                    )
                ])

            var request = SWBBuildRequest()
            request.parameters = SWBBuildParameters()
            request.parameters.action = "build"
            request.parameters.configurationName = "Debug"
            for target in testWorkspace.projects.flatMap({ $0.targets }) {
                request.add(target: SWBConfiguredTarget(guid: target.guid))
            }

            return (testWorkspace, request)
        }) { connection, handler, _ in
            #expect(handler.notifications.withLock { notifications in
                notifications.contains { notification in
                    notification is OnBuildTargetDidChangeNotification
                }
            })
            let targetsResponse = try await connection.send(WorkspaceBuildTargetsRequest())
            let firstLibrary = try #require(targetsResponse.targets.filter { $0.displayName == "Target" }.only)
            let secondLibrary = try #require(targetsResponse.targets.filter { $0.displayName == "Target2" }.only)
            let tests = try #require(targetsResponse.targets.filter { $0.displayName == "Tests" }.only)

            #expect(firstLibrary.dependencies == [])
            #expect(secondLibrary.dependencies == [])
            #expect(Set(tests.dependencies) == Set([firstLibrary.id, secondLibrary.id]))

            #expect(firstLibrary.tags == [])
            #expect(secondLibrary.tags == [.dependency])
            #expect(Set(tests.tags) == Set([.test]))
        }
    }

    @Test(.requireSDKs(.host))
    func targetSources() async throws {
        try await withBuildServerConnection(setup: { tmpDir in
            let testWorkspace = TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        defaultConfigurationName: "Debug",
                        groupTree: TestGroup(
                            "Foo",
                            children: [
                                TestFile("a.swift"),
                                TestFile("b.c"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Target",
                                type: .dynamicLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [:])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "a.swift",
                                        "b.c"
                                    ])
                                ]
                            ),
                        ]
                    )
                ])

            var request = SWBBuildRequest()
            request.parameters = SWBBuildParameters()
            request.parameters.action = "build"
            request.parameters.configurationName = "Debug"
            for target in testWorkspace.projects.flatMap({ $0.targets }) {
                request.add(target: SWBConfiguredTarget(guid: target.guid))
            }
            request.parameters.activeRunDestination = .host

            return (testWorkspace, request)
        }) { connection, _, tmpDir in
            let targetsResponse = try await connection.send(WorkspaceBuildTargetsRequest())
            let target = try #require(targetsResponse.targets.only)
            let sourcesResponse = try await connection.send(BuildTargetSourcesRequest(targets: [target.id]))

            do {
                let sourceA = try #require(sourcesResponse.items.only?.sources.filter { $0.uri.fileURL?.lastPathComponent == "a.swift" }.only)
                #expect(sourceA.uri == DocumentURI(URL(filePath: tmpDir.join("Test/aProject/a.swift").str)))
                #expect(sourceA.kind == .file)
                #expect(!sourceA.generated)
                #expect(sourceA.dataKind == .sourceKit)
                let data = try #require(SourceKitSourceItemData(fromLSPAny: sourceA.data))
                #expect(data.language == .swift)
                #expect(data.outputPath?.hasSuffix("a.o") == true)
            }

            do {
                let sourceB = try #require(sourcesResponse.items.only?.sources.filter { $0.uri.fileURL?.lastPathComponent == "b.c" }.only)
                #expect(sourceB.uri == DocumentURI(URL(filePath: tmpDir.join("Test/aProject/b.c").str)))
                #expect(sourceB.kind == .file)
                #expect(!sourceB.generated)
                #expect(sourceB.dataKind == .sourceKit)
                let data = try #require(SourceKitSourceItemData(fromLSPAny: sourceB.data))
                #expect(data.language == .c)
                #expect(data.outputPath?.hasSuffix("b.o") == true)
            }
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows))
    func basicPreparationAndCompilerArgs() async throws {
        try await withBuildServerConnection(setup: { tmpDir in
            let testWorkspace = TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        defaultConfigurationName: "Debug",
                        groupTree: TestGroup(
                            "Foo",
                            children: [
                                TestFile("a.swift"),
                                TestFile("b.swift"),
                            ]
                        ),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "CODE_SIGNING_ALLOWED": "NO",
                                "SWIFT_VERSION": "5.0",
                            ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "Target",
                                type: .dynamicLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [:])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "b.swift",
                                    ])
                                ]
                            ),
                            TestStandardTarget(
                                "Target2",
                                type: .dynamicLibrary,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [:])
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "a.swift",
                                    ])
                                ],
                                dependencies: ["Target"]
                            ),
                        ]
                    )
                ])

            var request = SWBBuildRequest()
            request.parameters = SWBBuildParameters()
            request.parameters.action = "build"
            request.parameters.configurationName = "Debug"
            for target in testWorkspace.projects.flatMap({ $0.targets }) {
                request.add(target: SWBConfiguredTarget(guid: target.guid))
            }
            request.parameters.activeRunDestination = .host

            try localFS.createDirectory(tmpDir.join("Test/aProject"), recursive: true)
            try localFS.write(tmpDir.join("Test/aProject/b.swift"), contents: "public let x = 42")
            try localFS.write(tmpDir.join("Test/aProject/a.swift"), contents: """
                import Target
                public func foo() {
                    print(x)
                }
            """)

            return (testWorkspace, request)
        }) { connection, collector, tmpDir in
            let targetsResponse = try await connection.send(WorkspaceBuildTargetsRequest())
            let target = try #require(targetsResponse.targets.filter { $0.displayName == "Target2" }.only)
            let sourcesResponse = try await connection.send(BuildTargetSourcesRequest(targets: [target.id]))
            let sourceA = try #require(sourcesResponse.items.only?.sources.filter { $0.uri.fileURL?.lastPathComponent == "a.swift" }.only)
            // Prepare, request compiler args for a source file, and then ensure those args work.
            _ = try await connection.send(BuildTargetPrepareRequest(targets: [target.id]))
            let logs = collector.notifications.withLock { notifications in
                notifications.compactMap { notification in
                    (notification as? OnBuildLogMessageNotification)?.message
                }
            }
            #expect(logs.contains("Build Complete"))
            let optionsResponse = try #require(try await connection.send(TextDocumentSourceKitOptionsRequest(textDocument: .init(sourceA.uri), target: target.id, language: .swift)))
            try await runProcess([swiftCompilerPath.str] + optionsResponse.compilerArguments + ["-typecheck"], workingDirectory: optionsResponse.workingDirectory.map { Path($0) })
        }
    }

    @Test(.requireSDKs(.host))
    func pifUpdate() async throws {
        try await withTemporaryDirectory { (temporaryDirectory: NamedTemporaryDirectory) in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let workspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: tmpDir.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            defaultConfigurationName: "Debug",
                            groupTree: TestGroup(
                                "Foo",
                                children: [
                                    TestFile("a.swift"),
                                ]
                            ),
                            targets: [
                                TestStandardTarget(
                                    "Target",
                                    guid: "TargetGUID",
                                    type: .dynamicLibrary,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [:])
                                    ],
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "a.swift"
                                        ])
                                    ]
                                ),
                            ]
                        )
                    ])
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                for target in workspace.projects.flatMap({ $0.targets }) {
                    request.add(target: SWBConfiguredTarget(guid: target.guid))
                }
                try await testSession.sendPIF(workspace)

                let connectionToServer = LocalConnection(receiverName: "server")
                let connectionToClient = LocalConnection(receiverName: "client")
                let buildServer = SWBBuildServer(session: testSession.session, buildRequest: request, connectionToClient: connectionToClient, exitHandler: { _ in })
                let collectingMessageHandler = CollectingMessageHandler()

                connectionToServer.start(handler: buildServer)
                connectionToClient.start(handler: collectingMessageHandler)
                _ = try await connectionToServer.send(
                    InitializeBuildRequest(
                        displayName: "test-bsp-client",
                        version: "1.0.0",
                        bspVersion: "2.2.0",
                        rootUri: URI(URL(filePath: tmpDir.str)),
                        capabilities: .init(languageIds: [.swift, .c, .objective_c, .cpp, .objective_cpp])
                    )
                )
                connectionToServer.send(OnBuildInitializedNotification())
                _ = try await connectionToServer.send(WorkspaceWaitForBuildSystemUpdatesRequest())

                let targetsResponse = try await connectionToServer.send(WorkspaceBuildTargetsRequest())
                #expect(targetsResponse.targets.map(\.displayName).sorted() == ["Target"])

                let updatedWorkspace = TestWorkspace(
                    "aWorkspace",
                    sourceRoot: tmpDir.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            defaultConfigurationName: "Debug",
                            groupTree: TestGroup(
                                "Foo",
                                children: [
                                    TestFile("a.swift"),
                                    TestFile("b.swift"),
                                ]
                            ),
                            targets: [
                                TestStandardTarget(
                                    "Target2",
                                    guid: "Target2GUID",
                                    type: .dynamicLibrary,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [:])
                                    ],
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "b.swift"
                                        ])
                                    ]
                                ),
                                TestStandardTarget(
                                    "Target",
                                    guid: "TargetGUID",
                                    type: .dynamicLibrary,
                                    buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [:])
                                    ],
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "a.swift"
                                        ])
                                    ],
                                    dependencies: ["Target2"]
                                ),
                            ]
                        )
                    ])
                try await testSession.sendPIF(updatedWorkspace)
                connectionToServer.send(OnWatchedFilesDidChangeNotification(changes: [
                    .init(uri: SWBBuildServer.sessionPIFURI, type: .changed)
                ]))
                _ = try await connectionToServer.send(WorkspaceWaitForBuildSystemUpdatesRequest())

                let updatedTargetsResponse = try await connectionToServer.send(WorkspaceBuildTargetsRequest())
                #expect(updatedTargetsResponse.targets.map(\.displayName).sorted() == ["Target", "Target2"])

                _ = try await connectionToServer.send(BuildShutdownRequest())
                connectionToServer.send(OnBuildExitNotification())
                connectionToServer.close()
            }
        }
    }
}
#endif
