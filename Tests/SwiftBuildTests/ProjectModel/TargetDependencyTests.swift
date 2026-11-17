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
fileprivate struct TargetDependencyTests {
    @Test func basicEncoding() throws {
        try testCodable(ProjectModel.TargetDependency.example)
    }

    @Test func emptyFiltersAreOmitted() throws {
        let dependency = ProjectModel.TargetDependency(targetId: "foo")
        try testCodable(dependency)
        #expect(try encodedKeys(dependency) == ["guid"])
    }

    @Test func nonEmptyFiltersAreEncoded() throws {
        let dependency = ProjectModel.TargetDependency(targetId: "foo", platformFilters: [.init(platform: "linux")], buildConfigurationFilters: [.init(buildConfiguration: "Debug")])
        try testCodable(dependency)
        #expect(try encodedKeys(dependency) == ["buildConfigurationFilters", "guid", "platformFilters"])
    }

    @Test(arguments: [
        #"{"guid": "foo"}"#,
        #"{"guid": "foo", "platformFilters": []}"#,
        #"{"guid": "foo", "platformFilters": [], "buildConfigurationFilters": []}"#,
    ])
    func decodesWithOrWithoutFilters(json: String) throws {
        let dependency = try JSONDecoder().decode(ProjectModel.TargetDependency.self, from: Data(json.utf8))
        #expect(dependency == ProjectModel.TargetDependency(targetId: "foo"))
    }
}


extension ProjectModel.TargetDependency {
    static var example: Self {
        return ProjectModel.TargetDependency(
            targetId: "foo",
            platformFilters: [.example]
        )
    }
}
