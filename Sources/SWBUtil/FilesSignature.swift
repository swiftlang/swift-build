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

import SWBLibc

/// Represents an opaque signature of a list of files.
///
/// If any path is a directory, the directory hierarchy is recursively traversed and all files in the hierarchy are collected to add to the signature.
///
/// The signature returned is a byte string constructed from an MD5 of properties of all of the files, so the order of `paths` is significant, and a different signature may be returned for different orderings.
public struct FilesSignature: Hashable, Encodable, Sendable {
    fileprivate let signature: ByteString

    public init(_ paths: [Path], fs: any FSProxy = localFS) {
        signature = fs.filesSignature(paths)
    }

    /// Whether the signatures are equivalent.
    public static func == (lhs: FilesSignature, rhs: FilesSignature) -> Bool {
        return lhs.signature == rhs.signature
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(signature)
    }
}

extension FilesSignature: SerializableCodable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serialize(signature)
    }

    public init(from deserializer: any Deserializer) throws {
        signature = try deserializer.deserialize()
    }
}

fileprivate extension FSProxy {
    /// Returns the signature of a list of files.
    ///
    /// If any path is a directory, then this method recursively traverses the directory hierarchy and collects all files in the hierarchy to add to the signature.
    ///
    /// The signature returned is a byte string constructed from an MD5 of properties of all of the files, so the order of `paths` is significant, and a different signature may be returned for different orderings.
    func filesSignature(_ paths: [Path]) -> ByteString {
        var stats: [(Path, stat?)] = []
        for path in paths {
            if isDirectory(path) {
                do {
                    try traverse(path) { subPath in
                        stats.append((subPath, try? getFileInfo(subPath).statBuf))
                    }
                } catch {
                    stats.append((path, nil))
                }
            } else {
                stats.append((path, try? getFileInfo(path).statBuf))
            }
        }

        return filesSignature(stats)
    }

    /// Returns the signature of a list of files.
    func filesSignature(_ statInfos: [(Path, stat?)]) -> ByteString {
        let md5Context = InsecureHashContext()
        for (path, statInfo) in statInfos {
            md5Context.add(string: path.str)
            if let statInfo {
                md5Context.add(string: "stat")
                md5Context.add(number: statInfo.st_ino)
                md5Context.add(number: statInfo.st_dev)
                md5Context.add(number: statInfo.st_size)
                md5Context.add(number: statInfo.st_mtimespec.tv_sec)
                md5Context.add(number: statInfo.st_mtimespec.tv_nsec)
            } else {
                md5Context.add(string: "<missing>")
            }
        }
        return md5Context.signature
    }
}
