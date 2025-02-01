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

import SWBUtil

/// Description for editing linker found dependencies.
struct DependencyInfoEditPayload: Serializable, Encodable {
    /// List of paths that need to be removed from the dependencies file if present.
    let removablePaths: Set<Path>

    /// List of file basenames which should be pruned from dependency info if present.
    let removableBasenames: Set<String>

    /// Path to the currently running Xcode location. This is used to skip linked dependencies that are part of the
    /// SDKs, and only process the linked dependencies that reside outside of the SDKs.
    let developerPath: Path

    init(removablePaths: Set<Path>, removableBasenames: Set<String>, developerPath: Path) {
        self.removablePaths = Set(removablePaths.map { $0.normalize() })
        self.removableBasenames = removableBasenames
        self.developerPath = developerPath
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(removablePaths)
            serializer.serialize(removableBasenames)
            serializer.serialize(developerPath)
        }
    }

    init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.removablePaths = try deserializer.deserialize()
        self.removableBasenames = try deserializer.deserialize()
        self.developerPath = try deserializer.deserialize()
    }
}

extension DependencyInfo {
    /// Attempts to modify itself according to the requested edit payload, and returns true iff it was modified in any
    /// way (i.e. if it requested to remove a path but it wasn't found, then it didn't get modified).
    mutating func modify(payload: DependencyInfoEditPayload, fs: any FSProxy) throws -> Bool {
        var removablePaths = Set<String>()
        var additionalPaths = Set<String>()

        for removablePath in payload.removablePaths {
            removablePaths.insert(removablePath.str)

            var destinationExists = false
            if fs.isSymlink(removablePath, &destinationExists) && destinationExists {
                let realRemovablePath = try fs.realpath(removablePath)
                removablePaths.insert(realRemovablePath.str)
            }
        }

        for input in inputs {
            guard !input.starts(with: payload.developerPath.str) else {
                continue
            }

            let inputPath = Path(input).normalize()
            var destinationExists = false
            if fs.isSymlink(inputPath, &destinationExists) && destinationExists {
                let realInput = try fs.realpath(inputPath)
                if removablePaths.contains(realInput.str) {
                    removablePaths.insert(input)
                } else {
                    additionalPaths.insert(realInput.str)
                }
            }
        }

        let removedCount = inputs.removeAll(where: { removablePaths.contains($0) }) + inputs.removeAll(where: { payload.removableBasenames.contains(Path($0).basename) })
        if !additionalPaths.isEmpty {
            inputs.append(contentsOf: additionalPaths)
        }

        return removedCount > 0 || !additionalPaths.isEmpty
    }
}
