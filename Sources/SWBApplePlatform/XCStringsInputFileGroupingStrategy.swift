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

public import SWBCore
import SWBUtil

/// A grouping strategy that places each xcstrings table in its own group, along with any other .strings or .stringsdicts with the same basename.
///
/// Having .xcstrings and .strings with the same basename in the same target is currently an unsupported configuration, so we group them to be able to diagnose that error downstream.
/// This also enables us to catch issues where more than one same-named .xcstrings file exists in the same target. That would ordinarily cause an error downstream, but is not guaranteed if the files contain only strings that don't actually need to build.
@_spi(Testing) public final class XCStringsInputFileGroupingStrategy: InputFileGroupingStrategy {

    let toolName: String

    @_spi(Testing) public init(toolName: String) {
        self.toolName = toolName
    }

    public func determineGroupIdentifier(groupable: any InputFileGroupable) -> String? {
        // Each xcstrings table gets its own group.
        return "tool:\(toolName) name:\(groupable.absolutePath.basenameWithoutSuffix)"
    }

    public func groupAdditionalFiles<S>(to target: FileToBuildGroup, from source: S, context: any InputFileGroupingStrategyContext) -> [FileToBuildGroup] where S : Sequence, S.Element == FileToBuildGroup {
        // Additionally include .strings and .stringsdict files with the same basename.

        guard let xcstringsBasenameWithoutSuffix = Set(target.files.map({ $0.absolutePath.basenameWithoutSuffix })).only else {
            assertionFailure("Expected same-named xcstrings files in \(target.files).")
            return []
        }

        let stringsFileTypes = ["text.plist.strings", "text.plist.stringsdict"].map { context.lookupFileType(identifier: $0)! }
        return source.filter { group in
            group.files.contains { file in
                file.fileType.conformsToAny(stringsFileTypes) && file.absolutePath.basenameWithoutSuffix == xcstringsBasenameWithoutSuffix
            }
        }
    }

}
