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
@_spi(Testing) import SWBAndroidPlatform
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SWBCore
import struct SWBProtocol.SwiftSDK
import SWBMacro

@Suite
fileprivate struct AndroidTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host), .enabled("No Android NDK is installed at any of the standard locations", { try await AndroidPlugin().effectiveInstallation(host: ProcessInfo.processInfo.hostOperatingSystem())?.ndk != nil }), arguments: ["aarch64", "x86_64"])
    func androidSwiftSDKRunDestination(architecture: String) async throws {
        // FIXME: Switch to Test.cancel once we are on Swift 6.3.
        let ndk = try #require(try await AndroidPlugin().effectiveInstallation(host: ProcessInfo.processInfo.hostOperatingSystem())?.ndk)
        try await withTemporaryDirectory { tmpDir in
            let clangCompilerPath = try await self.clangCompilerPath
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("SwiftFile.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyLibrary",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "auto",
                                                    "SUPPORTED_PLATFORMS": "android",
                                                    "CLANG_ENABLE_MODULES": "YES",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "CC": clangCompilerPath.str,
                                                    "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SourceFile.c"),
                                TestBuildFile("SwiftFile.swift"),
                            ]),
                        ]),
                ])
            // Use a dedicated core for this test so the SDKs it registers do not impact other tests
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            // Swift SDK contents
            let sdkManifestContents = """
            {
                "schemaVersion": "4.0",
                "targetTriples": {
                    "aarch64-unknown-linux-android28": {
                        "sdkRootPath": "ndk-sysroot",
                        "swiftResourcesPath": "swift-resources/usr/lib/swift-aarch64",
                        "swiftStaticResourcesPath": "swift-resources/usr/lib/swift_static-aarch64",
                        "toolsetPaths": [ "swift-toolset.json" ]
                    },
                    "x86_64-unknown-linux-android28": {
                        "sdkRootPath": "ndk-sysroot",
                        "swiftResourcesPath": "swift-resources/usr/lib/swift-x86_64",
                        "swiftStaticResourcesPath": "swift-resources/usr/lib/swift_static-x86_64",
                        "toolsetPaths": [ "swift-toolset.json" ]
                    }
                }
            }
            """
            let sdkManifestDir = tmpDir
            try localFS.createDirectory(sdkManifestDir)
            let sdkManifestPath = sdkManifestDir.join("swift-sdk.json")
            try await localFS.writeFileContents(sdkManifestDir.join("swift-sdk.json"), waitForNewTimestamp: false, body: { $0.write(sdkManifestContents) })
            try await localFS.writeFileContents(sdkManifestDir.join("swift-toolset.json"), waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "cCompiler": { "extraCLIOptions": ["-fPIC"] },
                    "swiftCompiler": { "extraCLIOptions": ["-Xclang-linker", "-fuse-ld=lld"] },
                    "linker": { "extraCLIOptions": ["-z", "max-page-size=16384"] },
                    "schemaVersion": "1.0"
                }
                """)
            })


            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: "\(architecture)-unknown-linux-android28", targetArchitecture: architecture, supportedArchitectures: ["aarch64", "x86_64"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination, overrides: ["ANDROID_DEPLOYMENT_TARGET": "28"])
            await tester.checkBuild(parameters, runDestination: nil, fs: localFS) { results in
                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains([
                        [clangCompilerPath.str],
                        ["-target", "\(architecture)-unknown-linux-android28"],
                    ].reduce([], +))

                    task.checkCommandLineMatches([.equal("--sysroot"), .pathEqual(prefix: "", ndk.sysroot.path)])
                }

                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains([
                        ["-resource-dir", sdkManifestDir.join("swift-resources").join("usr").join("lib").join("swift-\(architecture)").str],
                        ["-sdk", ndk.sysroot.path.str],
                        ["-target", "\(architecture)-unknown-linux-android28"],
                    ].reduce([], +))

                    task.checkCommandLineMatches([.equal("-sysroot"), .pathEqual(prefix: "", ndk.sysroot.path)])
                }

                results.checkTask(.matchTargetName("MyLibrary"), .matchRuleType("Ld")) { task in
                    task.checkCommandLineContains([
                        ["-target", "\(architecture)-unknown-linux-android28"],
                    ].reduce([], +))

                    task.checkCommandLineMatches([.equal("--sysroot"), .pathEqual(prefix: "", ndk.sysroot.path)])
                    task.checkCommandLineMatches([.equal("-resource-dir"), .pathEqual(prefix: "", ndk.clangResourceDir.path)])

                    // See Android.xcspec
                    task.checkCommandLineDoesNotContain("-sdk")
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }
}

fileprivate extension Core {
    func findAndroidSwiftSDK() async throws -> SwiftSDK? {
        try await findSwiftSDK("android")
    }
}

fileprivate extension Trait where Self == Testing.ConditionTrait {
    static var requiresAndroidSwiftSDK: Self {
        requireSwiftSDK("android", in: { try await AndroidBuildOperationTests.getSwiftSDKIntegrationTestingCore() })
    }
}

@Suite
fileprivate struct AndroidBuildOperationTests: CoreBasedTests {
    /// Tests C and C++ compilation for Android using only the Android NDK. Does not require or use a Swift SDK.
    @Test(.requireSDKs(.android), arguments: ["armv7", "aarch64", "riscv64", "i686", "x86_64"])
    func androidCommandLineTool(arch: String) async throws {
        try await withTemporaryDirectory { (tmpDir: Path) -> () in
            let testProject = TestProject(
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
                        "ARCHS": arch,
                        "CODE_SIGNING_ALLOWED": "NO",
                        "DEFINES_MODULE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "android",
                        "SUPPORTED_PLATFORMS": "android",
                        "ANDROID_DEPLOYMENT_TARGET": "22.0",
                        "ANDROID_DEPLOYMENT_TARGET[arch=riscv64]": "35.0",
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
            let core = try await getCore()
            let androidExtension = try #require(core.pluginManager.extensions(of: SDKRegistryExtensionPoint.self).compactMap { $0 as? AndroidSDKRegistryExtension }.only)
            let (_, androidNdk) = try #require(await androidExtension.plugin.effectiveInstallation(host: core.hostOperatingSystem))
            if androidNdk.version < Version(27) && arch == "riscv64" {
                return // riscv64 support was introduced in NDK r27
            }

            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.c")) { stream in
                stream <<< "int main() { }\n"
            }

            try await tester.fs.writeFileContents(projectDir.join("dynamic.c")) { stream in
                stream <<<
                """
                #include <stdlib.h>
                #include <stddef.h>
                #include <errno.h>
                #include <unistd.h>
                void dynamicLib() { }
                """
            }

            try await tester.fs.writeFileContents(projectDir.join("dynamic.cpp")) { stream in
                stream <<<
                """
                #include <cstdlib>
                #include <cstddef>
                #include <stddef.h>
                #include <errno.h>
                #include <unistd.h>
                void dynamicLibCxx() { }
                """
            }

            try await tester.fs.writeFileContents(projectDir.join("static.c")) { stream in
                stream <<<
                """
                #include <stdlib.h>
                #include <stddef.h>
                #include <errno.h>
                #include <unistd.h>
                void staticLib() { }
                """
            }

            try await tester.fs.writeFileContents(projectDir.join("static.cpp")) { stream in
                stream <<<
                """
                #include <cstdlib>
                #include <cstddef>
                #include <stddef.h>
                #include <errno.h>
                #include <unistd.h>
                void staticLibCxx() { }
                """
            }

            let minOS = arch == "riscv64" ? "35.0" : "22.0"

            let destination: RunDestinationInfo = .android
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()

                let clang = Path("bin").join(core.hostOperatingSystem.imageFormat.executableName(basename: "clang"))

                let pageSizeFlags: [StringPattern] = ["aarch64", "x86_64"].contains(arch) ? ["-Xlinker", "-z", "-Xlinker", "max-page-size=16384"] : []

                let sdk = try #require(core.sdkRegistry.lookup("android"))

                // The Android SDK in the Swift for Windows installer has extra search paths
                let sdkPath = (sdk.overrideSettings["__ANDROID_SDK_DIR"]?.stringValue).map(Path.init) ?? nil
                let windowsArgs: [StringPattern] = sdkPath.map { [.pathEqual(prefix: "-L", $0.join("usr/lib/swift/android/\(arch)"))] } ?? []

                results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-android/libdynamiclib.so").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(clang.str),
                        "-target", "\(arch)-unknown-linux-android\(minOS)",
                        "-shared",
                        "--sysroot",
                        .contains(Path("/toolchains/llvm/prebuilt/").str),
                        "-resource-dir",
                        .and(.contains(Path("/toolchains/llvm/prebuilt/").str), .contains(Path("/lib/clang/").str)),
                        "-Os",
                        .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-android")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/Debug-android")),
                    ] + windowsArgs + [
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-android/dynamiclib.build/Objects-normal/\(arch)/dynamiclib.LinkFileList")),
                        "-Xlinker", "-soname", "-Xlinker", "$ORIGIN/libdynamiclib.so",
                    ] + pageSizeFlags + [
                        "-fuse-ld=lld",
                        .and(.prefix("--ld-path="), .contains("ld.lld")),
                        "-o", .path(tmpDir.join("build/Debug-android/libdynamiclib.so"))
                    ])
                }

                results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-android/tool").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(clang.str),
                        "-target", "\(arch)-unknown-linux-android\(minOS)",
                        "--sysroot", .contains(Path("/toolchains/llvm/prebuilt/").str),
                        "-resource-dir",
                        .and(.contains(Path("/toolchains/llvm/prebuilt/").str), .contains(Path("/lib/clang/").str)),
                        "-Os",
                        .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-android")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/Debug-android")),
                    ] + windowsArgs + [
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-android/tool.build/Objects-normal/\(arch)/tool.LinkFileList")),
                    ] + pageSizeFlags + [
                        "-fuse-ld=lld",
                        .and(.prefix("--ld-path="), .contains("ld.lld")),
                        "-ldynamiclib",
                        "-lstaticlib",
                        "-o", .path(tmpDir.join("build/Debug-android/tool"))
                    ])
                }

                #expect(tester.fs.exists(projectDir.join("build").join("Debug\(destination.builtProductsDirSuffix)").join("tool")))
            }
        }
    }

    /// Tests Swift compilation for Android using a Swift SDK.
    @Test(.requireSDKs(.android), .requiresAndroidSwiftSDK, arguments: ["aarch64", "x86_64"])
    func androidCommandLineToolWithSwift_swiftSDK(arch: String) async throws {
        let core = try await Self.getSwiftSDKIntegrationTestingCore()
        let swiftSDK = try await core.findAndroidSwiftSDK()
        try await _androidCommandLineToolWithSwift(arch: arch, core: core, swiftSDK: swiftSDK)
    }

    /// Tests Swift compilation for Android using a toolchain-style SDK. This test will only ever run on a Windows host because only Windows hosts provide a toolchain-style SDK for Android.
    @Test(.requireSDKs(.android), .requireAndroidHasSwift, arguments: ["aarch64", "x86_64"])
    func androidCommandLineToolWithSwift_toolchain(arch: String) async throws {
        let core = try await getCore()
        try await _androidCommandLineToolWithSwift(arch: arch, core: core, swiftSDK: nil)
    }

    func _androidCommandLineToolWithSwift(arch: String, core: Core, swiftSDK: SwiftSDK?) async throws {
        try await withTemporaryDirectory { (tmpDir: Path) -> () in
            let defaultDeploymentTarget = swiftSDK != nil ? "28.0" : "22.0"
            let testProject = TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                        TestFile("dynamic.swift"),
                        TestFile("static.swift"),
                        TestFile("cmodule.h"),
                        TestFile("cmodule.c"),
                        TestFile("cmodule.modulemap"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": arch,
                        "CODE_SIGNING_ALLOWED": "NO",
                        "DEFINES_MODULE": "YES",
                        "LINKER_DRIVER": "auto",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": swiftSDK != nil ? "auto" : "android",
                        "SUPPORTED_PLATFORMS": swiftSDK != nil ? "$(AVAILABLE_PLATFORMS)" : "android",
                        "SWIFT_VERSION": "6.0",
                        "ANDROID_DEPLOYMENT_TARGET": defaultDeploymentTarget,
                        "ANDROID_DEPLOYMENT_TARGET[arch=riscv64]": "35.0",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "OTHER_SWIFT_FLAGS": "$(inherited) -Xcc -fmodule-map-file=$(PROJECT_DIR)/cmodule.modulemap"
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                            TestFrameworksBuildPhase([
                                TestBuildFile(.target("dynamiclib")),
                                TestBuildFile(.target("staticlib")),
                                TestBuildFile(.target("cmodule")),
                            ])
                        ],
                        dependencies: [
                            "cmodule",
                            "dynamiclib",
                            "staticlib",
                        ]
                    ),
                    TestStandardTarget(
                        "cmodule",
                        type: .staticLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "MODULEMAP_FILE": "cmodule.modulemap",

                                // FIXME: Find a way to make these default
                                "EXECUTABLE_PREFIX": "lib",
                            ])
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("cmodule.h", headerVisibility: .public)
                            ]),
                            TestSourcesBuildPhase(["cmodule.c"])
                        ],
                        productReferenceName: "libcmodule.a"
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
                            TestSourcesBuildPhase(["dynamic.swift"]),
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
                            TestSourcesBuildPhase(["static.swift"]),
                        ]
                    ),
                ])
            let androidExtension = try #require(core.pluginManager.extensions(of: SDKRegistryExtensionPoint.self).compactMap { $0 as? AndroidSDKRegistryExtension }.only)
            let (_, androidNdk) = try #require(await androidExtension.plugin.effectiveInstallation(host: core.hostOperatingSystem))
            if androidNdk.version < Version(27) && arch == "riscv64" {
                return // riscv64 support was introduced in NDK r27
            }

            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<<
                """
                import cmodule
                func main() {
                    f()
                }
                """
            }

            try await tester.fs.writeFileContents(projectDir.join("dynamic.swift")) { stream in
                stream <<< "func dynamicLib() { }"
            }

            try await tester.fs.writeFileContents(projectDir.join("static.swift")) { stream in
                stream <<< "func staticLib() { }"
            }

            try await tester.fs.writeFileContents(projectDir.join("cmodule.h")) { stream in
                stream <<<
                """
                #include <stdlib.h>
                #include <stddef.h>
                #include <errno.h>
                #include <unistd.h>
                void f();
                """
            }

            try await tester.fs.writeFileContents(projectDir.join("cmodule.c")) { stream in
                stream <<< "void f() {}"
            }

            try await tester.fs.writeFileContents(projectDir.join("cmodule.modulemap")) { stream in
                stream <<<
                """
                module cmodule {
                    umbrella header "cmodule.h"
                    export *
                }
                """
            }

            let minOS = arch == "riscv64" ? "35.0" : defaultDeploymentTarget

            let destination: RunDestinationInfo
            if let swiftSDK {
                destination = try RunDestinationInfo(sdkManifestPath: swiftSDK.manifestPath, triple: "\(arch)-unknown-linux-android\(Version(minOS).zeroTrimmed.description)", targetArchitecture: arch, supportedArchitectures: [arch], disableOnlyActiveArch: true, core: core)
            } else {
                destination = .init(platform: "android", sdk: "android", sdkVariant: "android", targetArchitecture: "undefined_arch", supportedArchitectures: ["armv7", "aarch64", "riscv64", "i686", "x86_64"], disableOnlyActiveArch: true)
            }

            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()
                results.checkWarnings([.contains("next compile won't be incremental")], failIfNotFound: false)

                let swiftc = Path("bin").join(core.hostOperatingSystem.imageFormat.executableName(basename: "swiftc"))

                let pageSizeFlags: [StringPattern] = ["aarch64", "x86_64"].contains(arch) ? ["-Xlinker", "-z", "-Xlinker", "max-page-size=16384"] : []

                let sdk = try #require(core.sdkRegistry.lookup("android"))

                // The Android SDK in the Swift for Windows installer has extra search paths
                let sdkPath = (sdk.overrideSettings["__ANDROID_SDK_DIR"]?.stringValue).map(Path.init) ?? nil
                let windowsArgs: [StringPattern] = sdkPath.map { [.pathEqual(prefix: "-L", $0.join("usr/lib/swift/android/\(arch)"))] } ?? []

                results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-android/libdynamiclib.so").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(swiftc.str),
                        "-target", "\(arch)-unknown-linux-android\(minOS)",
                        "-emit-library",
                        "-sysroot",
                        .contains(Path("/toolchains/llvm/prebuilt/").str),
                        "-Xclang-linker", "-resource-dir", "-Xclang-linker",
                        .and(.contains(Path("/toolchains/llvm/prebuilt/").str), .contains(Path("/lib/clang/").str)),
                        "-resource-dir",
                        .or(.contains("Android.sdk"), .contains(".artifactbundle")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-android")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/Debug-android")),
                    ] + windowsArgs + [
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-android/dynamiclib.build/Objects-normal/\(arch)/dynamiclib.LinkFileList")),
                        "-Xlinker", "-soname", "-Xlinker", "$ORIGIN/libdynamiclib.so",
                        .and(.prefix("-L"), .or(.suffix("/usr/lib/swift"), .suffix("\\usr\\lib\\swift\\android"))),
                        .pathEqual(prefix: "-L", Path("/usr/lib/swift")),
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-android/dynamiclib.build/Objects-normal/\(arch)/dynamiclib-swiftbuild.autolink")),
                    ] + pageSizeFlags + [
                        "-use-ld=lld",
                        .and(.prefix("-ld-path="), .contains("ld.lld")),
                        "-o", .path(tmpDir.join("build/Debug-android/libdynamiclib.so"))
                    ])
                }

                results.checkTask(.matchRuleType("Ld"), .matchRuleItemPattern(.suffix(Path("build/Debug-android/tool").str))) { task in
                    task.checkCommandLineMatches([
                        .suffix(swiftc.str),
                        "-target", "\(arch)-unknown-linux-android\(minOS)",
                        "-emit-executable",
                        "-sysroot",
                        .contains(Path("/toolchains/llvm/prebuilt/").str),
                        "-Xclang-linker", "-resource-dir", "-Xclang-linker",
                        .and(.contains(Path("/toolchains/llvm/prebuilt/").str), .contains(Path("/lib/clang/").str)),
                        "-resource-dir",
                        .or(.contains("Android.sdk"), .contains(".artifactbundle")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/EagerLinkingTBDs/Debug-android")),
                        .pathEqual(prefix: "-L", tmpDir.join("build/Debug-android")),
                    ] + windowsArgs + [
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-android/tool.build/Objects-normal/\(arch)/tool.LinkFileList")),
                        .and(.prefix("-L"), .or(.suffix("/usr/lib/swift"), .suffix("\\usr\\lib\\swift\\android"))),
                        .pathEqual(prefix: "-L", Path("/usr/lib/swift")),
                        .pathEqual(prefix: "@", tmpDir.join("build/TestProject.build/Debug-android/tool.build/Objects-normal/\(arch)/tool-swiftbuild.autolink")),
                    ] + pageSizeFlags + [
                        "-use-ld=lld",
                        .and(.prefix("-ld-path="), .contains("ld.lld")),
                        "-ldynamiclib",
                        "-lstaticlib",
                        "-lcmodule",
                        "-o", .path(tmpDir.join("build/Debug-android/tool"))
                    ])
                }

                #expect(tester.fs.exists(projectDir.join("build").join("Debug\(destination.builtProductsDirSuffix)").join("tool")))
            }
        }
    }
}
