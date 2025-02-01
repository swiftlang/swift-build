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
public import SWBProtocol
public import SWBMacro

/// Aggregate index for all the statically known header files present in a workspace.
///
/// This class handles collecting information on all of the header files present in the workspace structure and how they are used in each of the targets present in the workspace. It is used to drive the production of headermap and Clang virtual file system (VFS) content.
///
/// This object needs to be computed as an initial part of the build. Care should be taken to *only* use it to compute global information which can be effectively cached and which is truly necessary to be computed in a global fashion.
public final class WorkspaceHeaderIndex: Sendable {
    public let projectHeaderInfo: [Project: ProjectHeaderInfo]

    /// Construct the header index for a workspace.
    @_spi(Testing) public init(core: Core, workspace: Workspace) async {
        self.projectHeaderInfo = await Dictionary(uniqueKeysWithValues: workspace.projects.concurrentMap(maximumParallelism: 10) { project in
            await (project, ProjectHeaderInfo(core, project, workspace))
        })
    }
}

/// Information on the headers referenced by an individual project.
public struct ProjectHeaderInfo: Sendable {
    /// The ordered list of all header file references in the workspace.
    public let knownHeaders: OrderedSet<FileReference>

    /// The per-target table of known header files.
    public let targetHeaderInfo: [BuildPhaseTarget: TargetHeaderInfo]

    // The set of known header extensions, for backwards compatibility.
    //
    // FIXME: Move to standard place.
    public static let headerFileExtensions = Set<String>(["h", "H", "hxx", "HXX", "i", "I", "hpp", "HPP", "ipp", "IPP"])

    fileprivate init(_ core: Core, _ project: Project, _ workspace: Workspace) async {
        /// Check if a file reference should be treated as a header file.
        func isHeaderReference(_ fileRef: FileReference) -> Bool {
            // Check if the extension matches. Note that we do not use the full resolved path here, it would be too expensive.
            //
            // This is for compatibility purposes, but currently is more efficient than the subsequent check so we do it first.
            let ext = fileRef.path.stringRep.split(".").1
            if ProjectHeaderInfo.headerFileExtensions.contains(ext) {
                return true
            }

            // Check if the type matches.
            //
            // FIXME: Optimize this.
            guard let fileType = core.specRegistry.getSpec(fileRef.fileTypeIdentifier) as? FileTypeSpec else {
                return false
            }
            for headerType in core.specRegistry.headerFileTypes {
                if fileType.conformsTo(headerType) {
                    return true
                }
            }

            return false
        }
        func collectKnownHeaders(_ ref: Reference, _ headers: inout OrderedSet<FileReference>) {
            switch ref {
            case let group as FileGroup:
                // Traverse groups.
                for child in group.children {
                    collectKnownHeaders(child, &headers)
                }

            case let file as FileReference:
                // Check if this is a header file reference.
                if isHeaderReference(file) {
                    headers.append(file)
                }

            default:
                // Ignore all other types.
                //
                // FIXME: Ensure we don't need to traverse the custom group types.
                return
            }
        }


        // Construct the set of known header files.
        let knownHeaders = {
            var knownHeaders = OrderedSet<FileReference>()
            collectKnownHeaders(project.groupTree, &knownHeaders)
            return knownHeaders
        }()
        self.knownHeaders = knownHeaders

        // Collect the per target information.
        self.targetHeaderInfo = await Dictionary(uniqueKeysWithValues: project.targets.concurrentMap(maximumParallelism: 100, { target -> (BuildPhaseTarget, TargetHeaderInfo)? in
            if case let target as BuildPhaseTarget = target, let headerInfo = TargetHeaderInfo(target, knownHeaders, workspace) {
                return (target, headerInfo)
            }
            return nil
        }).compactMap { $0 })
    }
}

/// Information on the headers referenced by an individual target.
public struct TargetHeaderInfo: Sendable {
    public struct Entry: Sendable {
        public let fileReference: FileReference
        public let platformFilters: Set<PlatformFilter>
    }
    /// The list of target's public header source files.
    public let publicHeaders: [Entry]

    /// The list of target's private header source files.
    public let privateHeaders: [Entry]

    /// The list of target's project header source files.
    public let projectHeaders: [Entry]

    fileprivate init?(_ target: BuildPhaseTarget, _ knownHeaders: OrderedSet<FileReference>, _ workspace: Workspace) {
        // Ignore targets without a headers phase.
        guard let headersPhase = target.headersBuildPhase else { return nil }

        // FIXME: We should probably only examine targets which are actually in the current project (i.e., not ones which are target references). This shows up in Xcode w.r.t. the headermaps, we need to figure out where it fits in.

        // Build the collated lists of header types.
        var publicHeaders = [Entry]()
        var privateHeaders = [Entry]()
        var projectHeaders = [Entry]()
        for buildFile in headersPhase.buildFiles {
            // Ignore non-file references.
            guard case let .reference(guid) = buildFile.buildableItem,
                  let reference = workspace.lookupReference(for: guid),
                  let fileRef = reference as? FileReference else { continue }

            // If we don't have any entry for the target, ignore it.
            //
            // FIXME: Ensure we have a test case for this, I think it comes up for projects which have other files in their headers phase.
            guard knownHeaders.contains(fileRef) else { continue }

            switch buildFile.headerVisibility {
            case .public?:
                publicHeaders.append(.init(fileReference: fileRef, platformFilters: buildFile.platformFilters))
            case .private?:
                privateHeaders.append(.init(fileReference: fileRef, platformFilters: buildFile.platformFilters))
            case nil:
                projectHeaders.append(.init(fileReference: fileRef, platformFilters: buildFile.platformFilters))
            }
        }
        self.publicHeaders = publicHeaders
        self.privateHeaders = privateHeaders
        self.projectHeaders = projectHeaders
    }

    public struct HeaderDestDirs {
        public let publicPath : Path
        public let privatePath : Path
        public let basePath : Path

        public init(publicPath: Path, privatePath: Path, basePath: Path ) {
            self.publicPath = publicPath
            self.privatePath = privatePath
            self.basePath = basePath
        }
    }

    /// Utility method that generate top level directory paths for headers. This is primarily for the usecase
    /// of referencing headers instead of writing to the returned location.
    public static func builtProductDestDirs(scope: MacroEvaluationScope, workingDirectory: Path) -> HeaderDestDirs {
        var buildDirPath = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR)
        buildDirPath = buildDirPath.makeAbsolute(relativeTo: workingDirectory) ?? buildDirPath
        let wrapperPath = buildDirPath.join(scope.evaluate(BuiltinMacros.WRAPPER_NAME))
        let publicHeadersPath = scope.evaluate(BuiltinMacros.PUBLIC_HEADERS_FOLDER_PATH)
        let privateHeadersPath = scope.evaluate(BuiltinMacros.PRIVATE_HEADERS_FOLDER_PATH)

        return HeaderDestDirs(publicPath: wrapperPath.join(publicHeadersPath.basename),
                              privatePath: wrapperPath.join(privateHeadersPath.basename),
                              basePath: wrapperPath)
    }

    /// Utility method that generates the destination dir path for a given visibility. Returns `nil` if the path does not exist for that visibility.
    public static func destDirPath(for visibility: HeaderVisibility?, scope: MacroEvaluationScope) -> Path? {
        return visibility.map { visibility in destDirPath(for: visibility, scope: scope) } ?? nil
    }

    /// Non-optional overload for generating the destination dir path for a given header visibility.
    public static func destDirPath(for visibility: HeaderVisibility, scope: MacroEvaluationScope) -> Path {
        // Compute the output path.
        let folderPath: Path
        switch visibility {
        case .private:
            folderPath = scope.evaluate(BuiltinMacros.PRIVATE_HEADERS_FOLDER_PATH)
        case .public:
            folderPath = scope.evaluate(BuiltinMacros.PUBLIC_HEADERS_FOLDER_PATH)
        }

        // Concatenate into the install location.
        let dstDirPath: Path
        if scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) && folderPath.isAbsolute {
            dstDirPath = scope.evaluate(BuiltinMacros.DSTROOT).join(folderPath, preserveRoot: true)
        } else {
            dstDirPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(folderPath, preserveRoot: true)
        }

        return dstDirPath
    }

    /// Utility method which returns the path to which the given header file source would be copied by the target with the given scope.  Returns `nil` if the header would not be copied.
    public static func outputPath(for headerSourcePath: Path, visibility: HeaderVisibility?, scope: MacroEvaluationScope) -> Path? {
        return destDirPath(for: visibility, scope: scope)?.join(headerSourcePath.basename)
    }

    /// Non-optional overload for obtaining the output path for a header's source file.
    public static func outputPath(for headerSourcePath: Path, visibility: HeaderVisibility, scope: MacroEvaluationScope) -> Path {
        return destDirPath(for: visibility, scope: scope).join(headerSourcePath.basename)
    }
}
