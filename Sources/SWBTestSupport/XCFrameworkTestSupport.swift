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

package import struct SWBCore.XCFramework
package import SWBUtil

extension FSProxy {
    package func writeXCFramework(_ path: Path, _ xcframework: XCFramework, infoLookup: any PlatformInfoLookup) async throws {
        try await XCFrameworkTestSupport.writeXCFramework(xcframework, fs: self, path: path, infoLookup: infoLookup)
    }
}

package enum XCFrameworkTestSupport: Sendable {
    /// Test utility to writing out a mock XCFramework with the proper file structure based on the individual library. This is **not** a validate XCFramework in the sense that the contents of the files are just garbage values. This should **only** be used for tests that need to very the proper operations on the structure of an XCFramework.
    package static func writeXCFramework(_ xcframework: XCFramework, fs: any FSProxy, path: Path, infoLookup: any PlatformInfoLookup) async throws {
        let data = try xcframework.serialize()
        try fs.write(path.join("Info.plist"), contents: ByteString(data))

        for lib in xcframework.libraries {
            let libRoot = path.join(lib.libraryIdentifier)

            guard let platform = BuildVersion.Platform(platform: lib.supportedPlatform, environment: lib.platformVariant) else {
                throw StubError.error("Unknown platform: \([lib.supportedPlatform, lib.platformVariant].compactMap { $0 }.joined(separator: "-"))")
            }

            switch lib.libraryType {
            case .framework:
                let libPath = libRoot.join(lib.libraryPath)
                try fs.createDirectory(libPath, recursive: true)

                try await withTemporaryDirectory { tmpDir in
                    let xcode = try await InstalledXcode.currentlySelected()
                    try await fs.write(libPath.join(lib.libraryPath.basenameWithoutSuffix), contents: localFS.read(xcode.compileDynamicLibrary(path: tmpDir, platform: platform, infoLookup: infoLookup, archs: lib.supportedArchitectures.sorted())))
                }

                // An empty plist is enough for testing the contents of the framework is actually copied.
                try await fs.writePlist(libPath.join("Info.plist"), PropertyListItem.plDict([:]))

            case .staticLibrary, .dynamicLibrary:
                try fs.createDirectory(libRoot, recursive: true)

                // Write the library out.
                try await withTemporaryDirectory { tmpDir in
                    let xcode = try await InstalledXcode.currentlySelected()
                    let contents: ByteString
                    switch lib.libraryType {
                    case .staticLibrary:
                        contents = try await localFS.read(xcode.compileStaticLibrary(path: tmpDir, platform: platform, infoLookup: infoLookup, archs: lib.supportedArchitectures.sorted()))
                    case .dynamicLibrary:
                        contents = try await localFS.read(xcode.compileDynamicLibrary(path: tmpDir, platform: platform, infoLookup: infoLookup, archs: lib.supportedArchitectures.sorted()))
                    default:
                        return
                    }
                    try fs.write(libRoot.join(lib.libraryPath), contents: contents)
                }

            case let .unknown(fileExtension):
                throw StubError.error("Unsupported extension for the given library type: \(fileExtension)")
            }

            // Create some mock header files if the library has headers.
            if let headersPath = lib.headersPath {
                let libHeadersPath = libRoot.join(headersPath)
                try fs.createDirectory(libHeadersPath, recursive: true)
                try fs.write(libHeadersPath.join("header1.h"), contents: "// header 1")
                try fs.write(libHeadersPath.join("header2.h"), contents: "// header 2")
            }

            // Just create some fake debug symbols for when the library has symbols!
            if let debugSymbolsPath = lib.debugSymbolsPath {
                let targetPath = libRoot.join(debugSymbolsPath)
                try fs.createDirectory(targetPath, recursive: true)
                try fs.write(targetPath.join(lib.libraryPath.str + ".dSYM"), contents: "fake dsym!")
            }
        }
    }

}
