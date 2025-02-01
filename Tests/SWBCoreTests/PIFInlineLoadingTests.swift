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
import SWBTestSupport
import SWBUtil

@_spi(Testing) import SWBCore

// MARK: - Test cases for eliminating inline top-level object references in PIF (rdar://28005666)

@Suite fileprivate struct PIFInlineLoadingTests {
    @Test func loadingInlineWorkspaceReference() {
        let testInlineWorkspacePIF: PropertyListItem = [
            "guid": "some-workspace-guid",
            "name": "aWorkspace",
            "path": "/tmp/aWorkspace.xcworkspace/contents.xcworkspacedata",
            "projects": [] as [String]
        ]

        let pifLoader = PIFLoader(data: testInlineWorkspacePIF, namespace: BuiltinMacros.namespace)
        #expect(throws: (any Error).self) { try pifLoader.load(workspaceSignature: "WORKSPACE") }
    }

    @Test func loadingInlineProjectReference() {
        let testProjectPIF: PropertyListItem = [
            "guid": "some-project-guid",
            "path": "/tmp/SomeProject/aProject.xcodeproj",
            "projectDirectory": "/tmp/SomeOtherPlace",
            "targets": [] as [String],
            "groupTree": [
                "guid": "some-fileGroup-guid",
                "type": "group",
                "name": "SomeFiles",
                "sourceTree": "PROJECT_DIR",
                "path": "/tmp/SomeProject/SomeFiles"
            ],
            "buildConfigurations": [] as [String],
            "defaultConfigurationName": "Debug",
            "developmentRegion": "English"
        ]

        let testWorkspacePIF: [String: PropertyListItem] = [
            "guid": "some-workspace-guid",
            "name": "aWorkspace",
            "path": "/tmp/aWorkspace.xcworkspace/contents.xcworkspacedata",
            "projects": [testProjectPIF] // Inline *project* reference.
        ]

        // Convert the test data into a property list, then read the workspace from it.
        let pifLoader = PIFLoader(data: [], namespace: BuiltinMacros.namespace)
        #expect(throws: (any Error).self) { try Workspace(fromDictionary: testWorkspacePIF, signature: "mock", withPIFLoader: pifLoader) }
    }

    @Test func loadingInlineTargetReference() throws {
        let testWorkspacePIF: PropertyListItem = [
            "guid": "some-workspace-guid",
            "name": "aWorkspace",
            "path": "/tmp/aWorkspace.xcworkspace/contents.xcworkspacedata",
            "projects": ["PROJECT"]
        ]

        let testTargetPIF: PropertyListItem = [
            "guid": "some-target-guid",
            "name": "aTarget",
            "type": "standard",
            "productTypeIdentifier": "com.apple.product-type.application",
            "productReference": [
                "guid": "some-app",
                "name": "MyApp.app",
            ],
            "buildPhases": [] as [String],
            "buildRules": [] as [String],
            "buildConfigurations": [] as [String],
            "dependencies": [] as [String]
        ]

        let testProjectPIF: PropertyListItem = [
            "guid": "some-project-guid",
            "path": "/tmp/SomeProject/aProject.xcodeproj",
            "targets": [testTargetPIF], // Inline *target* reference.
            "groupTree": [
                "guid": "some-fileGroup-guid",
                "type": "group",
                "name": "SomeFiles",
                "sourceTree": "PROJECT_DIR",
                "path": "/tmp/SomeProject/SomeFiles",
            ],
            "buildConfigurations": [] as [String],
            "defaultConfigurationName": "Debug",
            "developmentRegion": "English"
        ]

        let testPIF: PropertyListItem = [
            [
                "signature": "WORKSPACE",
                "type": "workspace",
                "contents": testWorkspacePIF
            ],
            [
                "signature": "PROJECT",
                "type": "project",
                "contents": testProjectPIF
            ]
        ]

        let pifLoader = PIFLoader(data: testPIF, namespace: BuiltinMacros.namespace)
        #expect(throws: (any Error).self) { try pifLoader.load(workspaceSignature: "WORKSPACE") }
    }
}
