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

import Foundation
public import SWBUtil

/// Locates the built `MockToolchainCASPlugin` dynamic library, for use by tests.
public enum MockCASPluginLocator {
    /// Returns the path to the built `MockToolchainCASPlugin` dylib.
    ///
    /// The `SWBMOCK_CAS_PLUGIN_PATH` environment variable can be used to override the location,
    /// which is useful when the dylib isn't discoverable via the SwiftPM build products
    /// directory (e.g. when running tests outside of `swift test`).
    public static func locate() throws -> Path {
        if let overridePath = getEnvironmentVariable("SWBMOCK_CAS_PLUGIN_PATH")?.nilIfEmpty {
            return Path(overridePath)
        }

        #if SWIFT_PACKAGE
        // On Darwin, a test bundle is nested a level below the products directory (e.g.
        // `Products/Debug/Foo.xctest/Contents/MacOS/Foo`), so the products directory is the
        // bundle URL's parent. On Linux there's no such wrapper bundle: this module is statically
        // linked into the flat test executable that itself lives directly in the products
        // directory (e.g. `Products/Debug/Foo`), so `Bundle(for:).bundleURL` resolves to
        // `Bundle.main`'s directory, which already *is* the products directory. Probe both.
        let bundleURL = Bundle(for: BundleToken.self).bundleURL
        let candidateProductsDirs = [bundleURL.deletingLastPathComponent(), bundleURL]
        let os = try ProcessInfo.processInfo.hostOperatingSystem()
        // Unlike the Unix `lib<name>.<so|dylib>` convention, Windows dynamic libraries are named
        // `<name>.dll` with no `lib` prefix.
        let dylibPrefix: String
        switch os.imageFormat {
        case .pe:
            dylibPrefix = ""
        case .macho, .elf, .wasm:
            dylibPrefix = "lib"
        }
        for productsDir in candidateProductsDirs {
            let dylibPath = try productsDir.filePath.join("\(dylibPrefix)MockToolchainCASPlugin.\(os.imageFormat.dynamicLibraryExtension)")
            if localFS.exists(dylibPath) {
                return dylibPath
            }
            // Xcode's IDE build system (unlike the `swift build`/`swift test` CLI) wraps SwiftPM
            // `.dynamic` library products in a `.framework` bundle instead of emitting a bare dylib
            // named after the product, so also probe for that layout. The framework's main binary
            // is itself a valid Mach-O dylib and can be dlopen'd directly.
            let frameworkBinaryPath = try productsDir.filePath.join("PackageFrameworks").join("MockToolchainCASPlugin.framework").join("MockToolchainCASPlugin")
            if localFS.exists(frameworkBinaryPath) {
                return frameworkBinaryPath
            }
        }
        throw StubError.error("could not locate MockToolchainCASPlugin as a dylib or framework under \(try candidateProductsDirs.map { try $0.filePath.str }.joined(separator: " or ")) (set SWBMOCK_CAS_PLUGIN_PATH to override)")
        #else
        throw StubError.error("MockCASPluginLocator.locate() requires running via the SwiftPM build (set SWBMOCK_CAS_PLUGIN_PATH to override)")
        #endif
    }
}

private final class BundleToken {}
