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
import SWBProtocol

public struct Pair<First, Second> {
    public var first: First
    public var second: Second

    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }
}

extension Pair: Equatable where First: Equatable, Second: Equatable {}
extension Pair: Hashable where First: Hashable, Second: Hashable {}
extension Pair: Sendable where First: Sendable, Second: Sendable {}
extension Pair: Comparable where First: Comparable, Second: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.first, lhs.second) < (rhs.first, rhs.second)
    }
}

extension ProjectModel {
    public struct CustomTask: Hashable, Sendable {
        public var commandLine: [String]
        public var environment: [Pair<String, String>]
        public var workingDirectory: String?
        public var executionDescription: String
        public var inputFilePaths: [String]
        public var outputFilePaths: [String]
        public var enableSandboxing: Bool
        public var preparesForIndexing: Bool

        public init(
            commandLine: [String],
            environment: [Pair<String, String>],
            workingDirectory: String?,
            executionDescription: String,
            inputFilePaths: [String],
            outputFilePaths: [String],
            enableSandboxing: Bool,
            preparesForIndexing: Bool
        ) {
            self.commandLine = commandLine
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.executionDescription = executionDescription
            self.inputFilePaths = inputFilePaths
            self.outputFilePaths = outputFilePaths
            self.enableSandboxing = enableSandboxing
            self.preparesForIndexing = preparesForIndexing
        }
    }
}

extension ProjectModel.CustomTask: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.commandLine = try container.decode([String].self, forKey: .commandLine)
        let environment = try container.decode([[String]].self, forKey: .environment)
        self.environment = environment.compactMap { strs in
            guard let k = strs.first, let v = strs.dropFirst().first else {
                return nil
            }
            return Pair(k, v)
        }
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.executionDescription = try container.decode(String.self, forKey: .executionDescription)
        self.inputFilePaths = try container.decode([String].self, forKey: .inputFilePaths)
        self.outputFilePaths = try container.decode([String].self, forKey: .outputFilePaths)
        self.enableSandboxing = try container.decode(String.self, forKey: .enableSandboxing) == "true"
        self.preparesForIndexing = try container.decode(String.self, forKey: .preparesForIndexing) == "true"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.commandLine, forKey: .commandLine)
        try container.encode(self.environment.map { [$0.first, $0.second] }, forKey: .environment)
        try container.encodeIfPresent(self.workingDirectory, forKey: .workingDirectory)
        try container.encode(self.executionDescription, forKey: .executionDescription)
        try container.encode(self.inputFilePaths, forKey: .inputFilePaths)
        try container.encode(self.outputFilePaths, forKey: .outputFilePaths)
        try container.encode(self.enableSandboxing ? "true" : "false", forKey: .enableSandboxing)
        try container.encode(self.preparesForIndexing ? "true" : "false", forKey: .preparesForIndexing)
    }

    enum CodingKeys: String, CodingKey {
        case commandLine
        case environment
        case workingDirectory
        case executionDescription
        case inputFilePaths
        case outputFilePaths
        case enableSandboxing
        case preparesForIndexing
    }
}
