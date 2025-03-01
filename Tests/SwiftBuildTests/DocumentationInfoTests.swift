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
import SWBProtocol
import SWBTestSupport
@_spi(Testing) import SWBUtil
import SWBCore

@Suite(.requireHostOS(.macOS))
fileprivate struct DocumentationInfoTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS), .userDefaults(["EnablePluginManagerLogging": "0"]), arguments: [true, false])
    func documentationInfo(runDocumentationCompiler: Bool) async throws {
        try await withTemporaryDirectory { tmpDir in
            try await withAsyncDeferrable { deferrable in
                let tmpDirPath = tmpDir.str

                // Establish a connection to the build service.
                let service = try await SWBBuildService()
                await deferrable.addBlock {
                    await service.close()
                }

                // Check there are no sessions.
                #expect(try await service.listSessions() == [:])

                // Create a session.
                let (result, diagnostics) = await service.createSession(name: "FOO", cachePath: nil)
                #expect(diagnostics.isEmpty)
                let session = try result.get()
                #expect(try await service.listSessions() == ["S0": "FOO"])
                #expect(session.name == "FOO")
                #expect(session.uid == "S0")

                // Send a PIF (required to establish a workspace context).
                //
                // FIXME: Move this test data elsewhere.
                let projectDir = "\(tmpDirPath)/SomeProject"
                let projectFilesDir = "\(projectDir)/SomeFiles"
                let workspacePIF: SWBPropertyListItem = [
                    "guid":     "some-workspace-guid",
                    "name":     "aWorkspace",
                    "path":     .plString("\(tmpDirPath)/aWorkspace.xcworkspace/contents.xcworkspacedata"),
                    "projects": ["P1"]
                ]
                let projectPIF: SWBPropertyListItem = [
                    "guid": "P1",
                    "path": .plString("\(projectDir)/aProject.xcodeproj"),
                    "groupTree": [
                        "guid": "G1",
                        "type": "group",
                        "name": "SomeFiles",
                        "sourceTree": "PROJECT_DIR",
                        "path": .plString(projectFilesDir),
                        "children": [
                            [
                                "guid": "source-file-fileReference-guid",
                                "type": "file",
                                "sourceTree": "<group>",
                                "path": "Source.swift",
                                "fileType": "sourcecode.c.c"
                            ],
                            [
                                "guid": "doc-bundle-fileReference-guid",
                                "type": "file",
                                "sourceTree": "<group>",
                                "path": "DocBundle.docc",
                                "fileType": "folder.documentationcatalog"
                            ]
                        ]
                    ],
                    "buildConfigurations": [
                        [
                            "guid": "BC1",
                            "name": "Config1",
                            "buildSettings": [
                                "PRODUCT_NAME": "some-product-name",
                                "PRODUCT_BUNDLE_IDENTIFIER": "some-bundle-identifier",
                                "RUN_DOCUMENTATION_COMPILER": runDocumentationCompiler ? "YES" : "NO"
                            ]
                        ]
                    ],
                    "defaultConfigurationName": "Config1",
                    "developmentRegion": "English",
                    "targets": ["T1"]
                ]
                let targetPIF: SWBPropertyListItem = [
                    "guid": "T1",
                    "name": "Target1",
                    "type": "standard",
                    "productTypeIdentifier": "com.apple.product-type.framework",
                    "productReference": [
                        "guid": "PR1",
                        "name": "Target1",
                    ],
                    "buildPhases": [
                        [
                            "guid": "BP1",
                            "type": "com.apple.buildphase.sources",
                            "buildFiles": [
                                [
                                    "guid": "BF2",
                                    "name": "Source.swift",
                                    "fileReference": "source-file-fileReference-guid",
                                ],
                                [
                                    "guid": "BF3",
                                    "name": "DocBundle.docc",
                                    "fileReference": "doc-bundle-fileReference-guid",
                                ]
                            ]
                        ]
                    ],
                    "buildConfigurations": [
                        [
                            "guid": "C2",
                            "name": "Config1",
                            "buildSettings": [:]
                        ]
                    ],
                    "buildRules": [],
                    "dependencies": []
                ]
                let PIF: SWBPropertyListItem = [
                    [
                        "type": "workspace",
                        "signature": "W1",
                        "contents": workspacePIF
                    ],
                    [
                        "type": "project",
                        "signature": "P1",
                        "contents": projectPIF
                    ],
                    [
                        "type": "target",
                        "signature": "T1",
                        "contents": targetPIF
                    ]
                ]

                try await session.sendPIF(PIF)

                // Verify we can send the system and user info.
                try await session.setSystemInfo(.defaultForTesting)
                try await session.setUserInfo(.defaultForTesting)

                // Create a build request for which to ask for indexing information.
                var request = SWBBuildRequest()
                request.parameters = SWBBuildParameters()
                request.parameters.action = "build"
                request.parameters.configurationName = "Debug"
                request.parameters.activeRunDestination = .macOS
                request.add(target: SWBConfiguredTarget(guid: "T1"))

                // Collect indexing information, and wait for it.
                do {
                    let info = try await session.generateDocumentationInfo(for: request, delegate: EmptyBuildOperationDelegate())
                    #expect(info.builtDocumentationBundles.count == (runDocumentationCompiler ? 1 : 0))
                    if runDocumentationCompiler {
                        guard let result = info.builtDocumentationBundles.only else {
                            Issue.record("no documentation info found")
                            return
                        }

                        let targetBuildDir = "\(projectDir)/build/Config1"
                        let expectedPath = "\(targetBuildDir)/some-product-name.doccarchive"

                        #expect(result.outputPath == expectedPath)
                    }
                }

                // We’re done with the session.
                try await session.close()

                // Verify there are no sessions remaining.
                #expect(try await service.listSessions() == [:])
            }
        }
    }
}
