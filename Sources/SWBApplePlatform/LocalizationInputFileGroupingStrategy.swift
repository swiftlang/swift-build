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

/// A grouping strategy that groups all files with the same region variant (including a group for unlocalized files).
@_spi(Testing) public final class LocalizationInputFileGroupingStrategy: InputFileGroupingStrategy {
    /// Name of the tool to which the grouping strategy belongs (used as a part of the returned group identifier).
    let toolName: String

    @_spi(Testing) public init(toolName: String) {
        self.toolName = toolName
    }

    public func determineGroupIdentifier(groupable: any InputFileGroupable) -> String? {
        return "tool:\(toolName) region:\(groupable.regionVariantName ?? "")"
    }
}
