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

import class SwiftBuild.SWBBuildService
import SWBBuildSystem
import SWBCore
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SWBProtocol

@Suite
fileprivate struct XCFrameworkBuildOperationTests: CoreBasedTests {
    enum WrappedFileType {
        case `static`
        case macho(MachO.FileType)
    }

    /// Check the handling of processing dynamically linked XCFrameworks.
    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func xCFrameworkProcessing() async throws {
        try await testXCFrameworkProcessing(fileType: .macho(.dylib))
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func xCFrameworkProcessingSkipDynamicAutoEmbed() async throws {
        try await testXCFrameworkProcessing(fileType: .macho(.dylib), skipDynamicAutoEmbed: true)
    }

    /// Check the handling of processing statically linked XCFrameworks.
    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func xCFrameworkProcessingStatic() async throws {
        try await testXCFrameworkProcessing(fileType: .static)
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func xCFrameworkProcessingStaticSkipAutoEmbed() async throws {
        try await testXCFrameworkProcessing(fileType: .static, skipStaticAutoEmbed: true)
    }

    /// Check the handling of processing XCFrameworks containing object files.
    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func xCFrameworkProcessingObject() async throws {
        try await testXCFrameworkProcessing(fileType: .macho(.object))
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func xCFrameworkProcessingObjectSkipAutoEmbed() async throws {
        try await testXCFrameworkProcessing(fileType: .macho(.object), skipStaticAutoEmbed: true)
    }

    func testXCFrameworkProcessing(fileType: WrappedFileType, skipDynamicAutoEmbed: Bool = false, skipStaticAutoEmbed: Bool = false) async throws {
        var `static`: Bool = false
        var object: Bool = false
        switch (fileType) {
        case .static: `static` = true
        case .macho(.object): object = true
        case .macho(.dylib): break
        default: break
        }

        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let xcode = try await InstalledXcode.currentlySelected()
            let infoLookup = try await getCore()
            let path1 = try await xcode.compileFramework(path: tmpDirPath.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, static: `static`, linkerOptions: [.noAdhocCodeSign],object: object, needInfoPlist: true, needSigned: true)
            let path2 = try await xcode.compileFramework(path: tmpDirPath.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: true, static: `static`, linkerOptions: [.noAdhocCodeSign], object: object, needInfoPlist: true, needSigned: true)
            let path3 = try await xcode.compileFramework(path: tmpDirPath.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, static: `static`, linkerOptions: [.noAdhocCodeSign], object: object, needInfoPlist: true, needSigned: true)
            let path4 = try await xcode.compileFramework(path: tmpDirPath.join("watchos"), platform: .watchOS, infoLookup: infoLookup, archs: ["arm64_32"], useSwift: true, static: `static`, linkerOptions: [.noAdhocCodeSign], object: object, needInfoPlist: true, needSigned: true)
            let path5 = try await xcode.compileFramework(path: tmpDirPath.join("watchsimulator"), platform: .watchOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, static: `static`, linkerOptions: [.noAdhocCodeSign], object: object, needInfoPlist: true, needSigned: true)

            let outputPath = tmpDirPath.join("Test/aProject/Sources/sample.xcframework")
            let commandLine = ["createXCFramework", "-framework", path1.str, "-framework", path2.str, "-framework", path3.str, "-framework", path4.str, "-framework", path5.str, "-output", outputPath.str]
            let service = try await SWBBuildService()
            let (result, message) = await service.createXCFramework(commandLine, currentWorkingDirectory: tmpDirPath.str, developerPath: nil)
            #expect(result, "unable to build xcframework: \(message)")

            // We need a copy inside "aPackageProject/Sources" for the package case.
            let packageOutputPath = tmpDirPath.join("Test/aPackageProject/Sources/sample.xcframework")
            try localFS.createDirectory(packageOutputPath.dirname, recursive: true)
            try localFS.copy(outputPath, to: packageOutputPath)

            let sourceRoot = tmpDirPath.join("Test")
            let packageFrameworks = sourceRoot.join("aPackageProject/build/PackageFrameworks")
            let binaryName = `static` ? "staticsample" : "sample" // `xcode.compileFramework` uses different names
            let frameworkName = binaryName + ".framework"

            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: sourceRoot,
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("A1.c"),
                                TestFile("A2.c"),
                                TestFile("A3.c"),
                                TestFile("sample.xcframework"),
                                TestFile("Info.plist"),
                                TestFile("best.swift")
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "USE_HEADERMAP": "NO",
                                "SKIP_INSTALL": "NO",
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                "SWIFT_VERSION": swiftVersion,
                                "CODE_SIGN_IDENTITY": "-",
                                "COPY_PHASE_STRIP": "NO",
                                "PACKAGE_SKIP_AUTO_EMBEDDING_DYNAMIC_BINARY_FRAMEWORKS": skipDynamicAutoEmbed ? "YES" : "NO",
                                "PACKAGE_SKIP_AUTO_EMBEDDING_STATIC_BINARY_FRAMEWORKS": skipStaticAutoEmbed ? "YES" : "NO",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "F1", type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([TestBuildFile("A1.c"), TestBuildFile("best.swift")]),
                                    TestFrameworksBuildPhase([TestBuildFile("sample.xcframework", codeSignOnCopy: true)]),
                                ], dependencies: ["F2", "F3"]),
                            TestStandardTarget(
                                "F2", type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([TestBuildFile("A2.c"), TestBuildFile("best.swift")]),
                                    TestFrameworksBuildPhase([TestBuildFile("sample.xcframework", codeSignOnCopy: true)]),
                                    TestCopyFilesBuildPhase([TestBuildFile("sample.xcframework", codeSignOnCopy: true)], destinationSubfolder: .frameworks, onlyForDeployment: false),
                                ], dependencies: ["F3"]),
                            TestStandardTarget(
                                "F3", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([TestBuildFile("A3.c"), TestBuildFile("best.swift")]),
                                ], dependencies: []),
                            TestStandardTarget(
                                "F4", type: .application,
                                buildPhases: [
                                    TestFrameworksBuildPhase([TestBuildFile(.target("P1Product"))]),
                                ], dependencies: ["P1Product", "P2Product"]),
                            TestStandardTarget(
                                "F5", type: .framework,
                                buildPhases: [
                                    TestFrameworksBuildPhase([TestBuildFile(.target("P1Product"))]),
                                ], dependencies: ["P1Product", "P2Product"]),
                            TestStandardTarget(
                                "F6", type: .applicationExtension,
                                buildPhases: [
                                    TestFrameworksBuildPhase([TestBuildFile(.target("P1Product"))]),
                                ], dependencies: ["P1Product", "P2Product"]),
                            TestStandardTarget(
                                "F7", type: .watchKitExtension,
                                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                                    "SDKROOT": "watchsimulator", // explicitly using the simulator here to avoid code signing and entitlement requirements
                                ])],
                                buildPhases: [
                                    TestFrameworksBuildPhase([TestBuildFile(.target("P1Product"))]),
                                ], dependencies: ["P1Product", "P2Product"]),
                            TestStandardTarget(
                                "F8", type: .staticLibrary,
                                buildPhases: [
                                    TestSourcesBuildPhase([TestBuildFile("best.swift")]),
                                    TestFrameworksBuildPhase([TestBuildFile(.target("P1Product"))]),
                                ], dependencies: ["P1Product", "P2Product"]),
                        ]),
                    TestPackageProject(
                        "aPackageProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("sample.xcframework", guid: "PKG-sample.xcframework"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "USE_HEADERMAP": "NO",
                                "SKIP_INSTALL": "NO",
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                "CODE_SIGN_IDENTITY": "-",
                                "COPY_PHASE_STRIP": "NO",
                            ]
                        )],
                        targets: [
                            TestPackageProductTarget(
                                "P1Product",
                                frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile("sample.xcframework", codeSignOnCopy: true)])),
                            TestPackageProductTarget(
                                "P2Product",
                                frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile("sample.xcframework", codeSignOnCopy: true)]),
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: [
                                        "BUILT_PRODUCTS_DIR": packageFrameworks.str,
                                        "TARGET_BUILD_DIR": packageFrameworks.str,
                                    ])
                                ]
                            ),
                        ]),
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            let sourceDirectory = SRCROOT.str
            let pkgSourceDirectory = testWorkspace.sourceRoot.join("aPackageProject")
            let buildDirectory = testWorkspace.sourceRoot.join("aProject/build").str
            let pkgBuildDirectory = testWorkspace.sourceRoot.join("aPackageProject/build").str

            // Write the Info.plist file.
            try await tester.fs.writePlist(SRCROOT.join("Sources/Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/A1.c")) { contents in
                contents <<< "int f1(void) {\n";
                contents <<< "  return 0;\n";
                contents <<< "}\n";
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/A2.c")) { contents in
                contents <<< "int f2(void) {\n";
                contents <<< "  return 0;\n";
                contents <<< "}\n";
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/A3.c")) { contents in
                contents <<< "int f3(void) {\n";
                contents <<< "  return 0;\n";
                contents <<< "}\n";
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/best.swift")) { contents in }

            let parameters = BuildParameters(configuration: "Debug", overrides: [
                "DSTROOT": tmpDirPath.join("dst").str,
            ])

            let signableTargets = Set(["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "P1Product", "P2Product"])
            let signableTargetInputs = Dictionary(uniqueKeysWithValues: signableTargets.map { ($0, ProvisioningTaskInputs(identityHash: "-", identityName: "-", signedEntitlements: .plDict(["com.apple.security.get-task-allow": .plBool(true)]))) })

            func validateStructure(at path: Path) throws {
                #expect(tester.fs.exists(path.join("Modules")))
                #expect(tester.fs.exists(path.join("Modules/module.modulemap")))
                #expect(tester.fs.exists(path.join("Modules/sample.swiftmodule")))
                #expect(tester.fs.exists(path.join("Modules/sample.swiftmodule/sample.swiftinterface")))
                #expect(tester.fs.exists(path.join("Modules/sample.swiftmodule/x86_64.swiftdoc")))
                #expect(tester.fs.exists(path.join("Modules/sample.swiftmodule/x86_64.swiftsourceinfo")))
                #expect(tester.fs.exists(path.join("sample")))
            }

            func validateBuild(_ results: BuildOperationTester.BuildResults) throws {
                let buildDir = Path(buildDirectory).join("Debug")
                let basePath = buildDir.join(frameworkName)

                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/F3.build/Objects-normal/x86_64/A3.o", "\(sourceDirectory)/Sources/A3.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["ProcessXCFramework", "\(sourceDirectory)/Sources/sample.xcframework", basePath.str, "macos"])) { _ in }
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/F2.build/Objects-normal/x86_64/A2.o", "\(sourceDirectory)/Sources/A2.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRule(["CompileC", "\(buildDirectory)/aProject.build/Debug/F1.build/Objects-normal/x86_64/A1.o", "\(sourceDirectory)/Sources/A1.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchRuleType("Ld"), .matchRuleItem("\(buildDirectory)/Debug/F3.framework/Versions/A/F3")) { _ in }
                results.checkTask(.matchRuleType("Ld"), .matchRuleItem("\(buildDirectory)/Debug/F2.app/Contents/MacOS/F2")) { _ in }
                results.checkTask(.matchRuleType("Ld"), .matchRuleItem("\(buildDirectory)/Debug/F1.app/Contents/MacOS/F1")) { _ in }

                let embeddedPath = buildDir.join("F2.app/Contents/Frameworks/\(frameworkName)")

                if `static` || object {
                    #expect(tester.fs.exists(basePath))
                    #expect(tester.fs.exists(embeddedPath))

                    // use MachO parser to confirm that the embedded binary is stub-dylib not an object
                    let macho = try MachO(reader: BinaryReader(data: tester.fs.read(embeddedPath.join("Versions/A/\(binaryName)"))))
                    let linkage = try macho.slicesIncludingLinkage().linkage
                    #expect(linkage == .macho(.dylib))
                } else {
                    results.checkTask(.matchRule(["Copy",  "\(buildDirectory)/Debug/F2.app/Contents/Frameworks/\(frameworkName)", "\(sourceDirectory)/Sources/sample.xcframework/macos-x86_64/\(frameworkName)"])) { _ in }

                    // Validate the base copy.
                    try validateStructure(at: basePath)

                    // Validate the embedded copy.
                    try validateStructure(at: embeddedPath)
                }

                results.checkNoDiagnostics()
            }

            // Check a normal build.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs) { results in
                try validateBuild(results)
            }

            // Clean out the build folder.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }

            // Check a test build.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, schemeCommand: .test, persistent: true, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs) { results in
                try validateBuild(results)
            }

            // Clean out the build folder.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }

            // Check building a package.
            let relevantTargets = tester.workspace.allTargets.filter { ["F4", "F5", "F6", "F7", "F8"].contains($0.name) }
            let request = BuildRequest(parameters: parameters,
                                       buildTargets: relevantTargets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) },
                                       continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: request, persistent: true, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs) { results in
                let basePath = Path(pkgBuildDirectory).join("Debug").join(frameworkName)

                results.checkTask(.matchRule(["ProcessXCFramework", "\(testWorkspace.sourceRoot.str)/aPackageProject/Sources/sample.xcframework", basePath.str, "macos"])) { _ in }

                let embeddedPath = Path(buildDirectory).join("Debug").join("F4.app/Contents/Frameworks/\(frameworkName)")

                if `static` || object {
                    #expect(tester.fs.exists(basePath))
                    if skipStaticAutoEmbed {
                        #expect(!tester.fs.exists(embeddedPath))
                    } else {
                        #expect(tester.fs.exists(embeddedPath))

                        // use MachO parser to confirm that the embedded binary is stub-dylib not an object
                        let macho = try MachO(reader: BinaryReader(data: tester.fs.read(embeddedPath.join("Versions/A/\(binaryName)"))))
                        let linkage = try macho.slicesIncludingLinkage().linkage
                        #expect(linkage == .macho(.dylib))
                    }
                } else {
                    // Validate the base copy.
                    try validateStructure(at: basePath)

                    // Validate the embedded copy.
                    if skipDynamicAutoEmbed {
                        #expect(!tester.fs.exists(embeddedPath))
                    } else {
                        try validateStructure(at: embeddedPath)
                    }
                }

                // Verify that we are not embedding into frameworks anymore.
                let frameworkPath = Path(buildDirectory).join("Debug").join("F5.framework")
                #expect(tester.fs.exists(frameworkPath))
                let embeddedPathInFramework = frameworkPath.join("Versions/A/Frameworks/\(frameworkName)")
                #expect(!tester.fs.exists(embeddedPathInFramework))

                // Verify that we are not embedding into application extensions anymore.
                let appExtPath = Path(buildDirectory).join("Debug").join("F6.appex")
                #expect(tester.fs.exists(appExtPath))
                let embeddedPathInAppExt = appExtPath.join("Contents/Frameworks/\(frameworkName)")
                #expect(!tester.fs.exists(embeddedPathInAppExt))

                // Verify that we are still embedding into watch extensions.
                let watchBasePath = Path(buildDirectory).join("Debug-watchsimulator").join(frameworkName)
                let watchAppExtPath = Path(buildDirectory).join("Debug-watchsimulator").join("F7.appex")
                let embeddedPathInWatchAppExt = watchAppExtPath.join("Frameworks/\(frameworkName)")

                // Verify that we are not "embedding" into static library targets.
                let staticLibPath = Path(buildDirectory).join("Debug").join("libF8.a")
                #expect(tester.fs.exists(staticLibPath))
                // Since we cannot actually emebed into a static library, we would end up creating a "Frameworks" directory at the top level.
                let topLevelFrameworksPath = Path(buildDirectory).join("Debug").join("Frameworks")
                #expect(!tester.fs.exists(topLevelFrameworksPath))
                let embeddedPathForStaticLib = topLevelFrameworksPath.join(frameworkName)
                #expect(!tester.fs.exists(embeddedPathForStaticLib))

                if `static` || object {
                    #expect(tester.fs.exists(watchBasePath))
                    #expect(tester.fs.exists(watchAppExtPath))

                    if skipStaticAutoEmbed {
                        #expect(!tester.fs.exists(embeddedPathInWatchAppExt))
                    } else {
                        #expect(tester.fs.exists(embeddedPathInWatchAppExt))
                    }
                } else {
                    // Validate the base copy.
                    try validateStructure(at: watchBasePath)

                    // Validate the embedded copy.
                    if skipDynamicAutoEmbed {
                        #expect(!tester.fs.exists(embeddedPathInWatchAppExt))
                    } else {
                        try validateStructure(at: embeddedPathInWatchAppExt)
                    }
                }

                results.checkNoDiagnostics()
            }

            // Clean out the build folder.
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildCommand: .cleanBuildFolder(style: .regular)) { _ in }

            // Check building a package product only
            let packageProductTarget = try #require(tester.workspace.allTargets.first { $0.name == "P1Product" })
            let packageProductRequest = BuildRequest(parameters: parameters,
                                                     buildTargets: [BuildRequest.BuildTargetInfo(parameters: parameters, target: packageProductTarget)],
                                                     continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: packageProductRequest, persistent: true, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs) { results in
                let buildDir = Path(pkgBuildDirectory).join("Debug")
                let basePath = buildDir.join(frameworkName)

                results.checkTask(.matchRule(["ProcessXCFramework", "\(pkgSourceDirectory.str)/Sources/sample.xcframework", basePath.str, "macos"])) { _ in }

                if `static` || object {
                    #expect(tester.fs.exists(basePath))
                } else {
                    // Validate the base copy.
                    try validateStructure(at: basePath)
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func ensureHeaderDiagnosticsForCollisions() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("file.c"),
                        TestFile("libsample.xcframework"),
                        TestFile("libother.xcframework"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ]),
                ],
                targets: [
                    // Test building an app which links and embeds an xcframework.
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.c"]),
                            TestFrameworksBuildPhase(["libsample.xcframework", "libother.xcframework"]),
                        ],
                        dependencies: []
                    ),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs
            let infoLookup = try await getCore()

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try fs.createDirectory(Path(SRCROOT), recursive: true)

            try await fs.writeFileContents(Path(SRCROOT).join("file.c"), body: { $0 <<< "int main() { return 0; }" })

            let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
            ])
            let supportXCFrameworkPath = Path(SRCROOT).join("libsample.xcframework")
            try fs.createDirectory(supportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

            let otherXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libother.a"), binaryPath: Path("libother.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libother.a"), binaryPath: Path("libother.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
            ])
            let otherXCFrameworkPath = Path(SRCROOT).join("libother.xcframework")
            try fs.createDirectory(otherXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(otherXCFramework, fs: fs, path: otherXCFrameworkPath, infoLookup: infoLookup)

            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
                results.checkError(.equal(
                                    """
                                    Multiple commands produce '\(SRCROOT)/build/Debug/include/header1.h'
                                    Command: ProcessXCFramework \(SRCROOT)/libother.xcframework \(SRCROOT)/build/Debug/libother.a macos
                                    Command: ProcessXCFramework \(SRCROOT)/libsample.xcframework \(SRCROOT)/build/Debug/libsample.a macos
                                    """))
                results.checkError(.equal(
                                    """
                                    Multiple commands produce '\(SRCROOT)/build/Debug/include/header2.h'
                                    Command: ProcessXCFramework \(SRCROOT)/libother.xcframework \(SRCROOT)/build/Debug/libother.a macos
                                    Command: ProcessXCFramework \(SRCROOT)/libsample.xcframework \(SRCROOT)/build/Debug/libsample.a macos
                                    """))

                results.checkWarning(.equal("duplicate output file '\(SRCROOT)/build/Debug/include/header1.h' on task: ProcessXCFramework \(SRCROOT)/libsample.xcframework \(SRCROOT)/build/Debug/libsample.a macos"))
                results.checkWarning(.equal("duplicate output file '\(SRCROOT)/build/Debug/include/header2.h' on task: ProcessXCFramework \(SRCROOT)/libsample.xcframework \(SRCROOT)/build/Debug/libsample.a macos"))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func missingMetadataFoldersProducesDiagnostics() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("file.c"),
                        TestFile("libsample.xcframework"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ]),
                ],
                targets: [
                    // Test building an app which links and embeds an xcframework.
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.c"]),
                            TestFrameworksBuildPhase(["libsample.xcframework"]),
                        ],
                        dependencies: []
                    ),
                ])

            let scenarios: [(path: (XCFramework.Library) -> Path?, message: (Path) -> String)] = [
                (
                    { return $0.debugSymbolsPath },
                    { return "Missing path (\($0.join("dSYMs").str)) from XCFramework 'libsample.xcframework' as defined by 'DebugSymbolsPath' in its `Info.plist` file (in target \'App\' from project \'aProject\')" }
                ),
                (
                    { return $0.headersPath },
                    { return "Missing path (\($0.join("Headers").str)) from XCFramework 'libsample.xcframework' as defined by 'HeadersPath' in its `Info.plist` file (in target \'App\' from project \'aProject\')" }
                ),
            ]

            for scenario in scenarios {
                let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
                let fs = tester.fs
                let infoLookup = try await getCore()

                let SRCROOT = tester.workspace.projects[0].sourceRoot.str

                try fs.createDirectory(Path(SRCROOT), recursive: true)

                try await fs.writeFileContents(Path(SRCROOT).join("file.c"), body: { $0 <<< "int main() { return 0; }" })

                let supportXCFrameworkPath = Path(SRCROOT).join("libsample.xcframework")
                let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                    XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
                    XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
                ])

                try fs.createDirectory(supportXCFrameworkPath, recursive: true)
                try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

                func remove(_ path: Path) throws {
                    if fs.isDirectory(path) {
                        try fs.removeDirectory(path)
                    }
                    else {
                        try fs.remove(path)
                    }
                    #expect(!fs.exists(path))
                }

                // Remove the contents of the various folders to ensure no error is produced for empty items.
                for library in supportXCFramework.libraries {
                    let path = scenario.path(library)
                    try remove(supportXCFrameworkPath.join(library.libraryIdentifier).join(path))
                }

                try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
                    results.checkError(StringPattern(stringLiteral: scenario.message(supportXCFrameworkPath.join("x86_64-apple-macos10.15"))))
                }

                try fs.removeDirectory(supportXCFrameworkPath)
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func mismatchingSignatureProducesDiagnostics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("file.c"),
                        TestFile("libsample.xcframework", expectedSignature: "AppleDeveloperProgram:mysignature"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ]),
                ],
                targets: [
                    // Test building an app which links and embeds an xcframework.
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.c"]),
                            TestFrameworksBuildPhase(["libsample.xcframework"]),
                        ],
                        dependencies: []
                    ),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs
            let infoLookup = try await getCore()

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try fs.createDirectory(Path(SRCROOT), recursive: true)

            try await fs.writeFileContents(Path(SRCROOT).join("file.c"), body: { $0 <<< "int main() { return 0; }" })

            let supportXCFrameworkPath = Path(SRCROOT).join("libsample.xcframework")
            let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
            ])

            try fs.createDirectory(supportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)


            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
                results.checkError(.contains("“libsample.xcframework” is not signed with the expected identity and may have been compromised.\nExpected team identifier: mysignature"))
            }

            try fs.removeDirectory(supportXCFrameworkPath)
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func mismatchingSignatureDoesNotProduceDiagnostics() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("file.c"),
                        TestFile("libsample.xcframework", expectedSignature: "AppleDeveloperProgram:mysignature"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES"
                    ]),
                ],
                targets: [
                    // Test building an app which links and embeds an xcframework.
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.c"]),
                            TestFrameworksBuildPhase(["libsample.xcframework"]),
                        ],
                        dependencies: []
                    ),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs
            let infoLookup = try await getCore()

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try fs.createDirectory(Path(SRCROOT), recursive: true)

            try await fs.writeFileContents(Path(SRCROOT).join("file.c"), body: { $0 <<< "int main() { return 0; }" })

            let supportXCFrameworkPath = Path(SRCROOT).join("libsample.xcframework")
            let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "x86_64-apple-macos10.15", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos13.0", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: Path("Headers"), debugSymbolsPath: Path("dSYMs")),
            ])

            try fs.createDirectory(supportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)


            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: ["DISABLE_XCFRAMEWORK_SIGNATURE_VALIDATION": "YES"]), runDestination: .macOS) { results in
                results.checkWarning(.contains("XCFramework signature validation is being skipped. Remove `DISABLE_XCFRAMEWORK_SIGNATURE_VALIDATION` to disable this warning."))
            }

            try fs.removeDirectory(supportXCFrameworkPath)
        }
    }

    // Regression test for rdar://110396889 (Xcode 15 fails to build project with Crashlytics run script build phase)
    @Test(.requireSDKs(.macOS))
    func xCFrameworksAreCopiedIndependentlyOfUserBuildPhases() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            // Create an XCFramework
            let xcode = try await InstalledXcode.currentlySelected()
            let infoLookup = try await getCore()
            let frameworkPath = try await xcode.compileFramework(path: tmpDirPath.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, static: false)
            let packageOutputPath = tmpDirPath.join("Test/aPackageProject/Sources/sample.xcframework")
            let commandLine = ["createXCFramework", "-framework", frameworkPath.str, "-output", packageOutputPath.str]
            let service = try await SWBBuildService()
            let (result, message) = await service.createXCFramework(commandLine, currentWorkingDirectory: tmpDirPath.str, developerPath: nil)
            #expect(result, "unable to build xcframework: \(message)")
            try localFS.createDirectory(tmpDirPath.join("Test/aProject/Sources/sample.xcframework").dirname, recursive: true)
            try localFS.copy(packageOutputPath, to: tmpDirPath.join("Test/aProject/Sources/sample.xcframework"))
            let sourceRoot = tmpDirPath.join("Test")

            // This workspace includes an Xcode target which consumes an XCFramework vended by the package. The Xcode target also includes a script phase which reads the final generated Info.plist.
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: sourceRoot,
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("best.swift")
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "USE_HEADERMAP": "NO",
                                "SKIP_INSTALL": "NO",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "SWIFT_VERSION": swiftVersion,
                                "SKIP_EMBEDDED_FRAMEWORKS_VALIDATION": "YES",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "App", type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([TestBuildFile("best.swift")]),
                                    TestFrameworksBuildPhase([TestBuildFile(.target("Product"))]),
                                    TestShellScriptBuildPhase(name: "Read Info.plist", shellPath: "/bin/bash", originalObjectID: "ReadPlist", contents: "echo Hello!", inputs: ["$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)"], outputs: [], alwaysOutOfDate: true),
                                ], dependencies: ["Product"]),
                        ]),
                    TestPackageProject(
                        "aPackageProject",
                        sourceRoot: sourceRoot.join("aPackageProject"),
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("sample.xcframework"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ALWAYS_SEARCH_USER_PATHS": "NO",
                                "CLANG_ENABLE_MODULES": "YES",
                                "USE_HEADERMAP": "NO",
                                "SKIP_INSTALL": "NO",
                            ]
                        )],
                        targets: [
                            TestPackageProductTarget(
                                "Product",
                                frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile("sample.xcframework", codeSignOnCopy: true)])),
                        ]),
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            try await tester.fs.writeFileContents(sourceRoot.join("aProject/Sources/best.swift")) { contents in }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true) { results in
                // The build should succeed without reporting any cycles.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.iOS, .watchOS))
    func avoidSignatureFileCollisions() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("file.c"),
                        TestFile("sample.xcframework"),
                        TestFile("libsample.xcframework"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SDKROOT": "iphoneos",
                                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.c"]),
                            TestFrameworksBuildPhase(["sample.xcframework", "libsample.xcframework"]),
                            TestCopyFilesBuildPhase([
                                "WatchApp.app",
                            ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/Watch", onlyForDeployment: false
                                                   ),
                        ],
                        dependencies: ["WatchApp"]
                    ),
                    TestStandardTarget(
                        "WatchApp",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SDKROOT": "watchos",
                                "SUPPORTED_PLATFORMS": "watchos watchsimulator"
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["file.c"]),
                            TestFrameworksBuildPhase(["sample.xcframework", "libsample.xcframework"]),
                        ],
                        dependencies: []
                    ),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs
            let infoLookup = try await getCore()

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try fs.createDirectory(Path(SRCROOT), recursive: true)

            try await fs.writeFileContents(Path(SRCROOT).join("file.c"), body: { $0 <<< "int main() { return 0; }" })

            let supportXCFrameworkPath = Path(SRCROOT).join("sample.xcframework")
            let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(infoLookup.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("sample.framework"), binaryPath: Path("sample.framework/sample"), headersPath: nil, debugSymbolsPath: Path("dSYMs")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-watchos\(infoLookup.loadSDK(.watchOS).defaultDeploymentTarget)", supportedPlatform: "watchos", supportedArchitectures: ["arm64", "arm64_32"], platformVariant: nil, libraryPath: Path("sample.framework"), binaryPath: Path("sample.framework/sample"), headersPath: nil, debugSymbolsPath: Path("dSYMs")),
            ])

            try fs.createDirectory(supportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

            let staticSupportXCFrameworkPath = Path(SRCROOT).join("libsample.xcframework")
            let staticSupportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(infoLookup.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: nil, debugSymbolsPath: Path("dSYMs")),
                XCFramework.Library(libraryIdentifier: "arm64-apple-watchos\(infoLookup.loadSDK(.watchOS).defaultDeploymentTarget)", supportedPlatform: "watchos", supportedArchitectures: ["arm64", "arm64_32"], platformVariant: nil, libraryPath: Path("libsample.a"), binaryPath: Path("libsample.a"), headersPath: nil, debugSymbolsPath: Path("dSYMs")),
            ])

            try fs.createDirectory(staticSupportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(staticSupportXCFramework, fs: fs, path: staticSupportXCFrameworkPath, infoLookup: infoLookup)

            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: ["ENABLE_SIGNATURE_AGGREGATION": "YES"]), runDestination: .anyiOSDevice) { results in
                results.checkNoDiagnostics()
                let iOSSignatureFiles = try Set(localFS.listdir(tmpDir.join("build/Debug-iphoneos")).filter { $0.hasSuffix(".signature") })
                let watchOSSignatureFiles = try Set(localFS.listdir(tmpDir.join("build/Debug-watchos")).filter { $0.hasSuffix(".signature") })
                #expect(iOSSignatureFiles.isDisjoint(with: watchOSSignatureFiles), "unexpected collision between iOS signatures (\(iOSSignatureFiles) and watchOS signatures (\(watchOSSignatureFiles)")
            }
        }
    }

    @Test(.requireSDKs(.iOS, .watchOS))
    func multiplatformFramework() async throws {

        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.c"),
                        TestFile("test.swift"),
                        TestFile("Support.xcframework"),
                        TestFile("Info.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "INFOPLIST_FILE": "Info.plist",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SDKROOT": "iphoneos",
                                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator"
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.c"]),
                            TestCopyFilesBuildPhase([
                                "WatchApp.app",
                            ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/Watch", onlyForDeployment: false
                                                   ),
                        ],
                        dependencies: ["WatchApp", "Multi"]
                    ),
                    TestStandardTarget(
                        "WatchApp",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SDKROOT": "watchos",
                                "SUPPORTED_PLATFORMS": "watchos watchsimulator"
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.c"]),
                        ],
                        dependencies: ["Multi"]
                    ),
                    TestStandardTarget(
                        "Multi",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SDKROOT": "auto",
                                "SDK_VARIANT": "auto",
                                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator watchos watchsimulator",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["test.swift"]),
                            TestFrameworksBuildPhase(["Support.xcframework"]),
                        ],
                        dependencies: []
                    ),
                ])

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let fs = tester.fs
            let infoLookup = try await getCore()

            let SRCROOT = tester.workspace.projects[0].sourceRoot

            try fs.createDirectory(SRCROOT, recursive: true)

            try await fs.writeFileContents(SRCROOT.join("main.c"), body: { $0 <<< "int main() { return 0; }" })
            try await fs.writeFileContents(SRCROOT.join("test.swift"), body: { $0 <<< "// test.swift" })

            try await tester.fs.writePlist(SRCROOT.join("Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            let supportXCFrameworkPath = SRCROOT.join("Support.xcframework")
            let supportXCFramework = try XCFramework(
                version: Version(1, 0),
                libraries: [
                    XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(infoLookup.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
                    XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(infoLookup.loadSDK(.watchOS).defaultDeploymentTarget)", supportedPlatform: "watchos", supportedArchitectures: ["arm64", "arm64_32"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
                ])

            try fs.createDirectory(supportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: fs, path: supportXCFrameworkPath, infoLookup: infoLookup)

            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug"), runDestination: .anyiOSDevice) { results in
                results.checkNoDiagnostics()
            }
        }
    }
}
