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
import SwiftBuild
import Testing

@Suite
fileprivate struct ProjectTests {
    @Test func basicEncoding() throws {
        let obj = ProjectModel.Project(id: "foo", path: "/tmp", projectDir: "/tmp/foo", name: "Foo")
        try testProjectCodable(obj) { $0.name = "Project Name" }
        try testProjectCodable(obj) { $0.developmentRegion = "Earth" }
        try testProjectCodable(obj) { $0.mainGroup.path = "/tmp/bar" }
        try testProjectCodable(obj) {
            $0.addBuildConfig { id in
                .init(id: id, name: "Build Config", settings: ProjectModel.BuildSettings())
            }
        }
        try testProjectCodable(obj) { $0.projectDir = "/tmp/bar" }
        try testProjectCodable(obj) { try $0.addTarget { _ in .example(.executable) } }
        try testProjectCodable(obj) { try $0.addTarget { _ in .example(.application) } }
        try testProjectCodable(obj) { $0.isPackage = true }
    }

    private static func makeTarget(_ i: Int) -> ProjectModel.Target {
        ProjectModel.Target(id: "target-\(i)", productType: .executable, name: "Target\(i)", productName: "Product\(i)")
    }

    @Test func targetLookupAndMutationThroughKeyPaths() throws {
        var project = ProjectModel.Project(id: "p", path: "/tmp", projectDir: "/tmp/p", name: "P")
        var keyPaths: [WritableKeyPath<ProjectModel.Project, ProjectModel.Target>] = []
        for i in 0..<200 {
            keyPaths.append(try project.addTarget { _ in Self.makeTarget(i) })
        }
        let aggregateKP = try project.addAggregateTarget { _ in ProjectModel.AggregateTarget(id: "agg", name: "Agg") }

        for (i, kp) in keyPaths.enumerated() {
            #expect(project[keyPath: kp].id.value == "target-\(i)")
        }
        project[keyPath: keyPaths[150]].common.addDependency(on: "target-3", platformFilters: [])
        project[keyPath: keyPaths[150]].common.name = "Renamed"
        project[keyPath: aggregateKP].common.addDependency(on: "target-7", platformFilters: [])

        #expect(project[keyPath: keyPaths[150]].common.dependencies.map(\.targetId.value) == ["target-3"])
        #expect(project[keyPath: keyPaths[150]].common.name == "Renamed")
        #expect(project[keyPath: aggregateKP].common.dependencies.map(\.targetId.value) == ["target-7"])
        #expect(project[keyPath: keyPaths[149]].common.dependencies.isEmpty)
        #expect(project[keyPath: keyPaths[151]].common.name == "Target151")
        #expect(project.targets.count == 201)

        #expect(throws: (any Error).self) {
            try project.addTarget { _ in Self.makeTarget(42) }
        }
        #expect(throws: (any Error).self) {
            try project.addAggregateTarget { _ in ProjectModel.AggregateTarget(id: "target-0", name: "Dup") }
        }
    }

    @Test func targetLookupSurvivesDirectMutationOfTargets() throws {
        var project = ProjectModel.Project(id: "p", path: "/tmp", projectDir: "/tmp/p", name: "P")
        var keyPaths: [WritableKeyPath<ProjectModel.Project, ProjectModel.Target>] = []
        for i in 0..<20 {
            keyPaths.append(try project.addTarget { _ in Self.makeTarget(i) })
        }

        // Reorder and remove through the public `targets` array; the index cache is now stale.
        project.targets.reverse()
        project.targets.removeFirst()  // removes target-19
        for i in 0..<19 {
            #expect(project[keyPath: keyPaths[i]].id.value == "target-\(i)")
        }
        project[keyPath: keyPaths[5]].common.name = "Five"
        #expect(project.targets.first(where: { $0.id.value == "target-5" })?.common.name == "Five")
        #expect(throws: (any Error).self) {
            try project.addTarget { _ in Self.makeTarget(5) }
        }

        let readded = try project.addTarget { _ in Self.makeTarget(19) }
        #expect(project[keyPath: readded].id.value == "target-19")
        #expect(project.findTarget(id: "target-0").map { project[keyPath: $0].name } == "Target0")
    }

    @Test func equalityIgnoresLookupCache() throws {
        var built = ProjectModel.Project(id: "p", path: "/tmp", projectDir: "/tmp/p", name: "P")
        for i in 0..<5 {
            try built.addTarget { _ in Self.makeTarget(i) }
        }
        let initialized = ProjectModel.Project(id: "p", path: "/tmp", projectDir: "/tmp/p", name: "P", targets: built.targets)
        #expect(built == initialized)
        #expect(built.hashValue == initialized.hashValue)

        // Same targets, but a cache built for the reverse order (now stale): still equal, same hash.
        var stale = ProjectModel.Project(id: "p", path: "/tmp", projectDir: "/tmp/p", name: "P", targets: built.targets.reversed())
        stale.targets.reverse()
        #expect(built == stale)
        #expect(built.hashValue == stale.hashValue)
    }

    @Test func throwingInPlaceMutationWritesBackTarget() throws {
        struct Failure: Error {}
        func renameThenThrow(_ common: inout ProjectModel.TargetCommon) throws {
            common.name = "Changed"
            throw Failure()
        }

        var project = ProjectModel.Project(id: "p", path: "/tmp", projectDir: "/tmp/p", name: "P")
        try project.addTarget { _ in Self.makeTarget(0) }
        #expect(throws: Failure.self) {
            try renameThenThrow(&project.targets[0].common)
        }
        #expect(project.targets[0].id.value == "target-0")
        #expect(project.targets[0].common.name == "Changed")
    }

    @Test func mutationsThroughACopyDoNotLeakIntoTheOriginal() throws {
        var original = ProjectModel.Project(id: "p", path: "/tmp", projectDir: "/tmp/p", name: "P")
        let kp = try original.addTarget { _ in Self.makeTarget(0) }
        try original.addTarget { _ in Self.makeTarget(1) }
        let pristine = original

        var copy = original
        copy[keyPath: kp].common.addDependency(on: "x", platformFilters: [])
        copy.targets[1].common.name = "Changed"

        #expect(original == pristine)
        #expect(copy[keyPath: kp].common.dependencies.map(\.targetId.value) == ["x"])
        #expect(copy.targets[1].common.name == "Changed")
    }
}

extension ProjectModel.Project {
    static var example: Self {
        get throws {
            var project = Self(
                id: "project-id",
                path: "some/path/to/project",
                projectDir: "ProjectDir",
                name: "ProjectName"
            )
            project.mainGroup.addFileReference { _ in ProjectModel.FileReference.example }
            let standardTargetKP = try project.addTarget { _ in ProjectModel.Target.example(.executable) }
            let standardTargetId = project[keyPath: standardTargetKP].id
            try project.addAggregateTarget { _ in
                var target = ProjectModel.AggregateTarget.example
                target.common.addDependency(on: standardTargetId, platformFilters: [.init(platform: "linux")], buildConfigurationFilters: [.init(buildConfiguration: "Debug")])
                return target
            }
            return project
        }
    }
}

fileprivate func testProjectCodable(
    _ original: ProjectModel.Project,
    _ modify: ((inout ProjectModel.Project) throws -> Void)? = nil,
    _ fileID: String = #fileID,
    _ filePath: String = #filePath,
    _ line: Int = #line,
    _ column: Int = #column
) throws {
    var original = original
    if let modify { try modify(&original) }

    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    for target in original.targets {
        if let signature = target.common.signature,
           let key = CodingUserInfoKey(rawValue: signature) {
            assert(decoder.userInfo[key] == nil)
            decoder.userInfo[key] = target
        }
    }
    let obj = try decoder.decode(ProjectModel.Project.self, from: data)
    #expect(original == obj, sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
}

