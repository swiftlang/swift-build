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
import SWBCore

@Suite fileprivate struct WorkspaceDiffTests: CoreBasedTests {
    @Test
    func sameWorkspace() async throws {
        let workspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            groupTree: TestGroup("root"),
                            targets: [
                                TestStandardTarget("testTarget", type: .application)
                            ])
            ]).load(getCore())

        let diff = workspace.diff(against: workspace)

        #expect(!diff.hasChanges)
    }

    @Test
    func missingProject() async throws {
        let workspace = try await TestWorkspace(
            "testWorkspace",
            projects: []).load(getCore())

        let otherWorkspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            groupTree: TestGroup("root"),
                            targets: [
                                TestStandardTarget("testTarget", type: .application)
                            ])
            ]).load(getCore())

        let diff = workspace.diff(against: otherWorkspace)

        #expect(diff.hasChanges)
        #expect(1 == diff.rightProjects.count)
        #expect(0 == diff.leftProjects.count)
    }

    @Test
    func extraProject() async throws {
        let workspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            groupTree: TestGroup("root"),
                            targets: [
                                TestStandardTarget("testTarget", type: .application)
                            ])
            ]).load(getCore())

        let otherWorkspace = try await TestWorkspace(
            "testWorkspace",
            projects: []).load(getCore())

        let diff = workspace.diff(against: otherWorkspace)

        #expect(diff.hasChanges)
        #expect(0 == diff.rightProjects.count)
        #expect(1 == diff.leftProjects.count)
    }

    @Test
    func missingTarget() async throws {
        let workspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root"),
                            targets: [])
            ]).load(getCore())

        let otherWorkspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root"),
                            targets: [
                                TestStandardTarget("testTarget", type: .application)
                            ])
            ]).load(getCore())

        let diff = workspace.diff(against: otherWorkspace)

        #expect(diff.hasChanges)
        #expect(0 == diff.rightProjects.count)
        #expect(0 == diff.leftProjects.count)
        #expect(1 == diff.rightTargets.count)
        #expect(0 == diff.leftTargets.count)
    }

    @Test
    func extraTarget() async throws {
        let workspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root"),
                            targets: [
                                TestStandardTarget("testTarget", type: .application)
                            ])
            ]).load(getCore())

        let otherWorkspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root"),
                            targets: [])
            ]).load(getCore())

        let diff = workspace.diff(against: otherWorkspace)

        #expect(diff.hasChanges)
        #expect(0 == diff.rightProjects.count)
        #expect(0 == diff.leftProjects.count)
        #expect(0 == diff.rightTargets.count)
        #expect(1 == diff.leftTargets.count)
    }

    @Test
    func complexExample() async throws {
        let workspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("projectA",
                            groupTree: TestGroup("whatever"),
                            targets: [TestStandardTarget("targetA", type: .application)]),
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root"),
                            targets: [
                                TestStandardTarget("testTarget", type: .application)
                            ])
            ]).load(getCore())

        let otherWorkspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root"),
                            targets: []),
                TestProject("projectB",
                            groupTree: TestGroup("whatever"),
                            targets: [TestStandardTarget("targetB", type: .application),
                                      TestStandardTarget("targetC", type: .application)])
            ]).load(getCore())

        let diff = workspace.diff(against: otherWorkspace)

        #expect(diff.hasChanges)
        #expect(1 == diff.rightProjects.count)
        #expect("projectB" == diff.rightProjects[0].name)
        #expect(1 == diff.leftProjects.count)
        #expect("projectA" == diff.leftProjects[0].name)
        #expect(2 == diff.rightTargets.count)
        #expect(2 == diff.leftTargets.count)
    }

    @Test
    func extraFile() async throws {
        let extraFile = TestFile("Foo.c")

        let workspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root",
                                                 guid: "G1234",
                                                 children: [extraFile]),
                            targets: [
                                TestStandardTarget("testTarget", guid: "efgh", type: .application)
                            ])
            ]).load(getCore())

        let otherWorkspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root", guid: "G1234"),
                            targets: [
                                TestStandardTarget("testTarget", guid: "efgh", type: .application)
                            ])
            ]).load(getCore())

        let diff = workspace.diff(against: otherWorkspace)

        #expect(diff.hasChanges)
        #expect(0 == diff.leftProjects.count)
        #expect(0 == diff.rightProjects.count)
        #expect(0 == diff.leftTargets.count)
        #expect(0 == diff.rightTargets.count)
        #expect(1 == diff.leftReferences.count)
        #expect(0 == diff.rightReferences.count)

        #expect(extraFile.guid == diff.leftReferences[0].guid)
    }

    @Test
    func missingFile() async throws {
        let missingFile = TestFile("Foo.c")

        let workspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root", guid: "G1234"),
                            targets: [
                                TestStandardTarget("testTarget", guid: "efgh", type: .application)
                            ])
            ]).load(getCore())

        let otherWorkspace = try await TestWorkspace(
            "testWorkspace",
            projects: [
                TestProject("testProject",
                            guid: "abcd",
                            groupTree: TestGroup("root",
                                                 guid: "G1234",
                                                 children: [missingFile]),
                            targets: [
                                TestStandardTarget("testTarget", guid: "efgh", type: .application)
                            ])
            ]).load(getCore())

        let diff = workspace.diff(against: otherWorkspace)

        #expect(diff.hasChanges)
        #expect(0 == diff.leftProjects.count)
        #expect(0 == diff.rightProjects.count)
        #expect(0 == diff.leftTargets.count)
        #expect(0 == diff.rightTargets.count)
        #expect(0 == diff.leftReferences.count)
        #expect(1 == diff.rightReferences.count)

        #expect(missingFile.guid == diff.rightReferences[0].guid)
    }

}
