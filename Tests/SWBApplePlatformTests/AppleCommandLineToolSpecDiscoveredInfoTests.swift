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
import SWBApplePlatform
import Testing
import SWBCore
import SWBTestSupport
import SWBUtil
import SWBProtocol

@Suite
fileprivate struct AppleCommandLineToolSpecDiscoveredInfoTests: CoreBasedTests {
    func _testDiscoveredIbSpecInfo(_ spec: CommandLineToolSpec) async throws {
        try await withSpec(spec.identifier, .deferred) { (info: DiscoveredIbtoolToolSpecInfo) in
            XCTAssertMatch(info.toolPath.basename, .or(.equal("actool"), .equal("ibtool")))
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion > Version(0, 0, 0))
            let bundleVersion = try #require(info.bundleVersion)
            #expect(bundleVersion > Version(0, 0, 0))
            let shortBundleVersion = try #require(info.shortBundleVersion)
            #expect(shortBundleVersion > Version(0, 0, 0))
        }
    }

    @Test(.requireHostOS(.macOS))
    func discoveredActoolSpecInfo() async throws {
        // Once with the real tool
        try await _testDiscoveredIbSpecInfo(getCore().specRegistry.getSpec() as ActoolCompilerSpec)

        let output = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>com.apple.actool.version</key>
                <dict>
                    <key>bundle-version</key>
                    <string>87946</string>
                    <key>short-bundle-version</key>
                    <string>125.1</string>
                </dict>
            </dict>
            </plist>
            """

        // ...and with fake data
        try await withSpec(ActoolCompilerSpec.self, .result(status: .exit(0), stdout: Data(output.utf8), stderr: Data())) { (info: DiscoveredIbtoolToolSpecInfo) in
            #expect(info.toolPath.basename == "actool")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(87946))
            let bundleVersion = try #require(info.bundleVersion)
            #expect(bundleVersion == Version(87946))
            let shortBundleVersion = try #require(info.shortBundleVersion)
            #expect(shortBundleVersion == Version(125, 1))
        }
    }

    @Test(.requireHostOS(.macOS))
    func discoveredIbtoolSpecInfo() async throws {
        // Once with the real tool
        try await _testDiscoveredIbSpecInfo(getCore().specRegistry.getSpec() as IbtoolCompilerSpecStoryboard)

        let output = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>com.apple.ibtool.version</key>
                <dict>
                    <key>bundle-version</key>
                    <string>87946</string>
                    <key>short-bundle-version</key>
                    <string>125.1</string>
                </dict>
            </dict>
            </plist>
            """

        // ...and with fake data
        try await withSpec(IbtoolCompilerSpecStoryboard.self, .result(status: .exit(0), stdout: Data(output.utf8), stderr: Data())) { (info: DiscoveredIbtoolToolSpecInfo) in
            #expect(info.toolPath.basename == "ibtool")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(87946))
            let bundleVersion = try #require(info.bundleVersion)
            #expect(bundleVersion == Version(87946))
            let shortBundleVersion = try #require(info.shortBundleVersion)
            #expect(shortBundleVersion == Version(125, 1))
        }
    }

    @Test(.requireHostOS(.macOS))
    func discoveredStoryboardLinkerSpecInfo() async throws {
        // Once with the real tool
        try await _testDiscoveredIbSpecInfo(getCore().specRegistry.getSpec() as IBStoryboardLinkerCompilerSpec)

        let output = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>com.apple.ibtool.version</key>
                <dict>
                    <key>bundle-version</key>
                    <string>87946</string>
                    <key>short-bundle-version</key>
                    <string>125.1</string>
                </dict>
            </dict>
            </plist>
            """

        // ...and with fake data
        try await withSpec(IBStoryboardLinkerCompilerSpec.self, .result(status: .exit(0), stdout: Data(output.utf8), stderr: Data())) { (info: DiscoveredIbtoolToolSpecInfo) in
            #expect(info.toolPath.basename == "ibtool")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(87946))
            let bundleVersion = try #require(info.bundleVersion)
            #expect(bundleVersion == Version(87946))
            let shortBundleVersion = try #require(info.shortBundleVersion)
            #expect(shortBundleVersion == Version(125, 1))
        }
    }

    @Test(.requireHostOS(.macOS))
    func discoveredMigSpecInfo() async throws {
        // Once with the real tool
        try await withSpec(MigCompilerSpec.self, .deferred) { (info: DiscoveredMiGToolSpecInfo) in
            #expect(info.toolPath.basename == "mig")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion > Version(0, 0, 0))
        }

        // ...and with fake data
        try await withSpec(MigCompilerSpec.self, .result(status: .exit(0), stdout: Data("bootstrap_cmds-108\n".utf8), stderr: Data())) { (info: DiscoveredMiGToolSpecInfo) in
            #expect(info.toolPath.basename == "mig")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(108))
        }

        try await withSpec(MigCompilerSpec.self, .result(status: .exit(0), stdout: Data("bootstrap_cmds-99.0.0.400.6\n".utf8), stderr: Data())) { (info: DiscoveredMiGToolSpecInfo) in
            #expect(info.toolPath.basename == "mig")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(99, 0, 0, 400, 6))
        }
    }

    @Test(.requireHostOS(.macOS))
    func discoveredIigSpecInfo() async throws {
        // Once with the real tool
        try await withSpec("com.apple.compilers.iig", .deferred) { (info: DiscoveredIiGToolSpecInfo) in
            #expect(info.toolPath.basename == "iig")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion > Version(0, 0, 0))
        }

        // ...and with fake data
        try await withSpec("com.apple.compilers.iig", .result(status: .exit(0), stdout: Data("DriverKit-29\n".utf8), stderr: Data())) { (info: DiscoveredIiGToolSpecInfo) in
            #expect(info.toolPath.basename == "iig")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(29))
        }
    }

    @Test(.requireHostOS(.macOS))
    func discoveredCoreMLSpecInfo() async throws {
        try await withSpec(CoreMLCompilerSpec.self, .deferred) { (info: DiscoveredCoreMLToolSpecInfo) in
            #expect(info.toolPath.basename == "coremlc")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion > Version(0, 0, 0))
        }

        // ...and with fake data
        try await withSpec(CoreMLCompilerSpec.self, .result(status: .exit(0), stdout: Data("PROGRAM:coremlcompiler  PROJECT:CoreML-1749.0.0.0.2\nPROGRAM:coremlcompiler  PROJECT:CoreML-1749.0.0.0.2\n".utf8), stderr: Data())) { (info: DiscoveredCoreMLToolSpecInfo) in
            #expect(info.toolPath.basename == "coremlc")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(1749, 0, 0, 0, 2))
        }

        try await withSpec(CoreMLCompilerSpec.self, .result(status: .exit(0), stdout: Data("PROGRAM:coremlc  PROJECT:IDEMLKit-999999\n".utf8), stderr: Data())) { (info: DiscoveredCoreMLToolSpecInfo) in
            #expect(info.toolPath.basename == "coremlc")
            let toolVersion = try #require(info.toolVersion)
            #expect(toolVersion == Version(999999))
        }
    }
}
