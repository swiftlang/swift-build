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

public enum SWBBuildAction: String, Sendable {
    case analyze = "analyze" // used by legacy target-based builds using xcodebuild
    case archive = "archive" // used by legacy target-based builds using xcodebuild
    case clean = "clean"
    case build = "build"
    case exportLoc = "exportloc"
    case install = "install"
    case installAPI = "installapi"
    case installHeaders = "installhdrs"
    case installLoc = "installloc"
    case installSource = "installsrc"
    case docBuild = "docbuild"
}

extension BuildAction {
    init(_ x: SWBBuildAction) {
        switch x {
        case .analyze:
            self = .analyze
        case .archive:
            self = .archive
        case .clean:
            self = .clean
        case .build:
            self = .build
        case .exportLoc:
            self = .exportLoc
        case .install:
            self = .install
        case .installAPI:
            self = .installAPI
        case .installHeaders:
            self = .installHeaders
        case .installLoc:
            self = .installLoc
        case .installSource:
            self = .installSource
        case .docBuild:
            self = .docBuild
        }
    }
}
