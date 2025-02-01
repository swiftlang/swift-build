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

import Foundation
import SwiftBuild
import Testing

@Suite
fileprivate struct BuildPhasesTests {
    @Test func basicEncoding() throws {
        try testCodable(ProjectModel.BuildPhase.copyFilesExample)
        try testCodable(ProjectModel.BuildPhase.headersExample)
        try testCodable(ProjectModel.BuildPhase.sourcesExample)
        try testCodable(ProjectModel.BuildPhase.frameworksExample)
        try testCodable(ProjectModel.BuildPhase.copyBundleResourcesExample)
        try testCodable(ProjectModel.BuildPhase.shellScriptExample)
    }
}

extension ProjectModel.BuildPhase {
    static var copyFilesExample: Self { return .copyFiles(.example) }
    static var headersExample: Self { return .headers(.example) }
    static var sourcesExample: Self { return .sources(.example) }
    static var frameworksExample: Self { return .frameworks(.example) }
    static var copyBundleResourcesExample: Self { return .copyBundleResources(.example) }
    static var shellScriptExample: Self { return .shellScript(.example) }
}

extension ProjectModel.CopyFilesBuildPhase {
    static var example: Self {
        return .init(common: .init(id: "foo"), destinationSubfolder: .absolute)
    }
}

extension ProjectModel.HeadersBuildPhase {
    static var example: Self {
        return .init(id: "foo", files: [.example])
    }
}

extension ProjectModel.SourcesBuildPhase {
    static var example: Self {
        return .init(id: "foo", files: [.example])
    }
}

extension ProjectModel.FrameworksBuildPhase {
    static var example: Self {
        return .init(id: "foo", files: [.example])
    }
}

extension ProjectModel.CopyBundleResourcesBuildPhase {
    static var example: Self {
        return .init(id: "foo")
    }
}

extension ProjectModel.ShellScriptBuildPhase {
    static var example: Self {
        return .init(id: "foo", name: "shellScriptBuildPhase", scriptContents: "contents", shellPath: "path", inputPaths: ["inputPath"], outputPaths: ["outputPath"], emitEnvironment: true, alwaysOutOfDate: true, originalObjectID: "originalId")
    }
}
