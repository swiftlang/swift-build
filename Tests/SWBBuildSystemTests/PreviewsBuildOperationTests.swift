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

import Testing
import SWBUtil
import SWBTestSupport
import SWBProtocol
import SWBCore
@_spi(Testing) import SWBBuildService
import SWBTaskExecution
import SwiftBuildTestSupport

@Suite(.requireXcode16())
fileprivate struct PreviewsBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.iOS))
    func previewXOJITBuilds() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                        TestFile("Assets.xcassets"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                        "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_VERSION": "5.0",
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                        "SDK_STAT_CACHE_ENABLE": "NO",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.test.ProjectName",
                        "SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION": "NO",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("main.swift"),
                            ]),
                            TestResourcesBuildPhase([
                                TestBuildFile("Assets.xcassets"),
                            ])
                        ]
                    ),
                ]
            )

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            try tester.fs.createDirectory(srcRoot.join("Sources"), recursive: true)
            try tester.fs.write(srcRoot.join("Sources/main.swift"), contents: "")

            let xcassets = srcRoot.join("Sources/Assets.xcassets")
            try await tester.fs.writeAssetCatalog(xcassets, .root, .appIcon("AppIcon"), .imageSet("Foo", [.init(filename: "Blah.png", scale: 2, idiom: .universal)]), .colorSet("Bar", [.sRGB(red: 0, green: 0, blue: 0, alpha: 0, idiom: .universal)]))
            try tester.fs.createDirectory(xcassets.join("Foo.imageset"), recursive: true)
            try tester.fs.writeImage(xcassets.join("Foo.imageset").join("Blah.png"), width: 1, height: 1)

            let previewInfoInput = TaskGeneratePreviewInfoInput.thunkInfo(sourceFile: srcRoot.join("Sources/main.swift"), thunkVariantSuffix: "selection")

            // Concrete iOS simulator destination with overrides for an iPhone 14 Pro
            let buildParameters = BuildParameters(configuration: "Debug", overrides: [
                "ASSETCATALOG_FILTER_FOR_DEVICE_MODEL": "iPhone15,2",
                "ASSETCATALOG_FILTER_FOR_DEVICE_OS_VERSION": core.loadSDK(.iOSSimulator).defaultDeploymentTarget,
                "ASSETCATALOG_FILTER_FOR_THINNING_DEVICE_CONFIGURATION": "iPhone15,2",
                "BUILD_ACTIVE_RESOURCES_ONLY": "YES",
                "ENABLE_SDK_IMPORTS": "NO",
                "TARGET_DEVICE_IDENTIFIER": "DB9FA063-8DA7-41C1-835E-EC616E6AF448",
                "TARGET_DEVICE_MODEL": "iPhone15,2",
                "TARGET_DEVICE_OS_VERSION": core.loadSDK(.iOSSimulator).defaultDeploymentTarget,
                "TARGET_DEVICE_PLATFORM_NAME": "iphonesimulator",

                // And XOJIT previews enabled, which should be passed when the workspace setting is on
                "ENABLE_XOJIT_PREVIEWS": "YES",

                // Check that no warnings are produced from this setting.
                "LD_WARN_UNUSED_DYLIBS": "YES",

                // Skip objc runtime linking otherwise we get warning for the debug dylib about not
                // using libobjc symbols.
                "LINK_OBJC_RUNTIME": "NO",

                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGN_IDENTITY": "-",
            ])

            let provisioningInputs = ["AppTarget": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict(["foo": "bar"]))]

            var buildDescriptionID: BuildDescriptionID?

            try await tester.checkBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .build(style: .buildOnly, skipDependencies: false), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()
                results.checkNote(.equal("Emplaced \(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/Assets.car (for task: [\"LinkAssetCatalog\", \"\(srcRoot.str)/Sources/Assets.xcassets\"])"))
                results.checkNote(.equal("Using stub executor library with Swift entry point. (for task: [\"ConstructStubExecutorLinkFileList\", \"\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-ExecutorLinkFileList-normal-x86_64.txt\"])"))
                results.checkNoNotes()

                results.checkTasks(.matchRuleItemPattern(.prefix("Swift"))) { _ in }
                results.consumeTasksMatchingRuleTypes(["Copy", "CopySwiftLibs", "ExtractAppIntentsMetadata", "Gate", "GenerateDSYMFile", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "ClangStatCache", "RegisterExecutionPolicyException", "AppIntentsSSUTraining", "ProcessInfoPlistFile", "Touch", "Validate", "LinkAssetCatalogSignature", "CodeSign", "ProcessProductPackaging", "ProcessProductPackagingDER"])

                results.consumeTasksMatchingRuleTypes(["GenerateDSYMFile"])

                // For the regular build we should expect to run the thinned asset catalog task
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant")) { task in
                    task.checkRuleInfo(["CompileAssetCatalogVariant", "thinned", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app", "\(srcRoot.str)/Sources/Assets.xcassets"])
                    task.checkCommandLine(["\(core.developerPath.path.str)/usr/bin/actool", "\(srcRoot.str)/Sources/Assets.xcassets", "--compile", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/thinned", "--output-format", "human-readable-text", "--notices", "--warnings", "--export-dependency-info", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_dependencies_thinned", "--output-partial-info-plist", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist_thinned", "--app-icon", "AppIcon", "--compress-pngs", "--enable-on-demand-resources", "YES", "--filter-for-thinning-device-configuration", "iPhone15,2", "--filter-for-device-os-version", core.loadSDK(.iOSSimulator).defaultDeploymentTarget, "--development-region", "English", "--target-device", "iphone", "--minimum-deployment-target", core.loadSDK(.iOSSimulator).defaultDeploymentTarget, "--platform", "iphonesimulator"])
                }

                results.checkTask(.matchRuleType("LinkAssetCatalog")) { task in
                    task.checkRuleInfo(["LinkAssetCatalog", "\(srcRoot.str)/Sources/Assets.xcassets"])
                    task.checkCommandLine(["builtin-linkAssetCatalog", "--thinned", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/thinned", "--thinned-dependencies", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_dependencies_thinned", "--thinned-info-plist-content", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist_thinned", "--unthinned", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/unthinned", "--unthinned-dependencies", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_dependencies_unthinned", "--unthinned-info-plist-content", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist_unthinned", "--output", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app", "--plist-output", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist"])
                }

                // We should have the preview dylib link task
                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget.debug.dylib", "normal"])) { _ in }

                // We should construct the stub executor link file list
                results.checkTask(.matchRule(["ConstructStubExecutorLinkFileList", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-ExecutorLinkFileList-normal-x86_64.txt"])) { _ in }

                // We should have the normal link task, which is the preview shim, and it should link the bootstrap static library
                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget", "normal"])) { task in
                    task.checkCommandLine(
                        [
                            "\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
                            "-Xlinker", "-reproducible",
                            "-target", "\(results.runDestinationTargetArchitecture)-apple-ios\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)-simulator",
                            "-isysroot", core.loadSDK(.iOSSimulator).path.str,
                            "-Os",
                            "-L\(srcRoot.str)/build/Debug-iphonesimulator",
                            "-F\(srcRoot.str)/build/Debug-iphonesimulator",
                            "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                            "-rdynamic",
                            "-Xlinker", "-objc_abi_version", "-Xlinker", "2",
                            "-e", "___debug_blank_executor_main",
                            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__debug_dylib", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-DebugDylibPath-normal-\(results.runDestinationTargetArchitecture).txt",
                            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__debug_instlnm", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-DebugDylibInstallName-normal-\(results.runDestinationTargetArchitecture).txt",
                            "-Xlinker", "-filelist", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-ExecutorLinkFileList-normal-x86_64.txt",
                            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app-Simulated.xcent",
                            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__ents_der", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app-Simulated.xcent.der",
                            "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget.debug.dylib",
                            "-Xlinker", "-no_adhoc_codesign",
                            "-o", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget"
                        ]
                    )
                }

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/__preview.dylib", "normal"])) { _ in }

                results.checkNoTask()

                let buildDescription = results.buildDescription
                #expect(buildDescriptionID == nil)
                buildDescriptionID = buildDescription.ID

                let targets = buildDescription.allConfiguredTargets.sorted { $0.target.name < $1.target.name }

                for target in targets {
                    let previewInfos = buildDescription.generatePreviewInfoForTesting(for: [target], workspaceContext: tester.workspaceContext, buildRequestContext: results.buildRequestContext, input: previewInfoInput)

                    #expect(previewInfos.count == 1)
                    if let previewInfo = previewInfos.only {
                        #expect(previewInfo.context.architecture == results.runDestinationTargetArchitecture)
                        #expect(previewInfo.context.buildVariant == "normal")

                        #expect(previewInfo.context.pifGUID == target.target.guid)
                        #expect(previewInfo.context.sdkRoot == core.loadSDK(.iOSSimulator).name)
                        #expect(previewInfo.context.sdkVariant == "iphonesimulator")

                        // Ignore irrelevant paths which change often
                        var compileCommandLine = previewInfo.thunkInfo?.compileCommandLine ?? []
                        for idx in compileCommandLine.indices.reversed().dropFirst() {
                            if ["-external-plugin-path", "-plugin-path", "-blocklist-file", "-prebuilt-module-cache-path", "-in-process-plugin-server-path", "-resource-dir"].contains(compileCommandLine[idx]) {
                                // Remove the flag and argument
                                compileCommandLine.remove(at: idx)
                                compileCommandLine.remove(at: idx)
                            }
                            if ["-disable-clang-spi", "-no-auto-bridging-header-chaining", "-auto-bridging-header-chaining"].contains(compileCommandLine[idx]) {
                                // Remove the flag
                                compileCommandLine.remove(at: idx)
                            }
                            if ["-fcolor-diagnostics", "-fno-color-diagnostics"].contains(compileCommandLine[idx+1]) && compileCommandLine[idx] == "-Xcc" {
                                compileCommandLine.remove(at: idx)
                                compileCommandLine.remove(at: idx)
                            }
                        }

                        XCTAssertEqualSequences(
                            compileCommandLine,
                            [
                                "\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                                "-frontend",
                                "-c",
                                "-primary-file",
                                "\(srcRoot.str)/Sources/main.swift",
                                "-serialize-diagnostics-path",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/main.selection.preview-thunk.dia",
                                "-target",
                                "\(results.runDestinationTargetArchitecture)-apple-ios\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)-simulator",
                                "-enable-objc-interop",
                                "-sdk",
                                "\(core.loadSDK(.iOSSimulator).path.str)",
                                "-I",
                                "\(srcRoot.str)/build/Debug-iphonesimulator",
                                "-F",
                                "\(srcRoot.str)/build/Debug-iphonesimulator",
                                "-vfsoverlay",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/vfsoverlay-main.selection.preview-thunk.swift.json",
                                "-no-color-diagnostics",
                                "-g",
                                "-debug-info-format=dwarf",
                                "-dwarf-version=5",
                                "-swift-version",
                                "5",
                                "-enforce-exclusivity=checked",
                                "-Onone",
                                "-serialize-debugging-options",
                                "-enable-experimental-feature",
                                "DebugDescriptionMacro",
                                "-enable-bare-slash-regex",
                                "-empty-abi-descriptor",
                                "-Xcc",
                                "-working-directory",
                                "-Xcc",
                                "\(srcRoot.str)",
                                "-enable-anonymous-context-mangled-names",
                                "-file-compilation-dir",
                                "\(srcRoot.str)",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/swift-overrides.hmap",
                                "-Xcc",
                                "-iquote",
                                "-Xcc",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-generated-files.hmap",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-own-target-headers.hmap",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-all-target-headers.hmap",
                                "-Xcc",
                                "-iquote",
                                "-Xcc",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-project-headers.hmap",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/Debug-iphonesimulator/include",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources/\(results.runDestinationTargetArchitecture)",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources",
                                "-module-name",
                                "AppTarget",
                                "-target-sdk-version",
                                "\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)",
                                "-target-sdk-name",
                                "iphonesimulator\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)",
                                "-o",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/main.selection.preview-thunk.o"
                            ]
                        )
                        #expect(previewInfo.thunkInfo?.thunkSourceFile == Path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/main.selection.preview-thunk.swift"))
                        #expect(previewInfo.thunkInfo?.thunkObjectFile == Path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/main.selection.preview-thunk.o"))

                        // Empty for XOJIT previews, at least for now
                        #expect(previewInfo.thunkInfo?.linkCommandLine == [])
                        #expect(previewInfo.thunkInfo?.thunkLibrary == Path(""))
                    }

                    let targetPreviewInfos = buildDescription.generatePreviewInfoForTesting(for: [target], workspaceContext: tester.workspaceContext, buildRequestContext: results.buildRequestContext, input: .targetDependencyInfo)
                    #expect(targetPreviewInfos.count == 1)
                    if let targetPreviewInfo = targetPreviewInfos.only {
                        #expect(targetPreviewInfo.context.architecture == results.runDestinationTargetArchitecture)
                        #expect(targetPreviewInfo.context.buildVariant == "normal")

                        #expect(targetPreviewInfo.context.pifGUID == target.target.guid)
                        #expect(targetPreviewInfo.context.sdkRoot == core.loadSDK(.iOSSimulator).name)
                        #expect(targetPreviewInfo.context.sdkVariant == "iphonesimulator")

                        #expect(targetPreviewInfo.targetDependencyInfo?.objectFileInputMap == [
                            "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/main.o": Set(["\(srcRoot.str)/Sources/main.swift"])
                            ])
                        var linkerCommandLine = targetPreviewInfo.targetDependencyInfo?.linkCommandLine ?? []
                        for idx in linkerCommandLine.indices.reversed() {
                            if linkerCommandLine[idx].hasSuffix("linker-args.resp") {
                                linkerCommandLine.remove(at: idx)
                            }
                        }
                        XCTAssertEqualSequences(linkerCommandLine, ["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "-Xlinker", "-reproducible", "-target", "\(results.runDestinationTargetArchitecture)-apple-ios\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)-simulator", "-dynamiclib", "-isysroot", core.loadSDK(.iOSSimulator).path.str, "-Os", "-Xlinker", "-warn_unused_dylibs", "-L\(srcRoot.str)/build/EagerLinkingTBDs/Debug-iphonesimulator", "-L\(srcRoot.str)/build/Debug-iphonesimulator", "-F\(srcRoot.str)/build/EagerLinkingTBDs/Debug-iphonesimulator", "-F\(srcRoot.str)/build/Debug-iphonesimulator", "-filelist", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/AppTarget.LinkFileList", "-install_name", "@rpath/AppTarget.debug.dylib", "-dead_strip", "-Xlinker", "-object_path_lto", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/AppTarget_lto.o", "-Xlinker", "-objc_abi_version", "-Xlinker", "2", "-Xlinker", "-dependency_info", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/AppTarget_dependency_info.dat", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphonesimulator", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/AppTarget.swiftmodule", "-Xlinker", "-alias", "-Xlinker", "_main", "-Xlinker", "___debug_main_executable_dylib_entry_point", "-Xlinker", "-no_adhoc_codesign", "-o", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget.debug.dylib"])
                    }
                }

                // The preview shim should still retain custom entitlements that normally go to the main executable
                await #expect(throws: Never.self) {
                    try await results.checkEntitlements(.simulated, srcRoot.join("build/Debug-iphonesimulator/AppTarget.app/AppTarget")) { entitlements in
                        #expect(entitlements?["foo"] == .plString("bar"))
                    }
                }

                await #expect(throws: Never.self) {
                    try await results.checkNoEntitlements(.signed, srcRoot.join("build/Debug-iphonesimulator/AppTarget.app/AppTarget"))
                }
            }

            try await tester.checkNullBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .build(style: .buildOnly, skipDependencies: false), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs)

            try await tester.checkBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .preview(style: .xojit), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()
                results.checkNote(.equal("Emplaced \(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/Assets.car (for task: [\"LinkAssetCatalog\", \"\(srcRoot.str)/Sources/Assets.xcassets\"])"))
                results.checkNoNotes()

                // Switching from build to preview should not have changed the build description
                #expect(buildDescriptionID == results.buildDescription.ID)

                // And it should only compile (this time, the unthinned variant) and "re-link" asset catalogs
                results.consumeTasksMatchingRuleTypes(["Gate", "GenerateDSYMFile", "ProcessInfoPlistFile", "LinkAssetCatalogSignature", "CodeSign", "Validate", "AppIntentsSSUTraining"])

                // For the preview build we should expect to run the unthinned asset catalog task
                results.checkTask(.matchRuleType("CompileAssetCatalogVariant")) { task in
                    task.checkRuleInfo(["CompileAssetCatalogVariant", "unthinned", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app", "\(srcRoot.str)/Sources/Assets.xcassets"])
                    task.checkCommandLine(["\(core.developerPath.path.str)/usr/bin/actool", "\(srcRoot.str)/Sources/Assets.xcassets", "--compile", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_output/unthinned", "--output-format", "human-readable-text", "--notices", "--warnings", "--export-dependency-info", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_dependencies_unthinned", "--output-partial-info-plist", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/assetcatalog_generated_info.plist_unthinned", "--app-icon", "AppIcon", "--compress-pngs", "--enable-on-demand-resources", "YES", "--development-region", "English", "--target-device", "iphone", "--minimum-deployment-target", core.loadSDK(.iOSSimulator).defaultDeploymentTarget, "--platform", "iphonesimulator"])
                }

                // And we should link into place again, because the inputs (e.g. the unthinned catalog) changed
                results.checkTask(.matchRuleType("LinkAssetCatalog")) { _ in }

                results.checkNoTask()
            }

            try await tester.checkNullBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .preview(style: .xojit), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs)

            try await tester.checkBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .build(style: .buildOnly, skipDependencies: false), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                // Switching from preview to build should not have changed the build description
                #expect(buildDescriptionID == results.buildDescription.ID)

                // And it should ONLY "re-link" asset catalogs, this time only because the "signature" task representing the build command changed, even though neither of the input catalogs did
                results.consumeTasksMatchingRuleTypes(["Gate", "LinkAssetCatalogSignature"])
                results.checkTask(.matchRuleType("LinkAssetCatalog")) { _ in }
                results.checkTaskExists(.matchRuleType("ProcessInfoPlistFile"))
                results.checkNoTask()
            }

            try await tester.checkNullBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .build(style: .buildOnly, skipDependencies: false), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs)

            try await tester.checkBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .preview(style: .xojit), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                // Switching from build to preview should not have changed the build description
                #expect(buildDescriptionID == results.buildDescription.ID)

                // And it should ONLY "re-link" asset catalogs
                results.consumeTasksMatchingRuleTypes(["Gate", "LinkAssetCatalogSignature"])
                results.checkTask(.matchRuleType("LinkAssetCatalog")) { _ in }
                results.checkTaskExists(.matchRuleType("ProcessInfoPlistFile"))
                results.checkNoTask()
            }

            try await tester.checkNullBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .preview(style: .xojit), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs)
        }
    }

    /// Test that `generatePreviewInfo` does the right thing in the face of multiple Swift files.
    @Test(.requireSDKs(.iOS))
    func previewXOJITBuildsMultiFile() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                        TestFile("File1.swift"),
                        TestFile("File2.swift"),
                        TestFile("File3.swift"),
                        TestFile("Assets.xcassets"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                        "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_VERSION": "5.0",
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                        "SDK_STAT_CACHE_ENABLE": "NO",
                        "SWIFT_VALIDATE_CLANG_MODULES_ONCE_PER_BUILD_SESSION": "NO",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("main.swift"),
                                TestBuildFile("File1.swift"),
                                TestBuildFile("File2.swift"),
                                TestBuildFile("File3.swift"),
                            ]),
                            TestResourcesBuildPhase([
                                TestBuildFile("Assets.xcassets"),
                            ])
                        ]
                    ),
                ]
            )

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            try tester.fs.createDirectory(srcRoot.join("Sources"), recursive: true)
            try tester.fs.write(srcRoot.join("Sources/main.swift"), contents: "")
            try tester.fs.write(srcRoot.join("Sources/File1.swift"), contents: "")
            try tester.fs.write(srcRoot.join("Sources/File2.swift"), contents: "")
            try tester.fs.write(srcRoot.join("Sources/File3.swift"), contents: "")

            let xcassets = srcRoot.join("Sources/Assets.xcassets")
            try await tester.fs.writeAssetCatalog(xcassets, .root, .appIcon("AppIcon"), .imageSet("Foo", [.init(filename: "Blah.png", scale: 2, idiom: .universal)]), .colorSet("Bar", [.sRGB(red: 0, green: 0, blue: 0, alpha: 0, idiom: .universal)]))
            try tester.fs.createDirectory(xcassets.join("Foo.imageset"), recursive: true)
            try tester.fs.writeImage(xcassets.join("Foo.imageset").join("Blah.png"), width: 1, height: 1)

            let previewInfoInput = TaskGeneratePreviewInfoInput.thunkInfo(sourceFile: srcRoot.join("Sources/File1.swift"), thunkVariantSuffix: "selection")

            // Concrete iOS simulator destination with overrides for an iPhone 14 Pro
            let buildParameters = BuildParameters(configuration: "Debug", overrides: [
                "ASSETCATALOG_FILTER_FOR_DEVICE_MODEL": "iPhone15,2",
                "ASSETCATALOG_FILTER_FOR_DEVICE_OS_VERSION": core.loadSDK(.iOSSimulator).defaultDeploymentTarget,
                "ASSETCATALOG_FILTER_FOR_THINNING_DEVICE_CONFIGURATION": "iPhone15,2",
                "BUILD_ACTIVE_RESOURCES_ONLY": "YES",
                "ENABLE_SDK_IMPORTS": "NO",
                "TARGET_DEVICE_IDENTIFIER": "DB9FA063-8DA7-41C1-835E-EC616E6AF448",
                "TARGET_DEVICE_MODEL": "iPhone15,2",
                "TARGET_DEVICE_OS_VERSION": core.loadSDK(.iOSSimulator).defaultDeploymentTarget,
                "TARGET_DEVICE_PLATFORM_NAME": "iphonesimulator",

                // And XOJIT previews enabled, which should be passed when the workspace setting is on
                "ENABLE_XOJIT_PREVIEWS": "YES",
                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGNING_ALLOWED": "YES",
                "CODE_SIGN_IDENTITY": "-",
            ])

            let provisioningInputs = ["AppTarget": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict(["foo": "bar"]))]

            try await tester.checkBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .build(style: .buildOnly, skipDependencies: false), signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()

                let buildDescription = results.buildDescription

                let targets = buildDescription.allConfiguredTargets.sorted { $0.target.name < $1.target.name }

                for target in targets {
                    let previewInfos = buildDescription.generatePreviewInfoForTesting(for: [target], workspaceContext: tester.workspaceContext, buildRequestContext: results.buildRequestContext, input: previewInfoInput)

                    #expect(previewInfos.count == 1)
                    if let previewInfo = previewInfos.only {
                        #expect(previewInfo.context.architecture == results.runDestinationTargetArchitecture)
                        #expect(previewInfo.context.buildVariant == "normal")

                        #expect(previewInfo.context.pifGUID == target.target.guid)
                        #expect(previewInfo.context.sdkRoot == core.loadSDK(.iOSSimulator).name)
                        #expect(previewInfo.context.sdkVariant == "iphonesimulator")

                        // Ignore irrelevant paths which change often.
                        var compileCommandLine = previewInfo.thunkInfo?.compileCommandLine ?? []
                        for idx in compileCommandLine.indices.reversed().dropFirst() {
                            if ["-external-plugin-path", "-plugin-path", "-blocklist-file", "-prebuilt-module-cache-path", "-in-process-plugin-server-path", "-resource-dir"].contains(compileCommandLine[idx]) {
                                // Remove the flag and argument
                                compileCommandLine.remove(at: idx)
                                compileCommandLine.remove(at: idx)
                            }
                            if ["-disable-clang-spi", "-no-auto-bridging-header-chaining", "-auto-bridging-header-chaining"].contains(compileCommandLine[idx]) {
                                // Remove the flag
                                compileCommandLine.remove(at: idx)
                            }
                            if ["-fcolor-diagnostics", "-fno-color-diagnostics"].contains(compileCommandLine[idx+1]) && compileCommandLine[idx] == "-Xcc" {
                                compileCommandLine.remove(at: idx)
                                compileCommandLine.remove(at: idx)
                            }
                        }

                        XCTAssertEqualSequences(
                            compileCommandLine,
                            [
                                "\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                                "-frontend",
                                "-c",
                                "\(srcRoot.str)/Sources/main.swift",
                                "-primary-file",
                                "\(srcRoot.str)/Sources/File1.swift",
                                "\(srcRoot.str)/Sources/File2.swift",
                                "\(srcRoot.str)/Sources/File3.swift",
                                "-serialize-diagnostics-path",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/File1.selection.preview-thunk.dia",
                                "-target",
                                "\(results.runDestinationTargetArchitecture)-apple-ios\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)-simulator",
                                "-enable-objc-interop",
                                "-sdk",
                                "\(core.loadSDK(.iOSSimulator).path.str)",
                                "-I",
                                "\(srcRoot.str)/build/Debug-iphonesimulator",
                                "-F",
                                "\(srcRoot.str)/build/Debug-iphonesimulator",
                                "-vfsoverlay",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/vfsoverlay-File1.selection.preview-thunk.swift.json",
                                "-no-color-diagnostics",
                                "-g",
                                "-debug-info-format=dwarf",
                                "-dwarf-version=5",
                                "-swift-version",
                                "5",
                                "-enforce-exclusivity=checked",
                                "-Onone",
                                "-serialize-debugging-options",
                                "-enable-experimental-feature",
                                "DebugDescriptionMacro",
                                "-enable-bare-slash-regex",
                                "-empty-abi-descriptor",
                                "-Xcc",
                                "-working-directory",
                                "-Xcc",
                                "\(srcRoot.str)",
                                "-enable-anonymous-context-mangled-names",
                                "-file-compilation-dir",
                                "\(srcRoot.str)",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/swift-overrides.hmap",
                                "-Xcc",
                                "-iquote",
                                "-Xcc",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-generated-files.hmap",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-own-target-headers.hmap",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-all-target-headers.hmap",
                                "-Xcc",
                                "-iquote",
                                "-Xcc",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/AppTarget-project-headers.hmap",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/Debug-iphonesimulator/include",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources/\(results.runDestinationTargetArchitecture)",
                                "-Xcc",
                                "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/DerivedSources",
                                "-module-name",
                                "AppTarget",
                                "-target-sdk-version",
                                "\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)",
                                "-target-sdk-name",
                                "iphonesimulator\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)",
                                "-o",
                                "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/File1.selection.preview-thunk.o"
                            ]
                        )
                        #expect(previewInfo.thunkInfo?.thunkSourceFile == Path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/File1.selection.preview-thunk.swift"))
                        #expect(previewInfo.thunkInfo?.thunkObjectFile == Path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/File1.selection.preview-thunk.o"))

                        // Empty for XOJIT previews, at least for now
                        #expect(previewInfo.thunkInfo?.linkCommandLine == [])
                        #expect(previewInfo.thunkInfo?.thunkLibrary == Path(""))
                    }

                    let targetPreviewInfos = buildDescription.generatePreviewInfoForTesting(for: [target], workspaceContext: tester.workspaceContext, buildRequestContext: results.buildRequestContext, input: .targetDependencyInfo)
                    #expect(targetPreviewInfos.count == 1)
                    if let targetPreviewInfo = targetPreviewInfos.only {
                        #expect(targetPreviewInfo.context.architecture == results.runDestinationTargetArchitecture)
                        #expect(targetPreviewInfo.context.buildVariant == "normal")

                        #expect(targetPreviewInfo.context.pifGUID == target.target.guid)
                        #expect(targetPreviewInfo.context.sdkRoot == core.loadSDK(.iOSSimulator).name)
                        #expect(targetPreviewInfo.context.sdkVariant == "iphonesimulator")

                        #expect(targetPreviewInfo.targetDependencyInfo?.objectFileInputMap == [
                            "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/main.o": Set(["\(srcRoot.str)/Sources/main.swift"]),
                            "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/File1.o": Set(["\(srcRoot.str)/Sources/File1.swift"]),
                            "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/File2.o": Set(["\(srcRoot.str)/Sources/File2.swift"]),
                            "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/File3.o": Set(["\(srcRoot.str)/Sources/File3.swift"]),
                        ])
                        var linkerCommandLine = targetPreviewInfo.targetDependencyInfo?.linkCommandLine ?? []
                        for idx in linkerCommandLine.indices.reversed() {
                            if linkerCommandLine[idx].hasSuffix("linker-args.resp") {
                                linkerCommandLine.remove(at: idx)
                            }
                        }
                        XCTAssertEqualSequences(linkerCommandLine, ["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "-Xlinker", "-reproducible", "-target", "\(results.runDestinationTargetArchitecture)-apple-ios\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)-simulator", "-dynamiclib", "-isysroot", core.loadSDK(.iOSSimulator).path.str, "-Os", "-L\(srcRoot.str)/build/EagerLinkingTBDs/Debug-iphonesimulator", "-L\(srcRoot.str)/build/Debug-iphonesimulator", "-F\(srcRoot.str)/build/EagerLinkingTBDs/Debug-iphonesimulator", "-F\(srcRoot.str)/build/Debug-iphonesimulator", "-filelist", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/AppTarget.LinkFileList", "-install_name", "@rpath/AppTarget.debug.dylib", "-dead_strip", "-Xlinker", "-object_path_lto", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/AppTarget_lto.o", "-Xlinker", "-objc_abi_version", "-Xlinker", "2", "-Xlinker", "-dependency_info", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/AppTarget_dependency_info.dat", "-fobjc-link-runtime", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphonesimulator", "-L/usr/lib/swift", "-Xlinker", "-add_ast_path", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/AppTarget.swiftmodule", "-Xlinker", "-alias", "-Xlinker", "_main", "-Xlinker", "___debug_main_executable_dylib_entry_point", "-Xlinker", "-no_adhoc_codesign", "-o", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget.debug.dylib"])
                    }
                }
            }
        }
    }

    /// Tests that multi-arch XOJIT preview builds work, specifically to ensure the `lipo` tasks are set up correctly for the preview dylib and XOJIT stub executor.
    @Test(.requireSDKs(.iOS))
    func previewXOJITBuildsMultiArch() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_VERSION": "5.0",
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("main.swift"),
                            ]),
                        ]
                    ),
                ]
            )

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            try tester.fs.createDirectory(srcRoot.join("Sources"), recursive: true)
            try tester.fs.write(srcRoot.join("Sources/main.swift"), contents: "")

            let buildParameters = BuildParameters(configuration: "Debug", overrides: [
                // And XOJIT previews enabled, which should be passed when the workspace setting is on
                "ENABLE_XOJIT_PREVIEWS": "YES",
            ])

            try await tester.checkBuild(parameters: buildParameters, runDestination: .anyiOSSimulator, buildCommand: .build(style: .buildOnly, skipDependencies: false)) { results in
                results.checkNoDiagnostics()

                results.consumeTasksMatchingRuleTypes(["Copy", "CopySwiftLibs", "ExtractAppIntentsMetadata", "Gate", "GenerateDSYMFile", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "ClangStatCache", "RegisterExecutionPolicyException", "AppIntentsSSUTraining", "ProcessInfoPlistFile", "Touch", "Validate", "LinkAssetCatalogSignature", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ConstructStubExecutorLinkFileList", "ProcessSDKImports"])
                results.consumeTasksMatchingRuleTypes(["SwiftCompile", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftEmitModule", "SwiftMergeGeneratedHeaders"])
                results.consumeTasksMatchingRuleTypes(["GenerateDSYMFile"])

                for arch in ["arm64", "x86_64"] {
                    results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(arch)/Binary/AppTarget", "normal", arch])) { _ in }

                    results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(arch)/Binary/AppTarget.debug.dylib", "normal", arch])) { _ in }

                    results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/\(arch)/Binary/__preview.dylib", "normal", arch])) { _ in }
                }

                results.checkTask(.matchRule(["CreateUniversalBinary", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget", "normal", "arm64 x86_64"])) { _ in }

                results.checkTask(.matchRule(["CreateUniversalBinary", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/AppTarget.debug.dylib", "normal", "arm64 x86_64"])) { _ in }

                results.checkTask(.matchRule(["CreateUniversalBinary", "\(srcRoot.str)/build/Debug-iphonesimulator/AppTarget.app/__preview.dylib", "normal", "arm64 x86_64"])) { _ in }

                results.checkNoTask()
            }
        }
    }

    /// Tests that XOJIT preview builds work with app extensions, which use a custom entry point.
    @Test(.requireSDKs(.iOS))
    func previewXOJITBuildsAppExtension() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        TestFile("main.swift"),
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_VERSION": "5.0",
                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "AppExTarget",
                        type: .applicationExtension,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("main.swift"),
                            ]),
                        ]
                    ),
                ]
            )

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            try tester.fs.createDirectory(srcRoot.join("Sources"), recursive: true)
            try tester.fs.write(srcRoot.join("Sources/main.swift"), contents: "")

            let buildParameters = BuildParameters(configuration: "Debug", overrides: [
                // And XOJIT previews enabled, which should be passed when the workspace setting is on
                "ENABLE_XOJIT_PREVIEWS": "YES",
            ])

            try await tester.checkBuild(parameters: buildParameters, runDestination: .iOSSimulator, buildCommand: .build(style: .buildOnly, skipDependencies: false)) { results in
                results.checkNoDiagnostics()

                try results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppExTarget.build/AppExTarget-DebugDylibPath-normal-\(results.runDestinationTargetArchitecture).txt"])) { _ in
                    let entryPoint = try results.fs.read(Path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppExTarget.build/AppExTarget-DebugDylibPath-normal-\(results.runDestinationTargetArchitecture).txt"))
                    #expect(entryPoint == ByteString(encodingAsUTF8: "AppExTarget.debug.dylib"))
                }

                try results.checkTask(.matchRule(["WriteAuxiliaryFile", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppExTarget.build/AppExTarget-DebugEntryPoint-normal-\(results.runDestinationTargetArchitecture).txt"])) { _ in
                    let entryPoint = try results.fs.read(Path("\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppExTarget.build/AppExTarget-DebugEntryPoint-normal-\(results.runDestinationTargetArchitecture).txt"))
                    #expect(entryPoint == ByteString(encodingAsUTF8: "_NSExtensionMain"))
                }

                results.consumeTasksMatchingRuleTypes(["Copy", "CopySwiftLibs", "ExtractAppIntentsMetadata", "Gate", "GenerateDSYMFile", "MkDir", "CreateBuildDirectory", "WriteAuxiliaryFile", "ClangStatCache", "RegisterExecutionPolicyException", "AppIntentsSSUTraining", "ProcessInfoPlistFile", "Touch", "Validate", "LinkAssetCatalogSignature", "ConstructStubExecutorLinkFileList", "ProcessSDKImports"])
                results.consumeTasksMatchingRuleTypes(["GenerateDSYMFile"])
                results.consumeTasksMatchingRuleTypes(["SwiftCompile", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftEmitModule", "SwiftMergeGeneratedHeaders", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm"])

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/AppExTarget.appex/AppExTarget", "normal"])) { task in
                    task.checkCommandLine(
                        [
                            "\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
                            "-Xlinker", "-reproducible",
                            "-target", "\(results.runDestinationTargetArchitecture)-apple-ios\(core.loadSDK(.iOSSimulator).defaultDeploymentTarget)-simulator",
                            "-isysroot", core.loadSDK(.iOSSimulator).path.str,
                            "-Os",
                            "-L\(srcRoot.str)/build/Debug-iphonesimulator",
                            "-F\(srcRoot.str)/build/Debug-iphonesimulator",
                            "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                            "-rdynamic",
                            "-Xlinker", "-objc_abi_version", "-Xlinker", "2",
                            "-e", "___debug_blank_executor_main",
                            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__debug_dylib", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppExTarget.build/AppExTarget-DebugDylibPath-normal-\(results.runDestinationTargetArchitecture).txt",
                            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__debug_entry", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppExTarget.build/AppExTarget-DebugEntryPoint-normal-\(results.runDestinationTargetArchitecture).txt",
                            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__debug_instlnm", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppExTarget.build/AppExTarget-DebugDylibInstallName-normal-\(results.runDestinationTargetArchitecture).txt",
                            "-Xlinker", "-filelist", "-Xlinker", "\(srcRoot.str)/build/ProjectName.build/Debug-iphonesimulator/AppExTarget.build/AppExTarget-ExecutorLinkFileList-normal-x86_64.txt",
                            "\(srcRoot.str)/build/Debug-iphonesimulator/AppExTarget.appex/AppExTarget.debug.dylib",
                            "-o", "\(srcRoot.str)/build/Debug-iphonesimulator/AppExTarget.appex/AppExTarget"
                        ]
                    )
                }

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/AppExTarget.appex/AppExTarget.debug.dylib", "normal"])) { _ in }

                results.checkTask(.matchRule(["Ld", "\(srcRoot.str)/build/Debug-iphonesimulator/AppExTarget.appex/__preview.dylib", "normal"])) { _ in }

                results.checkNoTask()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func previewThunkBuilds() async throws {
        let archs = ["arm64", "arm64e"]

        for explicitModules in [false, true] {
            try await withTemporaryDirectory { (tmpDirPath: Path) in
                let srcRoot = tmpDirPath.join("srcroot")

                let testProject = try await TestProject(
                    "ProjectName",
                    guid: "ProjectNameGUID",
                    sourceRoot: srcRoot,
                    groupTree: TestGroup(
                        "Sources", path: "Sources",
                        children: [
                            TestFile("main.swift"),
                            TestFile("FrameworkTarget.h"),
                            TestFile("BridgingHeader.h"),
                            TestFile("ObjC.h"),
                            TestFile("ObjC.m"),
                            TestFile("Info.plist"),
                            TestFile("Entitlements.plist"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "iphoneos",
                            "MACOSX_DEPLOYMENT_TARGET": "13.0",
                            "ARCHS": archs.joined(separator: " "),
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGN_IDENTITY": "",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "INFOPLIST_FILE": "Sources/Info.plist",
                            "SWIFT_VERSION": swiftVersion,
                            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                            "ENABLE_PREVIEWS": "YES",
                            "CLANG_ENABLE_MODULES": "YES",
                            "SDK_STAT_CACHE_ENABLE": "NO",

                            "SWIFT_ENABLE_EXPLICIT_MODULES": explicitModules ? "YES" : "NO",

                            "SUPPORTS_TEXT_BASED_API": "YES",
                            "DYLIB_INSTALL_NAME_BASE": "@rpath",
                        ]),
                    ],
                    targets: [
                        TestAggregateTarget(
                            "Umbrella",
                            buildConfigurations: [
                                TestBuildConfiguration("Debug"),
                            ],
                            dependencies: [
                                "AppTargetBundleLoader",
                                "AppTargetPreviewDylib",
                                "FrameworkTarget",
                                "StaticTarget",
                            ]
                        ),

                        // App-hosted mode
                        TestStandardTarget(
                            "AppTargetBundleLoader",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "SWIFT_OBJC_BRIDGING_HEADER": "Sources/BridgingHeader.h",
                                ]),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase([
                                    TestBuildFile("main.swift"),
                                    TestBuildFile("ObjC.m"),
                                ]),
                            ]),

                        // Standard framework
                        TestStandardTarget(
                            "FrameworkTarget",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings:[
                                    "DEFINES_MODULE": "YES",
                                ]),
                            ],
                            buildPhases: [
                                TestHeadersBuildPhase([
                                    TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                                    TestBuildFile("ObjC.h", headerVisibility: .public),
                                ]),
                                TestSourcesBuildPhase([
                                    TestBuildFile("main.swift"),
                                    TestBuildFile("ObjC.m"),
                                ]),
                            ]),

                        // Should not be able to generate previews
                        TestStandardTarget(
                            "StaticTarget",
                            type: .staticLibrary,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug", buildSettings: [
                                    "SWIFT_OBJC_BRIDGING_HEADER": "Sources/BridgingHeader.h",
                                ]),
                            ],
                            buildPhases: [
                                TestHeadersBuildPhase([
                                    TestBuildFile("ObjC.h", headerVisibility: .public),
                                ]),
                                TestSourcesBuildPhase([
                                    TestBuildFile("main.swift"),
                                    TestBuildFile("ObjC.m"),
                                ]),
                            ]),
                    ])
                let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)

                try await tester.fs.writePlist(srcRoot.join("Sources/Info.plist"), .plDict([:]))

                try await tester.fs.writeFileContents(srcRoot.join("Sources/main.swift")) { stream in
                    stream <<< """
                        private class C {
                        private func f0() {}
                        private func f1() { ObjCFunc() }
                        }
                        """
                }

                try await tester.fs.writeFileContents(srcRoot.join("Sources/ObjC.h")) { stream in
                    stream <<< """
                        extern void ObjCFunc();
                        """
                }

                try await tester.fs.writeFileContents(srcRoot.join("Sources/ObjC.m")) { stream in
                    stream <<< """
                        #import "ObjC.h"
                        void ObjCFunc() {}
                        """
                }

                try await tester.fs.writeFileContents(srcRoot.join("Sources/FrameworkTarget.h")) { stream in
                    stream <<< """
                        #import <FrameworkTarget/ObjC.h>
                        """
                }

                try await tester.fs.writeFileContents(srcRoot.join("Sources/BridgingHeader.h")) { stream in
                    stream <<< """
                        #import "ObjC.h"
                        """
                }

                let previewInfoInput = TaskGeneratePreviewInfoInput.thunkInfo(sourceFile: srcRoot.join("Sources/main.swift"), thunkVariantSuffix: "selection")

                try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .anyiOSDevice) { results in
                    results.checkNoDiagnostics()
                    let buildDescription = results.buildDescription
                    let targets = buildDescription.allConfiguredTargets.sorted { $0.target.name < $1.target.name }

                    for target in targets {
                        let previewInfos = buildDescription.generatePreviewInfoForTesting(for: [target], workspaceContext: tester.workspaceContext, buildRequestContext: results.buildRequestContext, input: previewInfoInput)

                        if target.target.name == "StaticTarget" {
                            #expect(previewInfos.count == 0)
                            continue
                        }

                        #expect(previewInfos.count == archs.count)
                        for arch in archs {
                            guard let previewInfo = (previewInfos.filter { $0.context.architecture == arch }.only) else {
                                Issue.record("Could not find only one preview info for \(arch) in \(previewInfos)")
                                continue
                            }

                            try await tester.fs.writeFileContents(#require(previewInfo.thunkInfo?.thunkSourceFile)) { stream in
                                stream <<< """
                                    @_private(sourceFile: "main.swift") import \(target.target.name)

                                    private extension C {
                                        @_dynamicReplacement(for: f1())
                                        private func __preview__f1() { f0(); ObjCFunc(); }
                                    }
                                    """
                            }

                            let linkStyle: LinkStyle
                            let linkAgainst: Path
                            let expectUnextendedModuleOverlay: Bool

                            switch target.target.name {
                            case "AppTargetBundleLoader":
                                linkStyle = .bundleLoader
                                linkAgainst = Path("\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/AppTargetBundleLoader.build/Objects-normal/\(arch)/Binary/AppTargetBundleLoader")
                                expectUnextendedModuleOverlay = false

                            case "FrameworkTarget":
                                linkStyle = .dylib
                                linkAgainst = Path("\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/FrameworkTarget.build/Objects-normal/\(arch)/Binary/FrameworkTarget")
                                expectUnextendedModuleOverlay = true

                            default: fatalError()
                            }

                            try await _checkPreviewCommands(previewInfo, srcRoot: srcRoot, target: target, arch: arch, linkStyle: linkStyle, linkAgainst: linkAgainst, expectUnextendedModuleOverlay: expectUnextendedModuleOverlay, explicitModuleBuild: explicitModules)
                            try await _execPreviewBuild(previewInfo)
                        }
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func previewThunkBuildsForPackages() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let srcRoot = tmpDirPath.join("srcroot")

            let testProject = try await TestPackageProject("aPackage", sourceRoot: srcRoot,
                                                           groupTree: TestGroup(
                                                            "Sources", path: "Sources",
                                                            children: [
                                                                TestFile("main.swift"),
                                                            ]),
                                                           buildConfigurations: [
                                                            TestBuildConfiguration("Debug", buildSettings: [
                                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                            ])
                                                           ],
                                                           targets: [
                                                            TestPackageProductTarget(
                                                                "PackageLibProduct",
                                                                frameworksBuildPhase: TestFrameworksBuildPhase([
                                                                    TestBuildFile(.target("PackageLib"))]),
                                                                buildConfigurations: [
                                                                    // Targets need to opt-in to specialization.
                                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                                        "SDKROOT": "auto",
                                                                        "SDK_VARIANT": "auto",
                                                                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                                        "SWIFT_VERSION": swiftVersion,
                                                                        "ENABLE_PREVIEWS": "YES",
                                                                        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                                                    ]),
                                                                ],
                                                                dependencies: ["PackageLib"]
                                                            ),
                                                            TestStandardTarget("PackageLib", type: .objectFile,
                                                                               buildConfigurations: [
                                                                                // Targets need to opt-in to specialization.
                                                                                TestBuildConfiguration("Debug", buildSettings: [
                                                                                    "SDKROOT": "auto",
                                                                                    "SDK_VARIANT": "auto",
                                                                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                                                    "SWIFT_VERSION": swiftVersion,
                                                                                    "ENABLE_PREVIEWS": "YES",
                                                                                    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                                                                                ]),
                                                                               ],
                                                                               buildPhases: [TestSourcesBuildPhase([TestBuildFile("main.swift")])]),
                                                           ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)

            try await tester.fs.writeFileContents(srcRoot.join("Sources/main.swift")) { stream in
                stream <<< """
                    private class C {
                    private func f0() {}
                    }
                    """
            }

            let previewInfoInput = TaskGeneratePreviewInfoInput.thunkInfo(sourceFile: srcRoot.join("Sources/main.swift"), thunkVariantSuffix: "selection")

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS) { results in
                results.checkNoDiagnostics()

                let buildDescription = results.buildDescription
                let targets = buildDescription.allConfiguredTargets.sorted { $0.target.name < $1.target.name }

                for target in targets {
                    let previewInfos = buildDescription.generatePreviewInfoForTesting(for: [target], workspaceContext: tester.workspaceContext, buildRequestContext: results.buildRequestContext, input: previewInfoInput)
                    let linkCommandLines = previewInfos.compactMap { $0.thunkInfo }.map { $0.linkCommandLine }.filter { !$0.isEmpty }

                    #expect(!linkCommandLines.isEmpty, "did not get any preview info")
                    for commandLine in linkCommandLines {
                        #expect(!commandLine.contains("-nostdlib"), "-nostdlib should not be passed to the linker")
                    }
                }
            }
        }
    }

    private enum LinkStyle {
        case dylib
        case bundleLoader
    }

    private func _checkPreviewCommands(_ previewInfo: PreviewInfoOutput, srcRoot: Path, target: ConfiguredTarget, arch: String, linkStyle: LinkStyle, linkAgainst: Path, expectUnextendedModuleOverlay: Bool, explicitModuleBuild: Bool) async throws {
        let core = try await getCore()
        let sdkPath = core.sdkRegistry.lookup("iphoneos")!.path
        let targetName = target.target.name

        let installAPIArgs = targetName == "FrameworkTarget" ? [
            "-emit-tbd",
            "-emit-tbd-path", "\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/Objects-normal/\(arch)/Swift-API.tbd",
            "-Xfrontend", "-tbd-install_name", "-Xfrontend", "@rpath/FrameworkTarget.framework/FrameworkTarget"
        ] : []

        let moduleOverlayArgs = expectUnextendedModuleOverlay ? [
            "-Xcc",
            "-ivfsoverlay",
            "-Xcc",
            "\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/unextended-module-overlay.yaml",
            ] : []

        // Ignore irrelevant paths which change often
        var compileCommandLine = previewInfo.thunkInfo?.compileCommandLine ?? []
        if let range = compileCommandLine.firstRange(of: ["-Xfrontend", "-prebuilt-module-cache-path"]) {
            for _ in 0..<4 {
                compileCommandLine.remove(at: range.lowerBound)
            }
        }

        XCTAssertEqualSequences(compileCommandLine, [[
            "\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
            "-enforce-exclusivity=checked",
            "-enable-experimental-feature", "DebugDescriptionMacro",
            "-sdk", sdkPath.str,
            "-target", "\(arch)-apple-ios\(core.loadSDK(.iOS).defaultDeploymentTarget)",
            "-Xfrontend", "-serialize-debugging-options",
            "-swift-version", try await swiftVersion,
            "-I", "\(srcRoot.str)/build/Debug-iphoneos",
            "-F", "\(srcRoot.str)/build/Debug-iphoneos",
            ], installAPIArgs, [
            "-c",
            "-j\(ProcessInfo.processInfo.activeProcessorCount)",
            "-no-color-diagnostics",
            "-serialize-diagnostics",
            "-Xcc", "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/swift-overrides.hmap",
            "-Xcc", "-iquote", "-Xcc", "\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/\(targetName)-generated-files.hmap",
            "-Xcc", "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/\(targetName)-own-target-headers.hmap",
            "-Xcc", "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/\(targetName)-all-non-framework-target-headers.hmap",
            "-Xcc", "-ivfsoverlay", "-Xcc", "\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/ProjectName-ProjectNameGUID-VFS-iphoneos/all-product-headers.yaml",
            "-Xcc", "-iquote", "-Xcc", "\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/\(targetName)-project-headers.hmap",
            "-Xcc", "-I\(srcRoot.str)/build/Debug-iphoneos/include",
            "-Xcc", "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/DerivedSources-normal/\(arch)",
            "-Xcc", "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/DerivedSources/\(arch)",
            "-Xcc", "-I\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/DerivedSources",
            ], moduleOverlayArgs, [
            "-working-directory", "\(srcRoot.str)",
            "-experimental-emit-module-separately",
            "-disable-cmo",
            "-disable-bridging-pch",
            "\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/Objects-normal/\(arch)/main.selection.preview-thunk.swift",
            "-o", "\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/Objects-normal/\(arch)/main.selection.preview-thunk.o",
            "-module-name", "\(targetName)_PreviewReplacement_main_selection",
            "-parse-as-library",
            "-Onone",
            "-Xfrontend", "-disable-modules-validate-system-headers",
        ]].reduce([], +))

        let linkStyleArgs: [String]
        switch linkStyle {
        case .dylib:
            linkStyleArgs = ["-dynamiclib", linkAgainst.str]

        case .bundleLoader:
            linkStyleArgs = ["-bundle", "-bundle_loader", linkAgainst.str]
        }

        var linkerCommandLine = previewInfo.thunkInfo?.linkCommandLine ?? []
        for idx in linkerCommandLine.indices.reversed() {
            if linkerCommandLine[idx].hasSuffix("linker-args.resp") {
                linkerCommandLine.remove(at: idx)
            }
        }

        XCTAssertEqualSequences(linkerCommandLine, [[
            "\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            "-Xlinker", "-reproducible",
            "-target", "\(arch)-apple-ios\(core.loadSDK(.iOS).defaultDeploymentTarget)",
            "-isysroot", sdkPath.str,
            "-Os",
            "-L\(srcRoot.str)/build/EagerLinkingTBDs/Debug-iphoneos",
            "-L\(srcRoot.str)/build/Debug-iphoneos",
            "-F\(srcRoot.str)/build/EagerLinkingTBDs/Debug-iphoneos",
            "-F\(srcRoot.str)/build/Debug-iphoneos",
            "-fobjc-link-runtime",
            "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/iphoneos",
            "-L/usr/lib/swift",
        ], linkStyleArgs, [
                "\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/Objects-normal/\(arch)/main.selection.preview-thunk.o",
                "-o", "\(srcRoot.str)/build/ProjectName.build/Debug-iphoneos/\(targetName).build/Objects-normal/\(arch)/main.selection.preview-thunk.dylib",
            ]].reduce([], +))
    }

    /// Check that actually executing the command-lines we produced for previews will work for the scenarios we enumerated
    private func _execPreviewBuild(_ previewInfo: PreviewInfoOutput) async throws {
        let thunkInfo = try #require(previewInfo.thunkInfo)

        do {
            try await runProcess(thunkInfo.compileCommandLine)
        } catch {
            Issue.record("Failed to compile thunk: \(error)")
        }

        do {
            try await runProcess(thunkInfo.linkCommandLine)
        } catch {
            Issue.record("Failed to link thunk: \(error)")
        }

        #expect(localFS.exists(thunkInfo.thunkLibrary))
    }
}
