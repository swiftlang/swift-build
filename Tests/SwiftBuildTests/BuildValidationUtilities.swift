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

@_spi(Testing) import SwiftBuild
import SWBTestSupport
import SWBUtil
import Foundation

// MARK: Tool Under Test Paths

/// The path to the main service binary.
let swbServiceURL = SWBBuildServiceConnection.serviceExecutableURL

// FIXME: Move this elsewhere.

/// The path to the `xcodebuild` to use when testing.
//
// FIXME: This is broken, we are trying to test integration across products without a strong guarantee about what we are testing. In practice, we set XCODEBUILD_PATH on our current bots.

/// The path to the `swbuild` tool.
let swbuildToolPath = { () -> Path in
    let bundle = Bundle(for: MockClass.self)
    let builtProductsDir = Path(bundle.bundlePath).dirname
    return builtProductsDir.join("swbuild")
}()

/// The path to the inferior `xcodebuild` tool to use.
func xcodebuildUnderTestPath() async throws -> Path {
    let bundle = Bundle(for: MockClass.self)
    let builtProductsDir = Path(bundle.bundlePath).dirname

    // If the BUILT_PRODUCTS_DIR has `xcodebuild`, use that.
    let xcodebuildToolPath = builtProductsDir.join("xcodebuild")

    // If we didn't find any tool, fall back to the defaults.
    if !localFS.exists(xcodebuildToolPath) {
        if let path = ProcessInfo.processInfo.environment["XCODEBUILD_PATH"]?.nilIfEmpty.map(Path.init) {
            return path
        }
        return try await InstalledXcode.currentlySelected().find("xcodebuild")
    }

    return xcodebuildToolPath
}

private class MockClass {}
