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
}
