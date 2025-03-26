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
@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil
import Testing
import SWBMacro

@Suite fileprivate struct CommandLineToolSpecDiscoveredInfoTests: CoreBasedTests {
    @Test(.skipHostOS(.windows, "Failed to obtain command line tool spec info but no errors were emitted"))
    func discoveredClangSpecInfo() async throws {
        try await withSpec("com.apple.compilers.llvm.clang.1_0", .deferred) { (info: DiscoveredClangToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
#if canImport(Darwin)
            #expect(info.clangVersion != nil)
#endif
            if let clangVersion = info.clangVersion {
                #expect(clangVersion > Version(0, 0, 0, 0))
            }
#if canImport(Darwin)
            #expect(info.llvmVersion != nil)
#endif
            if let llvmVersion = info.llvmVersion {
                #expect(llvmVersion > Version(0, 0, 0))
            }
        }

        // undefined_arch + sysroot=nil

        try await withSpec("com.apple.compilers.llvm.clang.1_0", .result(status: .exit(0), stdout: Data("#define __clang_version__ \"8.1.0 (clang-802.1.38)\"".utf8), stderr: Data())) { (info: DiscoveredClangToolSpecInfo) in
            #expect(info.toolPath.basename == "clang")
            #expect(info.clangVersion == Version(802, 1, 38))
            #expect(info.llvmVersion == Version(8, 1))
        }

        try await withSpec("com.apple.compilers.llvm.clang.1_0", .result(status: .exit(0), stdout: Data("#define __clang_version__ \"12.0.0 (clang-1200.0.31.1)\"".utf8), stderr: Data())) { (info: DiscoveredClangToolSpecInfo) in
            #expect(info.toolPath.basename == "clang")
            #expect(info.clangVersion == Version(1200, 0, 31, 1))
            #expect(info.llvmVersion == Version(12))
        }

        try await withSpec("com.apple.compilers.llvm.clang.1_0", .result(status: .exit(0), stdout: Data("#define __clang_version__ \"12.0.0 (clang-1200.0.22.5) [ptrauth objc isa mode: sign-and-strip]\"".utf8), stderr: Data())) { (info: DiscoveredClangToolSpecInfo) in
            #expect(info.toolPath.basename == "clang")
            #expect(info.clangVersion == Version(1200, 0, 22, 5))
            #expect(info.llvmVersion == Version(12))
        }

        try await withSpec("com.apple.compilers.llvm.clang.1_0", .result(status: .exit(0), stdout: Data("#define __clang_version__ \"11.0.3 (clang-1103.0.29.20) (-macos10.15-objc-selector-opts)\"".utf8), stderr: Data())) { (info: DiscoveredClangToolSpecInfo) in
            #expect(info.toolPath.basename == "clang")
            #expect(info.clangVersion == Version(1103, 0, 29, 20))
            #expect(info.llvmVersion == Version(11, 0, 3))
        }

        try await withSpec("com.apple.compilers.llvm.clang.1_0", .result(status: .exit(0), stdout: Data("#define __clang_version__ \"17.0.0 (https://github.com/swiftlang/llvm-project.git 5bbcb7bc1701d40b9189d124d910b64009665cc0)\"".utf8), stderr: Data())) { (info: DiscoveredClangToolSpecInfo) in
            #expect(info.toolPath.basename == "clang")
            #expect(info.clangVersion == nil)
            #expect(info.llvmVersion == Version(17))
        }

        try await withSpec("com.apple.compilers.llvm.clang.1_0", .result(status: .exit(0), stdout: Data("#define __clang_version__ \"19.0.0 (https://android.googlesource.com/toolchain/llvm-project 97a699bf4812a18fb657c2779f5296a4ab2694d2)\"".utf8), stderr: Data())) { (info: DiscoveredClangToolSpecInfo) in
            #expect(info.toolPath.basename == "clang")
            #expect(info.clangVersion == nil)
            #expect(info.llvmVersion == Version(19))
        }
    }

    @Test
    func discoveredClangSpecInfoAcrossToolchains() async throws {
        let core = try await getCore()
        let toolchains = core.toolchainRegistry.toolchains
        #expect(toolchains.count > 0) // must be at least one toolchain (default)
        for toolchain in toolchains.sorted(by: \.identifier) {
            if toolchain.identifier == "qnx" {
                // QNX toolchains do not have clang
                continue
            }

            let clangPath = try #require(toolchain.executableSearchPaths.findExecutable(operatingSystem: core.hostOperatingSystem, basename: "clang"), "Unable to find clang in search paths for toolchain '\(toolchain.identifier)': \(toolchain.executableSearchPaths.environmentRepresentation)")
            let info = try await discoveredClangToolInfo(toolPath: clangPath, arch: "undefined_arch", sysroot: nil)
            #expect(info.toolPath == clangPath)

#if canImport(Darwin)
            if toolchain.identifier.hasPrefix("org.swift.") || toolchain.identifier.hasPrefix("org.swiftwasm.") {
                #expect(info.clangVersion == nil, "Open Source toolchains are expected to NOT have a clang version")
            } else if toolchain.identifier == "android" {
                #expect(info.clangVersion == nil, "Android toolchains are expected to NOT have a clang version")
            } else {
                #expect(info.clangVersion != nil, "Unable to find clang version for toolchain \(toolchain.identifier). Used clang at path \(clangPath.str).")
            }

            #expect(info.llvmVersion != nil, "Unable to find llvm version for toolchain \(toolchain.identifier). Used clang at path \(clangPath.str).")
#endif
        }
    }

    @Test
    func discoveredSwiftSpecInfo() async throws {
        let core = try await getCore()

        try await withSpec(SwiftCompilerSpec.self, .deferred) { (info: DiscoveredSwiftCompilerToolSpecInfo) in
            #expect(info.toolPath.basename == core.hostOperatingSystem.imageFormat.executableName(basename: "swiftc"))
            #expect(info.swiftVersion > Version(0, 0, 0))
            #expect(info.swiftlangVersion > Version(0, 0, 0))
            #expect(info.swiftABIVersion == nil)
#if canImport(Darwin)
            #expect(info.clangVersion != nil)
#endif
            if let clangVersion = info.clangVersion {
                #expect(clangVersion > Version(0, 0, 0))
            }
        }

        try await withSpec(SwiftCompilerSpec.self, .result(status: .exit(0), stdout: Data("Swift version 5.9-dev (LLVM fd31e7eab45779f, Swift 86e6bda88e47178)\n".utf8), stderr: Data())) { (info: DiscoveredSwiftCompilerToolSpecInfo) in
            #expect(info.toolPath.basename == core.hostOperatingSystem.imageFormat.executableName(basename: "swiftc"))
            #expect(info.swiftVersion == Version(5, 9))
            #expect(info.swiftlangVersion == Version(5, 9, 999, 999))
            #expect(info.clangVersion == Version(5, 9, 999, 999))
        }

        try await withSpec(SwiftCompilerSpec.self, .result(status: .exit(0), stdout: Data("Apple Swift version 5.9 (swiftlang-5.9.0.106.53 clang-1500.0.13.6)\n".utf8), stderr: Data("swift-driver version: 1.80 ".utf8))) { (info: DiscoveredSwiftCompilerToolSpecInfo) in
            #expect(info.toolPath.basename == core.hostOperatingSystem.imageFormat.executableName(basename: "swiftc"))
            #expect(info.swiftVersion == Version(5, 9))
            #expect(info.swiftlangVersion == Version(5, 9, 0, 106, 53))
            #expect(info.clangVersion == Version(1500, 0, 13, 6))
        }

        try await withSpec(SwiftCompilerSpec.self, .result(status: .exit(0), stdout: Data("Swift version 5.10.1 (swift-5.10.1-RELEASE)\nTarget: aarch64-unknown-linux-gnu\n".utf8), stderr: Data())) {  (info: DiscoveredSwiftCompilerToolSpecInfo) in
            #expect(info.toolPath.basename == core.hostOperatingSystem.imageFormat.executableName(basename: "swiftc"))
            #expect(info.swiftVersion == Version(5, 10, 1))
            #expect(info.swiftlangVersion == Version(5, 10, 1))
            #expect(info.clangVersion == nil)
        }
    }

    @Test
    func discoveredSwiftABIToolsSpecInfo() async throws {
        try await withSpec("com.apple.build-tools.swift-abi-checker", .deferred) { (info: DiscoveredSwiftCompilerToolSpecInfo) in
            #expect(info.toolPath.basenameWithoutSuffix == "swiftc")
        }

        try await withSpec("com.apple.build-tools.swift-abi-generation", .deferred) { (info: DiscoveredSwiftCompilerToolSpecInfo) in
            #expect(info.toolPath.basenameWithoutSuffix == "swiftc")
        }
    }

    // Linker tool discovery is a bit more complex as it afffected by the ALTERNATE_LINKER build setting.
    func ldMacroTable() async throws ->  MacroValueAssignmentTable {
            let core = try await getCore()
            return MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
    }

    @Test
    func discoveredLdLinkerSpecInfo() async throws {
        var table = try await ldMacroTable()
        table.push(BuiltinMacros._LD_MULTIARCH, literal: true)
        // Default Linker, just check we have one.
        try await withSpec(LdLinkerSpec.self, .deferred, additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion != nil)
            if let toolVersion = info.toolVersion {
                #expect(toolVersion > Version(0, 0, 0))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func discoveredLdLinkerSpecInfo_macOS() async throws {
        var table = try await ldMacroTable()
        table.push(BuiltinMacros._LD_MULTIARCH, literal: true)
        // Default Linker
        try await withSpec(LdLinkerSpec.self, .deferred, additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion != nil)
            if let toolVersion = info.toolVersion {
                #expect(toolVersion > Version(0, 0, 0))
            }
            #expect(info.linker == .ld64)
            // rdar://112109825 (ld_prime only reports arm64 and arm64e architectures in ld -version_details)
            // let expectedArchs = Set(["armv7", "armv7k", "armv7s", "arm64", "arm64e", "i386", "x86_64"])
            // XCTAssertEqual(info.architectures.intersection(expectedArchs), expectedArchs)
            // XCTAssertFalse(info.architectures.contains("(tvOS)"))
        }
    }
    @Test(.requireSDKs(.linux))
    func discoveredLdLinkerSpecInfo_Linux() async throws {
        var table = try await ldMacroTable()
        table.push(BuiltinMacros._LD_MULTIARCH, literal: true)
        // Default Linker
        try await withSpec(LdLinkerSpec.self, .deferred, additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion != nil)
            if let toolVersion = info.toolVersion {
                #expect(toolVersion > Version(0, 0, 0))
            }
            #expect(info.linker == .gnuld)
        }
        try await withSpec(LdLinkerSpec.self, .result(status: .exit(0), stdout: Data("GNU ld (GNU Binutils for Debian) 2.40\n".utf8), stderr: Data()), additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion == Version(2, 40))
            #expect(info.architectures == Set())
        }

        try await withSpec(LdLinkerSpec.self, .result(status: .exit(0), stdout: Data("GNU ld version 2.29.1-31.amzn2.0.1\n".utf8), stderr: Data()), additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion == Version(2, 29, 1))
            #expect(info.architectures == Set())
        }
        // llvm-ld
        table.push(BuiltinMacros.ALTERNATE_LINKER, literal: "lld")
        try await withSpec(LdLinkerSpec.self, .deferred, additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion != nil)
            if let toolVersion = info.toolVersion {
                #expect(toolVersion > Version(0, 0, 0))
            }
            #expect(info.linker == .lld)
        }
        // gold
        table.push(BuiltinMacros.ALTERNATE_LINKER, literal: "gold")
        try await withSpec(LdLinkerSpec.self, .deferred, additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion != nil)
            if let toolVersion = info.toolVersion {
                #expect(toolVersion > Version(0, 0, 0))
            }
            #expect(info.linker == .gold)
        }
    }

    @Test(.skipHostOS(.windows), .requireSystemPackages(apt: "libtool", yum: "libtool"))
    func discoveredLibtoolSpecInfo() async throws {
        try await withSpec(LibtoolLinkerSpec.self, .deferred) { (info: DiscoveredLibtoolLinkerToolSpecInfo) in
            #expect(info.toolPath.basename == "libtool")
            #expect(info.toolVersion != nil)
            if let toolVersion = info.toolVersion {
                #expect(toolVersion > Version(0, 0, 0))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func discoveredLibtoolSpecInfoApple() async throws {
        try await withSpec(LibtoolLinkerSpec.self, .result(status: .exit(0), stdout: Data("Apple Inc. version cctools-1008.2".utf8), stderr: Data()), platform: "macosx") { (info: DiscoveredLibtoolLinkerToolSpecInfo) in
            #expect(info.toolPath.basename == "libtool")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(1008, 2))
        }

        try await withSpec(LibtoolLinkerSpec.self, .result(status: .exit(0), stdout: Data("Apple Inc. version cctools_sdk-1008.2".utf8), stderr: Data()), platform: "macosx") { (info: DiscoveredLibtoolLinkerToolSpecInfo) in
            #expect(info.toolPath.basename == "libtool")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(1008, 2))
        }
    }

    @Test(.requireSDKs(.linux))
    func discoveredLibtoolSpecInfoLinux() async throws {
        try await withSpec(LibtoolLinkerSpec.self, .result(status: .exit(0), stdout: Data("libtool (GNU libtool) 2.4.7\nWritten by AUTHOR, 1996\n\nCopyright (c) 2014 Free Software Foundation, Inc.\n\n".utf8), stderr: Data()), platform: "linux") { (info: DiscoveredLibtoolLinkerToolSpecInfo) in
            #expect(info.toolPath.basename == "libtool")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(2, 4, 7))
        }
    }

    @Test(.requireHostOS(.macOS))
    func discoveredTAPISpecInfo() async throws {
        try await withSpec("com.apple.build-tools.tapi.installapi", .deferred) { (info: DiscoveredTAPIToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion != nil)
            if let toolVersion = info.toolVersion {
                #expect(toolVersion > Version(0, 0, 0))
            }
        }

        // ...and with fake data
        try await withSpec("com.apple.build-tools.tapi.installapi", .result(status: .exit(0), stdout: Data("Apple TAPI version 15.0.0 (tapi-1500.0.9.1)".utf8), stderr: Data())) { (info: DiscoveredTAPIToolSpecInfo) in
            #expect(info.toolPath.basename == "tapi")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(1500, 0, 9, 1))
        }

        try await withSpec("com.apple.build-tools.tapi.installapi", .result(status: .exit(0), stdout: Data("Apple TAPI version 15.0.0 (tapi-1500.0.8.4.3) (+internal-os)".utf8), stderr: Data())) { (info: DiscoveredTAPIToolSpecInfo) in
            #expect(info.toolPath.basename == "tapi")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(1500, 0, 8, 4, 3))
        }
    }

    @Test(.requireHostOS(.macOS))
    func discoveredTAPIExtraToolsSpecInfo() async throws {
        try await withSpec("com.apple.compilers.documentation.objc-symbol-extract", .deferred) { (info: DiscoveredTAPIToolSpecInfo) in
            #expect(info.toolPath.basename == "tapi")
        }

        try await withSpec("com.apple.build-tools.tapi.merge", .deferred) { (info: DiscoveredTAPIToolSpecInfo) in
            #expect(info.toolPath.basename == "tapi")
        }
    }

    @Test(.skipHostOS(.windows)) // docc.exe is missing from the Swift toolchain distribution
    func discoveredDoccSpecInfo() async throws {
        let core = try await getCore()

        // Once with the real tool
        try await withSpec("com.apple.compilers.documentation", .deferred, { (info: DocumentationCompilerToolSpecInfo) in
            #expect(info.toolPath.basename == core.hostOperatingSystem.imageFormat.executableName(basename: "docc"))
            #expect(info.toolVersion == nil)
            #expect(info.toolFeatures.has(.diagnosticsFile))
        })
    }
}
