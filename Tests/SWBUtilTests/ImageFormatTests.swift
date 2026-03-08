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

import Testing
import SWBUtil

@Suite fileprivate struct ImageFormatTests {
    @Test func elf() {
        let format = ImageFormat.elf

        #expect(format.executableExtension == "")
        // No extension means names pass through unchanged
        #expect(format.executableName(basename: "myapp") == "myapp")
        #expect(format.basename(executableName: "myapp") == "myapp")
        // A name with a dot is not treated as having an extension
        #expect(format.executableName(basename: "my.app") == "my.app")
        #expect(format.basename(executableName: "my.app") == "my.app")

        #expect(format.dynamicLibraryExtension == "so")

        #expect(format.requiresSwiftAutolinkExtract == true)
        #expect(format.requiresSwiftModulewrap == true)

        #expect(format.usesRpaths == true)
        #expect(format.rpathOrigin == "$ORIGIN")

        #expect(format.usesDsyms == false)
    }

    @Test func macho() {
        let format = ImageFormat.macho

        #expect(format.executableExtension == "")
        // No extension means names pass through unchanged
        #expect(format.executableName(basename: "myapp") == "myapp")
        #expect(format.basename(executableName: "myapp") == "myapp")
        // A name with a dot is not treated as having an extension
        #expect(format.executableName(basename: "my.app") == "my.app")
        #expect(format.basename(executableName: "my.app") == "my.app")

        #expect(format.dynamicLibraryExtension == "dylib")

        #expect(format.requiresSwiftAutolinkExtract == false)
        #expect(format.requiresSwiftModulewrap == false)

        #expect(format.usesRpaths == true)
        #expect(format.rpathOrigin == "@loader_path")

        #expect(format.usesDsyms == true)
    }

    @Test func pe() {
        let format = ImageFormat.pe

        #expect(format.executableExtension == "exe")
        // Appends .exe to a plain basename
        #expect(format.executableName(basename: "myapp") == "myapp.exe")
        // Strips .exe suffix to recover the basename
        #expect(format.basename(executableName: "myapp.exe") == "myapp")
        // Without the suffix, basename returns the name unchanged
        #expect(format.basename(executableName: "myapp") == "myapp")
        // executableName always appends, even if already suffixed
        #expect(format.executableName(basename: "myapp.exe") == "myapp.exe.exe")
        // Two-level basenames: only the .exe suffix is stripped
        #expect(format.executableName(basename: "ld.lld") == "ld.lld.exe")
        #expect(format.basename(executableName: "ld.lld.exe") == "ld.lld")
        #expect(format.basename(executableName: "ld.lld") == "ld.lld")

        #expect(format.dynamicLibraryExtension == "dll")

        #expect(format.requiresSwiftAutolinkExtract == false)
        #expect(format.requiresSwiftModulewrap == true)

        #expect(format.usesRpaths == false)
        #expect(format.rpathOrigin == nil)

        #expect(format.usesDsyms == false)
    }

    @Test func wasm() {
        let format = ImageFormat.wasm

        #expect(format.executableExtension == "wasm")
        // Appends .wasm to a plain basename
        #expect(format.executableName(basename: "myapp") == "myapp.wasm")
        // Strips .wasm suffix to recover the basename
        #expect(format.basename(executableName: "myapp.wasm") == "myapp")
        // Without the suffix, basename returns the name unchanged
        #expect(format.basename(executableName: "myapp") == "myapp")
        // executableName always appends, even if already suffixed
        #expect(format.executableName(basename: "myapp.wasm") == "myapp.wasm.wasm")
        // Two-level basenames: only the .wasm suffix is stripped
        #expect(format.executableName(basename: "ld.lld") == "ld.lld.wasm")
        #expect(format.basename(executableName: "ld.lld.wasm") == "ld.lld")
        #expect(format.basename(executableName: "ld.lld") == "ld.lld")

        #expect(format.dynamicLibraryExtension == "wasm")

        #expect(format.requiresSwiftAutolinkExtract == false)
        #expect(format.requiresSwiftModulewrap == true)

        #expect(format.usesRpaths == false)
        #expect(format.rpathOrigin == nil)

        #expect(format.usesDsyms == false)
    }
}
