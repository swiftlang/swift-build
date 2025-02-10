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
public import struct Foundation.Date
public import struct Foundation.TimeZone
public import class Foundation.ISO8601DateFormatter
public import SWBMacro

public typealias ODRTagSet = Set<String>

public struct ODRAssetPackInfo {
    public var identifier: String
    public var tags: ODRTagSet
    public var path: Path
    public var priority: Double?

    public var infoPlistContent: PropertyListItem {
        var infoPlistContent: [String: any PropertyListItemConvertible] = [
            "CFBundleIdentifier": identifier,
            "Tags": tags.sorted(),
            ]

        if let priority {
            infoPlistContent["Priority"] = priority
        }

        return PropertyListItem(infoPlistContent)
    }

    public init(identifier: String, tags: ODRTagSet, path: Path, priority: Double?) {
        self.identifier = identifier
        self.tags = tags
        self.path = path
        self.priority = priority
    }

    public init(tags: ODRTagSet, priority: Double?, productBundleIdentifier: String, _ scope: MacroEvaluationScope) {
        let maximumAssetPackDirectoryNameLength = 240
        let onDemandResourcesSubdirectoryName = "OnDemandResources"

        self.tags = tags
        let orderedTags = tags.sorted()
        let hash: String = orderedTags.joined(separator: ":").md5()

        let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
        let unlocalizedResourcesFolderPath = scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH)
        let assetPackFolderPath = scope.evaluate(BuiltinMacros.ASSET_PACK_FOLDER_PATH)
        let productOnDemandResourcesDirectory: Path
        if !assetPackFolderPath.isEmpty {
            productOnDemandResourcesDirectory = targetBuildDir.join(assetPackFolderPath)
        }
        else if scope.evaluate(BuiltinMacros.EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE) && !unlocalizedResourcesFolderPath.isEmpty {
            let productResourcesDir = targetBuildDir.join(unlocalizedResourcesFolderPath)
            productOnDemandResourcesDirectory = productResourcesDir.join(onDemandResourcesSubdirectoryName)
        }
        else {
            productOnDemandResourcesDirectory = targetBuildDir.join(onDemandResourcesSubdirectoryName)
        }

        self.identifier = "\(productBundleIdentifier).asset-pack-\(hash)"

        let tagsString = orderedTags.joined(separator: "+")
        var namePrefix = "\(productBundleIdentifier).\(tagsString)"
        let nameSuffix = "-\(hash).assetpack"
        while namePrefix.utf8.count + nameSuffix.utf8.count > maximumAssetPackDirectoryNameLength {
            namePrefix.removeLast()
        }

        let assetPackName = "\(namePrefix)\(nameSuffix)"
        precondition(assetPackName.utf8.count <= maximumAssetPackDirectoryNameLength)

        // Get the node that represents the file system location of the top-level asset pack directory.
        self.path = productOnDemandResourcesDirectory.join(assetPackName)

        self.priority = priority
    }
}

/// Models actool's --asset-pack-output-specifications
public struct AssetPackOutputSpecificationsPlist: PropertyListItemConvertible {
    public struct Entry: Hashable {
        public var identifier: String
        public var tags: ODRTagSet
        public var path: Path
    }

    public var entries: Set<Entry>

    public init(assetPacks: [ODRAssetPackInfo]) {
        entries = Set(assetPacks.map {
            Entry(identifier: $0.identifier, tags: $0.tags, path: $0.path)
        })
    }

    public var propertyListItem: PropertyListItem {
        return .init(entries
            .sorted { $0.identifier < $1.identifier }
            .map {
                [
                    "bundle-id": .plString($0.identifier),
                    "tags": PropertyListItem($0.tags.sorted()),
                    "bundle-path": .plString($0.path.str),
                ]
            })
    }
}

/// Models OnDemandResources.plist
public struct OnDemandResourcesPlist: PropertyListItemConvertible {
    var tagsToAssetPacks: [String: Set<String>]
    var assetPacksToSubPaths: [String: Set<String>]

    public init(_ assetPacks: [ODRAssetPackInfo], subPaths: [String: Set<String>]) {
        let tagsToAssetPacks: [String: Set<String>] = {
            var result: [String: Set<String>] = [:]
            for assetPack in assetPacks {
                for tag in assetPack.tags {
                    result[tag, default: Set()].insert(assetPack.identifier)
                }
            }

            return result
        }()

        self.tagsToAssetPacks = tagsToAssetPacks
        self.assetPacksToSubPaths = subPaths.filter { !$0.1.isEmpty }
    }

    public var propertyListItem: PropertyListItem {
        return [
            "NSBundleResourceRequestTags": PropertyListItem(tagsToAssetPacks.mapValues { ["NSAssetPacks": PropertyListItem($0.sorted())] }),
            "NSBundleResourceRequestAssetPacks": PropertyListItem(assetPacksToSubPaths.mapValues { PropertyListItem($0.sorted()) }),
        ]
    }
}

/// Models AssetPackManifest[Template].plist
public struct AssetPackManifestPlist: Hashable, PropertyListItemConvertible {
    public struct Resource: Hashable, PropertyListItemConvertible {
        public enum PrimaryContentHash: Hashable, PropertyListItemConvertible {
            case modtime(Date)

            public static let modtimeFormatStyle: Date.ISO8601FormatStyle = .iso8601
                .year()
                .month()
                .day()
                .timeZone(separator: .omitted)
                .time(includingFractionalSeconds: true)
                .timeSeparator(.colon)

            public var propertyListItem: PropertyListItem {
                switch self {
                case .modtime(let date):
                    let hash = date.formatted(PrimaryContentHash.modtimeFormatStyle)

                    return PropertyListItem([
                        "strategy": "modtime",
                        "hash": hash,
                        ])
                }
            }
        }

        public var assetPackBundleIdentifier: String
        public var isStreamable: Bool
        public var primaryContentHash: PrimaryContentHash
        public var uncompressedSize: Int
        public var url: String
        public var downloadPriority: Double?

        public init(assetPackBundleIdentifier: String, isStreamable: Bool, primaryContentHash: PrimaryContentHash, uncompressedSize: Int, url: String, downloadPriority: Double?) {
            self.assetPackBundleIdentifier = assetPackBundleIdentifier
            self.isStreamable = isStreamable
            self.primaryContentHash = primaryContentHash
            self.uncompressedSize = uncompressedSize
            self.url = url
            self.downloadPriority = downloadPriority
        }

        public var propertyListItem: PropertyListItem {
            var result: [String: any PropertyListItemConvertible] = [
                "bundleKey": assetPackBundleIdentifier,
                "isStreamable": isStreamable,
                "primaryContentHash": primaryContentHash,
                "uncompressedSize": uncompressedSize,
                "URL": url,
                ]

            if let p = downloadPriority {
                result["downloadPriority"] = p
            }

            return PropertyListItem(result)
        }
    }

    public var resources: Set<Resource>

    public init(resources: Set<Resource>) {
        self.resources = resources
    }

    public var propertyListItem: PropertyListItem {
        return PropertyListItem([
            "resources": resources.sorted { $0.assetPackBundleIdentifier < $1.assetPackBundleIdentifier },
            ])
    }
}
