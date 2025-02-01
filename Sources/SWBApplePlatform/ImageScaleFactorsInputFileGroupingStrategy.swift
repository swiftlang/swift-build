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

// FIXME: Presently we have no good way during grouping to detect whether we're matching a single file against tiffutil or multiple files against tiffutil.  In principle we could handle that in FilesBasedBuildPhaseTaskProducer once all grouping is completed.  But at present this is handled in a hackier manner in TiffUtilToolSpec.constructTasks() - see the FIXME comment therein for more about this.
//
/// A grouping strategy that groups image files containing scale factors of the form "@<n>x" at the end of their base names.
@_spi(Testing) public final class ImageScaleFactorsInputFileGroupingStrategy : InputFileGroupingStrategy {

    /// Name of the tool to which the grouping strategy belongs (used as a part of the returned group identifier).
    let toolName: String

    @_spi(Testing) public init(toolName: String) {
        self.toolName = toolName
    }

    public func determineGroupIdentifier(groupable: any InputFileGroupable) -> String? {
        // Work with the path without the '.extension'.  Note that this is the full path without the extension, not just the basename of the last path component.
        // Note that we always end up including the suffix in the identifier, since we don't want to group files of different types together in the same command.
        let path = groupable.absolutePath
        let pathWithoutSuffix = path.withoutSuffix

        // This logic walks backwards over the end of the path-without-extension looking for the '@<n>x' marker.  If it at any point determines there isn't such a marker then it returns the original path.  If it does find the marker, then it returns the path without the marker.
        var idx = pathWithoutSuffix.endIndex
        guard idx > pathWithoutSuffix.startIndex else { return "tool:\(toolName) file-base:\(path.str)" }
        idx = pathWithoutSuffix.index(before: idx)
        guard pathWithoutSuffix[idx] == "x" else { return "tool:\(toolName) file-base:\(path.str)" }
        guard idx > pathWithoutSuffix.startIndex else { return "tool:\(toolName) file-base:\(path.str)" }
        idx = pathWithoutSuffix.index(before: idx)
        guard pathWithoutSuffix[idx] == "1" || pathWithoutSuffix[idx] == "2" || pathWithoutSuffix[idx] == "3" else { return "tool:\(toolName) file-base:\(path.str)" }
        guard idx > pathWithoutSuffix.startIndex else { return "tool:\(toolName) file-base:\(path.str)" }
        idx = pathWithoutSuffix.index(before: idx)
        guard pathWithoutSuffix[idx] == "@" else { return "tool:\(toolName) file-base:\(path.str)" }
        guard idx > pathWithoutSuffix.startIndex else { return "tool:\(toolName) file-base:\(path.str)" }
        return "tool:\(toolName) file-base:\(pathWithoutSuffix[pathWithoutSuffix.startIndex..<idx])\(path.fileSuffix)"
    }
}
