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

public import SWBUtil

public struct CustomTask: SerializableCodable, Sendable {
    public let commandLine: [MacroExpressionSource]
    public let environment: [(MacroExpressionSource, MacroExpressionSource)]
    public let workingDirectory: MacroExpressionSource
    public let executionDescription: MacroExpressionSource
    public let inputFilePaths: [MacroExpressionSource]
    public let outputFilePaths: [MacroExpressionSource]
    public let enableSandboxing: Bool
    public let preparesForIndexing: Bool

    public init(commandLine: [MacroExpressionSource], environment: [(MacroExpressionSource, MacroExpressionSource)], workingDirectory: MacroExpressionSource, executionDescription: MacroExpressionSource, inputFilePaths: [MacroExpressionSource], outputFilePaths: [MacroExpressionSource], enableSandboxing: Bool, preparesForIndexing: Bool) {
        self.commandLine = commandLine
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.executionDescription = executionDescription
        self.inputFilePaths = inputFilePaths
        self.outputFilePaths = outputFilePaths
        self.enableSandboxing = enableSandboxing
        self.preparesForIndexing = preparesForIndexing
    }
    
    enum CodingKeys: CodingKey {
        case commandLine
        case environmentVars
        case environmentValues
        case workingDirectory
        case executionDescription
        case inputFilePaths
        case outputFilePaths
        case enableSandboxing
        case preparesForIndexing
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.commandLine, forKey: .commandLine)
        try container.encode(environment.map(\.0), forKey: .environmentVars)
        try container.encode(environment.map(\.1), forKey: .environmentValues)
        try container.encode(workingDirectory, forKey: .workingDirectory)
        try container.encode(executionDescription, forKey: .executionDescription)
        try container.encode(inputFilePaths, forKey: .inputFilePaths)
        try container.encode(outputFilePaths, forKey: .outputFilePaths)
        try container.encode(enableSandboxing, forKey: .enableSandboxing)
        try container.encode(preparesForIndexing, forKey: .preparesForIndexing)
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.commandLine = try container.decode([MacroExpressionSource].self, forKey: .commandLine)
        let environmentVars = try container.decode([MacroExpressionSource].self, forKey: .environmentVars)
        let environmentValues = try container.decode([MacroExpressionSource].self, forKey: .environmentValues)
        self.environment = Array(zip(environmentVars, environmentValues))
        self.workingDirectory = try container.decode(MacroExpressionSource.self, forKey: .workingDirectory)
        self.executionDescription = try container.decode(MacroExpressionSource.self, forKey: .executionDescription)
        self.inputFilePaths = try container.decode([MacroExpressionSource].self, forKey: .inputFilePaths)
        self.outputFilePaths = try container.decode([MacroExpressionSource].self, forKey: .outputFilePaths)
        self.enableSandboxing = try container.decode(Bool.self, forKey: .enableSandboxing)
        self.preparesForIndexing = try container.decode(Bool.self, forKey: .preparesForIndexing)
    }
}

