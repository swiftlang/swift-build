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
import Foundation
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// A CAS object representing a filesystem node
public struct CASFSNode<CAS: CASProtocol>: Sendable {
    private enum Errors: Error {
        case pathDoesNotExist(Path)
        case cannotImportUnsupportedFSObject(Path)
        case missingCASObject(CAS.DataID)
        case deserializationError(String)
    }

    private enum Content {
        case directory(DirectoryContent)
        case symlink(SymlinkContent)
        case file(FileContent)
    }

    private struct DirectoryContent {
        let name: String
        // TODO: user, mode, group, etc.
        let entries: [CAS.DataID]
    }

    private struct SymlinkContent: Serializable {
        let name: String
        // TODO: user, mode, group, etc.
        let destination: Path

        init(name: String, destination: Path) {
            self.name = name
            self.destination = destination
        }

        func serialize<T>(to serializer: T) where T : SWBUtil.Serializer {
            serializer.beginAggregate(2)
            serializer.serialize(name)
            serializer.serialize(destination)
            serializer.endAggregate()
        }

        init(from deserializer: any SWBUtil.Deserializer) throws {
            try deserializer.beginAggregate(2)
            self.name = try deserializer.deserialize()
            self.destination = try deserializer.deserialize()
        }
    }

    private struct FileContent {
        let filename: String
        let chunkSize: Int64
        // TODO: user, mode, group, etc.
        let chunks: [CAS.DataID]

        init(filename: String, chunkSize: Int64, chunks: [CAS.DataID]) {
            self.filename = filename
            self.chunkSize = chunkSize
            self.chunks = chunks
        }
    }

    private let content: Content

    private var name: String {
        switch content {
        case .directory(let directoryContent):
            return directoryContent.name
        case .symlink(let symlinkContent):
            return symlinkContent.name
        case .file(let fileContent):
            return fileContent.filename
        }
    }

    public static func `import`(path: Path, fs: any FSProxy, cas: CAS) async throws -> CAS.DataID {
        guard fs.exists(path) else {
            throw Errors.pathDoesNotExist(path)
        }
        if fs.isSymlink(path) {
            let node = CASFSNode(content: .symlink(.init(name: path.basename, destination: try fs.readlink(path))))
            return try await node.store(cas: cas)
        } else if fs.isDirectory(path) {
            let entries = try await fs.listdir(path).concurrentMap(maximumParallelism: 10) { item in
                try await CASFSNode.import(path: path.join(item), fs: fs, cas: cas)
            }
            let node = CASFSNode(content: .directory(.init(name: path.basename, entries: entries)))
            return try await node.store(cas: cas)
        } else if try fs.isFile(path) {
            var chunks: [CAS.DataID] = []
            let chunkSize: Int64
            if let mappedData = try? fs.readMemoryMapped(path) {
                chunkSize = Int64(1024 * 1024 * 4)
                let (q, r) = mappedData.count.quotientAndRemainder(dividingBy: numericCast(chunkSize))
                let numChunks = q + ((r > 0) ? 1 : 0)
                chunks = try await (0..<numChunks).concurrentMap(maximumParallelism: 10) { chunkNum in
                    let start = Int(chunkNum) * Int(chunkSize)
                    let end = Int(min((chunkNum + 1) * numericCast(chunkSize), mappedData.count))
                    let bytes = mappedData[(mappedData.startIndex + start)..<(mappedData.startIndex + end)]
                    return try await cas.store(object: .init(data: ByteString(bytes), refs: []))
                }
            } else {
                let contents = try fs.read(path)
                chunkSize = Int64(contents.count)
                chunks.append(try await cas.store(object: .init(data: contents, refs: [])))
            }
            let node = CASFSNode(content: .file(.init(filename: path.basename, chunkSize: chunkSize, chunks: chunks)))
            return try await node.store(cas: cas)
        } else {
            throw Errors.cannotImportUnsupportedFSObject(path)
        }
    }

    public func export(at path: Path, fs: any FSProxy, cas: CAS) async throws {
        guard fs.exists(path.dirname) else {
            throw Errors.pathDoesNotExist(path.dirname)
        }
        switch content {
        case .directory(let directoryContent):
            try fs.createDirectory(path)
            _ = try await directoryContent.entries.concurrentMap(maximumParallelism: 10) { entry in
                let entryNode = try await CASFSNode.load(id: entry, cas: cas)
                try await entryNode.export(at: path.join(entryNode.name), fs: fs, cas: cas)
            }
        case .symlink(let symlinkContent):
            try fs.symlink(path, target: symlinkContent.destination)
        case .file(let fileContent):
            do {
                try await fs.write(path) { fd in
                    _ = try await fileContent.chunks.enumerated().asyncMap { (index, chunk) in
                        guard let casObject = try await cas.load(id: chunk) else {
                            throw Errors.missingCASObject(chunk)
                        }
                        try fd.writeAll(toAbsoluteOffset: Int64(index) * fileContent.chunkSize, casObject.data)
                    }
                }
            } catch {
                var content = ByteString()
                for chunk in fileContent.chunks {
                    guard let casObject = try await cas.load(id: chunk) else {
                        throw Errors.missingCASObject(chunk)
                    }
                    content += casObject.data
                }
                try fs.write(path, contents: content)
            }
        }
    }

    public func export(into path: Path, fs: any FSProxy, cas: CAS) async throws {
        try await export(at: path.join(name), fs: fs, cas: cas)
    }

    private func store(cas: CAS) async throws -> CAS.DataID {
        let dataSerializer = MsgPackSerializer()
        var refs: [CAS.DataID] = []
        switch content {
        case .directory(let directoryContent):
            dataSerializer.serialize(0)
            dataSerializer.serialize(directoryContent.name)
            refs = directoryContent.entries
        case .symlink(let symlinkContent):
            dataSerializer.serialize(1)
            dataSerializer.serialize(symlinkContent)
        case .file(let fileContent):
            dataSerializer.serialize(2)
            dataSerializer.serialize(fileContent.filename)
            dataSerializer.serialize(fileContent.chunkSize)
            refs = fileContent.chunks
        }
        return try await cas.store(object: .init(data: dataSerializer.byteString, refs: refs))
    }

    public static func load(id: CAS.DataID, cas: CAS) async throws -> CASFSNode {
        guard let casObject = try await cas.load(id: id) else {
            throw Errors.missingCASObject(id)
        }
        let deserializer = MsgPackDeserializer(casObject.data)
        switch try deserializer.deserialize() as Int {
        case 0:
            return CASFSNode(content: .directory(.init(name: try deserializer.deserialize(), entries: casObject.refs)))
        case 1:
            return CASFSNode(content: .symlink(try deserializer.deserialize()))
        case 2:
            let filename: String = try deserializer.deserialize()
            let chunkSize: Int64 = try deserializer.deserialize()
            return CASFSNode(content: .file(.init(filename: filename, chunkSize: chunkSize, chunks: casObject.refs)))
        default:
            throw Errors.deserializationError("Unknown content type")
        }
    }
}
