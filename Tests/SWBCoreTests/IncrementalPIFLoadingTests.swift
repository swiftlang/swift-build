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
import SWBUtil
import SWBTestSupport
@_spi(Testing) import SWBCore
import SWBProtocol

/// Test of the incremental PIF loading mechanisms.
@Suite(.serialized) fileprivate struct IncrementalPIFLoadingTests {
    @Test
    func basics() throws {
        let testTarget = TestAggregateTarget("aTarget")
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            targets: [testTarget])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let testWorkspace2 = TestWorkspace("bWorkspace", projects: [testProject])

        let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: nil)

        allStatistics.zero()

        // Load the first workspace.
        do {

            // We expect two entries in the PIF data.
            let pifObjects = try testWorkspace.toObjects()
            #expect(pifObjects.count == 3)
            let workspaceObject = pifObjects[0]
            let projectObject = pifObjects[1]
            let targetObject = pifObjects[2]

            // Initiate a loading session.
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            #expect(session.missingObjects.map{ $0.signature } == [testWorkspace.signature])

            // Add the workspace data.
            try session.add(object: workspaceObject)
            #expect(session.missingObjects.map{ $0.signature } == [testProject.signature])

            // Add the project data.
            try session.add(object: projectObject)
            #expect(session.missingObjects.map{ $0.signature } == [testTarget.signature])

            // Add the target data.
            try session.add(object: targetObject)
            #expect(session.missingObjects.map{ $0.signature } == [])

            // Load the workspace.
            let workspace = try session.load()

            #expect(workspace.name == "aWorkspace")
            #expect(workspace.projects.map{ $0.name } == ["aProject"])

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 3)
        }

        // Reset the stats.
        allStatistics.zero()

        // Load a second workspace, which shares the project.
        do {
            let pifObjects = try testWorkspace2.toObjects()
            #expect(pifObjects.count == 3)
            let workspaceObject = pifObjects[0]

            // Initiate a loading session.
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace2.signature)
            #expect(session.missingObjects.map{ $0.signature } == [testWorkspace2.signature])

            // Add the workspace data, which should complete all the necessary objects.
            try session.add(object: workspaceObject)
            #expect(session.missingObjects.map{ $0.signature } == [])

            // Check we error out if we try to add something that isn't required.
            #expect(throws: (any Error).self) {
                try session.add(object: workspaceObject)
            }
            #expect(session.missingObjects.map{ $0.signature } == [])

            // Load the workspace.
            let workspace = try session.load()

            #expect(workspace.name == "bWorkspace")
            #expect(workspace.projects.map{ $0.name } == ["aProject"])

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 1)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 1)
        }
    }

    @Test
    func brokenCache() throws {
        let testTarget = TestAggregateTarget("aTarget")
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            targets: [testTarget])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let fs = PseudoFS()
        let cachePath = Path.root.join("tmp")

        let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: cachePath, fs: fs)
        let pifObjects = try testWorkspace.toObjects()
        #expect(pifObjects.count == 3)
        let workspaceObject = pifObjects[0]
        let projectObject = pifObjects[1]
        let targetObject = pifObjects[2]

        // Load the pif.
        do {
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            #expect(session.missingObjects.map{$0}.count == 1)
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")
        }

        // We should not get any missing object when we load again.
        do {
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")
        }

        // Remove one of the cache directory.
        do {
            let workspaceCachePath = cachePath.join("workspace")
            try fs.removeDirectory(workspaceCachePath)
        }

        // Load again after breaking the integrity of a cache directory.
        do {
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            // We should have missingObjects.
            #expect(incrementalLoader.loadedObjectCount == 2)
            #expect(session.missingObjects.map{$0}.count == 1)

            // Add the workspace object back.
            try session.add(object: workspaceObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")
        }

        // Remove the full cache and load again
        try fs.removeDirectory(cachePath)
        do {
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            // We should have missingObjects.
            #expect(incrementalLoader.loadedObjectCount == 2)
            #expect(session.missingObjects.map{$0}.count == 1)

            // Add the objects back.
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")
        }
    }

    @Test
    func persistence() throws {
        let testTarget = TestAggregateTarget("aTarget")
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources"),
            targets: [testTarget])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let testWorkspace2 = TestWorkspace("bWorkspace", projects: [testProject])

        let fs = PseudoFS()

        allStatistics.zero()

        // Transfer the first workspace.
        do {
            let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: Path.root.join("tmp"), fs: fs)
            let pifObjects = try testWorkspace.toObjects()
            #expect(pifObjects.count == 3)
            let workspaceObject = pifObjects[0]
            let projectObject = pifObjects[1]
            let targetObject = pifObjects[2]
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 3)
        }

        allStatistics.zero()

        // Load the first workspace again.
        do {
            let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: Path.root.join("tmp"), fs: fs)
            let pifObjects = try testWorkspace.toObjects()
            #expect(pifObjects.count == 3)
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "aWorkspace")

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 0)
        }

        allStatistics.zero()

        // Load a second workspace, which shares the project.
        do {
            let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: Path.root.join("tmp"), fs: fs)
            let pifObjects = try testWorkspace2.toObjects()
            #expect(pifObjects.count == 3)
            let workspaceObject = pifObjects[0]
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace2.signature)
            try session.add(object: workspaceObject)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()
            #expect(workspace.name == "bWorkspace")

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 1)
        }
    }

    /// Check that references are rewired correctly on incremental loading.
    @Test
    func projectReferences() throws {
        let testTargetA = TestStandardTarget(
            "aTarget",
            type: .application,
            buildPhases: [TestSourcesBuildPhase(["foo.c"])])
        let testTargetB = TestStandardTarget(
            "bTarget",
            type: .application,
            buildPhases: [TestSourcesBuildPhase(["bar.c"])])
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", children: [TestFile("foo.c"), TestFile("bar.c"), TestFile("baz.c")]),
            targets: [testTargetA, testTargetB])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])

        let incrementalLoader = IncrementalPIFLoader(internalNamespace: BuiltinMacros.namespace, cachePath: nil)

        allStatistics.zero()

        // Load the first workspace.
        do {
            let pifObjects = try testWorkspace.toObjects()
            #expect(pifObjects.count == 4)
            let workspaceObject = pifObjects[0]
            let projectObject = pifObjects[1]
            let targetObjectA = pifObjects[2]
            let targetObjectB = pifObjects[3]

            // Load the workspace.
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace.signature)
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObjectA)
            try session.add(object: targetObjectB)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()

            #expect(workspace.name == "aWorkspace")
            #expect(workspace.projects.map{ $0.name } == ["aProject"])
            #expect(workspace.projects.flatMap{ $0.targets }.map{ $0.name } == ["aTarget", "bTarget"])

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 4)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 4)
        }

        // Reset the stats.
        allStatistics.zero()

        // Load with a new project but shared targetA.
        let testTargetB2 = TestStandardTarget(
            "bTarget",
            type: .application,
            buildPhases: [TestSourcesBuildPhase(["baz.c"])])
        let testProject2 = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", children: [TestFile("foo.c"), TestFile("bar.c"), TestFile("baz.c")]),
            targets: [testTargetA, testTargetB2])
        let testWorkspace2 = TestWorkspace("aWorkspace", projects: [testProject2])

        // Load a second workspace with the new target.
        do {
            let pifObjects = try testWorkspace2.toObjects()
            #expect(pifObjects.count == 4)
            let workspaceObject = pifObjects[0]
            let projectObject = pifObjects[1]
            let targetObjectB = pifObjects[3]

            // Load the workspace.
            let session = incrementalLoader.startLoading(workspaceSignature: testWorkspace2.signature)
            try session.add(object: workspaceObject)
            try session.add(object: projectObject)
            try session.add(object: targetObjectB)
            #expect(session.missingObjects.map{ $0.signature } == [])
            let workspace = try session.load()

            #expect(workspace.name == "aWorkspace")
            #expect(workspace.projects.map{ $0.name } == ["aProject"])
            #expect(workspace.projects.flatMap{ $0.targets }.map{ $0.name } == ["aTarget", "bTarget"])

            #expect(IncrementalPIFLoader.loadsRequested.value == 1)
            #expect(IncrementalPIFLoader.objectsLoaded.value == 3)
            #expect(IncrementalPIFLoader.objectsTransferred.value == 3)

            // Validate that the file references are consistent.
            var knownReferences = Set<SWBCore.FileReference>()
            func visit(_ ref: SWBCore.Reference) {
                switch ref {
                case let asGroup as SWBCore.FileGroup:
                    asGroup.children.forEach(visit)
                case let asFile as SWBCore.FileReference:
                    knownReferences.insert(asFile)
                default:
                    fatalError("unexpected reference: \(ref)")
                }
            }
            for project in workspace.projects {
                knownReferences.removeAll()
                visit(project.groupTree)
                for case let target as SWBCore.BuildPhaseTarget in project.targets {
                    for case let phase as SWBCore.BuildPhaseWithBuildFiles in target.buildPhases {
                        for buildFile in phase.buildFiles {
                            switch buildFile.buildableItem {
                            case .reference(let guid):
                                let ref = try #require(workspace.lookupReference(for: guid) as? SWBCore.FileReference)
                                #expect(knownReferences.contains(ref), "unexpected target reference: \(ref)")
                            case .targetProduct(_):
                                continue
                            case .namedReference:
                                Issue.record("unexpected named reference")
                            }
                        }
                    }
                }
            }
        }
    }
}

