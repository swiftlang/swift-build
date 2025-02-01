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

public final class VFS {
    final class Directory {
        var children: [String: Directory] = [:]
        var externalContents: [String: Path] = [:]
    }

    let root = Directory()

    public init() {
    }

    private func getDirectory(_ path: Path) -> Directory {
        if path.isRoot {
            return root
        }

        let basename = path.basename
        let parent = getDirectory(path.dirname)
        if let child = parent.children[basename] {
            return child
        }
        let directory = Directory()
        parent.children[basename] = directory

        return directory
    }

    public func addMapping(_ virtualPath: Path, externalContents: Path) {
        let parent = getDirectory(virtualPath.dirname)
        parent.externalContents[virtualPath.basename] = externalContents
    }

    public func toVFSOverlay() -> VFSOverlay {
        // Gather the complete, ordered, flat list of non-empty directories.
        func gatherAllDirectories(_ path: Path, _ directory: Directory, _ result: inout [(path: Path, directory: Directory)]) {
            // Visit all children.
            for (key: name, value: child) in directory.children.sorted(byKey: <) {
                gatherAllDirectories(path.join(name), child, &result)
            }

            // Only add non-empty directories.
            if !directory.externalContents.isEmpty {
                result.append((path, directory))
            }
        }
        var allDirectories = [(path: Path, directory: Directory)]()
        gatherAllDirectories(.root, root, &allDirectories)

        return VFSOverlay(version: 0, caseSensitive: false, roots: allDirectories.map { path, directory in
            VFSOverlay.Root(name: path.str, contents: directory.externalContents.sorted(byKey: <).map { name, path in
                VFSOverlay.Root.Contents(name: name, externalContents: path.str)
            })
        })
    }
}

@available(*, unavailable)
extension VFS: Sendable { }

public struct VFSOverlay: PropertyListItemConvertible, Sendable {
    struct Root: PropertyListItemConvertible {
        struct Contents: PropertyListItemConvertible {
            let type = "file"
            let name: String
            let externalContents: String

            var propertyListItem: PropertyListItem {
                return .plDict([
                    "type": type.propertyListItem,
                    "name": name.propertyListItem,
                    "external-contents": externalContents.propertyListItem
                ])
            }
        }

        let type = "directory"
        let name: String
        let contents: [Contents]

        var propertyListItem: PropertyListItem {
            return .plDict([
                "type": type.propertyListItem,
                "name": name.propertyListItem,
                "contents": contents.propertyListItem
            ])
        }
    }

    let version: Int
    let caseSensitive: Bool
    let roots: [Root]

    public var propertyListItem: PropertyListItem {
        return .plDict([
            "version": version.propertyListItem,
            "case-sensitive": String(caseSensitive).propertyListItem, // serialized as string for some reason
            "roots": roots.propertyListItem
        ])
    }
}

public struct DirectoryRemapVFSOverlay: PropertyListItemConvertible, Sendable {
    public enum RedirectingWith: String, Sendable {
        case fallback = "fallback"
        case `fallthrough` = "fallthrough"
        case redirectOnly = "redirect-only"
    }

    public struct Remap: PropertyListItemConvertible, Sendable {
        public let name: String
        public let externalContents: String

        public init(name: String, externalContents: String) {
            self.name = name
            self.externalContents = externalContents
        }

        public var propertyListItem: PropertyListItem {
            return .plDict([
                "type": "directory-remap".propertyListItem,
                "name": name.propertyListItem,
                "external-contents": externalContents.propertyListItem
            ])
        }
    }

    public let version: Int
    public let caseSensitive: Bool
    public let redirectingWith: RedirectingWith
    public let remapping: [Remap]

    public init(version: Int, caseSensitive: Bool, redirectingWith: RedirectingWith, remapping: [Remap]) {
        self.version = version
        self.caseSensitive = caseSensitive
        self.redirectingWith = redirectingWith
        self.remapping = remapping
    }

    public var propertyListItem: PropertyListItem {
        let values = [
            "version": version.propertyListItem,
            "case-sensitive": String(caseSensitive).propertyListItem, // serialized as string for some reason
            "redirecting-with": redirectingWith.rawValue.propertyListItem,
            "roots": remapping.propertyListItem
        ]
        return .plDict(values)
    }
}
