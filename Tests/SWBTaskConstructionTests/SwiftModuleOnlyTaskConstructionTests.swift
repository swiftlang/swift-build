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

import SWBCore
import SWBProtocol
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct SwiftModuleOnlyTaskConstructionTests: CoreBasedTests {
    // MARK: - Test cases.

    @Test(.requireSDKs(.macOS, .iOS))
    func swiftModuleOnlyArchsDynamicLibraryDebugBuild() async throws {
        try await checkSwiftModuleOnlyArchsAllPlatforms(
            targetType: .dynamicLibrary,
            buildConfiguration: "Debug")
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func swiftModuleOnlyArchsDynamicLibraryReleaseBuild() async throws {
        try await checkSwiftModuleOnlyArchsAllPlatforms(
            targetType: .dynamicLibrary,
            buildConfiguration: "Release")
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func swiftModuleOnlyArchsStaticLibraryDebugBuild() async throws {
        try await checkSwiftModuleOnlyArchsAllPlatforms(
            targetType: .staticLibrary,
            buildConfiguration: "Debug")
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func swiftModuleOnlyArchsStaticLibraryReleaseBuild() async throws {
        try await checkSwiftModuleOnlyArchsAllPlatforms(
            targetType: .staticLibrary,
            buildConfiguration: "Release")
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func swiftModuleOnlyArchsFrameworkDebugBuild() async throws {
        try await checkSwiftModuleOnlyArchsAllPlatforms(
            targetType: .framework,
            buildConfiguration: "Debug")
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func swiftModuleOnlyArchsFrameworkReleaseBuild() async throws {
        try await checkSwiftModuleOnlyArchsAllPlatforms(
            targetType: .framework,
            buildConfiguration: "Release")
    }

    /// Check swiftmodule content when overloading arch-specific deployment targets
    @Test(.requireSDKs(.macOS, .iOS))
    func overloadedArchDeploymentTarget() async throws {
        let targetType: TestStandardTarget.TargetType = .dynamicLibrary
        let buildConfiguration = "Release"

        // macOS
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macOS,
                deploymentTarget: "10.15",
                archs: ["x86_64", "x86_64h"],
                moduleOnlyDeploymentTarget: "10.13",
                moduleOnlyArchs: ["i386"],
                archDeploymentTargets: [
                    "i386": "10.14.4",
                ]))

        // macOS (Zippered)
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macOS,
                isZippered: true,
                deploymentTarget: "10.15",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.13",
                moduleOnlyArchs: ["x86_64h"],
                archDeploymentTargets: [
                    "x86_64h": "10.14.4",
                ],
                zipperedDeploymentTarget: "13.0",
                zipperedModuleOnlyDeploymentTarget: "10.0",
                zipperedArchDeploymentTargets: [
                    "x86_64": "10.3",
                ]))

        // Mac Catalyst
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macCatalyst,
                deploymentTarget: "13.0",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.0",
                moduleOnlyArchs: ["x86_64h"],
                archDeploymentTargets: [
                    "x86_64h": "10.3"
                ]))

        // Mac Catalyst (Zippered)
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macCatalyst,
                isZippered: true,
                deploymentTarget: "13.0",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.0",
                moduleOnlyArchs: ["x86_64h"],
                archDeploymentTargets: [
                    "i386": "10.3"
                ],
                zipperedDeploymentTarget: "10.15",
                zipperedModuleOnlyDeploymentTarget: "10.13",
                zipperedArchDeploymentTargets: [
                    "x86_64": "10.14.4",
                ]))

        // iOS
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.iOS,
                deploymentTarget: "13.0",
                archs: ["arm64", "arm64e"],
                moduleOnlyDeploymentTarget: "10.3",
                moduleOnlyArchs: ["armv7", "armv7s"],
                archDeploymentTargets: [
                    "armv7": "10.1",
                    "armv7s": "10.2",
                ]))

        // iOS Simulator
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.iOSSimulator,
                deploymentTarget: "13.0",
                archs: ["arm64"],
                moduleOnlyDeploymentTarget: "10.0",
                moduleOnlyArchs: ["x86_64"],
                archDeploymentTargets: [
                    "x86_64": "10.3",
                ]))
    }

    /// Check no Swift module-only tasks are generated for 32-bit architectures
    @Test(.requireSDKs(.macOS, .iOS))
    func test32BitMacCatalystPrimaryVariantNoop() async throws {
        let targetType: TestStandardTarget.TargetType = .dynamicLibrary
        let buildConfiguration = "Release"

        // macOS
        try await checkSwiftModuleOnly32bitTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macOS,
                deploymentTarget: "10.15",
                archs: ["x86_64", "x86_64h"],
                moduleOnlyDeploymentTarget: "10.13",
                moduleOnlyArchs: ["i386"]))

        // macOS (Zippered)
        try await checkSwiftModuleOnly32bitTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macOS,
                isZippered: true,
                deploymentTarget: "10.15",
                archs: ["x86_64", "x86_64h"],
                moduleOnlyDeploymentTarget: "10.13",
                moduleOnlyArchs: ["i386"],
                zipperedDeploymentTarget: "13.0",
                zipperedModuleOnlyDeploymentTarget: "10.3"))

        // Mac Catalyst
        try await checkSwiftModuleOnly32bitTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macCatalyst,
                deploymentTarget: "13.0",
                archs: ["x86_64", "x86_64h"],
                moduleOnlyDeploymentTarget: "10.3",
                moduleOnlyArchs: ["i386"]))

        // Mac Catalyst (Zippered)
        try await checkSwiftModuleOnly32bitTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macCatalyst,
                isZippered: true,
                deploymentTarget: "13.0",
                archs: ["x86_64", "x86_64h"],
                moduleOnlyDeploymentTarget: "10.3",
                moduleOnlyArchs: ["i386"],
                zipperedDeploymentTarget: "10.15",
                zipperedModuleOnlyDeploymentTarget: "10.13"))
    }

    /// Check no 'RuleScriptExecution' tasks are generated
    @Test(.requireSDKs(.macOS, .iOS))
    func noSwiftModuleOnlyRuleScriptExecutionTasksGenerated() async throws {
        let targetType: TestStandardTarget.TargetType = .dynamicLibrary
        let buildConfiguration = "Release"
        let inputFiles = [
            "File1.swift",
            "File2.swift",

            "File1.fake-lang",
        ]

        let buildDir = Path("$(DERIVED_FILES_DIR)-$(CURRENT_VARIANT)")
            .join("$(CURRENT_ARCH)")
            .join("$(INPUT_FILE_REGION_PATH_COMPONENT)")

        let customBuildRule = TestBuildRule(
            filePattern: "*/*.fake-lang",
            script: "fake-langc",
            inputs: [],
            outputs: [
                buildDir.join("$(INPUT_FILE_REGION_PATH_COMPONENT)-$(INPUT_FILE_BASE).o").str,
            ],
            runOncePerArchitecture: true)

        // macOS
        try await checkNoSwiftModuleOnlyRuleScriptExecutionTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macOS,
                deploymentTarget: "10.15",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.13",
                moduleOnlyArchs: ["x86_64h"],
                inputFiles: inputFiles,
                buildRules: [customBuildRule]))

        // macOS (Zippered)
        try await checkNoSwiftModuleOnlyRuleScriptExecutionTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macOS,
                isZippered: true,
                deploymentTarget: "10.15",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.13",
                moduleOnlyArchs: ["x86_64h"],
                zipperedDeploymentTarget: "13.0",
                zipperedModuleOnlyDeploymentTarget: "10.0",
                inputFiles: inputFiles,
                buildRules: [customBuildRule]))

        // Mac Catalyst
        try await checkNoSwiftModuleOnlyRuleScriptExecutionTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macCatalyst,
                deploymentTarget: "13.0",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.0",
                moduleOnlyArchs: ["x86_64h"],
                inputFiles: inputFiles,
                buildRules: [customBuildRule]))

        // Mac Catalyst (Zippered)
        try await checkNoSwiftModuleOnlyRuleScriptExecutionTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macCatalyst,
                isZippered: true,
                deploymentTarget: "13.0",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.0",
                moduleOnlyArchs: ["x86_64h"],
                zipperedDeploymentTarget: "10.15",
                zipperedModuleOnlyDeploymentTarget: "10.13",
                inputFiles: inputFiles,
                buildRules: [customBuildRule]))

        // iOS
        try await checkNoSwiftModuleOnlyRuleScriptExecutionTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.iOS,
                deploymentTarget: "13.0",
                archs: ["arm64", "arm64e"],
                moduleOnlyDeploymentTarget: "10.3",
                moduleOnlyArchs: ["armv7", "armv7s"],
                inputFiles: inputFiles,
                buildRules: [customBuildRule]))

        // iOS Simulator
        try await checkNoSwiftModuleOnlyRuleScriptExecutionTasks(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.iOSSimulator,
                deploymentTarget: "13.0",
                archs: ["arm64"],
                moduleOnlyDeploymentTarget: "10.0",
                moduleOnlyArchs: ["x86_64"],
                inputFiles: inputFiles,
                buildRules: [customBuildRule]))
    }

    // MARK: - Private test constants.

    private let forbiddenModuleOnlyRuleTypes = [
        "CompileSwift",
        "CompileSwiftSources",
        "Ld",
        "CreateUniversalBinary"
    ]

    // MARK: Private structs and helper methods.

    private struct TestProjectConfig {
        var projectName: String = "MyProject"
        var targetName: String = "MyTarget"
        var targetType: TestStandardTarget.TargetType
        var buildConfiguration: String
        var platform: BuildVersion.Platform
        var isZippered: Bool = false
        var deploymentTarget: String
        var archs: [String]
        var moduleOnlyDeploymentTarget: String?
        var moduleOnlyArchs: [String]
        var archDeploymentTargets: [String:String] = [:]

        var zipperedDeploymentTarget: String? = nil
        var zipperedModuleOnlyDeploymentTarget: String? = nil
        var zipperedArchDeploymentTargets: [String:String] = [:]

        var inputFiles: [String] = ["File1.swift", "File2.swift"]
        var buildRules: [TestBuildRule] = []

        var activeRunDestination: RunDestinationInfo? {
            switch platform {
            case .macOS:
                return .anyMac
            case .macCatalyst:
                return .anyMacCatalyst
            case .iOS:
                return .anyiOSDevice
            case .iOSSimulator:
                return .anyiOSSimulator
            default:
                return nil
            }
        }

        var buildConfigurationDirName: String {
            switch platform {
            case .macOS:
                return buildConfiguration
            case .macCatalyst:
                return "\(buildConfiguration)\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)"
            default:
                return "\(buildConfiguration)-\(platform.sdkName)"
            }
        }

        var sdkRoot: String {
            platform.sdkName
        }

        var secondaryPlatform: BuildVersion.Platform {
            switch platform {
            case .macOS:
                return .macCatalyst
            case .macCatalyst:
                return .macOS
            default:
                return platform
            }
        }
    }

    private func buildTestProject(testProjectConfig tpc: TestProjectConfig,
                                  overrides: [String:String] = [:]) async throws -> TestProject {
        let infoLookup = try await getCore()

        var buildSettings = try await [
            "CODE_SIGNING_ALLOWED": "NO",

            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SDKROOT": tpc.sdkRoot,

            "SUPPORTS_MACCATALYST": String(tpc.platform == .macCatalyst),
            "IS_ZIPPERED": String(tpc.isZippered),

            "SWIFT_EXEC": swiftCompilerPath.str,
            "SWIFT_VERSION": swiftVersion,
            "TAPI_EXEC": tapiToolPath.str,
            "LIBTOOL": libtoolPath.str,

            "ARCHS": tpc.archs.joined(separator: " "),
            "VALID_ARCHS[sdk=macosx*]": "$(inherited) x86_64h",
            tpc.platform.deploymentTargetSettingName(infoLookup: infoLookup): tpc.deploymentTarget,

            "SWIFT_EMIT_MODULE_INTERFACE": String(true),
            "SWIFT_MODULE_ONLY_ARCHS": tpc.moduleOnlyArchs.joined(separator: " "),
        ]

        if let moduleOnlyDeploymentTarget = tpc.moduleOnlyDeploymentTarget {
            buildSettings["SWIFT_MODULE_ONLY_\(tpc.platform.deploymentTargetSettingName(infoLookup: infoLookup))"] = moduleOnlyDeploymentTarget
        }

        if tpc.isZippered {
            let settingName = tpc.secondaryPlatform.deploymentTargetSettingName(infoLookup: infoLookup)
            buildSettings[settingName] = tpc.zipperedDeploymentTarget
            buildSettings["SWIFT_MODULE_ONLY_\(settingName)"] = tpc.zipperedModuleOnlyDeploymentTarget
        }

        for (arch, value) in tpc.archDeploymentTargets {
            let settingName = tpc.platform.deploymentTargetSettingName(infoLookup: infoLookup)
            buildSettings["SWIFT_MODULE_ONLY_\(settingName)[arch=\(arch)]"] = value
        }

        for (arch, value) in tpc.zipperedArchDeploymentTargets {
            let settingName = tpc.secondaryPlatform.deploymentTargetSettingName(infoLookup: infoLookup)
            buildSettings["SWIFT_MODULE_ONLY_\(settingName)[arch=\(arch)]"] = value
        }

        return TestProject(
            tpc.projectName,
            groupTree: TestGroup(
                "SomeFiles",
                path: "Sources",
                children: tpc.inputFiles.map { TestFile($0) }),
            buildConfigurations: [
                TestBuildConfiguration(
                    tpc.buildConfiguration,
                    buildSettings: buildSettings.addingContents(of: overrides)),
            ],
            targets: [
                TestStandardTarget(
                    tpc.targetName,
                    type: tpc.targetType,
                    buildConfigurations: [
                        TestBuildConfiguration(tpc.buildConfiguration),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(tpc.inputFiles.map { TestBuildFile($0) }),
                    ],
                    buildRules: tpc.buildRules),
            ])
    }

    private struct TestContext {
        var testProjectConfig: TestProjectConfig

        var results: TaskConstructionTester.PlanningResults
        var target: ConfiguredTarget
        var platform: BuildVersion.Platform
        var arch: String
        var sourceRoot: Path
        var isZippered: Bool = false

        var buildDir: Path {
            sourceRoot.join("build")
        }

        var archBuildDir: Path {
            buildDir
                .join("\(testProjectConfig.projectName).build")
                .join(testProjectConfig.buildConfigurationDirName)
                .join("\(testProjectConfig.targetName).build")
                .join("Objects-normal")
                .join(arch)
        }

        var frameworkModuleSubdir: Path {
            switch platform {
            case .macOS, .macCatalyst:
                return Path("Versions/A/Modules")
            default:
                return Path("Modules")
            }
        }

        var deploymentTarget: String? {
            if isZippered {
                return zipperedDeploymentTarget
            }

            if testProjectConfig.archs.contains(arch) {
                return testProjectConfig.archDeploymentTargets[arch]
                ?? testProjectConfig.deploymentTarget
            }

            if testProjectConfig.moduleOnlyArchs.contains(arch) {
                return testProjectConfig.archDeploymentTargets[arch]
                ?? testProjectConfig.moduleOnlyDeploymentTarget
            }

            return nil
        }

        var zipperedDeploymentTarget: String? {
            if testProjectConfig.archs.contains(arch) {
                return testProjectConfig.zipperedArchDeploymentTargets[arch]
                ?? testProjectConfig.zipperedDeploymentTarget
            }

            if testProjectConfig.moduleOnlyArchs.contains(arch) {
                return testProjectConfig.zipperedArchDeploymentTargets[arch]
                ?? testProjectConfig.zipperedModuleOnlyDeploymentTarget
            }

            return nil
        }

        func getSwiftmoduleBuildDir() -> Path? {
            switch testProjectConfig.targetType {
            case .dynamicLibrary, .staticLibrary:
                return sourceRoot
                    .join("build")
                    .join(testProjectConfig.buildConfigurationDirName)
                    .join("\(testProjectConfig.targetName).swiftmodule")
            case .framework:
                return sourceRoot
                    .join("build")
                    .join(testProjectConfig.buildConfigurationDirName)
                    .join("\(testProjectConfig.targetName).framework")
                    .join(frameworkModuleSubdir)
                    .join("\(testProjectConfig.targetName).swiftmodule")
            default:
                return nil
            }
        }
    }

    private func filenameSuffix(for platform: BuildVersion.Platform, infoLookup: any PlatformInfoLookup) -> String {
        let envSuffix = platform.environment(infoLookup: infoLookup).map { "-\($0)" } ?? ""
        return "-\(platform.name(infoLookup: infoLookup))\(envSuffix)"
    }

    // MARK: Test components.

    private func checkGenerateSwiftModuleTasks(_ context: TestContext) async throws {
        let tpc = context.testProjectConfig
        let infoLookup = try await getCore()

        let archBuildDir = context.archBuildDir
        let platformSuffix = filenameSuffix(for: context.platform, infoLookup: infoLookup)
        let targetTriple = context.platform.targetTripleString(
            arch: context.arch,
            deploymentTarget: try context.deploymentTarget.map { try Version($0) } ?? nil,
            infoLookup: infoLookup)
        let sdkPath = try await getSDKPath(platform: tpc.platform)

        let swiftCompilerPath = try await self.swiftCompilerPath

        // Check the Swift task to generate the Swift module and tasks to copy its outputs.
        context.results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"),
                                  .matchTarget(context.target),
                                  .matchRuleItem("\(context.arch)\(platformSuffix)")) { task in
                                      #expect(task.execDescription == "Unblock downstream dependents of \(context.target.target.name) (\(context.arch))")

                                      // Validate command line arguments
                                      do {
                                          // Check that expected options are passed to generate the module.
                                          task.checkCommandLineContains([
                                            swiftCompilerPath.str,
                                            "-module-name", tpc.targetName,
                                            "-sdk", sdkPath.str,
                                            "-target", targetTriple,

                                            // FIXME: We don't pass -index-store-path (for now) per rdar://48211996
                                            // "-index-store-path",
                                            //    context.sourceRoot.join("build").join("\(projectName).build").join("Index").str,

                                            "-output-file-map",
                                            archBuildDir.join("\(tpc.targetName)\(platformSuffix)-OutputFileMap.json").str,
                                            "-serialize-diagnostics",
                                            "-emit-dependencies",
                                            "-emit-module",
                                            "-emit-module-path",
                                            archBuildDir.join("\(tpc.targetName)\(platformSuffix).swiftmodule").str,
                                            "-emit-module-interface-path",
                                            archBuildDir.join("\(tpc.targetName)\(platformSuffix).swiftinterface").str,
                                            "-emit-private-module-interface-path",
                                            archBuildDir.join("\(tpc.targetName)\(platformSuffix).private.swiftinterface").str,
                                          ])

                                          // Check that options that should *not* be passed when generating the module are indeed absent.
                                          task.checkCommandLineDoesNotContain("-target-variant")
                                          task.checkCommandLineDoesNotContain("-c")
                                          if context.isZippered {
                                              task.checkCommandLineDoesNotContain("-emit-objc-header")
                                              task.checkCommandLineDoesNotContain("-emit-objc-header-path")
                                          } else {
                                              task.checkCommandLineContains(["-emit-objc-header"])
                                              task.checkCommandLineContains(["-emit-objc-header-path"])
                                          }
                                          task.checkCommandLineDoesNotContain("-whole-module-optimization")

                                          // Make sure we're not passing -index-store-path (for now) per rdar://48211996
                                          task.checkCommandLineDoesNotContain("-index-store-path")
                                      }

                                      // Check the dependency data.
                                      #expect(task.dependencyData == .makefileIgnoringSubsequentOutputs(archBuildDir.join("\(tpc.targetName)\(platformSuffix)-master-emit-module.d")))
                                  }
    }

    private func checkCopySwiftmoduleContentTasks(_ context: TestContext) async throws {
        let tpc = context.testProjectConfig

        guard let swiftmoduleBuildDir = context.getSwiftmoduleBuildDir() else {
            Issue.record("unable to determine swiftmodule build dir for target type: \(tpc.targetType)")
            return
        }

        let infoLookup = try await getCore()
        let platformSuffix = filenameSuffix(for: context.platform, infoLookup: infoLookup)
        let moduleTriple = context.platform.targetTripleString(arch: context.arch, deploymentTarget: nil, infoLookup: infoLookup)

        let swiftmoduleDestDir = context.sourceRoot
            .join("build")
            .join("\(tpc.projectName).build")
            .join(tpc.buildConfigurationDirName)
            .join("\(tpc.targetName).build")
            .join("Objects-normal")
            .join(context.arch)

        func checkCopyTask(fileExtension: String) {
            let outputFile = swiftmoduleBuildDir.join("\(moduleTriple)\(fileExtension)")
            let inputFile = swiftmoduleDestDir.join("\(tpc.targetName)\(platformSuffix)\(fileExtension)")
            let copyRule = ["Copy", outputFile.str, inputFile.str]

            // Check 'Copy' task exists to copy `inputFile.str` to `outputFile.str`
            context.results.checkTaskExists(.matchTarget(context.target), .matchRule(copyRule))
        }

        checkCopyTask(fileExtension: ".swiftmodule")
        checkCopyTask(fileExtension: ".swiftinterface")
        checkCopyTask(fileExtension: ".private.swiftinterface")
        checkCopyTask(fileExtension: ".swiftdoc")
    }

    private func checkOutputFileMap(_ context: TestContext) async throws {
        let tpc = context.testProjectConfig
        let infoLookup = try await getCore()

        let archBuildDir = context.archBuildDir
        let platformSuffix = filenameSuffix(for: context.platform, infoLookup: infoLookup)

        func checkGlobalDict(dict: [String:PropertyListItem]) throws {
            // Check the global dictionary.
            let globalDict = try #require(dict[""])

            XCTAssertEqualPropertyListItems(globalDict, .plDict([
                "swift-dependencies": .plString(archBuildDir.join("\(tpc.targetName)\(platformSuffix)-master.swiftdeps").str),
                "diagnostics": .plString(archBuildDir.join("\(tpc.targetName)\(platformSuffix)-master.dia").str),
                "emit-module-diagnostics": .plString(archBuildDir.join("\(tpc.targetName)\(platformSuffix)-master-emit-module.dia").str),
                "emit-module-dependencies": .plString(archBuildDir.join("\(tpc.targetName)\(platformSuffix)-master-emit-module.d").str),
                "pch": .plString(archBuildDir.join("\(tpc.targetName)\(platformSuffix)-master-Bridging-header.pch").str),
            ]))
        }

        func checkFileDict(file: String, dict: [String:PropertyListItem]) {
            let basename = Path(file).basenameWithoutSuffix
            let filePath = context.sourceRoot.join("Sources").join(file)

            guard let fileDict = dict[filePath.str]?.dictValue else {
                Issue.record("output file map does not contain a dictionary for '\(file)'")
                return
            }

            #expect(fileDict["object"] == nil)

            #expect(fileDict.count == 4)
            #expect(fileDict["diagnostics"]?.stringValue == archBuildDir.join("\(basename)\(platformSuffix).dia").str)
            #expect(fileDict["dependencies"]?.stringValue == archBuildDir.join("\(basename)\(platformSuffix).d").str)
            #expect(fileDict["swift-dependencies"]?.stringValue == archBuildDir.join("\(basename)\(platformSuffix).swiftdeps").str)
            #expect(fileDict["swiftmodule"]?.stringValue == archBuildDir.join("\(basename)\(platformSuffix)~partial.swiftmodule").str)
        }

        let wafMatchRule = [
            "WriteAuxiliaryFile",
            archBuildDir.join("\(tpc.targetName)\(platformSuffix)-OutputFileMap.json").str,
        ]

        // Check the contents of the output file map file for the module generation task.
        try context.results.checkWriteAuxiliaryFileTask(.matchTarget(context.target),
                                                        .matchRule(wafMatchRule)) { task, contents in
                                                            guard let plist = try? PropertyList.fromJSONData(contents) else {
                                                                Issue.record("could not convert output file map from JSON to plist")
                                                                return
                                                            }

                                                            guard let dict = plist.dictValue else {
                                                                Issue.record("output file map is not a dictionary")
                                                                return
                                                            }

                                                            #expect(dict.count == 3)

                                                            // Check global dict is valid
                                                            try checkGlobalDict(dict: dict)

                                                            // Check the dictionary for each Swift input file.
                                                            for file in tpc.inputFiles {
                                                                // Check output file map contains dictionary for <file>
                                                                checkFileDict(file: file, dict: dict)
                                                            }
                                                        }
    }

    private func checkSwiftModuleOnlyArchs(_ tpc: TestProjectConfig, overrides: [String:String] = [:]) async throws {
        let testProject = try await buildTestProject(testProjectConfig: tpc, overrides: overrides)
        let infoLookup = try await getCore()

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let sourceRoot = tester.workspace.projects[0].sourceRoot

        let buildParameters = BuildParameters(configuration: tpc.buildConfiguration)

        try await tester.checkBuild(buildParameters, runDestination: tpc.activeRunDestination) { results in
            do {
                // Match tasks we know we're not interested in.
                results.consumeTasksMatchingRuleTypes([
                    "CompileSwift",
                    "CompileSwiftSources",
                    "CreateBuildDirectory",
                    "Gate",
                    "GenerateDSYMFile",
                    "Ld",
                    "MkDir",
                    "RegisterExecutionPolicyException",
                    "SymLink",
                ])

                let missingModuleOnlyDeploymentTarget = tpc.moduleOnlyDeploymentTarget == nil
                let missingSecondaryModuleOnlyDeploymentTarget = tpc.zipperedModuleOnlyDeploymentTarget == nil && tpc.isZippered
                if !tpc.moduleOnlyArchs.isEmpty && (missingModuleOnlyDeploymentTarget || missingSecondaryModuleOnlyDeploymentTarget) {
                    // Check expected diagnostics emitted
                    do {
                        if missingModuleOnlyDeploymentTarget {
                            for _ in tpc.moduleOnlyArchs {
                                results.checkError(.equal("Using SWIFT_MODULE_ONLY_ARCHS but no module-only deployment target has been specified via SWIFT_MODULE_ONLY_\(tpc.platform.deploymentTargetSettingName(infoLookup: infoLookup)). (in target 'MyTarget' from project 'MyProject')"))
                            }
                        }

                        if missingSecondaryModuleOnlyDeploymentTarget {
                            for _ in tpc.moduleOnlyArchs {
                                results.checkError(.equal("Using SWIFT_MODULE_ONLY_ARCHS but no module-only deployment target has been specified via SWIFT_MODULE_ONLY_\(tpc.secondaryPlatform.deploymentTargetSettingName(infoLookup: infoLookup)). (in target 'MyTarget' from project 'MyProject')"))
                            }
                        }

                        results.checkWarning(.equal("SWIFT_MODULE_ONLY_ARCHS assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"))
                        results.checkWarning(.equal("SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"), failIfNotFound: false)
                        results.checkWarning(.equal("SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"), failIfNotFound: false)

                        results.checkNoDiagnostics()
                    }
                } else {
                    // Check no diagnostics emitted
                    results.checkWarning(.equal("SWIFT_MODULE_ONLY_ARCHS assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"))
                    results.checkWarning(.equal("SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"), failIfNotFound: false)
                    results.checkWarning(.equal("SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"), failIfNotFound: false)
                    results.checkNoDiagnostics()
                }

                try await results.checkTarget(tpc.targetName) { target in
                    for arch in tpc.moduleOnlyArchs {
                        // Check no unexpected tasks are generated for <arch>
                        for ruleType in forbiddenModuleOnlyRuleTypes {
                            results.checkNoTask(.matchTarget(target), .matchRuleItem(arch), .matchRuleType(ruleType))
                        }

                        func runChecks(_ context: TestContext) async throws {
                            // Check 'GenerateSwiftModule' tasks are valid for <arch>
                            try await checkGenerateSwiftModuleTasks(context)

                            // Check copy tasks are valid for <arch>
                            try await checkCopySwiftmoduleContentTasks(context)

                            // Check output file map is valid for <arch>
                            try await checkOutputFileMap(context)
                        }

                        try await runChecks(TestContext(
                            testProjectConfig: tpc,
                            results: results,
                            target: target,
                            platform: tpc.platform,
                            arch: arch,
                            sourceRoot: sourceRoot))

                        if tpc.isZippered {
                            // Check zippered tasks for <arch>
                            try await runChecks(TestContext(
                                testProjectConfig: tpc,
                                results: results,
                                target: target,
                                platform: tpc.secondaryPlatform,
                                arch: arch,
                                sourceRoot: sourceRoot,
                                isZippered: tpc.isZippered))
                        }
                    }
                }
            }
        }
    }

    private func checkSwiftModuleOnly32bitTasks(_ tpc: TestProjectConfig, overrides: [String:String] = [:]) async throws {
        let testProject = try await buildTestProject(testProjectConfig: tpc, overrides: overrides)
        let infoLookup = try await getCore()

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let buildParameters = BuildParameters(configuration: tpc.buildConfiguration)

        try await tester.checkBuild(buildParameters, runDestination: tpc.activeRunDestination) { results in
            // Match tasks we know we're not interested in.
            results.consumeTasksMatchingRuleTypes([
                "CompileSwift",
                "CompileSwiftSources",
                "CreateBuildDirectory",
                "Gate",
                "GenerateDSYMFile",
                "Ld",
                "MkDir",
                "RegisterExecutionPolicyException",
                "SymLink",
                "WriteAuxiliaryFile",
            ])

            // Check no diagnostics emitted
            results.checkWarning(.equal("SWIFT_MODULE_ONLY_ARCHS assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"))
            results.checkWarning(.equal("SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"), failIfNotFound: false)
            results.checkWarning(.equal("SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"), failIfNotFound: false)
            results.checkNoDiagnostics()

            try results.checkTarget(tpc.targetName) { target in
                for arch in tpc.moduleOnlyArchs {
                    func checkPlatform(_ platform: BuildVersion.Platform, deploymentTarget: String?) throws {
                        let platformSuffix = filenameSuffix(for: platform, infoLookup: infoLookup)
                        let moduleTriple = platform.targetTripleString(arch: arch, deploymentTarget: nil, infoLookup: infoLookup)

                        if platform == .macOS {
                            // Check 'SwiftDriver GenerateModule' tasks are generated for <arch>
                            results.checkTaskExists(
                                .matchTarget(target),
                                .matchRuleItem(arch + platformSuffix),
                                .matchRuleType("SwiftDriver Compilation Requirements"))

                            // Check 'Copy' tasks are generated for <arch>
                            results.checkTaskExists(
                                .matchTarget(target),
                                .matchRuleItemPattern(.suffix("\(moduleTriple).swiftmodule")),
                                .matchRuleType("Copy"))
                        }

                        else if platform == .macCatalyst {
                            // Check no 'GenerateSwiftModule' tasks are generated for <arch>
                            results.checkNoTask(
                                .matchTarget(target),
                                .matchRuleItem(arch + platformSuffix),
                                .matchRuleType("GenerateSwiftModule"))

                            // Check no 'Copy' tasks are generated for <arch>
                            results.checkNoTask(
                                .matchTarget(target),
                                .matchRuleItemPattern(.suffix("\(moduleTriple).swiftmodule")),
                                .matchRuleType("Copy"))
                        }
                    }

                    try checkPlatform(tpc.platform, deploymentTarget: tpc.moduleOnlyDeploymentTarget)

                    if tpc.isZippered {
                        try checkPlatform(
                            tpc.secondaryPlatform,
                            deploymentTarget: tpc.zipperedModuleOnlyDeploymentTarget)
                    }
                }
            }
        }
    }

    private func checkNoSwiftModuleOnlyRuleScriptExecutionTasks(_ tpc: TestProjectConfig) async throws {
        #expect(!tpc.moduleOnlyArchs.isEmpty)

        let testProject = try await buildTestProject(testProjectConfig: tpc)

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let buildParameters = BuildParameters(configuration: tpc.buildConfiguration)

        await tester.checkBuild(buildParameters, runDestination: tpc.activeRunDestination) { results in
            // Match tasks we know we're not interested in.
            results.consumeTasksMatchingRuleTypes([
                "CompileSwift",
                "CompileSwiftSources",
                "CreateBuildDirectory",
                "Copy",
                "Gate",
                "GenerateDSYMFile",
                "Ld",
                "MkDir",
                "RegisterExecutionPolicyException",
                "SymLink",
                "WriteAuxiliaryFile",
            ])

            // Check no diagnostics emitted
            results.checkWarning(.equal("SWIFT_MODULE_ONLY_ARCHS assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"))
            results.checkWarning(.equal("SWIFT_MODULE_ONLY_MACOSX_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"), failIfNotFound: false)
            results.checkWarning(.equal("SWIFT_MODULE_ONLY_IPHONEOS_DEPLOYMENT_TARGET assigned at level: project. Module-only architecture back deployment is now handled automatically by the build system and this setting will be ignored. Remove it from your project. (in target 'MyTarget' from project 'MyProject')"), failIfNotFound: false)
            results.checkNoDiagnostics()

            for arch in tpc.archs {
                // Check 'RuleScriptExecution' task exists for <arch>
                results.checkTaskExists(.matchRuleType("RuleScriptExecution"), .matchRuleItem(arch))
            }

            for arch in tpc.moduleOnlyArchs {
                // Check no 'RuleScriptExecution' task exists for <arch>
                results.checkNoTask(.matchRuleType("RuleScriptExecution"), .matchRuleItem(arch))
            }
        }
    }

    /// Check swiftmodule content when building `targetType` in `buildConfiguration` mode
    private func checkSwiftModuleOnlyArchsAllPlatforms(targetType: TestStandardTarget.TargetType,
                                                       buildConfiguration: String) async throws {
        // macOS
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macOS,
                deploymentTarget: "10.15",
                archs: ["x86_64", "x86_64h"],
                moduleOnlyDeploymentTarget: "10.13",
                moduleOnlyArchs: ["i386"]))

        // macOS (Zippered)
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macOS,
                isZippered: true,
                deploymentTarget: "10.15",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.13",
                moduleOnlyArchs: ["x86_64h"],
                zipperedDeploymentTarget: "13.0",
                zipperedModuleOnlyDeploymentTarget: "10.3"))

        // Mac Catalyst
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macCatalyst,
                deploymentTarget: "13.0",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.3",
                moduleOnlyArchs: ["x86_64h"]))

        // Mac Catalyst (Zippered)
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.macCatalyst,
                isZippered: true,
                deploymentTarget: "13.0",
                archs: ["x86_64"],
                moduleOnlyDeploymentTarget: "10.3",
                moduleOnlyArchs: ["x86_64h"],
                zipperedDeploymentTarget: "10.15",
                zipperedModuleOnlyDeploymentTarget: "10.13"))

        // iOS
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.iOS,
                deploymentTarget: "13.0",
                archs: ["arm64", "arm64e"],
                moduleOnlyDeploymentTarget: "10.3",
                moduleOnlyArchs: ["armv7", "armv7s"]))

        // iOS Simulator
        try await checkSwiftModuleOnlyArchs(
            TestProjectConfig(
                targetType: targetType,
                buildConfiguration: buildConfiguration,
                platform: BuildVersion.Platform.iOSSimulator,
                deploymentTarget: "13.0",
                archs: ["arm64"],
                moduleOnlyDeploymentTarget: "10.3",
                moduleOnlyArchs: ["x86_64"]))
    }
}
