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

public final class CustomTaskTypeDescription: TaskTypeDescription {
    
    private init() {
    }
    
    public static let only: any TaskTypeDescription = CustomTaskTypeDescription()
    
    public var payloadType: (any TaskPayload.Type)? {
        nil
    }
    
    public var isUnsafeToInterrupt: Bool {
        false
    }
    
    public var toolBasenameAliases: [String] {
        []
    }
    
    public func commandLineForSignature(for task: any ExecutableTask) -> [ByteString]? {
        return nil
    }
    
    public func serializedDiagnosticsPaths(_ task: any ExecutableTask, _ fs: any FSProxy) -> [Path] {
        []
    }
    
    public func generateIndexingInfo(for task: any ExecutableTask, input: TaskGenerateIndexingInfoInput) -> [TaskGenerateIndexingInfoOutput] {
        []
    }
    
    public func generatePreviewInfo(for task: any ExecutableTask, input: TaskGeneratePreviewInfoInput, fs: any FSProxy) -> [TaskGeneratePreviewInfoOutput] {
        []
    }
    
    public func generateDocumentationInfo(for task: any ExecutableTask, input: TaskGenerateDocumentationInfoInput) -> [TaskGenerateDocumentationInfoOutput] {
        []
    }
    
    public func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        ShellScriptOutputParser.self
    }
    
    public func interestingPath(for task: any ExecutableTask) -> Path? {
        nil
    }

    public func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] {
       []
    }
}
