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

public final class LinkAssetCatalogTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        "link-assetcatalog"
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        switch task.commandLine.first?.asByteString {
        case "builtin-linkAssetCatalog":
            return performLinkAssetCatalogTaskAction(task, executionDelegate: executionDelegate, outputDelegate: outputDelegate)
        case "builtin-linkAssetCatalogSignature":
            guard let signaturePath = task.commandLine.dropFirst().first.map({ Path($0.asByteString) }) else {
                return .failed
            }

            // Write a sentinel file containing whether or not the action we just performed was for the XOJIT preview build command or not. This will cause the dependent link task to re-run whenever the build command changes. Unfortunately, we can't use a single task and getSignature to do this, because if build system caching is enabled (which it is by default), then the signature will only be computed on the first build and not recomputed on incremental builds. Similarly, isResultValid isn't useful because we'd need to somehow store the previous build command state in the BuildValue for the rule, but llbuild doesn't presently expose a way to do so in the ExternalCommand C API.
            do {
                _ = try executionDelegate.fs.writeIfChanged(signaturePath, contents: ByteString(encodingAsUTF8: executionDelegate.isXOJITPreviewBuildCommand.description))
                return .succeeded
            } catch {
                outputDelegate.emitError("\(error)")
                return .failed
            }
        default:
            outputDelegate.emitError("Unexpected command \(task.commandLine.first?.asString ?? "<nil>")")
            return .failed
        }
    }

    private func performLinkAssetCatalogTaskAction(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, outputDelegate: any TaskOutputDelegate) -> CommandResult {
        do {
            var thinnedDir: Path?
            var thinnedDependencies: Path?
            var thinnedPlist: Path?
            var unthinnedDir: Path?
            var unthinnedDependencies: Path?
            var unthinnedPlist: Path?
            var plistOutputPath: Path?
            var outputDir: Path?
            let it = task.commandLineAsStrings.dropFirst().makeIterator()
            while let arg = it.next() {
                func value() throws -> String {
                    guard let val = it.next() else {
                        throw StubError.error("Missing value for argument \(arg)")
                    }
                    return val
                }

                switch arg {
                case "--thinned":
                    thinnedDir = try Path(value())
                case "--thinned-dependencies":
                    thinnedDependencies = try Path(value())
                case "--thinned-info-plist-content":
                    thinnedPlist = try Path(value())
                case "--unthinned":
                    unthinnedDir = try Path(value())
                case "--unthinned-dependencies":
                    unthinnedDependencies = try Path(value())
                case "--unthinned-info-plist-content":
                    unthinnedPlist = try Path(value())
                case "--plist-output":
                    plistOutputPath = try Path(value())
                case "--output":
                    outputDir = try Path(value())
                default:
                    outputDelegate.emitError("Unexpected argument \(arg)")
                    return .failed
                }
            }

            guard let thinnedDir else {
                outputDelegate.emitError("No value for argument --thinned")
                return .failed
            }

            guard let thinnedDependencies else {
                outputDelegate.emitError("No value for argument --thinned-dependencies")
                return .failed
            }

            guard let thinnedPlist else {
                outputDelegate.emitError("No value for argument --thinned-info-plist-content")
                return .failed
            }

            guard let unthinnedDir else {
                outputDelegate.emitError("No value for argument --unthinned")
                return .failed
            }

            guard let unthinnedDependencies else {
                outputDelegate.emitError("No value for argument --unthinned-dependencies")
                return .failed
            }

            guard let unthinnedPlist else {
                outputDelegate.emitError("No value for argument --unthinned-info-plist-content")
                return .failed
            }

            guard let plistOutputPath else {
                outputDelegate.emitError("No value for argument --plist-output")
                return .failed
            }

            guard let outputDir else {
                outputDelegate.emitError("No value for argument --output")
                return .failed
            }

            let sourceDirectory: Path
            let sourceDependencies: Path
            let alternateSourceDirectory: Path
            let sourcePlist: Path
            if executionDelegate.isXOJITPreviewBuildCommand {
                sourceDirectory = unthinnedDir
                sourceDependencies = unthinnedDependencies
                alternateSourceDirectory = thinnedDir
                sourcePlist = unthinnedPlist
            } else {
                sourceDirectory = thinnedDir
                sourceDependencies = thinnedDependencies
                alternateSourceDirectory = unthinnedDir
                sourcePlist = thinnedPlist
            }

            try executionDelegate.fs.copyHierarchy(sourceDirectory: sourceDirectory, alternateSourceDirectory: alternateSourceDirectory, destinationDirectory: outputDir, outputDelegate: outputDelegate)

            switch task.dependencyData {
            case let .dependencyInfo(path):
                if executionDelegate.fs.exists(path) {
                    try executionDelegate.fs.remove(path)
                }
                try executionDelegate.fs.copy(sourceDependencies, to: path)
            case .makefile, .makefiles, .makefileIgnoringSubsequentOutputs,  nil:
                throw StubError.error("Unexpected dependency data style")
            }

            if executionDelegate.fs.exists(plistOutputPath) {
                try executionDelegate.fs.remove(plistOutputPath)
            }

            let contents = try executionDelegate.fs.read(sourcePlist)
            _ = try executionDelegate.fs.writeIfChanged(plistOutputPath, contents: contents)

            return .succeeded
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
    }
}

extension TaskExecutionDelegate {
    fileprivate var isXOJITPreviewBuildCommand: Bool {
        return buildCommand == .preview(style: .xojit)
    }
}

extension FSProxy {
    /// Copies a filesystem hierarchy to some destination path, using `alternateDirectory` to remove files in the destination.
    ///
    /// 1. Computes a list of relative paths representing the non-directory contents of `sourceDirectory`, "sources".
    /// 2. Computes a list of relative paths representing the non-directory contents of `alternateSourceDirectory`, "alternates".
    /// 3. Computes the set of "alternates" minus "sources", "removals".
    /// 4. Copies "sources" into `destinationDirectory`.
    /// 5. Deletes "removals" in `destinationDirectory`.
    func copyHierarchy(sourceDirectory: Path, alternateSourceDirectory: Path, destinationDirectory: Path, outputDelegate: any TaskOutputDelegate) throws {
        let sourceDirectoryRelativePaths = try relativeFilePaths(directory: sourceDirectory)
        for subpath in sourceDirectoryRelativePaths {
            let dst = destinationDirectory.join(subpath)
            try createDirectory(dst.dirname)
            if exists(dst) {
                try remove(dst)
            }
            try copy(sourceDirectory.join(subpath), to: dst)
            outputDelegate.emitNote("Emplaced \(dst.str)")
        }

        if exists(alternateSourceDirectory) {
            let removableRelativePaths = try relativeFilePaths(directory: alternateSourceDirectory).subtracting(sourceDirectoryRelativePaths)
            for subpath in removableRelativePaths {
                let dst = destinationDirectory.join(subpath)
                try remove(dst)
                outputDelegate.emitNote("Removed \(dst.str)")
            }
        }
    }

    func relativeFilePaths(directory: Path) throws -> Set<Path> {
        try Set(traverse(directory) { path -> Path? in
            guard !isDirectory(path) else {
                return nil
            }
            guard let subpath = path.relativeSubpath(from: directory) else {
                throw StubError.error("Could not compute path of \(path.str) relative to \(directory.str)")
            }
            return Path(subpath)
        })
    }
}
