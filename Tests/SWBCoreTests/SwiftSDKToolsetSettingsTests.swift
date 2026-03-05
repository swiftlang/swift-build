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

import Testing

import SWBTestSupport
@_spi(Testing) import SWBUtil
@_spi(Testing) import SWBCore
import SWBProtocol
import SWBMacro

@Suite
fileprivate struct SwiftSDKToolsetSettingsTests: CoreBasedTests {
    private func writeToolsetJSON(_ toolset: SwiftSDK.Toolset, to path: Path) throws {
        try localFS.createDirectory(path.dirname, recursive: true)
        let data = try JSONEncoder().encode(toolset)
        try localFS.write(path, contents: ByteString(data))
    }

    private func createTestSettings(projectBuildSettings: [String: String] = [:]) async throws -> Settings {
        let core = try await getCore()
        let testWorkspace = try TestWorkspace("Workspace",
            projects: [
                TestProject("aProject",
                    groupTree: TestGroup("SomeFiles"),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: projectBuildSettings)
                    ],
                    targets: [
                        TestStandardTarget("MyTarget", type: .commandLineTool,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase([]),
                            ])
                    ])
            ]).load(core)

        let context = try await contextForTestData(testWorkspace, core: core, fs: localFS)
        let buildRequestContext = BuildRequestContext(workspaceContext: context)
        let testProject = context.workspace.projects[0]
        let testTarget = testProject.targets[0]

        let settings = Settings(workspaceContext: context, buildRequestContext: buildRequestContext,
                                parameters: BuildParameters(action: .build, configuration: "Debug"),
                                project: testProject, target: testTarget)
        return settings
    }

    @Test(.requireSDKs(.host))
    func toolsetBasics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let toolsetPath = tmpDir.join("toolset.json")
            let toolset = SwiftSDK.Toolset(
                rootPath: Path.root.join("toolchain").str,
                cCompiler: .init(path: Path("bin").join("clang").str, extraCLIOptions: ["-DCFLAG"]),
                cxxCompiler: .init(path: Path("bin").join("clang++").str, extraCLIOptions: ["-DCXXFLAG"]),
                swiftCompiler: .init(path: Path("bin").join("swiftc").str, extraCLIOptions: ["-DSWIFTFLAG"]),
                linker: .init(path: Path("bin").join("ld").str, extraCLIOptions: ["-lLib"]),
                librarian: .init(path: Path("bin").join("libtool").str, extraCLIOptions: ["-lOtherLib"])
            )
            try writeToolsetJSON(toolset, to: toolsetPath)
            let settings = try await createTestSettings(projectBuildSettings: ["SWIFT_SDK_TOOLSETS": toolsetPath.strWithPosixSlashes])

            #expect(settings.globalScope.evaluate(BuiltinMacros.SWIFT_EXEC).str == Path.root.join("toolchain").join("bin").join("swiftc").str)
            #expect(settings.globalScope.evaluate(BuiltinMacros.CC).str == Path.root.join("toolchain").join("bin").join("clang").str)
            #expect(settings.globalScope.evaluate(BuiltinMacros.CPLUSPLUS).str == Path.root.join("toolchain").join("bin").join("clang++").str)
            #expect(settings.globalScope.evaluate(BuiltinMacros.ALTERNATE_LINKER_PATH).str == Path.root.join("toolchain").join("bin").join("ld").str)
            #expect(settings.globalScope.evaluate(BuiltinMacros.AR).str == Path.root.join("toolchain").join("bin").join("libtool").str)
            #expect(settings.globalScope.evaluate(BuiltinMacros.LIBTOOL).str == Path.root.join("toolchain").join("bin").join("libtool").str)

            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_CFLAGS).contains("-DCFLAG"))
            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_CPLUSPLUSFLAGS).contains("-DCXXFLAG"))
            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains("-DSWIFTFLAG"))
            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_LDFLAGS).contains("-lLib"))
            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_LIBTOOLFLAGS).contains("-lOtherLib"))
        }
    }

    @Test(.requireSDKs(.host))
    func multipleToolsets() async throws {
        try await withTemporaryDirectory { tmpDir in
            let toolset1Path = tmpDir.join("toolset1.json")
            let toolset2Path = tmpDir.join("toolset2.json")
            try writeToolsetJSON(SwiftSDK.Toolset(swiftCompiler: .init(extraCLIOptions: ["-DFoo"])), to: toolset1Path)
            try writeToolsetJSON(SwiftSDK.Toolset(swiftCompiler: .init(extraCLIOptions: ["-DBar"])), to: toolset2Path)
            let settings = try await createTestSettings(projectBuildSettings: ["SWIFT_SDK_TOOLSETS": "\(toolset1Path.strWithPosixSlashes) \(toolset2Path.strWithPosixSlashes)"])

            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains("-DFoo"))
            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains("-DBar"))
        }
    }

    @Test(.requireSDKs(.host))
    func unsupportedSchemaVersion() async throws {
        try await withTemporaryDirectory { tmpDir in
            let toolsetPath = tmpDir.join("toolset.json")
            try writeToolsetJSON(SwiftSDK.Toolset(schemaVersion: "99.0"), to: toolsetPath)
            let settings = try await createTestSettings(projectBuildSettings: ["SWIFT_SDK_TOOLSETS": toolsetPath.strWithPosixSlashes])
            #expect(settings.errors.only?.hasPrefix("error processing toolset ") == true)
        }
    }

    @Test(.requireSDKs(.host))
    func swiftCompilerFlagsPassedToLinkerDriver() async throws {
        try await withTemporaryDirectory { tmpDir in
            let toolsetPath = tmpDir.join("toolset.json")
            let toolset = SwiftSDK.Toolset(
                swiftCompiler: .init(extraCLIOptions: ["-DSWIFTFLAG"])
            )
            try writeToolsetJSON(toolset, to: toolsetPath)
            let settings = try await createTestSettings(projectBuildSettings: [
                "SWIFT_SDK_TOOLSETS": toolsetPath.strWithPosixSlashes,
                "LINKER_DRIVER": "swiftc",
            ])

            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains("-DSWIFTFLAG"))
            #expect(settings.globalScope.evaluate(BuiltinMacros.OTHER_LDFLAGS).contains("-DSWIFTFLAG"))

            let settings2 = try await createTestSettings(projectBuildSettings: [
                "SWIFT_SDK_TOOLSETS": toolsetPath.strWithPosixSlashes,
                "LINKER_DRIVER": "clang",
            ])

            #expect(settings2.globalScope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains("-DSWIFTFLAG"))
            #expect(!settings2.globalScope.evaluate(BuiltinMacros.OTHER_LDFLAGS).contains("-DSWIFTFLAG"))
        }
    }

    @Test(.requireSDKs(.host))
    func toolPathResolution() async throws {
        try await withTemporaryDirectory { tmpDir in
            let toolsetPath = tmpDir.join("sdk/toolset.json")
            let toolset = SwiftSDK.Toolset(
                rootPath: Path.root.join("toolchain").str,
                cCompiler: .init(path: Path.root.join("usr").join("bin").join("clang").str),
                swiftCompiler: .init(path: Path("bin").join("swiftc").str),
            )
            try writeToolsetJSON(toolset, to: toolsetPath)
            let settings = try await createTestSettings(projectBuildSettings: ["SWIFT_SDK_TOOLSETS": toolsetPath.strWithPosixSlashes])

            #expect(settings.globalScope.evaluate(BuiltinMacros.CC).str == Path.root.join("usr").join("bin").join("clang").str)
            #expect(settings.globalScope.evaluate(BuiltinMacros.SWIFT_EXEC).str == Path.root.join("toolchain").join("bin").join("swiftc").str)

            let toolsetPath2 = tmpDir.join("sdk/toolset2.json")
            let toolset2 = SwiftSDK.Toolset(
                cxxCompiler: .init(path: Path("bin").join("clang++").str)
            )
            try writeToolsetJSON(toolset2, to: toolsetPath2)
            let settings2 = try await createTestSettings(projectBuildSettings: ["SWIFT_SDK_TOOLSETS": toolsetPath2.strWithPosixSlashes])

            #expect(settings2.globalScope.evaluate(BuiltinMacros.CPLUSPLUS) == tmpDir.join("sdk").join("bin").join("clang++"))
        }
    }
}
