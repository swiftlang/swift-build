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

import class Foundation.ProcessInfo
import struct Foundation.URL
import struct Foundation.UUID

import Testing

import func SWBBuildService.commandLineDisplayString
import SWBBuildSystem
import SWBCore
import struct SWBProtocol.RunDestinationInfo
import struct SWBProtocol.TargetDescription
import struct SWBProtocol.TargetDependencyRelationship
import SWBTestSupport
import SWBTaskExecution
@_spi(Testing) import SWBUtil
import SWBTestSupport

fileprivate func crossCompileTargets() throws -> [OperatingSystem] {
    // Skip the test when running on the same host as host testing is already covered by _most_ tests
    let hostOS = try ProcessInfo.processInfo.hostOperatingSystem()
    return [.linux, .freebsd, .openbsd].filter { $0 != hostOS }
}

@Suite
fileprivate struct GenerixUnixBuildOperationTests: CoreBasedTests {
    /// Tests cross-compilation to Linux, FreeBSD, and OpenBSD. Skipped with Xcode toolchains because lld is required for cross-compilation.
    @Test(.skipHostOS(.windows), .skipXcodeToolchain, arguments: try crossCompileTargets())
    func crossCompileCommandLineTool(operatingSystem: OperatingSystem) async throws {
        let core = try await getCore()

        // Skip the test when we don't have the necessary SDK, as this test specifically tests cross compilation via Swift SDKs.
        if try core.sdkRegistry.lookup(operatingSystem.xcodePlatformName) == nil && core.sdkRegistry.allSDKs.count(where: { try $0.aliases.contains(operatingSystem.xcodePlatformName) }) == 0 {
            // FIXME: Adopt Swift Testing API to "cancel" the test case when preconditions aren't met
            withKnownIssue {
                Issue.record("Skipping \(operatingSystem) because there is no Swift SDK installed for this platform")
            }
            return
        }

        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.c"),
                        TestFile("dynamic.c"),
                        TestFile("static.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "CODE_SIGNING_ALLOWED": "NO",
                        "DEFINES_MODULE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "\(operatingSystem.xcodePlatformName)",
                        "SUPPORTED_PLATFORMS": "\(operatingSystem.xcodePlatformName)",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.c"]),
                            TestFrameworksBuildPhase([
                                TestBuildFile(.target("dynamiclib")),
                                TestBuildFile(.target("staticlib")),
                            ])
                        ],
                        dependencies: [
                            "dynamiclib",
                            "staticlib",
                        ]
                    ),
                    TestStandardTarget(
                        "dynamiclib",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "DYLIB_INSTALL_NAME_BASE": "$ORIGIN",

                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["dynamic.c"]),
                        ],
                        productReferenceName: "libdynamiclib.so"
                    ),
                    TestStandardTarget(
                        "staticlib",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["static.c"]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.c")) { stream in
                stream <<< "int main() { }\n"
            }

            try await tester.fs.writeFileContents(projectDir.join("dynamic.c")) { stream in
                stream <<< "void dynamicLib() { }"
            }

            try await tester.fs.writeFileContents(projectDir.join("static.c")) { stream in
                stream <<< "void staticLib() { }"
            }

            let destination: RunDestinationInfo
            switch operatingSystem {
            case .linux:
                destination = .linux
            case .freebsd:
                destination = .freebsd
            case .openbsd:
                destination = .openbsd
            default:
                throw StubError.error("Unexpected platform \(operatingSystem)")
            }
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()

                let executionResult = try await Process.getOutput(url: URL(filePath: "/usr/bin/file"), arguments: [projectDir.join("build").join("Debug\(destination.builtProductsDirSuffix)").join(core.hostOperatingSystem.imageFormat.executableName(basename: "tool")).str], environment: destination.hostRuntimeEnvironment(core))
                #expect(executionResult.exitStatus == .exit(0))
                let s = String(decoding: executionResult.stdout, as: UTF8.self)
                #expect(s.contains("ELF 64-bit"), Comment(rawValue: s))
                if core.hostOperatingSystem != .openbsd {
                    switch operatingSystem {
                    case .linux:
                        #expect(s.contains("Linux"), Comment(rawValue: s))
                    case .freebsd:
                        #expect(s.contains("FreeBSD"), Comment(rawValue: s))
                    case .openbsd:
                        #expect(s.contains("OpenBSD"), Comment(rawValue: s))
                    default:
                        throw StubError.error("Unexpected platform \(operatingSystem)")
                    }
                } else {
                    // OpenBSD's `file` doesn't show platform details
                }
                #expect(String(decoding: executionResult.stderr, as: UTF8.self) == "")
            }
        }
    }
}
