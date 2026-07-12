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
import Testing
import SWBUtil

@Suite fileprivate struct LLVMTripleTests {
    @Test func androidUnversioned() throws {
        let triple = try LLVMTriple("aarch64-unknown-linux-android")
        #expect(triple.arch == "aarch64")
        #expect(triple.vendor == "unknown")
        #expect(triple.system == "linux")
        #expect(triple.systemComponent == "linux")
        #expect(triple.environment == "android")
        #expect(triple.environmentComponent == "android")
        #expect(try triple.version == nil)
    }

    @Test func androidVersioned() throws {
        let triple = try LLVMTriple("aarch64-unknown-linux-android35")
        #expect(triple.arch == "aarch64")
        #expect(triple.vendor == "unknown")
        #expect(triple.system == "linux")
        #expect(triple.systemComponent == "linux")
        #expect(triple.environment == "android")
        #expect(triple.environmentComponent == "android35")
        #expect(try triple.version == Version(35))
    }

    @Test func macUnversioned() throws {
        let triple = try LLVMTriple("aarch64-apple-macos")
        #expect(triple.arch == "aarch64")
        #expect(triple.vendor == "apple")
        #expect(triple.system == "macos")
        #expect(triple.systemComponent == "macos")
        #expect(triple.environment == nil)
        #expect(triple.environmentComponent == nil)
        #expect(try triple.version == nil)
    }

    @Test func macUnversionedWithEnv() throws {
        let triple = try LLVMTriple("aarch64-apple-macos-macho")
        #expect(triple.arch == "aarch64")
        #expect(triple.vendor == "apple")
        #expect(triple.system == "macos")
        #expect(triple.systemComponent == "macos")
        #expect(triple.environment == "macho")
        #expect(triple.environmentComponent == "macho")
        #expect(try triple.version == nil)
    }

    @Test func macVersioned() throws {
        let triple = try LLVMTriple("aarch64-apple-macos26.3")
        #expect(triple.arch == "aarch64")
        #expect(triple.vendor == "apple")
        #expect(triple.system == "macos")
        #expect(triple.systemComponent == "macos26.3")
        #expect(triple.environment == nil)
        #expect(triple.environmentComponent == nil)
        #expect(try triple.version == Version(26, 3))
    }

    @Test func macVersionedWithEnv() throws {
        let triple = try LLVMTriple("aarch64-apple-macos26.3-macho")
        #expect(triple.arch == "aarch64")
        #expect(triple.vendor == "apple")
        #expect(triple.system == "macos")
        #expect(triple.systemComponent == "macos26.3")
        #expect(triple.environment == "macho")
        #expect(triple.environmentComponent == "macho")
        #expect(try triple.version == Version(26, 3))
    }

    @Test func freeBSDUnversioned() throws {
        let triple = try LLVMTriple("aarch64-unknown-freebsd")
        #expect(triple.arch == "aarch64")
        #expect(triple.vendor == "unknown")
        #expect(triple.system == "freebsd")
        #expect(triple.systemComponent == "freebsd")
        #expect(triple.environment == nil)
        #expect(triple.environmentComponent == nil)
        #expect(try triple.version == nil)
    }

    @Test func freeBSDVersioned() throws {
        let triple = try LLVMTriple("aarch64-unknown-freebsd14.2")
        #expect(triple.arch == "aarch64")
        #expect(triple.vendor == "unknown")
        #expect(triple.system == "freebsd")
        #expect(triple.systemComponent == "freebsd14.2")
        #expect(triple.environment == nil)
        #expect(triple.environmentComponent == nil)
        #expect(try triple.version == Version(14, 2))
    }

    @Test func qnxUnversioned() throws {
        let triple = try LLVMTriple("x86_64-pc-nto-qnx")
        #expect(triple.arch == "x86_64")
        #expect(triple.vendor == "pc")
        #expect(triple.system == "nto")
        #expect(triple.systemComponent == "nto")
        #expect(triple.environment == "qnx")
        #expect(triple.environmentComponent == "qnx")
        #expect(try triple.version == nil)
    }

    @Test func qnxVersioned() throws {
        let triple = try LLVMTriple("x86_64-pc-nto-qnx800")
        #expect(triple.arch == "x86_64")
        #expect(triple.vendor == "pc")
        #expect(triple.system == "nto")
        #expect(triple.systemComponent == "nto")
        #expect(triple.environment == "qnx")
        #expect(triple.environmentComponent == "qnx800")
        #expect(try triple.version == Version(800))
    }

    @Test func wasi() throws {
        let triple = try LLVMTriple("wasm32-unknown-wasi")
        #expect(triple.arch == "wasm32")
        #expect(triple.vendor == "unknown")
        #expect(triple.system == "wasi")
        #expect(triple.systemComponent == "wasi")
        #expect(triple.environment == nil)
        #expect(triple.environmentComponent == nil)
        #expect(try triple.version == nil)
    }

    @Test func wasip1() throws {
        let triple = try LLVMTriple("wasm32-unknown-wasip1")
        #expect(triple.arch == "wasm32")
        #expect(triple.vendor == "unknown")
        #expect(triple.system == "wasip1")
        #expect(triple.systemComponent == "wasip1")
        #expect(triple.environment == nil)
        #expect(triple.environmentComponent == nil)
        #expect(try triple.version == nil)
    }

    @Test func creationFromComponents() throws {
        #expect(try LLVMTriple(arch: "arm64", vendor: "apple", systemComponent: "macos27.0").description == "arm64-apple-macos27.0")
        #expect(try LLVMTriple(arch: "arm64", vendor: "apple", systemComponent: "macos27.0", environmentComponent: "").description == "arm64-apple-macos27.0")
        #expect(try LLVMTriple(arch: "arm64", vendor: "apple", systemComponent: "macos27.0", environmentComponent: "macabi").description == "arm64-apple-macos27.0-macabi")
        #expect(try LLVMTriple(arch: "aarch64", vendor: "unknown", systemComponent: "linux", environmentComponent: "android35").description == "aarch64-unknown-linux-android35")

        // Check unversioned forms.
        #expect(try LLVMTriple(arch: "arm64", vendor: "apple", systemComponent: "macos27.0", environmentComponent: "macabi").unversioned.description == "arm64-apple-macos-macabi")
        #expect(try LLVMTriple(arch: "aarch64", vendor: "unknown", systemComponent: "linux", environmentComponent: "android35").unversioned.description == "aarch64-unknown-linux-android")
    }

    @Test func suffix() throws {
        var triple = try LLVMTriple("arm64-apple-macos26.3")
        #expect(triple.suffix == "")
        triple.suffix = "macabi"
        #expect(triple.environment == "macabi")
        #expect(triple.suffix == "-macabi")
        triple.suffix = "-macho"
        #expect(triple.environment == "macho")
        #expect(triple.suffix == "-macho")
        triple.suffix = ""
        #expect(triple.suffix == "")
        triple.environment = "macabi"
        #expect(triple.environment == "macabi")
        #expect(triple.suffix == "-macabi")
    }

    @Test func unversioned() throws {
        #expect(try LLVMTriple("aarch64-unknown-linux-android").unversioned.description == "aarch64-unknown-linux-android")
        #expect(try LLVMTriple("aarch64-unknown-linux-android35").unversioned.description == "aarch64-unknown-linux-android")
        #expect(try LLVMTriple("aarch64-apple-macos").unversioned.description == "aarch64-apple-macos")
        #expect(try LLVMTriple("aarch64-apple-macos-macho").unversioned.description == "aarch64-apple-macos-macho")
        #expect(try LLVMTriple("aarch64-apple-macos26.3").unversioned.description == "aarch64-apple-macos")
        #expect(try LLVMTriple("aarch64-apple-macos26.3-macho").unversioned.description == "aarch64-apple-macos-macho")
        #expect(try LLVMTriple("aarch64-unknown-freebsd").unversioned.description == "aarch64-unknown-freebsd")
        #expect(try LLVMTriple("aarch64-unknown-freebsd14.2").unversioned.description == "aarch64-unknown-freebsd")
        #expect(try LLVMTriple("x86_64-pc-nto-qnx").unversioned.description == "x86_64-pc-nto-qnx")
        #expect(try LLVMTriple("x86_64-pc-nto-qnx800").unversioned.description == "x86_64-pc-nto-qnx")
        #expect(try LLVMTriple("wasm32-unknown-wasi").unversioned.description == "wasm32-unknown-wasi")
        #expect(try LLVMTriple("wasm32-unknown-wasip1").unversioned.description == "wasm32-unknown-wasip1")
    }

    @Test func normalized() throws {
        // macosx -> macos
        #expect(try LLVMTriple("arm64-apple-macos").normalized.description == "arm64-apple-macos")
        #expect(try LLVMTriple("arm64-apple-macos-macho").normalized.description == "arm64-apple-macos-macho")
        #expect(try LLVMTriple("arm64-apple-macos26.3").normalized.description == "arm64-apple-macos26.3")
        #expect(try LLVMTriple("arm64-apple-macos26.3-macho").normalized.description == "arm64-apple-macos26.3-macho")
        #expect(try LLVMTriple("arm64-apple-macosx").normalized.description == "arm64-apple-macos")
        #expect(try LLVMTriple("arm64-apple-macosx-macho").normalized.description == "arm64-apple-macos-macho")
        #expect(try LLVMTriple("arm64-apple-macosx26.3").normalized.description == "arm64-apple-macos26.3")
        #expect(try LLVMTriple("arm64-apple-macosx26.3-macho").normalized.description == "arm64-apple-macos26.3-macho")

        // aarch64 -> arm64
        #expect(try LLVMTriple("aarch64-unknown-linux-android").normalized.description == "aarch64-unknown-linux-android")
        #expect(try LLVMTriple("aarch64-unknown-linux-android35").normalized.description == "aarch64-unknown-linux-android35")
        #expect(try LLVMTriple("aarch64-unknown-freebsd").normalized.description == "aarch64-unknown-freebsd")
        #expect(try LLVMTriple("aarch64-unknown-freebsd14.2").normalized.description == "aarch64-unknown-freebsd14.2")
    }

    @Test func errors() throws {
        // Invalid formats.
        // Note that things that look like versions could be part of the arch or vendor components.
        #expect(throws: LLVMTripleError.self) {
            try LLVMTriple("arm64-apple")
        }
        #expect(throws: LLVMTripleError.self) {
            try LLVMTriple("apple-macos27.0")
        }
        #expect(throws: LLVMTripleError.self) {
            try LLVMTriple("-apple-macos27.0-macabi")
        }

        // Multiple versions.
        #expect(throws: LLVMTripleError.self) {
            try LLVMTriple(arch: "aarch64", vendor: "apple", systemComponent: "linux27", environmentComponent: "android35")
        }
    }
}
