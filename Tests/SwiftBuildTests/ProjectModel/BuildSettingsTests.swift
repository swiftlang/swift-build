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
import SWBUtil
import Testing

@Suite
fileprivate struct BuildSettingsTests {
    @Test func basicEncoding() throws {
        try testCodable(ProjectModel.BuildSettings.example)

        let obj = ProjectModel.BuildSettings()

        try testCodable(obj) { $0[.BUILT_PRODUCTS_DIR] = "/tmp" }
        try testCodable(obj) { $0[.HEADER_SEARCH_PATHS] = ["/foo", "/bar"] }
        try testCodable(obj) { $0.platformSpecificSettings[.macOS, default: [:]][.FRAMEWORK_SEARCH_PATHS] = ["/baz", "/qux"] }
    }

    @Test func unknownBuildSettings() throws {
        var obj = ProjectModel.BuildSettings()
        obj[single: "CUSTOM1"] = "value"
        obj[multiple: "CUSTOM2"] = ["foo", "bar"]

        let data = try JSONEncoder().encode(obj)
        let decoded = try #require(PropertyList.fromJSONData(data).dictValue)
        #expect(decoded["CUSTOM1"]?.stringValue == "value")
        #expect(decoded["CUSTOM2"]?.stringArrayValue == ["foo", "bar"])
    }
}

extension ProjectModel.BuildSettings {
    static var example: Self {
        var settings = ProjectModel.BuildSettings()
        settings[.CLANG_CXX_LANGUAGE_STANDARD] = "c++17"
        settings[.FRAMEWORK_SEARCH_PATHS] = ["/path1", "/path2"]
        settings.platformSpecificSettings[.linux, default: [:]][.HEADER_SEARCH_PATHS] = ["/foo", "/bar"]
        return settings
    }
}
