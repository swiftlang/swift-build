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
import SWBLibc
import SWBUtil
import struct Foundation.CharacterSet
import struct Foundation.Date
import class Foundation.DateFormatter
import typealias Foundation.TimeInterval
import SWBMacro

public final class ODRAssetPackManifestTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "create-asset-pack-manifest"
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        let env = task.environment.bindingsDictionary
        let assetPackManifestURLPrefix = env[BuiltinMacros.ASSET_PACK_MANIFEST_URL_PREFIX.name] ?? ""
        let embedAssetPacksInProductBundle = env[BuiltinMacros.EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE.name]?.boolValue ?? false
        let unlocalizedProductResourcesDir = Path(env[BuiltinMacros.UnlocalizedProductResourcesDir.name]!)
        let outputPath = Path(env[BuiltinMacros.OutputPath.name]!)
        let allowedChars = CharacterSet(charactersIn: "+,-./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~")

        let makeURL = { (assetPackPath: Path) throws -> String in
            if !assetPackManifestURLPrefix.isEmpty {
                // a) if ASSET_PACK_MANIFEST_URL_PREFIX is set to anything other than the empty string, we use it, and append the name of the asset pack to it (note that we do -not- insert a path separator, to allow prefixes like "http://myserver/script?pack=").
                guard let suffix = assetPackPath.basename.addingPercentEncoding(withAllowedCharacters: allowedChars) else { throw StubError.error("could not percent-encode \(assetPackPath.basename)") }
                return assetPackManifestURLPrefix.appending(suffix)
            }
            else if embedAssetPacksInProductBundle {
                // b) otherwise, if the ASSET_PACK_FOLDER_PATH path is inside the Resources directory of the main product bundle, we use the relative path to that Resources directory as the URL,
                guard let subPath = assetPackPath.relativeSubpath(from: unlocalizedProductResourcesDir) else { throw StubError.error("expected path \(assetPackPath.str) to be a subpath of \(unlocalizedProductResourcesDir.str)") }
                return subPath
            }
            else {
                // c) otherwise, we use a full http://127.0.0.1/full/path.assetpack path with an absolute path to the asset pack
                guard let suffix = assetPackPath.str.addingPercentEncoding(withAllowedCharacters: allowedChars) else { throw StubError.error("could not percent-encode \(assetPackPath.str)") }
                return "http://127.0.0.1".appending(suffix)
            }
        }

        do {
            let resources = try task.commandLineAsStrings.map { assetPackPath -> AssetPackManifestPlist.Resource in
                let path = Path(assetPackPath)
                let infoPlistPath = path.join("Info.plist")

                let infoPlist: PropertyListItem
                do {
                    infoPlist = try PropertyList.fromPath(infoPlistPath, fs: executionDelegate.fs)
                }
                catch {
                    throw StubError.error("failed to load \(infoPlistPath.str): \(error)")
                }

                guard case .plDict(let dict) = infoPlist else { throw StubError.error("expected dictionary in \(infoPlistPath.str)") }
                guard case .plString(let identifier)? = dict["CFBundleIdentifier"] else { throw StubError.error("expected string in \(infoPlistPath.str) : CFBundleIdentifier") }

                let priority: Double?
                if let priorityItem = dict["Priority"] {
                    guard case .plDouble(let p) = priorityItem else { throw StubError.error("expected number in \(infoPlistPath.str) : Priority") }
                    priority = p
                }
                else {
                    priority = nil
                }

                let url = try makeURL(path)
                let isStreamable = url.hasPrefix("http:") || url.hasPrefix("https:")

                let (uncompressedSize, modTimeDate) = try executionDelegate.fs.computeStats(path)

                return AssetPackManifestPlist.Resource(assetPackBundleIdentifier: identifier, isStreamable: isStreamable, primaryContentHash: .modtime(modTimeDate), uncompressedSize: uncompressedSize, url: url, downloadPriority: priority)
            }

            let plistData = try AssetPackManifestPlist(resources: Set(resources)).propertyListItem.asBytes(.binary)
            try executionDelegate.fs.write(outputPath, contents: ByteString(plistData))
        }
        catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }

        return .succeeded
    }
}

fileprivate extension FSProxy {
    func computeStats(_ path: Path) throws -> (uncompressedSize: Int, newestModTime: Date) {
        var uncompressedSize: Int = 0
        var newestModTime: Date = .distantPast

        try traverse(path) { subPath -> Void in
            let info = try getLinkFileInfo(subPath)
            uncompressedSize += Int(info.statBuf.st_size)
            newestModTime = max(newestModTime, info.modificationDate)
        }

        return (uncompressedSize, newestModTime)
    }
}
