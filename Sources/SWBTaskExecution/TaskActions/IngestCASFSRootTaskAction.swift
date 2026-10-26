//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBCore
import SWBUtil
import Foundation

public final class IngestCASFSRootTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "ingest-casfs-root"
    }

    public override func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        let payload = task.payload as! IngestCASFSRootTaskPayload
        let operationCtx = dynamicExecutionDelegate.operationContext
        let graph = operationCtx.swiftModuleDependencyGraph

        let environment: [String: String]
        if let executionEnvironment = executionDelegate.environment {
            environment = executionEnvironment.merging(task.environment.bindingsDictionary, uniquingKeysWith: { a, b in b })
        } else {
            environment = task.environment.bindingsDictionary
        }

        do {
            let casdb = try graph.getOrCreateCASDatabases(casOptions: payload.casOpts, compilerLocation: payload.compilerLocation, environment: environment)
            let fs = executionDelegate.fs

            struct FSGroup {
                let rootPath: Path
                let paths: [Path]
                let searchPaths: [Path]
                let searchPathIngestionDepth: Int
                var unresolvedRoots: [Path]
                var resolvedRoots: [String]
            }

            func readFSGroup(_ path: Path) throws -> FSGroup {
                let casFSDesc: CASFSDescription
                do {
                    casFSDesc = try JSONDecoder().decode(CASFSDescription.self, from: Data(fs.read(path)))
                } catch {
                    throw StubError.error("failed reading '\(path.str)' : \(error.localizedDescription)")
                }
                return FSGroup(
                    rootPath: path,
                    paths: casFSDesc.paths,
                    searchPaths: casFSDesc.searchPaths,
                    searchPathIngestionDepth: casFSDesc.searchPathIngestionDepth,
                    unresolvedRoots: casFSDesc.roots,
                    resolvedRoots: []
                )
            }

            func performIngestion() throws -> String {
                var fsGroups: [FSGroup] = [try readFSGroup(Path(task.commandLine[2].asByteString))]

                while true {
                    let lastGroup = fsGroups.endIndex - 1
                    if let unresolvedRoot = fsGroups[lastGroup].unresolvedRoots.popLast() {
                        if let rootID = operationCtx.getCachedCASFSIngestion(unresolvedRoot) {
                            fsGroups[lastGroup].resolvedRoots.append(rootID)
                        } else {
                            // FIXME: Shouldn't happen
                            guard fs.exists(unresolvedRoot) else {
                                continue
                            }
                            fsGroups.append(try readFSGroup(unresolvedRoot))
                        }
                    } else {
                        let casFSBuilder = try casdb.createCASFSBuilder()
                        for path in fsGroups[lastGroup].paths {
                            try casFSBuilder.ingestPath(path.str, recursive: false)
                        }
                        for root in fsGroups[lastGroup].resolvedRoots {
                            try casFSBuilder.mergeRoot(root)
                        }
                        // Only ingest header and module map files from the search paths.
                        func isSourceFile(_ path: Path) -> Bool {
                            return [
                                "modulemap",
                                "h", "hpp",
                            ].contains(path.fileExtension)
                        }
                        let maxDepth = fsGroups[lastGroup].searchPathIngestionDepth
                        func addSearchPathImpl(_ path: Path, depth: Int, _ casFSBuilder: SwiftCASFSBuilder) throws {
                            if fs.isSymlink(path) {
                                try casFSBuilder.ingestPath(path.str, recursive: false)
                                return
                            }
                            if try fs.isFile(path) {
                                if isSourceFile(path) {
                                    try casFSBuilder.ingestPath(path.str, recursive: false)
                                }
                                return
                            }
                            // Only recurse a limited number of times inside a search path directory to avoid ingesting too many files.
                            // By default (`CAS_SANDBOX_SEARCH_PATH_INGESTION_DEPTH` of 1), for a "<PATH>" search path, it will ingest
                            // "<PATH>/mymodule/myheader.h" but not "<PATH>/SomethingElse/whatever/header.h".
                            // This is not just to reduce ingestion load but also to reduce the surface area of input files that
                            // are affecting the module and its cache hits, encouraging project configurations to be more precise
                            // in the search paths they choose.
                            if depth <= maxDepth && fs.isDirectory(path) {
                                let subEntries = try fs.listdir(path).map{ path.join($0) }
                                for entry in subEntries {
                                    try addSearchPathImpl(entry, depth: depth + 1, casFSBuilder)
                                }
                            }
                        }
                        func addSearchPath(_ path: Path) throws -> String {
                            if let rootID = operationCtx.getCachedCASFSSearchPathIngestion(path, depth: maxDepth) {
                                return rootID
                            }
                            let casFSBuilder = try casdb.createCASFSBuilder()
                            try addSearchPathImpl(path, depth: 0, casFSBuilder)
                            let rootID = try casFSBuilder.finish()
                            operationCtx.setCachedCASFSSearchPathIngestion(path, depth: maxDepth, rootID: rootID)
                            return rootID
                        }
                        for searchPath in fsGroups[lastGroup].searchPaths {
                            if fs.exists(searchPath) {
                                let rootID = try addSearchPath(searchPath)
                                try casFSBuilder.mergeRoot(rootID)
                            }
                        }
                        let rootID = try casFSBuilder.finish()
                        operationCtx.setCachedCASFSIngestion(fsGroups[lastGroup].rootPath, rootID: rootID)
                        fsGroups.removeLast()
                        guard !fsGroups.isEmpty else {
                            return rootID
                        }
                        fsGroups[fsGroups.endIndex - 1].resolvedRoots.append(rootID)
                    }
                }
            }

            let rootID = try performIngestion()
            _ = try localFS.writeIfChanged(task.outputPaths[0], contents: ByteString(encodingAsUTF8: rootID))
            outputDelegate.emitOutput(ByteString(encodingAsUTF8: rootID))

            return .succeeded
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }
    }
}
