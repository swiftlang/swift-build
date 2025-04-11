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
import Foundation

/// A grouping strategy that groups all asset catalogs and all strings files that match sticker packs inside those asset catalogs.
@_spi(Testing) public final class ActoolInputFileGroupingStrategy: InputFileGroupingStrategy {

    /// Group identifier that’s returned for every path.
    let groupIdentifier: String

    @_spi(Testing) public init(groupIdentifier: String) {
        self.groupIdentifier = groupIdentifier
    }

    /// Always just returns the identifier with which the grouping strategy was initialized.
    public func determineGroupIdentifier(groupable: any InputFileGroupable) -> String? {
        return groupIdentifier
    }

    public func groupAdditionalFiles<S: Sequence>(to target: FileToBuildGroup, from source: S, context: any InputFileGroupingStrategyContext) -> [FileToBuildGroup] where S.Element == FileToBuildGroup {
        // TODO Should we make this a property of the product type?
        guard context.productType?.identifier == "com.apple.product-type.app-extension.messages-sticker-pack" else { return [] }

        let catalogFileTypes = ["folder.assetcatalog", "folder.stickers"].map { context.lookupFileType(identifier: $0)! }
        let stringsFileType = context.lookupFileType(identifier: "text.plist.strings")!

        let catalogPaths = target.files.compactMap { ftb in catalogFileTypes.contains { ftb.fileType.conformsTo($0) } ? ftb.absolutePath : nil }

        // Asserting because if this grouper is used on a rule that isn't processing asset catalogs, we have a bug
        assert(!catalogPaths.isEmpty, "Expected asset catalogs in \(target.files)")

        do {
            guard let stickerPackName = try ActoolInputFileGroupingStrategy.stickerPackName(inCatalogs: catalogPaths, fs: context.fs) else { return [] }
            return source.filter { group in
                group.files.contains { file in
                    file.fileType.conformsTo(stringsFileType) && file.absolutePath.basenameWithoutSuffix == stickerPackName
                }
            }
        }
        catch {
            context.error("\(error)", location: .unknown, component: .default)
            return []
        }
    }

    /// See IBICStickerPackScanner. Note: Only one sticker pack is supported per extension; actool will warn and pick one if there are multiple, so we're just going to return the first we see.
    static func stickerPackName(inCatalogs catalogs: [Path], fs: any FSProxy) throws -> String? {
        return try catalogs.flatMap { catalog in
            return try fs.listdir(catalog).compactMap { item in
                let path = Path(item)
                return path.fileExtension.caseInsensitiveCompare("stickerpack") == .orderedSame ? path.basenameWithoutSuffix : nil
            }
        }.min() /* Use .min() instead of .first to make it deterministic. */
    }
}
