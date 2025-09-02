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

import SWBProtocol

public struct SWBConfiguredTargetSourceFilesInfo: Equatable, Sendable {
    public struct SourceFileInfo: Equatable, Sendable {
        /// The path of the source file on disk
        public let path: AbsolutePath

        /// The language of the source file.
        ///
        /// `nil` if the language could not be determined due to an error.
        public let language: SWBSourceLanguage?

        /// The output path that is used for indexing, ie. the value of the `-index-unit-output-path` or `-o` option in
        /// the source file's build settings.
        ///
        /// This is a `String` and not a `Path` because th index output path may be a fake path that is relative to the
        /// build directory and has no relation to actual files on disks.
        ///
        /// May be `nil` if the output path could not be determined due to an error.
        public let indexOutputPath: String?

        public init(path: AbsolutePath, language: SWBSourceLanguage? = nil, indexOutputPath: String? = nil) {
            self.path = path
            self.language = language
            self.indexOutputPath = indexOutputPath
        }

        init(_ sourceFileInfo: BuildDescriptionConfiguredTargetSourcesResponse.SourceFileInfo) {
            self.path = AbsolutePath(sourceFileInfo.path)
            self.language = SWBSourceLanguage(sourceFileInfo.language)
            self.indexOutputPath = sourceFileInfo.indexOutputPath
        }
    }

    /// The configured target to which this info belongs
    public let configuredTarget: SWBConfiguredTargetGUID

    /// Information about the source files in this source file
    public let sourceFiles: [SourceFileInfo]

    public init(configuredTarget: SWBConfiguredTargetGUID, sourceFiles: [SWBConfiguredTargetSourceFilesInfo.SourceFileInfo]) {
        self.configuredTarget = configuredTarget
        self.sourceFiles = sourceFiles
    }

    init(_ sourceFilesInfo: BuildDescriptionConfiguredTargetSourcesResponse.ConfiguredTargetSourceFilesInfo) {
        self.configuredTarget = SWBConfiguredTargetGUID(sourceFilesInfo.configuredTarget)
        self.sourceFiles = sourceFilesInfo.sourceFiles.map { SourceFileInfo($0) }
    }
}
