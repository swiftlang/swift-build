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

package import SWBCore
package import SWBUtil
package import Testing

package enum IndexingInfoCondition: CustomStringConvertible, Sendable {
    case matchSourceFilePath(Path)
    case matchOutputFilePath(Path)

    package var description: String {
        switch self {
        case let .matchSourceFilePath(path):
            return "sourceFilePath == \(path.str)"
        case let .matchOutputFilePath(path):
            return "outputFilePath == \(path.str)"
        }
    }

    fileprivate func match(_ info: IndexingInfo) -> Bool {
        switch self {
        case let .matchSourceFilePath(path):
            return info.sourceFilePath == path
        case let .matchOutputFilePath(path):
            return info.outputFilePath == path
        }
    }
}

package final class IndexingInfoResults {
    private var uncheckedEntries: [IndexingInfo]

    package init(_ indexingInfo: [[String: PropertyListItem]]) {
        self.uncheckedEntries = indexingInfo.map { IndexingInfo(plist: $0) }
    }

    private var sortedUncheckedEntries: [IndexingInfo] {
        uncheckedEntries.sorted(by: { $0.outputFilePath?.str ?? "" < $1.outputFilePath?.str ?? "" })
    }

    package func checkIndexingInfo(_ conditions: IndexingInfoCondition..., sourceLocation: SourceLocation = #_sourceLocation, body: (IndexingInfo) async -> Void) async {
        if let item = findOneIndexingInfo(conditions, sourceLocation: sourceLocation) {
            _ = self.uncheckedEntries.removeAll(where: { $0 == item })
            await body(item)
            item.checkNoUnknownKeys(sourceLocation: sourceLocation)
        }
    }

    private func matchAll(_ info: IndexingInfo, _ conditions: [IndexingInfoCondition]) -> Bool {
        conditions.allSatisfy { $0.match(info) }
    }

    private func findOneIndexingInfo(_ conditions: [IndexingInfoCondition], sourceLocation: SourceLocation = #_sourceLocation) -> IndexingInfo? {
        let matchedEntries = uncheckedEntries.filter({ matchAll($0, conditions) })
        if matchedEntries.isEmpty {
            Issue.record("unable to find any entry matching conditions '\(conditions)', among entries:\n\t'\(sortedUncheckedEntries.compactMap { $0.sourceFilePath?.str }.joined(separator: ",\n\t"))'", sourceLocation: sourceLocation)
            return nil
        } else if matchedEntries.count > 1 {
            Issue.record("found multiple entries matching conditions '\(conditions)', found:\n\t\(matchedEntries.map { String(describing: $0) }.joined(separator: ",\n\t"))", sourceLocation: sourceLocation)
            return nil
        } else {
            return matchedEntries[0]
        }
    }

    package func checkNoIndexingInfo(sourceLocation: SourceLocation = #_sourceLocation) {
        for entry in uncheckedEntries {
            Issue.record("found unexpected entry: \(entry)", sourceLocation: sourceLocation)
        }
    }
}

@available(*, unavailable)
extension IndexingInfoResults: Sendable { }

package final class IndexingInfo: Hashable, CustomStringConvertible {
    private enum KnownKeys: String, CaseIterable {
        case sourceFilePath
        case outputFilePath
        case languageDialect = "LanguageDialect"
        case toolchains

        case clangPrefixFilePath
        case clangPCHFilePath
        case clangPCHHashCriteria
        case clangPCHCommandArguments

        case clangASTCommandArguments
        case clangASTBuiltProductsDir

        case metalASTCommandArguments
        case metalASTBuiltProductsDir

        case swiftASTCommandArguments
        case swiftASTBuiltProductsDir
        case swiftASTModuleName

        case coreMLGeneratedFilePaths = "COREMLCOMPILER_GENERATED_FILE_PATHS"
        case coreMLGeneratedLanguage = "COREMLCOMPILER_LANGUAGE_TO_GENERATE"
        case coreMLGeneratedNotice = "COREMLCOMPILER_GENERATOR_NOTICE"
        case coreMLGeneratedError = "COREMLCOMPILER_GENERATOR_ERROR"

        case intentsGeneratedFilePaths = "INTENTS_GENERATED_FILE_PATHS"
        case intentsGeneratedError = "INTENTS_GENERATOR_ERROR"

        case assetSymbolIndexPath = "assetSymbolIndexPath"
    }

    private struct Static {
        static let knownKeys = Set(KnownKeys.allCases.map(\.rawValue))
    }

    private let plist: [String: PropertyListItem]

    private var unmatchedKeys: Set<String>

    package init(plist: [String: PropertyListItem]) {
        self.plist = plist
        self.unmatchedKeys = Set(plist.keys)
    }

    package convenience init(sourceInfo: (any SourceFileIndexingInfo)?) {
        let plist = sourceInfo?.propertyListItem.dictValue ?? [:]
        self.init(plist: plist.mapValues { PropertyListItem($0) })
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(plist)
    }

    package static func == (lhs: IndexingInfo, rhs: IndexingInfo) -> Bool {
        return lhs.plist == rhs.plist
    }

    package var description: String {
        return plist.description
    }

    package func checkNoUnmatchedKeys(sourceLocation: SourceLocation = #_sourceLocation) {
        for key in unmatchedKeys.sorted() {
            Issue.record("unmatched key in indexing info dictionary: \(key)", sourceLocation: sourceLocation)
        }
    }

    fileprivate func checkNoUnknownKeys(sourceLocation: SourceLocation = #_sourceLocation) {
        for key in plist.keys.sorted() {
            if !Static.knownKeys.contains(key) {
                Issue.record("unknown key in indexing info dictionary: \(key)", sourceLocation: sourceLocation)
            }
        }
    }

    fileprivate var sourceFilePath: Path? {
        plist[KnownKeys.sourceFilePath.rawValue]?.stringValue.map(Path.init)
    }

    fileprivate var outputFilePath: Path? {
        plist[KnownKeys.outputFilePath.rawValue]?.stringValue.map(Path.init)
    }

    private func consumeKey(_ key: KnownKeys) -> PropertyListItem? {
        defer { unmatchedKeys.remove(key.rawValue) }
        return plist[key.rawValue]
    }

    private func consumeCheckableCommandLineKey(_ key: KnownKeys) -> any CommandLineCheckable {
        struct CLI: CommandLineCheckable {
            var commandLineAsByteStrings: [ByteString]
        }
        return CLI(commandLineAsByteStrings: (consumeKey(key)?.stringArrayValue ?? []).map { ByteString(encodingAsUTF8: $0) })
    }
}

@available(*, unavailable)
extension IndexingInfo: Sendable { }

extension IndexingInfo {
    package func checkSourceFilePath(_ path: Path, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.sourceFilePath) == PropertyListItem.plString(path.str), sourceLocation: sourceLocation)
    }

    package func checkOutputFilePath(_ path: Path, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.outputFilePath) == PropertyListItem.plString(path.str), sourceLocation: sourceLocation)
    }

    package func checkLanguageDialect(_ dialect: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.languageDialect) == PropertyListItem.plString(dialect), sourceLocation: sourceLocation)
    }

    package func checkToolchains(_ toolchains: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.toolchains) == PropertyListItem(toolchains), sourceLocation: sourceLocation)
    }
}

extension IndexingInfo {
    package func checkPrefixHeaderPath(_ prefixHeaderPath: StringPattern?, sourceLocation: SourceLocation = #_sourceLocation) {
        XCTAssertMatch(self.consumeKey(.clangPrefixFilePath)?.stringValue, prefixHeaderPath, sourceLocation: sourceLocation)
    }

    package func checkPrecompiledHeaderPath(_ precompiledHeaderPath: StringPattern?, sourceLocation: SourceLocation = #_sourceLocation) {
        XCTAssertMatch(self.consumeKey(.clangPCHFilePath)?.stringValue, precompiledHeaderPath, sourceLocation: sourceLocation)
    }

    package func checkPrecompiledHeaderHashCriteria(_ hashCriteria: String?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.clangPCHHashCriteria) == hashCriteria.map { PropertyListItem.plString($0) }, sourceLocation: sourceLocation)
    }

    package var clangPrecompiledHeader: any CommandLineCheckable {
        return consumeCheckableCommandLineKey(.clangPCHCommandArguments)
    }
}


extension IndexingInfo {
    package var clang: any CommandLineCheckable {
        return consumeCheckableCommandLineKey(.clangASTCommandArguments)
    }

    package func checkClangBuiltProductsDir(_ builtProductsDir: Path, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.clangASTBuiltProductsDir) == PropertyListItem.plString(builtProductsDir.str), sourceLocation: sourceLocation)
    }
}

extension IndexingInfo {
    package var metal: any CommandLineCheckable {
        return consumeCheckableCommandLineKey(.metalASTCommandArguments)
    }

    package func checkMetalBuiltProductsDir(_ builtProductsDir: Path, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.metalASTBuiltProductsDir) == PropertyListItem.plString(builtProductsDir.str), sourceLocation: sourceLocation)
    }
}

extension IndexingInfo {
    package var swift: any CommandLineCheckable {
        return consumeCheckableCommandLineKey(.swiftASTCommandArguments)
    }

    package func checkSwiftBuiltProductsDir(_ builtProductsDir: Path, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.swiftASTBuiltProductsDir) == PropertyListItem.plString(builtProductsDir.str), sourceLocation: sourceLocation)
    }

    package func checkSwiftModuleName(_ moduleName: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.swiftASTModuleName) == PropertyListItem.plString(moduleName), sourceLocation: sourceLocation)
    }
}

extension IndexingInfo {
    package func checkCoreMLGeneratedFilePaths(_ paths: [Path], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.coreMLGeneratedFilePaths) == PropertyListItem(paths.map(\.str)), sourceLocation: sourceLocation)
    }

    package func checkCoreMLGeneratedLanguage(_ language: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.coreMLGeneratedLanguage) == PropertyListItem.plString(language), sourceLocation: sourceLocation)
    }

    package func checkCoreMLGeneratedError(_ error: StringPattern?, sourceLocation: SourceLocation = #_sourceLocation) {
        XCTAssertMatch(self.consumeKey(.coreMLGeneratedError)?.propertyListItem.stringValue, error, sourceLocation: sourceLocation)
    }
}

extension IndexingInfo {
    package func checkIntentsGeneratedFilePaths(_ paths: [Path], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.intentsGeneratedFilePaths) == PropertyListItem(paths.map(\.str)), sourceLocation: sourceLocation)
    }

    package func checkIntentsGeneratedError(_ error: StringPattern?, sourceLocation: SourceLocation = #_sourceLocation) {
        XCTAssertMatch(self.consumeKey(.intentsGeneratedError)?.stringValue, error, sourceLocation: sourceLocation)
    }
}

fileprivate func XCTAssertMatch(_ value: @autoclosure @escaping () -> String?, _ pattern: StringPattern?, _ message: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    if let pattern {
        XCTAssertMatch(value(), pattern, message, sourceLocation: sourceLocation)
    } else {
        #expect(value() == nil, Comment(rawValue: message ?? ""), sourceLocation: sourceLocation)
    }
}

extension IndexingInfo {
    package func checkAssetSymbolIndexPath(_ assetSymbolIndexPath: Path, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(consumeKey(.assetSymbolIndexPath) == PropertyListItem.plString(assetSymbolIndexPath.str), sourceLocation: sourceLocation)
    }
}
