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

public final class ClangModuleVerifierOutputParser: TaskOutputParser {
    private let task: any ExecutableTask
    private let payload: (any ClangModuleVerifierPayloadType)?

    public let workspaceContext: WorkspaceContext
    public let buildRequestContext: BuildRequestContext
    public let delegate: any TaskOutputParserDelegate

    public init(for task: any ExecutableTask, workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, delegate: any TaskOutputParserDelegate, progressReporter: (any SubtaskProgressReporter)?) {
        self.task = task
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
        self.payload = task.payload as? (any ClangModuleVerifierPayloadType)
    }

    public func write(bytes: ByteString) {
        // Forward the unparsed bytes immediately (without line buffering).
        delegate.emitOutput(bytes)

        // Disable diagnostic scraping, since we use serialized diagnostics.
    }

    public func close(result: TaskResult?) {
        defer {
            delegate.close()
        }
        // Don't try to read diagnostics if the process crashed or got cancelled as they were almost certainly not written in this case.
        if result.shouldSkipParsingDiagnostics { return }

        var serializedDiagnostics = task.type.serializedDiagnosticsPaths(task, workspaceContext.fs).flatMap { delegate.readSerializedDiagnostics(at: $0, workingDirectory: task.workingDirectory, workspaceContext: workspaceContext) }

        // Filter unwanted diagnostics.
        serializedDiagnostics.removeAll { diag in
            // Never discard diagnostics that were originally errors.
            if diag.behavior == .error {
                return false
            }
            // Filter diagnostics that are not specific to the verified module.
            // Most unrelated warnings are handled by -Wsystem-headers-in-module.
            let message = diag.data.description
            if case .path(let path, _) = diag.location {
                if path.str.contains(#/(/usr/include/|/usr/local/include|/usr/lib)/#) {
                    return true
                }
                if path.basename == "Test.h" && message.hasPrefix("missing submodule") {
                    return true
                }
            }
            if message.contains(#//[\\w.]+\\.xctoolchain/usr/lib/clang/[\\d.]+/include//#) {
                return true
            }
            if message.contains(".sdk/usr/include/c++/") {
                return true
            }

            return false
        }

        if serializedDiagnostics.isEmpty {
            return
        }

        let filenameMap: ModuleVerifierFilenameMap
        if let path = payload?.fileNameMapPath {
            filenameMap = ModuleVerifierFilenameMap(from: path, fs: workspaceContext.fs)
        } else {
            filenameMap = ModuleVerifierFilenameMap()
        }

        for diag in serializedDiagnostics {
            let updated = filenameMap.updateDiagnostic(diag)
            delegate.diagnosticsEngine.emit(updated)
        }
    }
}

extension ModuleVerifierFilenameMap {
    func updateDiagnostic(_ diag: Diagnostic) -> Diagnostic {
        let childDiagnostics = diag.childDiagnostics.map { updateDiagnostic($0) }
        let fixits = diag.fixIts.map { updateFixit($0) }
        var location = diag.location
        if case .path(let path, fileLocation: let fileLoc) = location,
           let mappedFilename = map(filename: path.str) {
            location = .path(Path(mappedFilename), fileLocation: fileLoc)
        }
        return diag.with(location: location, fixIts: fixits, childDiagnostics: childDiagnostics)
    }

    func updateFixit(_ fixit: Diagnostic.FixIt) -> Diagnostic.FixIt {
        if let mappedPath = map(filename: fixit.sourceRange.path.str) {
            return Diagnostic.FixIt(sourceRange: fixit.sourceRange.with(path: Path(mappedPath)), newText: fixit.textToInsert)
        }
        return fixit
    }
}
