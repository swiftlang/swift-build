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

public import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

// This is to workaround an issue on CI with duplicate definitions of the `deps()` helper.
protocol DependencyFilter {
    var value: String { get }
    var isWatchKitAppContainer: Bool { get }
}

extension DependencyFilter {
    var isWatchKitAppContainer: Bool {
        // rdar://73955181 - the watchos container targets "iphoneos", but the implicit dep is for "watchos", so it gets ignored.
        self.value == "Watchable WatchKit App"
    }
}

extension String: DependencyFilter {
    var value: String { return self }
}

extension TestTargetDependency: DependencyFilter {
    var value: String { return self.name }
}


extension SWBCore.Workspace {
    /// Finds the target with the given name.
    /// - Precondition: There are no duplicate targets with the given name.
    public func target(named: String) -> SWBCore.Target? {
        let candidates = self.targets(named: named)
        precondition(candidates.count <= 1)
        return candidates.first
    }
}


@Suite
fileprivate struct MultiPlatformTaskConstructionTests: CoreBasedTests {
    /// A helper function to determine which dependencies to return.
    func deps<T: DependencyFilter>(_ d: [T], useImplicitDependencies: Bool) -> [T] {
        let alwaysInclude = d.filter({ $0.isWatchKitAppContainer })
        if useImplicitDependencies { return alwaysInclude }
        return d
    }


    /**
     * Helper function to create the basic test project.
     * - Parameter overrides: set of build setting overrides for the specialized targets only.
     */
    /// @param overrides -
    func createBasicTestWorkspace(fs: any FSProxy, overrides: [String:String] = [:], useImplicitDependencies: Bool = false, allowTargetSpecializationByDefault: Bool = false) async throws -> TestWorkspace {
        let core = try await getCore()
        var buildSettings = try await [
            "ARCHS": "$(ARCHS_STANDARD)",
            "ARCHS[sdk=watchos*]": "arm64_32",
            "ENABLE_ON_DEMAND_RESOURCES": "NO",
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "CODE_SIGNING_ALLOWED": "NO",
            "CODE_SIGN_IDENTITY": "",
            "SWIFT_VERSION": swiftVersion,
            "TAPI_EXEC": tapiToolPath.str,
            "SWIFT_INSTALL_OBJC_HEADER": "NO",
            "SKIP_INSTALL": "YES",
            "GENERATE_INFOPLIST_FILE": "YES",
            "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
            "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
            "TVOS_DEPLOYMENT_TARGET": core.loadSDK(.tvOS).defaultDeploymentTarget,
            "WATCHOS_DEPLOYMENT_TARGET": core.loadSDK(.watchOS).defaultDeploymentTarget,
        ]

        if allowTargetSpecializationByDefault {
            buildSettings["ALLOW_TARGET_PLATFORM_SPECIALIZATION"] = "YES"
        }

        let debugBuildConfiguration = TestBuildConfiguration("Debug", buildSettings: buildSettings)

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    // watchOS app files
                    TestFile("watchosApp/Base.lproj/Interface.storyboard"),
                    TestFile("watchosApp/Assets.xcassets"),
                    TestFile("watchosApp/Info.plist"),

                    // watchOS extension files
                    TestFile("watchosExtension/Controller.m"),
                    TestFile("watchosExtension/WatchClass.swift"),
                    TestFile("watchosExtension/Assets.xcassets"),
                    TestFile("watchosExtension/Info.plist"),

                    // iOS app files
                    TestFile("iphoneosApp/Base.lproj/Interface.storyboard"),
                    TestFile("iphoneosApp/Assets.xcassets"),
                    TestFile("iphoneosApp/Info.plist"),
                    TestFile("iphoneosApp/ios.swift"),

                    // macCatalyst app files
                    TestFile("maccatalystApp/cat.swift"),

                    // macOS app files
                    TestFile("macosApp/Info.plist"),
                    TestFile("macosApp/mac.swift"),

                    // tvOS app file
                    TestFile("tvosApp/tv.swift"),

                    // Shared framework files
                    TestFile("shared/Info.plist"),
                    TestFile("shared/lib.swift"),
                ]),
            buildConfigurations: [
                debugBuildConfiguration
            ],
            targets: [
                TestStandardTarget(
                    "Watchable",
                    type: .watchKitAppContainer,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "iphoneos"
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            // The target must at least HAVE an empty phase for the automatic asset catalog and storyboard to work
                        ]),
                        TestCopyFilesBuildPhase(["Watchable WatchKit App.app"], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/Watch", onlyForDeployment: false
                                               ),
                    ],
                    dependencies: deps(["Watchable WatchKit App"], useImplicitDependencies: useImplicitDependencies)
                ),
                TestStandardTarget(
                    "Watchable WatchKit App",
                    type: .watchKitApp,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
                            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                            "SDKROOT": "watchos",
                            "TARGETED_DEVICE_FAMILY": "4",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            "Base.lproj/Interface.storyboard",
                            "watchosApp/Assets.xcassets",
                        ]),
                        TestCopyFilesBuildPhase(["Watchable WatchKit Extension.appex"], destinationSubfolder: .plugins, onlyForDeployment: false
                                               ),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                        ]),
                    ],
                    dependencies: deps(["Watchable WatchKit Extension", "Shared Framework"], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: ["SharedPkgTarget"])
                ),
                TestStandardTarget(
                    "Watchable WatchKit Extension",
                    type: .watchKitExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ASSETCATALOG_COMPILER_COMPLICATION_NAME": "Complication",
                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                            "SDKROOT": "watchos",
                            "TARGETED_DEVICE_FAMILY": "4",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Controller.m",
                            "watchosExtension/WatchClass.swift",
                        ]),
                        TestResourcesBuildPhase([
                            "Base.lproj/Interface.storyboard",
                            "watchosExtension/Assets.xcassets",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "iOS App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ASSETCATALOG_COMPILER_COMPLICATION_NAME": "Complication",
                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                            "SDKROOT": "iphoneos",
                            "TARGETED_DEVICE_FAMILY": "1",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "iphoneosApp/ios.swift",
                        ]),
                        TestResourcesBuildPhase([
                            "Base.lproj/Interface.storyboard",
                            "iphoneosApp/Assets.xcassets",
                        ]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                        ]),
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework")], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget")])
                ),
                TestStandardTarget(
                    "macCatalyst App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALWAYS_SEARCH_USER_PATHS": "NO",
                            "CODE_SIGNING_ALLOWED": "NO",
                            "SDKROOT": "iphoneos",
                            "SUPPORTS_MACCATALYST": "YES",
                            "TARGETED_DEVICE_FAMILY": "2,6",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["maccatalystApp/cat.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                        ])
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework")], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget")])
                ),
                TestStandardTarget(
                    "macOS App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "macosApp/mac.swift",
                        ]),
                        TestResourcesBuildPhase([]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                        ]),
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework")], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget")])
                ),
                TestStandardTarget(
                    "tvOS App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                            "SDKROOT": "appletvos",
                            "SUPPORTED_PLATFORMS": "appletvos",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "tvosApp/tv.swift",
                        ]),
                        TestResourcesBuildPhase([]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                        ]),
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework")], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget")])
                ),
                TestStandardTarget(
                    "Shared Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "TARGETED_DEVICE_FAMILY": "1",
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                        ].addingContents(of: overrides)),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("shared/lib.swift")]),
                    ]
                ),
                TestStandardTarget(
                    "MacAppEmbeddingiOSApp", type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "macosApp/mac.swift",
                        ]),
                        TestResourcesBuildPhase([]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("Shared Framework")),
                            TestBuildFile(.target("SharedPkgTarget")),
                        ]),
                        TestCopyFilesBuildPhase([TestBuildFile(.target("iOS App"))], destinationSubfolder: .builtProductsDir, destinationSubpath: "Samples")
                    ],
                    dependencies: deps([TestTargetDependency("Shared Framework")], useImplicitDependencies: useImplicitDependencies).appending(contentsOf: [TestTargetDependency("SharedPkgTarget"), TestTargetDependency("iOS App")])
                )
            ])

        let packageProject = TestPackageProject(
            "Package",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                // Shared package files
                TestFile("SharedPackageProduct/Info.plist"),
                TestFile("SharedPkgTarget/Info.plist"),
                TestFile("SharedPkgSource.swift"),
            ]),
            buildConfigurations: [
                debugBuildConfiguration
            ],
            targets: [
                TestPackageProductTarget(
                    "SharedPackageProduct::SharedPkgTarget",
                    frameworksBuildPhase: TestFrameworksBuildPhase([
                        TestBuildFile(.target("SharedPkgTarget"))
                    ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "SUPPORTS_MACCATALYST": "YES",
                        ].addingContents(of: overrides)),
                    ],
                    dependencies: ["SharedPkgTarget"]
                ),
                TestStandardTarget(
                    "SharedPkgTarget", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            "SUPPORTS_MACCATALYST": "YES",
                        ].addingContents(of: overrides)),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SharedPkgSource.swift"])
                    ]
                ),
            ]
        )

        try fs.createDirectory(core.developerPath.path.join("usr/bin"), recursive: true)
        try await fs.writeFileContents(core.developerPath.path.join("usr/bin/actool")) { $0 <<< "binary" }
        try await fs.writeFileContents(core.developerPath.path.join("usr/bin/ibtool")) { $0 <<< "binary" }

        // Create files in the filesystem so they're known to exist.
        try await fs.writeFileContents(swiftCompilerPath) { $0 <<< "binary" }
        try fs.writeSimulatedProvisioningProfile(uuid: "8db0e92c-592c-4f06-bfed-9d945841b78d")
        try fs.writeSimulatedWatchKitSupportFiles(watchosSDK: core.loadSDK(.watchOS), watchSimulatorSDK: core.loadSDK(.watchOSSimulator))
        try await fs.writeSimulatedMessagesAppSupportFiles(iosSDK: core.loadSDK(.iOS))

        return TestWorkspace("aWorkspace", projects: [testProject, packageProject])
    }

    func validateBuildFor(_ targets: [SWBCore.Target], destination: RunDestinationInfo, tester: TaskConstructionTester, useImplicitDependencies: Bool, fs: any FSProxy, file: StaticString = #filePath, line: UInt = #line) async throws -> [RunDestinationInfo] {

        // Capture the various platforms that the test case validated; used by callers to validate the expected validation blocks are hit.
        var validated: [RunDestinationInfo] = []

        // Pull out the list of targets from the tester object.
        let watchosTarget = try #require(tester.workspace.target(named: "Watchable"))
        let iphoneosTarget = try #require(tester.workspace.target(named: "iOS App"))
        let catalystTarget = try #require(tester.workspace.target(named: "macCatalyst App"))
        let macosTarget = try #require(tester.workspace.target(named: "macOS App"))
        let tvosTarget = try #require(tester.workspace.target(named: "tvOS App"))
        let sharedFrameworkTarget = try #require(tester.workspace.target(named: "Shared Framework"))
        let macAppWithEmbeddedPhoneAppTarget = try #require(tester.workspace.target(named: "MacAppEmbeddingiOSApp"))

        let parameters = BuildParameters(action: .build, configuration: "Debug")
        let request = BuildRequest(parameters: parameters, buildTargets: targets.map { BuildRequest.BuildTargetInfo(parameters: BuildParameters(action: .build, configuration: "Debug"), target: $0) }, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: useImplicitDependencies, useDryRun: false)

        let macos = targets.contains(macosTarget) || targets.contains(macAppWithEmbeddedPhoneAppTarget)
        let iphoneos = targets.contains(iphoneosTarget) || targets.contains(macAppWithEmbeddedPhoneAppTarget)
        let catalyst = targets.contains(catalystTarget)
        let watchos = targets.contains(watchosTarget)
        let tvos = targets.contains(tvosTarget)
        let shared = targets.contains(sharedFrameworkTarget)

        // Check the debug build, for the device.
        await tester.checkBuild(runDestination: destination, buildRequest: request, fs: fs) { results in

            func validateTargetCompiledForPlatform(_ partialTriple: String, tasks: GenericSequence<any PlannedTask>) {
                #expect(tasks.count > 0)
                for task in tasks {
                    task.checkCommandLineMatches([.contains(partialTriple)])
                }
            }

            // Ignore certain classes of tasks.
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CreateBuildDirectory", "Gate", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "Copy", "RegisterExecutionPolicyException", "SymLink", "Touch", "Validate", "ValidateEmbeddedBinary", "WriteAuxiliaryFile"])

            if iphoneos {
                validated.append(.iOS)
                let sdkroot = (destination == .iOSSimulator) ? "iphonesimulator" : "iphoneos"

                results.checkTarget("iOS App") { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileAssetCatalog")) { _ in }
                }

                results.checkTarget("Shared Framework", sdkroot: "iphoneos") { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                        validateTargetCompiledForPlatform("-apple-ios", tasks: tasks)
                    }
                }

                results.checkTarget("SharedPkgTarget", sdkroot: sdkroot) { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                        validateTargetCompiledForPlatform("-apple-ios", tasks: tasks)
                    }
                }
            }

            if watchos {
                validated.append(.watchOS)
                let sdkroot = destination == .watchOSSimulator ? "watchsimulator" : "watchos"

                // Check the shim app
                results.checkTarget("Watchable") { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileAssetCatalog")) { _ in }
                }

                results.checkTarget("Shared Framework", sdkroot: "watchos") { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                        validateTargetCompiledForPlatform("-apple-watchos", tasks: tasks)
                    }
                }

                results.checkTarget("SharedPkgTarget", sdkroot: sdkroot) { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                        validateTargetCompiledForPlatform("-apple-watchos", tasks: tasks)
                    }
                }
            }

            if catalyst {
                // Remember, catalyst apps are just iOS apps unless the .macCatalyst destination is used.
                if destination == .macCatalyst {
                    validated.append(.macCatalyst)

                    results.checkTarget("macCatalyst App") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver")) { _ in }
                    }

                    results.checkTarget("Shared Framework", sdkroot: "macosx") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            validateTargetCompiledForPlatform("-macabi", tasks: tasks)
                        }
                    }

                    results.checkTarget("SharedPkgTarget", sdkroot: "macosx") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            validateTargetCompiledForPlatform("-macabi", tasks: tasks)
                        }
                    }
                }
                else {
                    validated.append(.iOS)

                    results.checkTarget("macCatalyst App") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver")) { _ in }
                    }

                    // Since macCatalyst apps are really just iOS apps, if there is another iOS target, then the shared has already been consumed.
                    if !iphoneos {
                        results.checkTarget("Shared Framework", sdkroot: "iphoneos") { target in
                            results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                                validateTargetCompiledForPlatform("-apple-ios", tasks: tasks)
                            }
                        }

                        results.checkTarget("SharedPkgTarget", sdkroot: "iphoneos") { target in
                            results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                                validateTargetCompiledForPlatform("-apple-ios", tasks: tasks)
                            }
                        }
                    }
                }
            }

            if macos {
                validated.append(.macOS)

                if targets.contains(macosTarget) {
                    results.checkTarget("macOS App") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { #expect($0.count > 0) }
                    }
                }
                else if targets.contains(macAppWithEmbeddedPhoneAppTarget) {
                    results.checkTarget("MacAppEmbeddingiOSApp") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { #expect($0.count > 0) }
                    }
                }
                else {
                    Issue.record("Unexpectedly building for macos for targets: \(targets.map({ $0.name }))")
                }

                results.checkTarget("Shared Framework", sdkroot: "macosx") { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                        validateTargetCompiledForPlatform("-apple-macos", tasks: tasks)
                    }
                }

                results.checkTarget("SharedPkgTarget", sdkroot: "macosx") { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                        validateTargetCompiledForPlatform("-apple-macos", tasks: tasks)
                    }
                }
            }

            if tvos {
                validated.append(.tvOS)
                let sdkroot = destination == .tvOSSimulator ? "appletvsimulator" : "appletvos"

                results.checkTarget("Shared Framework", sdkroot: sdkroot) { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                        validateTargetCompiledForPlatform("-apple-tvos", tasks: tasks)
                    }
                }

                results.checkTarget("SharedPkgTarget", sdkroot: sdkroot) { target in
                    results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                        validateTargetCompiledForPlatform("-apple-tvos", tasks: tasks)
                    }
                }
            }

            if shared {
                if destination == .iOS {
                    validated.append(.iOS)
                    results.checkTarget("Shared Framework", sdkroot: "iphoneos") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            validateTargetCompiledForPlatform("-apple-ios", tasks: tasks)
                        }
                    }
                }

                if destination == .watchOS {
                    validated.append(.watchOS)
                    results.checkTarget("Shared Framework", sdkroot: "watchos") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            validateTargetCompiledForPlatform("-apple-watchos", tasks: tasks)
                        }
                    }
                }

                if destination == .macCatalyst {
                    validated.append(.macCatalyst)
                    results.checkTarget("Shared Framework", sdkroot: "macosx") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            validateTargetCompiledForPlatform("-macabi", tasks: tasks)
                        }
                    }
                }

                if destination == .macOS {
                    validated.append(.macOS)
                    results.checkTarget("Shared Framework", sdkroot: "macosx") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            validateTargetCompiledForPlatform("-apple-macos", tasks: tasks)
                        }
                    }
                }

                if destination == .tvOS {
                    validated.append(.tvOS)
                    results.checkTarget("Shared Framework", sdkroot: "appletvos") { target in
                        results.checkTasks(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { tasks in
                            validateTargetCompiledForPlatform("-apple-tvos", tasks: tasks)
                        }
                    }
                }
            }

            results.checkNoDiagnostics()
        }

        return validated.removingDuplicates()
    }

    // MARK: - Test specialization when building a single top-level target

    func _testSingleTopLevelTargetSpecialization(useImplicitDependencies: Bool) async throws {
        let fs = PseudoFS()

        let testWorkspace = try await createBasicTestWorkspace(fs: fs, useImplicitDependencies: useImplicitDependencies)
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        let watchosTarget = try #require(tester.workspace.targets(named: "Watchable").first)
        let iphoneosTarget = try #require(tester.workspace.targets(named: "iOS App").first)
        let catalystTarget = try #require(tester.workspace.targets(named: "macCatalyst App").first)
        let macosTarget = try #require(tester.workspace.targets(named: "macOS App").first)
        let macAppWithEmbeddedPhoneAppTarget = try #require(tester.workspace.targets(named: "MacAppEmbeddingiOSApp").first)

        #expect(try await validateBuildFor([watchosTarget], destination: .watchOS, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [.watchOS])
        #expect(try await validateBuildFor([iphoneosTarget], destination: .iOS, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [.iOS])
        #expect(try await validateBuildFor([catalystTarget], destination: .macCatalyst, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [.macCatalyst])
        #expect(try await validateBuildFor([macosTarget], destination: .macOS, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [.macOS])
        #expect(try await validateBuildFor([macAppWithEmbeddedPhoneAppTarget], destination: .macOS, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [ .iOS, .macOS])
    }

    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func singleTopLevelTargetSpecializedDeps_PublicSDK_ExplicitDependencies() async throws {
        try await _testSingleTopLevelTargetSpecialization(useImplicitDependencies: false)
    }


    @Test(.requireSDKs(.macOS, .iOS, .watchOS))
    func singleTopLevelTargetSpecializedDeps_PublicSDK_ImplicitDependencies() async throws {
        try await _testSingleTopLevelTargetSpecialization(useImplicitDependencies: true)
    }

    // MARK: - Test specialized framework can be built for a specific run destination

    func _testBuildingSpecializedFramework_PublicSDK() async throws {
        let fs = PseudoFS()

        let useImplicitDependencies = false

        let testProject = try await createBasicTestWorkspace(fs: fs, useImplicitDependencies: false)
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let sharedFrameworkTarget = tester.workspace.targets(named: "Shared Framework").first!

        #expect(try await validateBuildFor([sharedFrameworkTarget], destination: .watchOS, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [.watchOS])
        #expect(try await validateBuildFor([sharedFrameworkTarget], destination: .iOS, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [.iOS])
        #expect(try await validateBuildFor([sharedFrameworkTarget], destination: .macCatalyst, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [.macCatalyst])
        #expect(try await validateBuildFor([sharedFrameworkTarget], destination: .macOS, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [.macOS])
        #expect(try await validateBuildFor([sharedFrameworkTarget], destination: .tvOS, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs) == [.tvOS])
    }

    @Test(.requireSDKs(.macOS, .iOS, .tvOS, .watchOS))
    func buildingSpecializedFramework_PublicSDK() async throws {
        try await _testBuildingSpecializedFramework_PublicSDK()
    }

    // MARK: - Test mismatched top-level targets with specialized deps

    /// Test for the basic scenario for multi-platform frameworks.
    func _testBasicMultiPlatformScenario(targets: [String], destination: RunDestinationInfo, useImplicitDependencies: Bool) async throws -> [RunDestinationInfo] {
        let fs = PseudoFS()
        let testProject = try await createBasicTestWorkspace(fs: fs, useImplicitDependencies: useImplicitDependencies)
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let buildTargets = targets.compactMap({ tester.workspace.target(named: $0) })

        // Ensure we are going to build all of the requested targets.
        #expect(buildTargets.map({ $0.name }).sorted() == targets.sorted())

        // Validate the build tasks.
        return try await validateBuildFor(buildTargets, destination: destination, tester: tester, useImplicitDependencies: useImplicitDependencies, fs: fs)
    }

    func _testBasicMultiplePlatformScenarios(useImplicitDependencies: Bool) async throws {
        #expect(try await _testBasicMultiPlatformScenario(targets: ["macOS App", "iOS App"], destination: .iOS, useImplicitDependencies: false) == [.iOS, .macOS])
        #expect(try await _testBasicMultiPlatformScenario(targets: ["macOS App", "macCatalyst App"], destination: .iOS, useImplicitDependencies: false) == [.iOS, .macOS])


        #expect(try await _testBasicMultiPlatformScenario(targets: ["iOS App", "macCatalyst App"], destination: .iOS, useImplicitDependencies: false) == [.iOS])
        #expect(try await _testBasicMultiPlatformScenario(targets: ["iOS App", "macCatalyst App"], destination: .macCatalyst, useImplicitDependencies: false) == [.iOS, .macCatalyst])
        #expect(try await _testBasicMultiPlatformScenario(targets: ["iOS App", "macCatalyst App"], destination: .macOS, useImplicitDependencies: false) == [.iOS])

        #expect(try await _testBasicMultiPlatformScenario(targets: ["iOS App", "macOS App", "macCatalyst App", "tvOS App"], destination: .iOS, useImplicitDependencies: false) == [.iOS, .macOS, .tvOS])
        #expect(try await _testBasicMultiPlatformScenario(targets: ["iOS App", "macOS App", "macCatalyst App", "tvOS App"], destination: .macOS, useImplicitDependencies: false) == [.iOS, .macOS, .tvOS])
        #expect(try await _testBasicMultiPlatformScenario(targets: ["iOS App", "macOS App", "macCatalyst App", "tvOS App"], destination: .tvOS, useImplicitDependencies: false) == [.iOS, .macOS, .tvOS])
    }

    @Test(.requireSDKs(.macOS, .iOS, .tvOS, .watchOS))
    func basicMultiPlatformScenario_PublicSDK_ExplicitDeps() async throws {
        try await _testBasicMultiplePlatformScenarios(useImplicitDependencies: false)
    }

    @Test(.requireSDKs(.macOS, .iOS, .tvOS, .watchOS))
    func basicMultiPlatformScenario_PublicSDK_ImplicitDeps() async throws {
        try await _testBasicMultiplePlatformScenarios(useImplicitDependencies: true)
    }

    // MARK: - Test other special cases

    /// This is a specific regression test for rdar://74100490.
    @Test(.requireSDKs(.macOS, .iOS))
    func macAndMacCatalystFrameworksDoNotCollide() async throws {
        let core = try await getCore()
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    // macCatalyst app files
                    TestFile("maccatalystApp/cat.swift"),

                    // Shared framework files
                    TestFile("shared_mac/lib.swift"),

                    // Shared framework files
                    TestFile("shared_maccat/lib.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "$(ARCHS_STANDARD)",
                    "ENABLE_ON_DEMAND_RESOURCES": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGNING_ALLOWED": "NO",
                    "CODE_SIGN_IDENTITY": "",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "SWIFT_INSTALL_OBJC_HEADER": "NO",
                    "SKIP_INSTALL": "YES",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
                    "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "macCatalyst App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "iphoneos",
                            "SUPPORTS_MACCATALYST": "YES",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["maccatalystApp/cat.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile("Shared Framework.framework"),
                        ])
                    ],
                    dependencies: []
                ),
                TestStandardTarget(
                    "Shared Framework 1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx watchos watchsimulator",
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "PRODUCT_NAME": "Shared Framework",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("shared_mac/lib.swift")]),
                    ]
                ),
                TestStandardTarget(
                    "Shared Framework 2",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SDKROOT": "iphoneos",
                            "SUPPORTS_MACCATALYST": "YES",
                            "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
                            "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                            "PRODUCT_NAME": "Shared Framework",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("shared_maccat/lib.swift")]),
                    ]
                )
            ])

        let tester = try TaskConstructionTester(core, testProject)

        let targets = tester.workspace.targets(named: "macCatalyst App")
        for destination in [RunDestinationInfo.macOS, RunDestinationInfo.macCatalyst] {
            let parameters = BuildParameters(action: .build, configuration: "Debug")

            let request = BuildRequest(parameters: parameters, buildTargets: targets.map { BuildRequest.BuildTargetInfo(parameters: BuildParameters(action: .build, configuration: "Debug"), target: $0) }, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            await tester.checkBuild(runDestination: destination, buildRequest: request) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func macCatalystRunDestinationSDKVariantOverride_macOS() async throws {
        try await _testMacCatalystRunDestinationSDKVariantOverride(sdkroot: "macosx", destination: .macOS)
    }

    @Test(.requireSDKs(.macOS, .iOS), .knownIssue("Targets with SUPPORTS_MACCATALYST=NO still attempt to build for Mac Catalyst with a Mac Catalyst run destination when ALLOW_TARGET_PLATFORM_SPECIALIZATION is enabled"), .bug("rdar://96172508"))
    func macCatalystRunDestinationSDKVariantOverride_macCatalyst() async throws {
        try await _testMacCatalystRunDestinationSDKVariantOverride(sdkroot: "macosx", destination: .macCatalyst)
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func macCatalystRunDestinationSDKVariantOverride_iOS() async throws {
        try await _testMacCatalystRunDestinationSDKVariantOverride(sdkroot: "macosx", destination: .iOS)
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func macCatalystRunDestinationSDKVariantOverride_macOS_Auto() async throws {
        try await _testMacCatalystRunDestinationSDKVariantOverride(sdkroot: "auto", destination: .macOS)
    }

    @Test(.requireSDKs(.macOS, .iOS), .knownIssue("Targets with SUPPORTS_MACCATALYST=NO still attempt to build for Mac Catalyst with a Mac Catalyst run destination when ALLOW_TARGET_PLATFORM_SPECIALIZATION is enabled"), .bug("rdar://96172508"))
    func macCatalystRunDestinationSDKVariantOverride_macCatalyst_Auto() async throws {
        try await _testMacCatalystRunDestinationSDKVariantOverride(sdkroot: "auto", destination: .macCatalyst)
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func macCatalystRunDestinationSDKVariantOverride_iOS_Auto() async throws {
        try await _testMacCatalystRunDestinationSDKVariantOverride(sdkroot: "auto", destination: .iOS)
    }

    /// Tests that a Mac Catalyst run destination does not force a target to build for Mac Catalyst even when `SUPPORTS_MACCATALYST` is set to `NO`.
    func _testMacCatalystRunDestinationSDKVariantOverride(sdkroot: String, destination: RunDestinationInfo) async throws {
        let core = try await getCore()
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", path: "Sources",
                children: [
                    TestFile("test.c")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
                    "SDKROOT": sdkroot,
                    "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
                    "SUPPORTS_MACCATALYST": "YES",
                    "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
                    "CLANG_USE_RESPONSE_FILE": "NO",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "NativeTool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SUPPORTS_MACCATALYST": "NO",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["test.c"]),
                    ],
                    dependencies: []
                ),
            ])

        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(runDestination: destination) { results in
            results.consumeTasksMatchingRuleTypes()
            results.consumeTasksMatchingRuleTypes(["CreateUniversalBinary", "RegisterExecutionPolicyException", "Ld"])

            results.checkTarget("NativeTool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem(results.runDestinationTargetArchitecture)) { task in
                    // No matter the destination, we should always build for macOS.
                    task.checkCommandLineContainsUninterrupted(["-target", "\(results.runDestinationTargetArchitecture)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)"])
                }

                results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }
}
