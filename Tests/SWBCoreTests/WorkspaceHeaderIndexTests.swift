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
import SWBTestSupport
@_spi(Testing) import SWBCore
import SWBMacro

@Suite fileprivate struct WorkspaceHeaderIndexTests: CoreBasedTests {
    @Test
    func basics() async throws {
        let core = try await getCore()

        // Test the basic build of an empty target.
        let testWorkspace = TestWorkspace(
            "Test",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup("Sources", children: [
                        TestFile("Foo.h"),
                        TestFile("FooPublic.h"),
                        TestFile("FooPrivate.h"),
                        TestFile("Not-Header.cpp"),
                        // Variant groups are not searched for headers.
                        TestVariantGroup("Variant-Group", children: [
                            TestFile("not-really-a-header.h")
                        ])
                    ]),
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    targets: [
                        TestStandardTarget(
                            "Fwk1", type: .framework,
                            buildPhases: [
                                TestHeadersBuildPhase([
                                    TestBuildFile("FooPublic.h", headerVisibility: .public),
                                    TestBuildFile("FooPrivate.h", headerVisibility: .private),
                                    "Foo.h",
                                    "Not-Header.cpp",
                                    "Variant-Group",
                                ])
                            ]),
                        // A target w/o a headers phase should be ignored.
                        TestStandardTarget(
                            "EmptyFwk", type: .framework,
                            buildPhases: [])
                    ])
            ])
        let workspace = try testWorkspace.load(core)

        let index = await WorkspaceHeaderIndex(core: core, workspace: workspace)

        // There should be one project entry.
        #expect(index.projectHeaderInfo.count == 1)
        guard let (project, projectInfo) = index.projectHeaderInfo.first else {
            Issue.record("missing project entry")
            return
        }

        // There should be one known header in the project.
        #expect(project.name == "aProject")
        #expect(projectInfo.knownHeaders.map({ $0.path.stringRep }).sorted() == ["Foo.h", "FooPrivate.h", "FooPublic.h"])

        // There should be one target entry in the project.
        #expect(projectInfo.targetHeaderInfo.count == 1)
        guard let (target, targetInfo) = projectInfo.targetHeaderInfo.first else {
            Issue.record("missing target entry")
            return
        }

        // There should be one project header entry in the target.
        #expect(target.name == "Fwk1")
        #expect(targetInfo.publicHeaders.map({ $0.fileReference.path.stringRep }).sorted() == ["FooPublic.h"])
        #expect(targetInfo.privateHeaders.map({ $0.fileReference.path.stringRep }).sorted() == ["FooPrivate.h"])
        #expect(targetInfo.projectHeaders.map({ $0.fileReference.path.stringRep }).sorted() == ["Foo.h"])
    }
}
