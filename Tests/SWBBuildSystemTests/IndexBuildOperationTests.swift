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

import struct Foundation.Date

import Testing

import SWBCore
import struct SWBProtocol.ArenaInfo
import struct SWBProtocol.PreparedForIndexResultInfo
import struct SWBProtocol.RunDestinationInfo
import class SWBTaskConstruction.ProductPlan
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SWBMacro

@Suite
fileprivate struct IndexBuildOperationTests: CoreBasedTests {
    static let excludedStartTaskTypes = Set(["Gate", "CreateBuildDirectory", ProductPlan.preparedForIndexPreCompilationRuleName, ProductPlan.preparedForIndexModuleContentRuleName, "ClangStatCache", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm"])

    @Test(.requireSDKs(.macOS), .requireXcode16())
    func legacyPrebuild() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("main.m"),
                                TestFile("fwk.swift"),
                                TestFile("AppTarget.xcdatamodel"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])],
                        targets: [
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug"),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.m",
                                        "AppTarget.xcdatamodel",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "FwkTarget.framework"])
                                ],
                                dependencies: ["FwkTarget"]),
                            TestStandardTarget(
                                "FwkTarget",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug",
                                                           buildSettings: [
                                                            "VERSIONING_SYSTEM": "apple-generic",
                                                            "SWIFT_VERSION": swiftVersion,
                                                           ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "fwk.swift",
                                    ])]
                            ),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.m")) { stream in
                stream <<< "int main(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/fwk.swift")) { stream in
                stream <<< "func foo(){}"
            }
            try tester.fs.writeCoreDataModel(testWorkspace.sourceRoot.join("aProject/AppTarget.xcdatamodel"), language: .objectiveC, .entity("AppTarget"))

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let buildTargets = tester.workspace.allTargets.map{ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: false))
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: request, persistent: true) { results in
                results.consumeTasksMatchingRuleTypes(Self.excludedStartTaskTypes)

                // Swift modules and core data code generation
                results.checkTaskExists(.matchRule(["SwiftDriver", "FwkTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"]))
                results.checkTaskExists(.matchRule(["SwiftDriver Compilation Requirements", "FwkTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"]))
                results.checkTaskExists(.matchRule(["SwiftDriver Compilation", "FwkTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"]))
                results.checkTaskExists(.matchRule(["SwiftCompile", "normal", "x86_64", "Compiling fwk.swift", "\(tmpDirPath.str)/Test/aProject/fwk.swift"]))
                results.checkTaskExists(.matchRule(["SwiftEmitModule", "normal", "x86_64", "Emitting module for FwkTarget"]))
                results.checkTask(.matchRule(["DataModelCodegen", "\(tmpDirPath.str)/Test/aProject/AppTarget.xcdatamodel"])) { _ in }
                results.checkTask(.matchRule(["SwiftMergeGeneratedHeaders", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions/A/Headers/FwkTarget-Swift.h", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget-Swift.h"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions/A/Modules/FwkTarget.swiftmodule/x86_64-apple-macos.swiftdoc", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.swiftdoc"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions/A/Modules/FwkTarget.swiftmodule/x86_64-apple-macos.swiftmodule", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.swiftmodule"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions/A/Modules/FwkTarget.swiftmodule/x86_64-apple-macos.abi.json", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.abi.json"])) { _ in }
                results.checkTask(.matchRule(["Copy", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions/A/Modules/FwkTarget.swiftmodule/Project/x86_64-apple-macos.swiftsourceinfo", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.swiftsourceinfo"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget-OutputFileMap.json"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.SwiftFileList"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.SwiftConstValuesFileList"])) { _ in }

                // Header maps
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/AppTarget.build/AppTarget-all-non-framework-target-headers.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/AppTarget.build/AppTarget-all-target-headers.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/AppTarget.build/AppTarget-generated-files.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/AppTarget.build/AppTarget-own-target-headers.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/AppTarget.build/AppTarget-project-headers.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/AppTarget.build/AppTarget.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/FwkTarget-all-non-framework-target-headers.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/FwkTarget-all-target-headers.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/FwkTarget-generated-files.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/FwkTarget-own-target-headers.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/FwkTarget-project-headers.hmap"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/FwkTarget.hmap"])) { _ in }

                // Const extraction protocols
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget_const_extract_protocols.json"])) { _ in }

                // VFS
                results.checkTask(.matchRulePattern(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")])) { _ in }

                // Generated source file for apple-generic versioning
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/DerivedSources/FwkTarget_vers.c"])) { _ in }

                // Response files
                results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/7187679823f38a2a940e0043cdf9d637-common-args.resp"]))
                results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/e6072d4f65d7061329687fe24e3d63a7-common-args.resp"]))


                // Mkdir
                results.checkTask(.matchRule(["MkDir", "\(tmpDirPath.str)/Test/aProject/build/Debug/AppTarget.app"])) { _ in }
                results.checkTask(.matchRule(["MkDir", "\(tmpDirPath.str)/Test/aProject/build/Debug/AppTarget.app/Contents"])) { _ in }
                results.checkTask(.matchRule(["MkDir", "\(tmpDirPath.str)/Test/aProject/build/Debug/AppTarget.app/Contents/MacOS"])) { _ in }
                results.checkTask(.matchRule(["MkDir", "\(tmpDirPath.str)/Test/aProject/build/Debug/AppTarget.app/Contents/Resources"])) { _ in }
                results.checkTask(.matchRule(["MkDir", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework"])) { _ in }
                results.checkTask(.matchRule(["MkDir", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions"])) { _ in }
                results.checkTask(.matchRule(["MkDir", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions/A"])) { _ in }
                results.checkTask(.matchRule(["MkDir", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions/A/Headers"])) { _ in }

                // SymLink
                results.checkTask(.matchRule(["SymLink", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/FwkTarget", "Versions/Current/FwkTarget"])) { _ in }
                results.checkTask(.matchRule(["SymLink", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Headers", "Versions/Current/Headers"])) { _ in }
                results.checkTask(.matchRule(["SymLink", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Modules", "Versions/Current/Modules"])) { _ in }
                results.checkTask(.matchRule(["SymLink", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions/Current", "A"])) { _ in }

                // App Intents Metadata Dependencies
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/AppTarget.build/AppTarget.DependencyMetadataFileList"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/FwkTarget.DependencyMetadataFileList"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/AppTarget.build/AppTarget.DependencyStaticMetadataFileList"])) { _ in }
                results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug/FwkTarget.build/FwkTarget.DependencyStaticMetadataFileList"])) { _ in }

                let sdkImportsEnabled = results.buildRequestContext.getCachedSettings(parameters, target: try #require(buildTargets.first).target).globalScope.evaluate(BuiltinMacros.ENABLE_SDK_IMPORTS)
                if try await supportsSDKImports, sdkImportsEnabled {
                    // SDK imports create a resource file, but since we don't actually link here, we're not producing it.
                    results.checkTask(.matchRule(["MkDir", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Versions/A/Resources"])) { _ in }
                    results.checkTask(.matchRule(["SymLink", "\(tmpDirPath.str)/Test/aProject/build/Debug/FwkTarget.framework/Resources", "Versions/Current/Resources"])) { _ in }
                }

                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func legacyPrebuild2() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("base.h"),
                                TestFile("base.c"),
                                TestFile("foo.swift"),
                                TestFile("bar.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "DEFINES_MODULE": "YES",
                                    "USE_HEADERMAP": "NO",
                                ])],
                        targets: [
                            TestStandardTarget(
                                "base",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["base.c"]),
                                    TestHeadersBuildPhase([TestBuildFile("base.h", headerVisibility: .public)])
                                ]),
                            TestStandardTarget(
                                "bar",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["bar.swift"]),
                                    TestFrameworksBuildPhase(["base.framework"])
                                ],
                                dependencies: ["base"]),
                            TestStandardTarget(
                                "foo",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                buildPhases: [
                                    TestSourcesBuildPhase(["foo.swift"]),
                                    TestFrameworksBuildPhase(["bar.framework"])
                                ],
                                dependencies: ["bar"]),
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/base.h")) { stream in
                stream <<< "void basefn();"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/base.c")) { stream in
                stream <<< ""
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/bar.swift")) { stream in
                stream <<< "import base" <<< "\n"
                stream <<< "public func bar(){ basefn() }"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/foo.swift")) { stream in
                stream <<< "import bar" <<< "\n"
                stream <<< "public func foo(){ bar() }"
            }

            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let buildTargets = tester.workspace.allTargets.map{ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false, buildCommand: .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: false))
            try await tester.checkBuild(parameters: parameters, runDestination: .macOS, buildRequest: request, persistent: true) { results in
                results.check(contains: .buildCompleted)
            }
        }
    }

    @Test(.requireSDKs(.macOS), .skipDeveloperDirectoryWithEqualSign) // mig will fail on CAS mounts due to rdar://137363780 (env can't handle commands with = signs in the filename)
    func preparingForIndexingOnlyTheseTargets() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let appTarget = TestStandardTarget(
                "AppTarget",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug"),
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "main.m",
                        "AppTarget.xcdatamodel",
                        "mig.defs",
                    ]),
                    TestFrameworksBuildPhase([
                        "FwkTarget.framework"])
                ],
                dependencies: ["FwkTarget"])

            let fwkTarget = try await TestStandardTarget(
                "FwkTarget",
                type: .framework,
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "VERSIONING_SYSTEM": "apple-generic",
                                            "SWIFT_VERSION": swiftVersion,
                                           ]),
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "fwk.swift",
                    ]),
                    TestCopyFilesBuildPhase([
                        TestBuildFile("head.h"),
                    ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(PRIVATE_HEADERS_FOLDER_PATH)/Internal", onlyForDeployment: false),
                ]
            )

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("head.h"),
                                TestFile("main.m"),
                                TestFile("fwk.swift"),
                                TestFile("AppTarget.xcdatamodel"),
                                TestFile("mig.defs"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CLANG_ENABLE_MODULES": "YES",
                                    "DEFINES_MODULE": "YES",
                                ])],
                        targets: [
                            appTarget,
                            fwkTarget,
                        ])])

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            enum ExpectedPreparation {
                case frameworkOnly
                case both
            }

            func checkBuild(prepareTargets: [String], expectedPreparation: ExpectedPreparation) async throws {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                // Write the file data.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.m")) { stream in
                    stream <<< "int main(){}"
                }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/fwk.swift")) { stream in
                    stream <<< "func foo(){}"
                }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/head.h")) { stream in
                    stream <<< "#define M 1"
                }
                try tester.fs.writeCoreDataModel(testWorkspace.sourceRoot.join("aProject/AppTarget.xcdatamodel"), language: .objectiveC, .entity("AppTarget"))
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mig.defs")) { stream in
                    stream <<< "subsystem foo 1;"
                }

                try await tester.checkIndexBuild(prepareTargets: prepareTargets) { results in
                    let arena = try #require(results.arena)
                    let productsRoot = arena.buildProductsPath.str
                    let intermediatesRoot = arena.buildIntermediatesPath.str

                    results.consumeTasksMatchingRuleTypes(Self.excludedStartTaskTypes)

                    // Swift modules and core data code generation
                    if expectedPreparation == .both {
                        // Note: "SwiftCompile" doesn't actually compile, it's the integrated driver job and only builds required outputs
                        results.checkTaskExists(.matchRulePattern(["SwiftCompile", "normal", "x86_64", "Compiling fwk.swift", "\(SRCROOT.str)/fwk.swift"]))
                        results.checkTaskExists(.matchRule(["SwiftDriver GenerateModule", "FwkTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"]))
                        results.checkTaskExists(.matchRule(["SwiftDriver Compilation Requirements", "FwkTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"]))
                        results.checkTaskExists(.matchRule(["DataModelCodegen", "\(SRCROOT.str)/AppTarget.xcdatamodel"]))
                        results.checkTaskExists(.matchRule(["SwiftMergeGeneratedHeaders", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A/Headers/FwkTarget-Swift.h", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget-Swift.h"]))
                        results.checkTaskExists(.matchRule(["Copy", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A/Modules/FwkTarget.swiftmodule/x86_64-apple-macos.swiftdoc", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.swiftdoc"]))
                        results.checkTaskExists(.matchRule(["Copy", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A/Modules/FwkTarget.swiftmodule/Project/x86_64-apple-macos.swiftsourceinfo", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.swiftsourceinfo"]))
                        results.checkTaskExists(.matchRule(["Copy", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A/Modules/FwkTarget.swiftmodule/x86_64-apple-macos.swiftmodule", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.swiftmodule"]))
                    }
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget-OutputFileMap.json"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/Objects-normal/x86_64/FwkTarget.SwiftFileList"]))

                    // Header maps
                    if expectedPreparation == .both {
                        results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-all-non-framework-target-headers.hmap"]))
                        results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-all-target-headers.hmap"]))
                        results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-generated-files.hmap"]))
                        results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-own-target-headers.hmap"]))
                        results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-project-headers.hmap"]))
                        results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget.hmap"]))
                    }
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/FwkTarget-all-non-framework-target-headers.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/FwkTarget-all-target-headers.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/FwkTarget-generated-files.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/FwkTarget-own-target-headers.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/FwkTarget-project-headers.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/FwkTarget.hmap"]))

                    // Copy files
                    if expectedPreparation == .both {
                        results.checkTaskExists(.matchRule(["Copy", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A/PrivateHeaders/Internal/head.h", "\(SRCROOT.str)/head.h"]))
                    }

                    // VFS
                    results.checkTaskExists(.matchRulePattern(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")]))

                    // Mkdir
                    if expectedPreparation == .both {
                        results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/AppTarget.app"]))
                        results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/AppTarget.app/Contents"]))
                        results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/AppTarget.app/Contents/MacOS"]))
                        results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/AppTarget.app/Contents/Resources"]))
                    }
                    results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/FwkTarget.framework"]))
                    results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/FwkTarget.framework/Versions"]))
                    results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A"]))
                    results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A/Headers"]))
                    results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A/PrivateHeaders"]))
                    if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value {
                        results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A/Resources"]))
                    }

                    // Response files
                    if expectedPreparation == .both {
                        results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/7187679823f38a2a940e0043cdf9d637-common-args.resp"]))
                        results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/e6072d4f65d7061329687fe24e3d63a7-common-args.resp"]))
                    }


                    // SymLink
                    results.checkTaskExists(.matchRule(["SymLink", "\(productsRoot)/Debug/FwkTarget.framework/Headers", "Versions/Current/Headers"]))
                    results.checkTaskExists(.matchRule(["SymLink", "\(productsRoot)/Debug/FwkTarget.framework/PrivateHeaders", "Versions/Current/PrivateHeaders"]))
                    results.checkTaskExists(.matchRule(["SymLink", "\(productsRoot)/Debug/FwkTarget.framework/Modules", "Versions/Current/Modules"]))
                    if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value {
                        results.checkTaskExists(.matchRule(["SymLink", "\(productsRoot)/Debug/FwkTarget.framework/Resources", "Versions/Current/Resources"]))
                    }
                    results.checkTaskExists(.matchRule(["SymLink", "\(productsRoot)/Debug/FwkTarget.framework/Versions/Current", "A"]))

                    // Mig
                    if expectedPreparation == .both {
                        results.checkTaskExists(.matchRule(["Mig", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/DerivedSources/x86_64/mig.h", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/DerivedSources/x86_64/migUser.c", "\(tmpDirPath.str)/Test/aProject/mig.defs", "normal", "x86_64"]))
                    }

                    // Modulemap
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/module.modulemap"]))
                    results.checkTaskExists(.matchRule(["Copy", "\(productsRoot)/Debug/FwkTarget.framework/Versions/A/Modules/module.modulemap", "\(intermediatesRoot)/aProject.build/Debug/FwkTarget.build/module.modulemap"]))

                    // Index -> regular build overlay
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/index-overlay.yaml"]))

                    results.checkNoTask()
                }
            }

            // Prepare only App target.
            try await checkBuild(prepareTargets: [appTarget.guid], expectedPreparation: .both)

            // Prepare only Fwk target.
            try await checkBuild(prepareTargets: [fwkTarget.guid], expectedPreparation: .frameworkOnly)

            // Prepare App+Fwk target.
            try await checkBuild(prepareTargets: [appTarget.guid, fwkTarget.guid], expectedPreparation: .both)
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func preparingForIndexingSimulatorTarget() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let appTarget = TestStandardTarget(
                "AppTarget",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "iphonesimulator",
                        "SUPPORTED_PLATFORMS": "iphonesimulator",
                    ])
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "main.m",
                    ]),
                ],
                dependencies: ["FwkTarget"])

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("main.m"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])],
                        targets: [
                            appTarget,
                        ])])

            func checkBuild(prepareTargets: [String], runDestination: RunDestinationInfo) async throws {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                // Write the file data.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.m")) { stream in
                    stream <<< "int main(){}"
                }

                try await tester.checkIndexBuild(prepareTargets: prepareTargets, runDestination: runDestination) { results in
                    let arena = try #require(results.arena)
                    let productsRoot = arena.buildProductsPath.str
                    let intermediatesRoot = arena.buildIntermediatesPath.str

                    results.consumeTasksMatchingRuleTypes(Self.excludedStartTaskTypes)

                    // Header maps
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget-all-non-framework-target-headers.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget-all-target-headers.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget-generated-files.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget-own-target-headers.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget-project-headers.hmap"]))
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.hmap"]))
                    results.checkTaskExists(.matchRulePattern(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")]))

                    // Response files
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/x86_64/e6072d4f65d7061329687fe24e3d63a7-common-args.resp"]))

                    // Mkdir
                    results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug-iphonesimulator/AppTarget.app"]))

                    // Index -> regular build overlay
                    results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/index-overlay.yaml"]))

                    results.checkNoTask()
                }
            }

            try await checkBuild(prepareTargets: [appTarget.guid], runDestination: .iOSSimulator)

            // Build it properly for simulator (as it is intended) ignoring the currently selected run destination.
            try await checkBuild(prepareTargets: [appTarget.guid], runDestination: .macOS)
        }
    }

    @Test(.requireSDKs(.macOS))
    func preparingForIndexingMetalFile() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let appTarget = TestStandardTarget(
                "AppTarget",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug")
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "Metal.metal",
                    ]),
                ],
                dependencies: [])

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("Metal.metal"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])],
                        targets: [
                            appTarget,
                        ])])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Metal.metal")) { stream in }

            // Build it properly for simulator (as it is intended) ignoring the currently selected run destination.
            try await tester.checkIndexBuild(prepareTargets: [appTarget.guid], runDestination: .macOS) { results in
                results.consumeTasksMatchingRuleTypes(Set(["Gate", "CreateBuildDirectory", ProductPlan.preparedForIndexPreCompilationRuleName]))

                let arena = try #require(results.arena)
                let productsRoot = arena.buildProductsPath.str
                let intermediatesRoot = arena.buildIntermediatesPath.str

                // Header maps
                results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-all-non-framework-target-headers.hmap"]))
                results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-all-target-headers.hmap"]))
                results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-generated-files.hmap"]))
                results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-own-target-headers.hmap"]))
                results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget-project-headers.hmap"]))
                results.checkTaskExists(.matchRule(["WriteAuxiliaryFile", "\(intermediatesRoot)/aProject.build/Debug/AppTarget.build/AppTarget.hmap"]))
                results.checkTaskExists(.matchRulePattern(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")]))

                // Mkdir
                results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/AppTarget.app"]))
                results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/AppTarget.app/Contents"]))
                results.checkTaskExists(.matchRule(["MkDir", "\(productsRoot)/Debug/AppTarget.app/Contents/Resources"]))

                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func preparingForIndexingPackages() async throws {

        try await withTemporaryDirectory { tmpDirPath in
            let packageLib = try await TestStandardTarget("PackageLib", type: .objectFile, buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "PackageLib",
                    "SDKROOT": "auto",
                    "SDK_VARIANT": "auto",
                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                    "SWIFT_VERSION": swiftVersion,
                ])
            ], buildPhases: [TestSourcesBuildPhase(["test.swift"])])

            let package = try await TestPackageProject("aPackage", groupTree: TestGroup("Package", children: [TestFile("test.swift")]), targets: [
                TestPackageProductTarget(
                    "PackageLibProduct",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("PackageLib"))]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "auto",
                            "SDK_VARIANT": "auto",
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "SWIFT_VERSION": swiftVersion,
                        ]),
                    ],
                    dependencies: ["PackageLib"]
                ),
                packageLib,
            ])

            let macAppTarget = TestStandardTarget(
                "macAppTarget",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                    ]),
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "mac-main.swift",
                    ]),
                    TestFrameworksBuildPhase([
                        TestBuildFile(.target("PackageLibProduct"))
                    ]),
                ],
                dependencies: ["PackageLibProduct"])

            let iosAppTarget = TestStandardTarget(
                "iOSAppTarget",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "iphonesimulator",
                        "SUPPORTED_PLATFORMS": "iphonesimulator",
                    ]),
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "ios-main.swift",
                    ]),
                    TestFrameworksBuildPhase([
                        TestBuildFile(.target("PackageLibProduct"))
                    ]),
                ],
                dependencies: ["PackageLibProduct"])

            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("mac-main.swift"),
                                TestFile("ios-main.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion,
                                ])],
                        targets: [
                            macAppTarget,
                            iosAppTarget,
                        ]), package])

            func getTargetRuleInfosForBuildDir(intermediatesRoot: String, configurationName: String) -> [[String]] {
                // accumulating because a big list literal hurts compile time.
                var ruleInfos: [[String]] = []
                // WriteAuxiliaryFile
                ruleInfos.append(["WriteAuxiliaryFile", "\(intermediatesRoot)/aPackage.build/\(configurationName)/PackageLib.build/Objects-normal/x86_64/PackageLib-OutputFileMap.json"])
                ruleInfos.append(["WriteAuxiliaryFile", "\(intermediatesRoot)/aPackage.build/\(configurationName)/PackageLib.build/Objects-normal/x86_64/PackageLib.SwiftFileList"])
                ruleInfos.append(["WriteAuxiliaryFile", "\(intermediatesRoot)/aPackage.build/\(configurationName)/PackageLib.build/PackageLib-all-non-framework-target-headers.hmap"])
                ruleInfos.append(["WriteAuxiliaryFile", "\(intermediatesRoot)/aPackage.build/\(configurationName)/PackageLib.build/PackageLib-all-target-headers.hmap"])
                ruleInfos.append(["WriteAuxiliaryFile", "\(intermediatesRoot)/aPackage.build/\(configurationName)/PackageLib.build/PackageLib-generated-files.hmap"])
                ruleInfos.append(["WriteAuxiliaryFile", "\(intermediatesRoot)/aPackage.build/\(configurationName)/PackageLib.build/PackageLib-own-target-headers.hmap"])
                ruleInfos.append(["WriteAuxiliaryFile", "\(intermediatesRoot)/aPackage.build/\(configurationName)/PackageLib.build/PackageLib-project-headers.hmap"])
                ruleInfos.append(["WriteAuxiliaryFile", "\(intermediatesRoot)/aPackage.build/\(configurationName)/PackageLib.build/PackageLib.hmap"])
                ruleInfos.append(["WriteAuxiliaryFile", "\(intermediatesRoot)/index-overlay.yaml"])
                return ruleInfos
            }

            func checkBuild(prepareTargets: [String], runDestination: RunDestinationInfo, body: (BuildOperationTester.BuildResults) throws -> Void) async throws {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                // Write the file data.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/mac-main.swift")) { stream in
                    stream <<< "func main(){}"
                }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ios-main.swift")) { stream in
                    stream <<< "func main(){}"
                }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aPackage/test.swift")) { stream in
                    stream <<< "func foo(){}"
                }

                try await tester.checkIndexBuild(prepareTargets: prepareTargets, runDestination: runDestination, body: body)
            }

            try await checkBuild(prepareTargets: [packageLib.guid], runDestination: .macOS) { results in
                let intermediatesRoot = try #require(results.arena).buildIntermediatesPath.str
                let osxTargetRuleInfos = getTargetRuleInfosForBuildDir(intermediatesRoot: intermediatesRoot, configurationName: "Debug")
                results.consumeTasksMatchingRuleTypes(Self.excludedStartTaskTypes)
                for ruleInfo in osxTargetRuleInfos {
                    results.checkTask(.matchRule(ruleInfo)) { _ in }
                }
                results.checkTasks(.matchRulePattern(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")])) { _ in}
                results.checkNoTask()
            }

            try await checkBuild(prepareTargets: [packageLib.guid], runDestination: .iOSSimulator) { results in
                let intermediatesRoot = try #require(results.arena).buildIntermediatesPath.str
                let iosTargetRuleInfos = getTargetRuleInfosForBuildDir(intermediatesRoot: intermediatesRoot, configurationName: "Debug-iphonesimulator")
                results.consumeTasksMatchingRuleTypes(Self.excludedStartTaskTypes)
                for ruleInfo in iosTargetRuleInfos {
                    results.checkTask(.matchRule(ruleInfo)) { _ in }
                }
                results.checkTasks(.matchRulePattern(["WriteAuxiliaryFile", .suffix("all-product-headers.yaml")])) { _ in}
                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func preparingWithBuildRuleOrPhaseScript() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let appTarget1 = TestStandardTarget(
                "AppTarget1",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                    ])
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "main.m",
                    ]),
                ],
                dependencies: [
                    "FwkTarget1",
                    "script1",
                    "script3",
                    "scriptNoOutForced",
                    "scriptSrcOutForced",
                ])

            let appTarget2 = TestStandardTarget(
                "AppTarget2",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                    ])
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "main.m",
                    ]),
                ],
                dependencies: [
                    "FwkTarget2",
                    "script2",
                    "scriptNoOut",
                    "scriptSrcOut",
                ])

            let fwkTarget1 = try await TestStandardTarget(
                "FwkTarget1",
                type: .framework,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "fwk.swift",
                        "generated1.swift.fake-customrule",
                    ])
                ],
                buildRules: [
                    TestBuildRule(filePattern: "*.fake-customrule", script: "cp \"$INPUT_FILE_PATH\" \"${DERIVED_FILE_DIR}/${INPUT_FILE_BASE}\"", outputs: ["$(DERIVED_FILE_DIR)/$(INPUT_FILE_BASE)"])
                ]
            )

            // This target disables script execution for the index build.
            let fwkTarget2 = try await TestStandardTarget(
                "FwkTarget2",
                type: .framework,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                        "SWIFT_VERSION": swiftVersion,
                        "INDEX_DISABLE_SCRIPT_EXECUTION": "YES",
                    ]),
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "fwk.swift",
                        "generated2.swift.fake-customrule",
                    ])
                ],
                buildRules: [
                    TestBuildRule(filePattern: "*.fake-customrule", script: "cp \"$INPUT_FILE_PATH\" \"${DERIVED_FILE_DIR}/${INPUT_FILE_BASE}\"", outputs: ["$(DERIVED_FILE_DIR)/$(INPUT_FILE_BASE)"])
                ]
            )

            let scriptTarget1 = TestAggregateTarget(
                "script1",
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "OBJROOT": tmpDirPath.join("objs").str,
                        "SYMROOT": tmpDirPath.join("syms").str,
                    ]),
                ],
                buildPhases: [
                    TestShellScriptBuildPhase(
                        name: "Script1",
                        originalObjectID: "Script1",
                        contents: """
                                  echo Script1Derived > \"${DERIVED_FILE_DIR}/script1-derived\"
                                  echo Script1Temp > \"${TARGET_TEMP_DIR}/script1-temp\"
                                  """,
                        inputs: [],
                        outputs: [
                            "$(DERIVED_FILE_DIR)/script1-derived",
                            "$(TARGET_TEMP_DIR)/script1-temp",
                        ])
                ]
            )

            // This target disables script execution for the index build.
            let scriptTarget2 = TestAggregateTarget(
                "script2",
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "INDEX_DISABLE_SCRIPT_EXECUTION": "YES",
                    ]),
                ],
                buildPhases: [
                    TestShellScriptBuildPhase(
                        name: "Script2", originalObjectID: "Script2", contents: "echo Script2 > \"${DERIVED_FILE_DIR}/script2-output\"", inputs: [], outputs: [
                            "$(DERIVED_FILE_DIR)/script2-output"
                        ])
                ]
            )

            // Using file lists.
            let scriptTarget3 = TestAggregateTarget(
                "script3",
                buildPhases: [
                    TestShellScriptBuildPhase(
                        name: "Script3", originalObjectID: "Script3", contents: "set -e\ncat \"$SCRIPT_INPUT_FILE_LIST_0\"\ncat \"$SCRIPT_OUTPUT_FILE_LIST_0\"\ntouch $TARGET_BUILD_DIR/Tool.app/out3.txt", inputs: [], inputFileLists: ["$(SRCROOT)/in3.xcfilelist"], outputs: [], outputFileLists: ["$(SRCROOT)/out3.xcfilelist"]
                    )
                ]
            )

            // The script has no output, it should not run.
            let scriptTargetNoOut = TestAggregateTarget(
                "scriptNoOut",
                buildPhases: [
                    TestShellScriptBuildPhase(
                        name: "ScriptNoOut", originalObjectID: "ScriptNoOut", contents: "echo hello", inputs: [], outputs: [])
                ]
            )

            // The script has no output, but it is forced to run using a setting.
            let scriptTargetNoOutForced = TestAggregateTarget(
                "scriptNoOutForced",
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "INDEX_FORCE_SCRIPT_EXECUTION": "YES",
                    ]),
                ],
                buildPhases: [
                    TestShellScriptBuildPhase(
                        name: "ScriptNoOutForced", originalObjectID: "ScriptNoOutForced", contents: "echo hello", inputs: [], outputs: [])
                ]
            )

            // The script has SRCROOT output, it should not run.
            let scriptTargetSrcOut = TestAggregateTarget(
                "scriptSrcOut",
                buildPhases: [
                    TestShellScriptBuildPhase(
                        name: "ScriptSrcOut", originalObjectID: "ScriptSrcOut", contents: "touch $SRCROOT/srcOut", inputs: [], outputs: ["$(SRCROOT)/srcOut"])
                ]
            )

            // The script has SRCROOT output, but it is forced to run using a setting.
            let scriptTargetSrcOutForced = TestAggregateTarget(
                "scriptSrcOutForced",
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "INDEX_FORCE_SCRIPT_EXECUTION": "YES",
                    ]),
                ],
                buildPhases: [
                    TestShellScriptBuildPhase(
                        name: "ScriptSrcOutForced", originalObjectID: "ScriptSrcOutForced", contents: "touch $SRCROOT/srcOutForced", inputs: [], outputs: ["$(SRCROOT)/srcOutForced"])
                ]
            )

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("main.m"),
                                TestFile("fwk.swift"),
                                TestFile("generated1.swift.fake-customrule"),
                                TestFile("generated2.swift.fake-customrule"),
                                TestFile("in3.xcfilelist"),
                                TestFile("out3.xcfilelist"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "OTHER_SWIFT_FLAGS": "$(inherited) -disallow-use-new-driver", // FIXME: remove when rdar://75754282 is fixed.
                            ])],
                        targets: [
                            appTarget1,
                            appTarget2,
                            fwkTarget1,
                            fwkTarget2,
                            scriptTarget1,
                            scriptTarget2,
                            scriptTarget3,
                            scriptTargetNoOut,
                            scriptTargetNoOutForced,
                            scriptTargetSrcOut,
                            scriptTargetSrcOutForced,
                        ])])

            func checkBuild(prepareTargets: [String], runDestination: RunDestinationInfo = .macOS, body: (BuildOperationTester.BuildResults) throws -> Void) async throws {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                // Write the file data.
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.m")) { stream in stream <<< "int main(){}" }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/fwk.swift")) { stream in stream <<< "func test(_: GenCls){}" }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/generated1.swift.fake-customrule")) { stream in stream <<< "class GenCls {}" }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/generated2.swift.fake-customrule")) { stream in stream <<< "class GenCls {}" }

                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/in3.xcfilelist")) { stream in stream <<< "$(SRCROOT)/input3.txt\n" }
                try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/out3.xcfilelist")) { stream in stream <<< "$(TARGET_BUILD_DIR)/Tool.app/out3.txt\n" }

                try await tester.checkIndexBuild(prepareTargets: prepareTargets, runDestination: runDestination, body: body)
            }

            try await checkBuild(prepareTargets: [appTarget1.guid]) { results in
                results.checkTask(.matchRuleType("RuleScriptExecution"), .matchTargetName(fwkTarget1.name)) { _ in }
                results.checkNoTask(.matchRuleType("RuleScriptExecution"))
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchTargetName(scriptTarget1.name)) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchTargetName(scriptTarget3.name)) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchTargetName(scriptTargetNoOutForced.name)) { _ in }
                results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchTargetName(scriptTargetSrcOutForced.name)) { _ in }
                results.checkNoTask(.matchRuleType("PhaseScriptExecution"))
                results.checkWarning("Run script build phase 'ScriptNoOut' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase. (in target 'scriptNoOut' from project 'aProject')")
                results.checkWarning("Run script build phase 'ScriptNoOutForced' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase. (in target 'scriptNoOutForced' from project 'aProject')")
                results.checkNoDiagnostics()
            }
            try await checkBuild(prepareTargets: [appTarget2.guid]) { results in
                results.checkNoTask(.matchRuleType("RuleScriptExecution"))
                results.checkNoTask(.matchRuleType("PhaseScriptExecution"))
                // Skip checking for diagnostics (rdar://141059258). This test is really just checking that the script
                // phase did not run.
                _ = results.getErrors()
                _ = results.getWarnings()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func prepareForIndexResultInfo() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let superframeTarget = TestStandardTarget(
                "SuperFrame", type: .framework,
                buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("superframe.swift")]),
                    TestShellScriptBuildPhase(
                        name: "Script1", originalObjectID: "Script1", contents: "exit 1", inputs: [], outputs: [
                            "$(DERIVED_FILE_DIR)/script1-output"
                        ])
                ])
            let frameTarget = TestStandardTarget(
                "Frame", type: .framework,
                buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("frame.swift")]),
                    TestFrameworksBuildPhase(["SuperFrame.framework"]),
                ])
            let headerFrame = TestStandardTarget(
                "HeaderFrame", type: .framework,
                buildPhases: [
                    TestSourcesBuildPhase(["header.c"]),
                    TestHeadersBuildPhase([TestBuildFile("header.h", headerVisibility: .public)])
                ])
            let toolTarget = TestStandardTarget(
                "Tool", type: .commandLineTool,
                buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("tool.swift")]),
                    TestFrameworksBuildPhase(["Frame.framework", "HeaderFrame.framework"]),
                ])
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup("Files", children: [
                    TestFile("superframe.swift"),
                    TestFile("frame.swift"),
                    TestFile("header.c"),
                    TestFile("header.h"),
                    TestFile("tool.swift")
                ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "macosx",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": "5",
                            "ALWAYS_SEARCH_USER_PATHS": "NO",
                        ])],
                targets: [superframeTarget, frameTarget, headerFrame, toolTarget])
            let testWorkspace = TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [testProject])
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the test sources.
            try await tester.fs.writeFileContents(SRCROOT.join("superframe.swift")) { contents in
                contents <<< "public func getTheValue() -> Int { return 0 }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("frame.swift")) { contents in
                contents <<< "public func getTheValue() -> Int { return 0 }\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("header.c")) { contents in
                contents <<< "int main() {}\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("header.h")) { contents in
                contents <<< "\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("tool.swift")) { contents in
                contents <<< "import Frame\n_ = getTheValue()\n"
            }

            let initialTime = Date()
            var currPrepareResult: PreparedForIndexResultInfo!
            try await tester.checkIndexBuild(prepareTargets: [toolTarget.guid], persistent: true) { results in
                results.checkError(.contains("PhaseScriptExecution failed"))
                results.checkNoDiagnostics()
                let prepareInfo = try #require(results.getPreparedForIndexResultInfo().only)
                #expect(prepareInfo.0.guid == toolTarget.guid)
                currPrepareResult = prepareInfo.1
                #expect(initialTime < currPrepareResult.timestamp)
            }

            // Update source file changing the source location of the function. The existing module file will be untouched but the `*.swiftsourceinfo` file will be updated.
            // The prepare result will be updated.
            try await tester.fs.writeFileContents(SRCROOT.join("frame.swift")) { contents in
                contents <<< "\npublic func getTheValue() -> Int { return 0 }\n"
            }
            try await tester.checkIndexBuild(prepareTargets: [toolTarget.guid], persistent: true) { results in
                results.checkError(.contains("PhaseScriptExecution failed"))
                results.checkTask(.matchRuleType("SwiftDriver GenerateModule"), .matchTargetName(frameTarget.name)) { _ in }
                let (_, resultInfo) = try #require(results.getPreparedForIndexResultInfo().only)
                if tester.fs.fileSystemMode != .checksumOnly {
                    // Make sure the timestamp has been updated. This is important
                    // since clients rely on the timestamp changing when
                    // preparation has changed.
                    #expect(currPrepareResult.timestamp < resultInfo.timestamp)
                }
                currPrepareResult = resultInfo
            }

            // Change the function signature. The swift module will get updated.
            // The prepare result should have new update.
            try await tester.fs.writeFileContents(SRCROOT.join("frame.swift")) { contents in
                contents <<< "public func getTheValue() -> Float { return 1 }\n"
            }
            try await tester.checkIndexBuild(prepareTargets: [toolTarget.guid], persistent: true) { results in
                results.checkError(.contains("PhaseScriptExecution failed"))
                results.checkTask(.matchRuleType("SwiftDriver GenerateModule"), .matchTargetName(frameTarget.name)) { _ in }

                let (_, resultInfo) = try #require(results.getPreparedForIndexResultInfo().only)
                if tester.fs.fileSystemMode != .checksumOnly {
                    #expect(currPrepareResult.timestamp < resultInfo.timestamp)
                }
                currPrepareResult = resultInfo
            }

            // Change the function signature from `SuperFrame`, the swift module of `Frame` will not get updated.
            // The prepare result should be unchanged.
            try await tester.fs.writeFileContents(SRCROOT.join("superframe.swift")) { contents in
                contents <<< "public func getTheValue() -> Float { return 1 }\n"
            }
            try await tester.checkIndexBuild(prepareTargets: [toolTarget.guid], persistent: true) { results in
                results.checkError(.contains("PhaseScriptExecution failed"))
                results.checkTask(.matchRuleType("SwiftDriver GenerateModule"), .matchTargetName(superframeTarget.name)) { _ in }
                let (_, resultInfo) = try #require(results.getPreparedForIndexResultInfo().only)
                if tester.fs.fileSystemMode != .checksumOnly {
                    #expect(currPrepareResult.timestamp == resultInfo.timestamp)
                }
                #expect(currPrepareResult == resultInfo)
            }

            // Touch the public header from the dependency.
            // The prepare result should have new update.
            try await tester.fs.writeFileContents(SRCROOT.join("header.h")) { contents in
                contents <<< "\n"
            }
            try await tester.checkIndexBuild(prepareTargets: [toolTarget.guid], persistent: true) { results in
                results.checkError(.contains("PhaseScriptExecution failed"))

                let (_, resultInfo) = try #require(results.getPreparedForIndexResultInfo().only)
                if tester.fs.fileSystemMode != .checksumOnly {
                    #expect(currPrepareResult.timestamp < resultInfo.timestamp)
                }
                currPrepareResult = resultInfo
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func preparingWithConflictingTargets() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let conflictTarget1 = TestStandardTarget(
                "conflictApp",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                    ])
                ],
                buildPhases: [
                    TestSourcesBuildPhase(["main.m"]),
                ],
                dependencies: [
                    "FwkTarget",
                ])

            let conflictTarget2 = TestStandardTarget(
                "conflictApp",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                    ])
                ],
                buildPhases: [
                    TestSourcesBuildPhase(["main.m"]),
                ],
                dependencies: [
                    "FwkTarget",
                ])

            let fwkTarget = try await TestStandardTarget(
                "FwkTarget",
                type: .framework,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                        "SWIFT_VERSION": swiftVersion,
                    ]),
                ],
                buildPhases: [
                    TestSourcesBuildPhase(["fwk.swift"])
                ])

            let toolTarget = TestStandardTarget(
                "ToolTarget",
                type: .commandLineTool,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                    ]),
                ],
                buildPhases: [
                    TestSourcesBuildPhase(["main.m"]),
                ],
                dependencies: [
                    "FwkTarget",
                ])

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject1",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                        targets: [
                            conflictTarget1,
                        ]
                    ),
                    TestProject(
                        "aProject2",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                        targets: [
                            conflictTarget2,
                        ]
                    ),
                    TestProject(
                        "aProject3",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("main.m"),
                                TestFile("fwk.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ])],
                        targets: [
                            fwkTarget,
                            toolTarget,
                        ]
                    ),
                ]
            )

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject3/main.m")) { stream in stream <<< "int main(){}" }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject3/fwk.swift")) { stream in stream <<< "func test(){}" }

            try await tester.checkIndexBuild(prepareTargets: [toolTarget.guid]) { results in
                results.checkTaskExists(.matchRuleType("SwiftDriver GenerateModule"), .matchTargetName(fwkTarget.name))
                results.checkError(.contains("Multiple commands produce '\(results.arena?.buildProductsPath.str ?? "missing")/Debug/conflictApp.app'"))
                while results.checkWarning(.contains("unexpected mutating task"), failIfNotFound: false) {}
                while results.checkWarning(.contains("duplicate output file"), failIfNotFound: false) {}
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func preparingWithDuplicateScriptOutput() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let leafTarget = TestStandardTarget(
                "leafTarget",
                type: .framework,
                buildPhases: [
                    TestSourcesBuildPhase(["leaf.swift"]),
                ],
                dependencies: [
                    "FwkTarget",
                ])
            let fwkTarget = TestStandardTarget(
                "FwkTarget",
                type: .framework,
                buildConfigurations: [
                    // Explicitly testing tasks from different platforms producing the same output file, force script execution since otherwise these tasks won't be run.
                    TestBuildConfiguration("Debug", buildSettings: [
                        "INDEX_FORCE_SCRIPT_EXECUTION": "YES",
                    ]),
                ],
                buildPhases: [
                    TestShellScriptBuildPhase(
                        name: "Script1", originalObjectID: "Script1", contents: "echo let foo = 0 > \"${SRCROOT}/gen.swift\"", inputs: [], outputs: ["$(SRCROOT)/gen.swift"]),
                    TestSourcesBuildPhase([
                        "gen.swift",
                        "gen2.swift.fake-customrule",
                        "fwk.swift",
                    ]),
                ],
                buildRules: [
                    TestBuildRule(filePattern: "*.fake-customrule", script: "echo let foo2 = 0 > \"${SRCROOT}/gen2.swift\"", outputs: ["$(SRCROOT)/gen2.swift"])
                ]
            )
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup("Files", children: [
                    TestFile("leaf.swift"),
                    TestFile("gen.swift"),
                    TestFile("gen2.swift"),
                    TestFile("fwk.swift"),
                    TestFile("gen2.swift.fake-customrule"),
                ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "SDKROOT": "iphoneos",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
                            "SUPPORTS_MACCATALYST": "NO",
                            "SWIFT_VERSION": swiftVersion,
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "ALWAYS_SEARCH_USER_PATHS": "NO",
                        ])],
                targets: [leafTarget, fwkTarget])
            let testWorkspace = TestWorkspace(
                "aWorkspace",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [testProject])

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            func checkBuild(_ runDestination: RunDestinationInfo, discriminator: String) async throws {
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                // Write the test sources.
                try await tester.fs.writeFileContents(SRCROOT.join("leaf.swift")) { contents in contents <<< "import FwkTarget\n" }
                try await tester.fs.writeFileContents(SRCROOT.join("fwk.swift")) { contents in contents <<< "public let m = foo + foo2\n" }
                try await tester.fs.writeFileContents(SRCROOT.join("gen2.swift.fake-customrule")) { contents in contents <<< "" }

                try await tester.checkIndexBuild(prepareTargets: [leafTarget.guid], runDestination: runDestination) { results in
                    results.checkTask(.matchRuleType("SwiftDriver GenerateModule"), .matchTargetName(fwkTarget.name)) { task in
                        #expect(task.forTarget?.platformDiscriminator == discriminator)
                    }
                    results.checkTask(.matchRuleType("PhaseScriptExecution"), .matchTargetName(fwkTarget.name)) { task in
                        #expect(task.forTarget?.platformDiscriminator == discriminator)
                    }

                    results.checkWarning(.contains("Multiple commands produce '\(SRCROOT.str)/gen.swift', picked with target"))
                    results.checkWarning(.contains("Multiple commands produce '\(SRCROOT.str)/gen2.swift', picked with target"))
                    while results.checkWarning(.contains("duplicate output file"), failIfNotFound: false) {}
                    results.checkNoDiagnostics()
                }
            }

            try await checkBuild(.macOS, discriminator: "macos")
            try await checkBuild(.iOSSimulator, discriminator: "iphonesimulator")
            try await checkBuild(.iOS, discriminator: "iphoneos")
        }
    }

    // Project with 2 frameworks that both have the same product name.
    // Check that we do not error with "multiple commands produce ..." and
    // that an appropriate configured target is picked instead.
    @Test(.requireSDKs(.macOS, .iOS))
    func preparingWithDuplicateProducts() async throws {

        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()

            let leafA = TestAggregateTarget(
                "LeafA",
                dependencies: [
                    "FirstFrameworkA",
                ]
            )
            let leafB = TestAggregateTarget(
                "LeafB",
                dependencies: [
                    "FirstFrameworkB",
                ]
            )
            let macosFramework = TestStandardTarget(
                "FirstFrameworkA",
                type: .framework,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "RenamedFramework",
                        "SDKROOT": "macosx",
                        "SUPPORTED_PLATFORMS": "macosx",
                        "DEFINES_MODULE": "Yes",
                    ]),
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "fwk.swift",
                    ]),
                ]
            )
            let iosFramework = TestStandardTarget(
                "FirstFrameworkB",
                type: .framework,
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "RenamedFramework",
                        "SDKROOT": "iphoneos",
                        "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                        "DEFINES_MODULE": "Yes",
                    ]),
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "fwk.swift",
                    ]),
                ]
            )
            let testWorkspace = try await TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup("Files", children: [
                        TestFile("fwk.swift"),
                    ]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_VERSION": swiftVersion,
                            ])
                    ],
                    targets: [leafA, leafB, macosFramework, iosFramework]
                )]
            )

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            func checkBuild(_ prepare: TestStandardTarget, _ runDestination: RunDestinationInfo, discriminator: String, matchingTarget: TestStandardTarget, sourceLocation: SourceLocation = #_sourceLocation) async throws {
                let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

                try await tester.fs.writeFileContents(SRCROOT.join("leaf.swift")) { contents in contents <<< "// app.swift\n" }
                try await tester.fs.writeFileContents(SRCROOT.join("fwk.swift")) { contents in contents <<< "// fwk.swift\n" }

                try await tester.checkIndexBuild(prepareTargets: [prepare.guid], runDestination: runDestination, sourceLocation: sourceLocation) { results in
                    results.checkTask(.matchRuleType("Copy"), .matchRulePattern([.contains("modulemap")]), .matchTargetName(matchingTarget.name), sourceLocation: sourceLocation) { task in
                        #expect(task.forTarget?.platformDiscriminator == discriminator)
                    }

                    while results.checkWarning(.contains("Multiple commands produce"), failIfNotFound: false, sourceLocation: sourceLocation) {}
                    while results.checkWarning(.contains("duplicate output file"), failIfNotFound: false, sourceLocation: sourceLocation) {}

                    results.checkNoDiagnostics(sourceLocation: sourceLocation)
                }
            }

            try await checkBuild(macosFramework, .macOS, discriminator: "macos", matchingTarget: macosFramework)
            try await checkBuild(iosFramework, .iOS, discriminator: "iphoneos", matchingTarget: iosFramework)
            // No run destination match, macos because it's lexicographically-first
            try await checkBuild(macosFramework, .watchOS, discriminator: "macos", matchingTarget: macosFramework)
            try await checkBuild(iosFramework, .watchOS, discriminator: "macos", matchingTarget: macosFramework)
        }
    }

    /// Check that precompiled PCH's are not part of the preparation for a target
    @Test(.requireSDKs(.macOS))
    func preparePCH() async throws {

        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()

            let precompiledPCHTarget = TestStandardTarget(
                "Foo", guid: "Foo", type: .staticLibrary,
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GCC_PREFIX_HEADER": "prefix.h",
                            "GCC_PRECOMPILE_PREFIX_HEADER": "YES"
                        ])
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "foo.c",
                    ])
                ])

            let regularTarget = TestStandardTarget(
                "Bar", guid: "Bar", type: .staticLibrary,
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GCC_PREFIX_HEADER": "prefix.h"
                        ])
                ],
                buildPhases: [
                    TestSourcesBuildPhase([
                        "foo.c",
                    ])
                ])

            let testWorkspace = TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Files",
                        children: [
                            TestFile("foo.c"),
                            TestFile("prefix.h"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "COMPILER_INDEX_STORE_ENABLE": "YES",
                                "INDEX_ENABLE_DATA_STORE": "YES",
                                "CLANG_ENABLE_MODULES": "YES",
                            ])
                    ],
                    targets: [
                        precompiledPCHTarget, regularTarget
                    ])
            ])

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(SRCROOT.join("foo.c")) { contents in contents <<< "// foo.c\n" }
            try await tester.fs.writeFileContents(SRCROOT.join("prefix.h")) { contents in contents <<< "// prefix.h" }

            try await tester.checkIndexBuild(prepareTargets: [precompiledPCHTarget.guid]) { results in
                results.checkNoDiagnostics()
                results.checkNoTask(.matchRuleType("ProcessPCH"))
            }

            try await tester.checkIndexBuild(prepareTargets: [regularTarget.guid]) { results in
                results.checkNoDiagnostics()
                results.checkNoTask(.matchRuleType("ProcessPCH"))
            }
        }
    }

    /// Check that preparation processes the xcframework for the correct platform
    @Test(.requireSDKs(.macOS, .iOS))
    func prepareXCFramework() async throws {

        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()

            let app = TestStandardTarget(
                "App",
                type: .application,
                buildConfigurations: [
                    TestBuildConfiguration("Debug"),
                ],
                buildPhases: [
                    TestSourcesBuildPhase(["test.swift"]),
                    TestFrameworksBuildPhase(["Support.xcframework"]),
                    TestCopyFilesBuildPhase(["Support.xcframework"], destinationSubfolder: .frameworks),
                ],
                dependencies: []
            )

            let testWorkspace = try await TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("test.swift"),
                            TestFile("Support.xcframework"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                            "SWIFT_VERSION": swiftVersion,
                        ]),
                    ],
                    targets: [app])
            ])

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(SRCROOT.join("test.swift")) { $0 <<< "// test.swift" }
            let supportXCFramework = try XCFramework(version: Version(1, 0), libraries: [
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64"], platformVariant: nil, libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
                XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)-simulator", supportedPlatform: "ios", supportedArchitectures: ["arm64"], platformVariant: "simulator", libraryPath: Path("Support.framework"), binaryPath: Path("Support.framework/Support"), headersPath: nil),
            ])
            let supportXCFrameworkPath = SRCROOT.join("Support.xcframework")
            try tester.fs.createDirectory(supportXCFrameworkPath, recursive: true)
            try await XCFrameworkTestSupport.writeXCFramework(supportXCFramework, fs: tester.fs, path: supportXCFrameworkPath, infoLookup: core)

            try await tester.checkIndexBuild(prepareTargets: [app.guid], runDestination: .iOS) { results in
                results.checkTask(.matchRuleType("ProcessXCFramework")) { task in
                    task.checkCommandLineContains(["builtin-process-xcframework", "--xcframework", "\(SRCROOT.str)/Support.xcframework", "--platform", "ios"])
                    task.checkCommandLineDoesNotContain("simulator")
                }
            }

            try await tester.checkIndexBuild(prepareTargets: [app.guid], runDestination: .iOSSimulator) { results in
                results.checkTask(.matchRuleType("ProcessXCFramework")) { task in
                    task.checkCommandLineContains(["builtin-process-xcframework", "--xcframework", "\(SRCROOT.str)/Support.xcframework", "--platform", "ios", "--environment", "simulator"])
                }
            }
        }
    }

    // Check that clean does in fact, clean.
    @Test(.requireSDKs(.macOS, .iOS))
    func clean() async throws {

        try await withTemporaryDirectory { tmpDir in
            let core = try await getCore()

            let app = TestStandardTarget(
                "App",
                type: .commandLineTool,
                buildConfigurations: [
                    TestBuildConfiguration("Debug"),
                ],
                buildPhases: [
                    TestSourcesBuildPhase(["test.swift"]),
                ],
                dependencies: []
            )

            let testWorkspace = try await TestWorkspace("Test", sourceRoot: tmpDir, projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("test.swift"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                            "SWIFT_VERSION": swiftVersion,
                        ]),
                    ],
                    targets: [app])
            ])

            let SRCROOT = testWorkspace.sourceRoot.join("aProject")
            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            try await tester.fs.writeFileContents(SRCROOT.join("test.swift")) { $0 <<< "// test.swift" }

            let arena = try await tester.checkIndexBuild(prepareTargets: [app.guid], persistent: true) { results in
                let arena = try #require(results.buildRequest.parameters.arena)
                #expect(tester.fs.exists(arena.buildProductsPath))
                return arena
            }

            let buildRequest = BuildRequest(parameters: BuildParameters(action: .indexBuild, configuration: nil, arena: arena), buildTargets: [], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false, buildCommand: .cleanBuildFolder(style: .regular))

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                #expect(!tester.fs.exists(arena.buildProductsPath))
            }
        }
    }
}
