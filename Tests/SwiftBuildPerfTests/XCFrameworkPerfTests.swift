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

import struct Foundation.UUID

import SwiftBuild
import SwiftBuildTestSupport

import SWBCore
import SWBTestSupport
import SWBUtil

import Testing

@Suite(.performance)
fileprivate struct XCFrameworkCreationPerfTests: CoreBasedTests, PerfTests {
    private let xcode: InstalledXcode
    private let infoLookup: any PlatformInfoLookup

    init() async throws {
        xcode = try await InstalledXcode.currentlySelected()
        infoLookup = try await Self.makeCore()
    }

    @Test(.requireSDKs(.macOS, .iOS), arguments: [true, false])
    func XCFrameworkCreationWithFrameworksPerf(useSwift: Bool) async throws {
        try await withTemporaryDirectory { tmpDir in
            let path1 = try await xcode.compileFramework(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)
            let path2 = try await xcode.compileFramework(path: tmpDir.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: useSwift)
            let path3 = try await xcode.compileFramework(path: tmpDir.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)

            let commandLine = ["createXCFramework", "-framework", path1.str, "-framework", path2.str, "-framework", path3.str, "-output"]

            let service = try await SWBBuildService()
            let console = SWBBuildServiceConsole(service: service)

            await measure {
                let (result, passed) = await console.sendCommand(commandLine + [tmpDir.join("sample-\(Foundation.UUID().description).xcframework").str])
                #expect(passed, Comment(rawValue: result.output))
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS), arguments: [true, false])
    func XCFrameworkCreationWithDynamicLibrariesPerf(useSwift: Bool) async throws {
        try await withTemporaryDirectory { tmpDir in
            let path1 = try await xcode.compileDynamicLibrary(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)
            let path2 = try await xcode.compileDynamicLibrary(path: tmpDir.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: useSwift)
            let path3 = try await xcode.compileDynamicLibrary(path: tmpDir.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: useSwift)

            let commandLine = ["createXCFramework", "-library", path1.str, "-headers", path1.dirname.join("include").str, "-library", path2.str, "-headers", path2.dirname.join("include").str, "-library", path3.str, "-headers", path3.dirname.join("include").str, "-output"]

            let service = try await SWBBuildService()
            let console = SWBBuildServiceConsole(service: service)

            await measure {
                let (result, passed) = await console.sendCommand(commandLine + [tmpDir.join("sample\(Foundation.UUID().description).xcframework").str])
                #expect(passed, Comment(rawValue: result.output))
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func buildPerformance_xcframework() async throws {
        let fs = localFS
        try await withTemporaryDirectory { temporaryDirectory in
            try await withAsyncDeferrable { deferrable in
                let tmpDir = temporaryDirectory.path
                let testSession = try await TestSWBSession(temporaryDirectory: temporaryDirectory)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await testSession.close()
                    }
                }

                let path1 = try await xcode.compileFramework(path: tmpDir.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true)
                let path2 = try await xcode.compileFramework(path: tmpDir.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: true)
                let path3 = try await xcode.compileFramework(path: tmpDir.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true)

                let outputPath = tmpDir.join("sample.xcframework")
                let commandLine = ["createXCFramework", "-framework", path1.str, "-framework", path2.str, "-framework", path3.str, "-output", outputPath.str]

                let service = try await SWBBuildService()
                let (result, message) = await service.createXCFramework(commandLine, currentWorkingDirectory: tmpDir.str, developerPath: nil)
                #expect(result, "unable to build xcframework: \(message)")

                let testTarget = TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestFrameworksBuildPhase(["sample.xcframework"]),
                    ],
                    dependencies: []
                )

                let testProject = TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("main.swift"),
                            TestFile("sample.xcframework"),
                            TestFile("Info.plist")
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALWAYS_SEARCH_USER_PATHS": "NO",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGN_IDENTITY": "-",
                            "ARCHS": "x86_64",
                            "SWIFT_VERSION": "5",
                        ]),
                    ],
                    targets: [
                        // Test building an app which links and embeds an xcframework.
                        testTarget,
                    ])

                let testWorkspace = TestWorkspace("aWorkspace",
                                                  sourceRoot: tmpDir.join("Test"),
                                                  projects: [testProject])
                let SRCROOT = testWorkspace.sourceRoot.join("aProject")

                let tester = try await CoreQualificationTester(testWorkspace, testSession, fs: fs)
                await deferrable.addBlock {
                    await #expect(throws: Never.self) {
                        try await tester.invalidate()
                    }
                }

                try fs.createDirectory(SRCROOT, recursive: true)

                // Copy the xcframework into place so it can be found.
                try fs.copy(outputPath, to: SRCROOT.join(outputPath.basename))

                // Write out the other source files.
                try fs.write(SRCROOT.join("main.swift"), contents: "import Foundation\npublic func f() {}\n")

                let request = {
                    var request = SWBBuildRequest()
                    request.useParallelTargets = true
                    request.parameters = SWBBuildParameters()
                    request.parameters.action = "build"
                    request.parameters.configurationName = "Debug"
                    request.add(target: SWBConfiguredTarget(guid: testTarget.guid, parameters: nil))
                    return request
                }()

                try await measure {
                    let events = try await testSession.runBuildOperation(request: request, delegate: TestBuildOperationDelegate())

                    try await tester.checkResults(events: events) { results in
                        results.checkTasks { tasks in
                            #expect(!tasks.isEmpty)
                        }
                        results.checkNoTask()

                        results.checkNote(.equal("Building targets in dependency order"))
                        results.checkNoDiagnostics()

                        results.checkNoFailedTasks()
                    }

                    #expect(events.filter { event in
                        switch event {
                        case .targetUpToDate:
                            return true
                        default:
                            return false
                        }
                    }.count == 0)

                    // completely remove the build folder to ensure all of the tasks are run again
                    try? fs.removeDirectory(SRCROOT.join("build"))
                }
            }
        }
    }
}
