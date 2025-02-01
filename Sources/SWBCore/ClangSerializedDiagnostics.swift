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

import SWBCSupport
public import SWBUtil

extension Diagnostic {
    public init(_ diagnostic: ClangDiagnostic, workingDirectory: Path, appendToOutputStream: Bool) {
        self.init(behavior: .init(diagnostic.severity), location: diagnostic.fileName.map { path in .path((Path(path).makeAbsolute(relativeTo: workingDirectory) ?? Path(path)).normalize(), line: Int(diagnostic.line), column: Int(diagnostic.column)) } ?? .unknown, sourceRanges: diagnostic.ranges.map { .init($0) }, data: DiagnosticData(diagnostic.text, component: diagnostic.categoryText.map { .clangCompiler(categoryName: $0) } ?? .default, optionName: diagnostic.optionName), appendToOutputStream: appendToOutputStream, fixIts: diagnostic.fixIts.map { .init($0) }, childDiagnostics: diagnostic.childDiagnostics.map { .init($0, workingDirectory: workingDirectory, appendToOutputStream: appendToOutputStream) })
    }
}

extension Diagnostic.SourceRange {
    public init(_ range: ClangSourceRange) {
        self.init(path: Path(range.path), startLine: Int(range.startLine), startColumn: Int(range.startColumn), endLine: Int(range.endLine), endColumn: Int(range.endColumn))
    }
}

extension Diagnostic.FixIt {
    public init(_ fixIt: ClangFixIt) {
        self.init(sourceRange: .init(fixIt.range), newText: fixIt.text)
    }
}

extension Diagnostic.Behavior {
    public init(_ severity: ClangDiagnostic.Severity) {
        switch severity {
        case .ignored:
            self = .ignored
        case .note:
            self = .note
        case .warning:
            self = .warning
        case .error,
             .fatal:
            self = .error
        }
    }
}
