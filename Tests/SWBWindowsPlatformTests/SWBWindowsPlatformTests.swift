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
    // Linker tool discovery is a bit more complex as it afffected by the ALTERNATE_LINKER build setting.
    func ldMacroTable() async throws ->  MacroValueAssignmentTable {
            let core = try await getCore()
            return MacroValueAssignmentTable(namespace: core.specRegistry.internalMacroNamespace)
    }

    @Test(.requireSDKs(.windows))
    func discoveredLdLinkerSpecInfo_Windows() async throws {
        var table = try await ldMacroTable()
        let core = try await getCore()
        table.push(BuiltinMacros._LD_MULTIARCH, literal: true)
        try await withSpec(LdLinkerSpec.self, .deferred, platform: "windows", additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion != nil)
            if let toolVersion = info.toolVersion {
                #expect(toolVersion > Version(0, 0, 0))
            }
            #expect(info.linker == .lld)
        }
        try await withSpec(LdLinkerSpec.self, .result(status: .exit(0), stdout: Data("Microsoft (R) Incremental Linker Version 14.41.34120.0\n".utf8), stderr: Data()), platform: "windows", additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
            #expect(!info.toolPath.isEmpty)
            #expect(info.toolVersion == Version(14, 41, 34120))
            #expect(info.architectures == Set())
        }

        // link.exe cannot be used for multipler architectures and requires a distinct link.exe for each target architecture
        table.push(BuiltinMacros.ALTERNATE_LINKER, literal: "link")
        table.push(BuiltinMacros._LD_MULTIARCH, literal: false)
        table.push(BuiltinMacros._LD_MULTIARCH_PREFIX_MAP, literal: ["aarch64:arm64", "arm64ec:arm64", "armv7:arm", "x86_64:x64", "i686:x86"])

        // link x86_64
        if try await core.hasVisualStudioComponent(.visualCppBuildTools_x86_x64) {
            table.push(BuiltinMacros.ARCHS, literal: ["x86_64"])
            try await withSpec(LdLinkerSpec.self, .deferred, platform: "windows", additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
                #expect(!info.toolPath.isEmpty)
                #expect(info.toolVersion != nil)
                if let toolVersion = info.toolVersion {
                    #expect(toolVersion > Version(0, 0, 0))
                }
                #expect(info.linker == .linkExe)
            }
        }
        // link i686
        if try await core.hasVisualStudioComponent(.visualCppBuildTools_x86_x64) {
            table.push(BuiltinMacros.ARCHS, literal: ["i686"])
            try await withSpec(LdLinkerSpec.self, .deferred, platform: "windows", additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
                #expect(!info.toolPath.isEmpty)
                #expect(info.toolVersion != nil)
                if let toolVersion = info.toolVersion {
                    #expect(toolVersion > Version(0, 0, 0))
                }
                #expect(info.linker == .linkExe)
            }
        }
        // link aarch64
        if try await core.hasVisualStudioComponent(.visualCppBuildTools_arm64) {
            table.push(BuiltinMacros.ARCHS, literal: ["aarch64"])
            try await withSpec(LdLinkerSpec.self, .deferred, platform: "windows", additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
                #expect(!info.toolPath.isEmpty)
                #expect(info.toolVersion != nil)
                if let toolVersion = info.toolVersion {
                    #expect(toolVersion > Version(0, 0, 0))
                }
                #expect(info.linker == .linkExe)
            }
        }
        // link armv7
        if try await core.hasVisualStudioComponent(.visualCppBuildTools_arm) {
            table.push(BuiltinMacros.ARCHS, literal: ["armv7"])
            try await withSpec(LdLinkerSpec.self, .deferred, platform: "windows", additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
                #expect(!info.toolPath.isEmpty)
                #expect(info.toolVersion != nil)
                if let toolVersion = info.toolVersion {
                    #expect(toolVersion > Version(0, 0, 0))
                }
                #expect(info.linker == .linkExe)
            }
        }
        // link arm64ec
        if try await core.hasVisualStudioComponent(.visualCppBuildTools_arm64ec) {
            table.push(BuiltinMacros.ARCHS, literal: ["arm64ec"])
            try await withSpec(LdLinkerSpec.self, .deferred, platform: "windows", additionalTable: table) { (info: DiscoveredLdLinkerToolSpecInfo) in
                #expect(!info.toolPath.isEmpty)
                #expect(info.toolVersion != nil)
                if let toolVersion = info.toolVersion {
                    #expect(toolVersion > Version(0, 0, 0))
                }
                #expect(info.linker == .linkExe)
            }
        }
    }
}