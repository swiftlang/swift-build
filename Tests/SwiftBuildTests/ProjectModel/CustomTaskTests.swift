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

func testCodable<T>(
    _ original: T,
    _ modify: ((inout T) -> Void)? = nil,
    _ fileID: String = #fileID,
    _ filePath: String = #filePath,
    _ line: Int = #line,
    _ column: Int = #column
) throws where T: Codable & Equatable {
    var original = original
    if let modify { modify(&original) }
    let data = try JSONEncoder().encode(original)
    let obj = try JSONDecoder().decode(T.self, from: data)
    #expect(original == obj, sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
}

@Suite
fileprivate struct CustomTaskTests {
    @Test func basicEncoding() throws {
        let task = ProjectModel.CustomTask(
            commandLine: [],
            environment: [],
            workingDirectory: nil,
            executionDescription: "",
            inputFilePaths: [],
            outputFilePaths: [],
            enableSandboxing: false,
            preparesForIndexing: false
        )
        try testCodable(task) { $0.commandLine = ["foo", "bar"] }
        try testCodable(task) { $0.environment = [Pair("a", "b"), Pair("c", "d")] }
        try testCodable(task) { $0.workingDirectory = "tmp" }
        try testCodable(task) { $0.executionDescription = "execution description" }
        try testCodable(task) { $0.inputFilePaths = ["input1", "input2"] }
        try testCodable(task) { $0.outputFilePaths = ["output1", "output2"] }
        try testCodable(task) { $0.enableSandboxing = true }
        try testCodable(task) { $0.preparesForIndexing = true }
    }
}

extension ProjectModel.CustomTask {
    static var example: Self {
        return ProjectModel.CustomTask(
            commandLine: ["foo", "bar"],
            environment: [Pair("a", "b"), Pair("c", "d")],
            workingDirectory: "tmp",
            executionDescription: "execution description",
            inputFilePaths: ["input1", "input2"],
            outputFilePaths: ["output1", "output2"],
            enableSandboxing: true,
            preparesForIndexing: true
        )
    }
}
