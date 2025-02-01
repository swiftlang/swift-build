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
                target.common.addDependency(on: standardTargetId, platformFilters: [.init(platform: "linux")])
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

