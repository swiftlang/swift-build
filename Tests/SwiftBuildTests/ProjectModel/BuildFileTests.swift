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
fileprivate struct BuildFileTests {
    @Test func basicEncoding() throws {
        let obj = ProjectModel.BuildFile(id: "foo", ref: .targetProduct(id: "bar"))
        try testCodable(obj)
    }

    @Test func emptyFiltersAreOmitted() throws {
        let keys = try encodedKeys(ProjectModel.BuildFile(id: "foo", ref: .targetProduct(id: "bar")))
        #expect(!keys.contains("platformFilters") && !keys.contains("buildConfigurationFilters"))
    }

    @Test func nonEmptyFiltersAreEncoded() throws {
        let obj = ProjectModel.BuildFile(id: "foo", ref: .targetProduct(id: "bar"), platformFilters: [.init(platform: "linux")], buildConfigurationFilters: [.init(buildConfiguration: "Release")])
        try testCodable(obj)
        let keys = try encodedKeys(obj)
        #expect(keys.contains("platformFilters") && keys.contains("buildConfigurationFilters"))
    }

    @Test(arguments: [
        #"{"guid": "foo", "targetReference": "bar"}"#,
        #"{"guid": "foo", "platformFilters": [], "targetReference": "bar"}"#,
        #"{"guid": "foo", "platformFilters": [], "buildConfigurationFilters": [], "targetReference": "bar"}"#,
    ])
    func decodesWithOrWithoutFilters(json: String) throws {
        let obj = try JSONDecoder().decode(ProjectModel.BuildFile.self, from: Data(json.utf8))
        #expect(obj == ProjectModel.BuildFile(id: "foo", ref: .targetProduct(id: "bar")))
    }
}

extension ProjectModel.BuildFile {
    static var example: Self {
        return .init(id: "buildFileId", ref: .reference(id: "referenceId"))
    }
}
