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

// Basic tests for different product types, across different platforms.

import Testing

import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction
import SWBMacro

@Suite
fileprivate struct PlatformTaskConstructionTests: CoreBasedTests {
    // MARK: iOS

    /// Test a basic iOS app.
    @Test(.requireSDKs(.iOS))
    func iOSAppBasics() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.m"),
                    TestFile("Class.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "INFOPLIST_FILE": "Info.plist",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "iphoneos",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("FwkTarget.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false
                                               ),
                        TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "Foo", contents: "echo \"Running script\"\nexit 0\n", alwaysOutOfDate: true),
                    ],
                    dependencies: ["FwkTarget"]
                ),
                TestStandardTarget(
                    "FwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "iphoneos",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Class.m",
                        ]),
                        TestFrameworksBuildPhase([
                            "FwkTarget.framework",
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let IPHONEOS_DEPLOYMENT_TARGET = core.loadSDK(.iOS).defaultDeploymentTarget

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("Info.plist"), contents: "<dict/>")

        // Check the debug build, for the device.
        await tester.checkBuild(runDestination: .iOS, fs: fs) { results in
            // Ignore tasks we don't want to specifically check.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("Touch")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("CreateUniversalBinary")) { _ in }

            // Check the framework target.  This only exists to be embedded, so we don't check anything interesting about it.
            results.checkTarget("FwkTarget") { target in
                results.checkTasks(.matchTarget(target)) { _ in }
            }

            // Check the app target.
            results.checkTarget("AppTarget") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("main.m"), .matchRuleItem("arm64")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("main.o"), .suffix("main.m"), .equal("normal"), .equal("arm64"), .equal("objective-c"), .any])
                    task.checkCommandLineLastArgumentEqual("\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/Objects-normal/arm64/main.o")
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    #expect(!task.commandLine.contains("__entitlements"))
                }

                // There should be one PhaseScriptExecution task.
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/Script-Foo.sh")) { task in
                    task.checkRuleInfo(["PhaseScriptExecution", "Run Script", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/Script-Foo.sh"])
                    task.checkCommandLine(["/bin/sh", "-c", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/Script-Foo.sh"])

                    // Validate that IPHONEOS_DEPLOYMENT_TARGET is present in the environment, but deployment targets for other platforms are not.
                    var scriptVariables: [String: StringPattern?] = ["IPHONEOS_DEPLOYMENT_TARGET": .equal(IPHONEOS_DEPLOYMENT_TARGET)]
                    for platform in core.platformRegistry.platforms {
                        if let otherPlatformDeploymentTargetName = platform.deploymentTargetMacro?.name {
                            if otherPlatformDeploymentTargetName != "IPHONEOS_DEPLOYMENT_TARGET" {
                                scriptVariables[otherPlatformDeploymentTargetName] = .none      // Set the value to nil, don't remove the entry
                            }
                        }
                    }
                    task.checkEnvironment(scriptVariables)
                }

                // There should be a product packaging task for the entitlements file.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemPattern(.suffix(".xcent"))) { task in
                    task.checkRuleInfo(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent"])
                    task.checkCommandLine(["builtin-productPackagingUtility", "-entitlements", "-format", "xml", "-o", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent"])

                    #expect(task.inputs.contains { $0.path.str == "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/DerivedSources/Entitlements.plist" })

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent"),])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemPattern(.suffix(".xcent"))) { task in
                    task.checkRuleInfo(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent.der"])
                    task.checkCommandLine(["/usr/bin/derq", "query", "-f", "xml", "-i", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent", "-o", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent.der", "--raw"])

                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent"),
                        .any,
                        .any,
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent.der"),
                    ])
                }

                // There should be a product packaging task for the provisioning profile.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemBasename("embedded.mobileprovision")) { task in
                    task.checkRuleInfo(["ProcessProductPackaging", "/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/embedded.mobileprovision"])
                    task.checkCommandLine(["builtin-productPackagingUtility", "/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision", "-o", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/embedded.mobileprovision"])

                    #expect(task.inputs.contains { $0.path.str == "/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision" })

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/embedded.mobileprovision"),])
                }

                // There should be a task to embed the framework and sign it.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                    task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework", "\(SRCROOT)/build/Debug-iphoneos/FwkTarget.framework"])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework/FwkTarget"),
                        .name("Copy \(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                    task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework"])
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--timestamp=none", "--preserve-metadata=identifier,entitlements,flags", "--generate-entitlement-der", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .name("Copy \(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework/FwkTarget"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework/FwkTarget"),
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework/_CodeSignature"),
                        .name("CodeSign \(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Frameworks/FwkTarget.framework"),
                    ])
                }

                // There should be a codesign task for the app.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app")) { task in
                    #expect(task.ruleInfo[1] == "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app")
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/AppTarget.app.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app"])
                    task.checkEnvironment([
                        "CODESIGN_ALLOCATE": .equal("codesign_allocate"),
                    ], exact: true)
                }

                // There should be one product validation task.
                results.checkTask(.matchTarget(target), .matchRuleType("Validate"), .matchRuleItemBasename("AppTarget.app")) { task in
                    task.checkRuleInfo(["Validate", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app"])
                    task.checkCommandLine(["builtin-validationUtility", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app", "-shallow-bundle", "-infoplist-subpath", "Info.plist"])

                    task.checkInputs([
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app"),
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/Info.plist"),
                        .namePattern(.and(.prefix("target-"), .suffix("-Barrier-RegisterExecutionPolicyException"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                        // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                        .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app"),
                        .name("Validate \(SRCROOT)/build/Debug-iphoneos/AppTarget.app"),
                    ])
                }

                // Check a couple other random tasks.
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile")) { task in }
                results.checkTasks(.matchTarget(target), .matchRuleType("CreateBuildDirectory")) { _ in }

                results.consumeTasksMatchingRuleTypes(["CompileC", "Ld"], targetName: target.target.name)

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check the debug build, for the simulator.
        await tester.checkBuild(runDestination: .iOSSimulator, fs: fs) { results in
            // Ignore tasks we don't want to specifically check.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("Touch")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

            // Check the framework target.  This only exists to be embedded, so we don't check anything interesting about it.
            results.checkTarget("FwkTarget") { target in
                results.checkTasks(.matchTarget(target)) { _ in }
            }

            results.checkTarget("AppTarget") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("main.m"), .matchRuleItem("x86_64")) { task in
                    task.checkRuleInfo([.equal("CompileC"), .suffix("main.o"), .suffix("main.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                    task.checkCommandLineLastArgumentEqual("\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/Objects-normal/x86_64/main.o")
                }

                func checkLdEntitlements(_ task: any PlannedTask) {
                    let entitlementsOutputPath = Path("\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app-Simulated.xcent")
                    task.checkCommandLineContainsUninterrupted(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__entitlements", "-Xlinker", entitlementsOutputPath.str])
                    #expect(task.inputs.contains { $0.path == entitlementsOutputPath })
                }

                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in checkLdEntitlements(task) }

                // There should be one PhaseScriptExecution task.
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/Script-Foo.sh")) { task in
                    task.checkRuleInfo(["PhaseScriptExecution", "Run Script", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/Script-Foo.sh"])
                    task.checkCommandLine(["/bin/sh", "-c", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/Script-Foo.sh"])

                    // Validate that IPHONEOS_DEPLOYMENT_TARGET is present in the environment, but deployment targets for other platforms are not.
                    var scriptVariables: [String: StringPattern?] = ["IPHONEOS_DEPLOYMENT_TARGET": .equal(IPHONEOS_DEPLOYMENT_TARGET)]
                    for platform in core.platformRegistry.platforms {
                        if let otherPlatformDeploymentTargetName = platform.deploymentTargetMacro?.name {
                            if otherPlatformDeploymentTargetName != "IPHONEOS_DEPLOYMENT_TARGET" {
                                scriptVariables[otherPlatformDeploymentTargetName] = .none      // Set the value to nil, don't remove the entry
                            }
                        }
                    }
                    task.checkEnvironment(scriptVariables)
                }

                // There should be a product packaging task for the entitlements file.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging"), .matchRuleItemBasename("AppTarget.app.xcent")) { task in
                    task.checkRuleInfo(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app.xcent"])
                    task.checkCommandLine(["builtin-productPackagingUtility", "-entitlements", "-format", "xml", "-o", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app.xcent"])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackagingDER"), .matchRuleItemBasename("AppTarget.app.xcent")) { task in
                    task.checkRuleInfo(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app.xcent", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app.xcent.der"])
                    task.checkCommandLine(["/usr/bin/derq", "query", "-f", "xml", "-i", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app.xcent", "-o", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app.xcent.der", "--raw"])
                }

                // There should be a task to embed the framework and sign it.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                    task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework", "\(SRCROOT)/build/Debug-iphonesimulator/FwkTarget.framework"])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework/FwkTarget"),
                        .name("Copy \(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework"),
                    ])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("FwkTarget.framework")) { task in
                    task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework"])
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--timestamp=none", "--preserve-metadata=identifier,entitlements,flags", "--generate-entitlement-der", "\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .name("Copy \(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework/FwkTarget"),
                        .any,
                        .any,
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework"),
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework/FwkTarget"),
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework/_CodeSignature"),
                        .name("CodeSign \(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Frameworks/FwkTarget.framework"),
                    ])
                }

                // There should be a task to generate the entitlements file.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app-Simulated.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app-Simulated.xcent", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app-Simulated.xcent.der"])) { _ in }

                // There should be a codesign task for the app.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app")) { task in
                    #expect(task.ruleInfo[1] == "\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app")
                    task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "105DE4E702E4", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AppTarget.build/AppTarget.app.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app"])
                }

                // There should be one product validation task.
                results.checkTask(.matchTarget(target), .matchRuleType("Validate"), .matchRuleItemBasename("AppTarget.app")) { task in
                    task.checkRuleInfo(["Validate", "\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app"])
                    task.checkCommandLine(["builtin-validationUtility", "\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app", "-shallow-bundle", "-infoplist-subpath", "Info.plist"])

                    task.checkInputs([
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app"),
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app/Info.plist"),
                        .namePattern(.and(.prefix("target-"), .suffix("-Barrier-RegisterExecutionPolicyException"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                        // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                        .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                    ])

                    task.checkOutputs([
                        .path("\(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app"),
                        .name("Validate \(SRCROOT)/build/Debug-iphonesimulator/AppTarget.app"),
                    ])
                }

                // Check a couple other random tasks.
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile")) { task in }
                results.checkTasks(.matchTarget(target), .matchRuleType("CreateBuildDirectory")) { _ in }

                // There should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func iOSAppWithVariant() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "BUILD_VARIANTS": "normal asan",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "INFOPLIST_FILE": "Info.plist",
                                                "SDKROOT": "iphoneos",
                                                "CODE_SIGN_IDENTITY": "Apple Development",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let srcRoot = tester.workspace.projects[0].sourceRoot

        let provisioningInputs = ProvisioningTaskInputs(identityHash: "Apple Development", identityName: "Dev Signing")

        let fs = PseudoFS()
        try fs.createDirectory(srcRoot, recursive: true)
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/"), recursive: true)

        try fs.write(srcRoot.join("Info.plist"), contents: "<dict/>")
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "")

        // Check the debug build, for the device.
        await tester.checkBuild(runDestination: .iOS, provisioningOverrides: provisioningInputs, fs: fs) { results in
            // Check the app target.
            results.checkTarget("AppTarget") { target in
                // There should be one product validation task.
                results.checkTask(.matchTarget(target), .matchRuleType("Validate"), .matchRuleItemBasename("AppTarget.app")) { task in
                    task.checkRuleInfo(["Validate", "\(srcRoot.str)/build/Debug-iphoneos/AppTarget.app"])
                    task.checkCommandLine(["builtin-validationUtility", "\(srcRoot.str)/build/Debug-iphoneos/AppTarget.app", "-shallow-bundle", "-infoplist-subpath", "Info.plist"])

                    task.checkOutputs([
                        .path("\(srcRoot.str)/build/Debug-iphoneos/AppTarget.app"),
                        .name("Validate \(srcRoot.str)/build/Debug-iphoneos/AppTarget.app"),
                    ])
                }

                // There should be no Validate task for the asan variant
                results.checkNoTask(.matchTarget(target), .matchRuleType("Validate"))
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    // MARK: iOS Messages / Sticker pack apps

    @Test(.requireSDKs(.iOS))
    func messagesAppsStickerPacks() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("AppTarget-Info.plist"),
                    TestFile("StickerTarget-Info.plist"),
                    TestFile("Source.m"),
                    TestFile("Stickers.xcstickers"),
                    TestVariantGroup("Sticker Pack.strings", children: [
                        TestFile("Base.lproj/Sticker Pack.strings", regionVariantName: "Base"),
                        TestFile("en.lproj/Sticker Pack.strings", regionVariantName: "en"),
                    ]),
                    TestFile("Other.strings"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "INFOPLIST_FILE": "Info.plist",
                        "SDKROOT": "iphoneos",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .messagesApp,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "INFOPLIST_FILE": "AppTarget-Info.plist",
                            ]),
                    ],
                    buildPhases: [
                        // TODO: PBX requires the target to already have a resources phase in order to inject the product type's storyboard, but it would be more robust to cons one up implicitly. No ERs about that yet.
                        TestResourcesBuildPhase([]),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("StickerTarget.appex", codeSignOnCopy: true),
                            TestBuildFile("MessagesExtensionTarget.appex", codeSignOnCopy: true),
                        ], destinationSubfolder: .plugins, onlyForDeployment: false
                                               ),
                    ],
                    dependencies: ["StickerTarget", "MessagesExtensionTarget"]
                ),
                TestStandardTarget(
                    "StickerTarget",
                    type: .messagesStickerPackExtension,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "INFOPLIST_FILE": "StickerTarget-Info.plist",
                            ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase([
                            TestBuildFile("Stickers.xcstickers"),
                            TestBuildFile("Sticker Pack.strings"),
                            TestBuildFile("Other.strings"),
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "MessagesExtensionTarget",
                    type: .messagesExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Source.m"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        guard let platformPath = core.platformRegistry.lookup(name: "iphoneos")?.path else { throw StubError.error("Couldn't find iphoneos platform") }

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        try fs.createDirectory(core.developerPath.path.join("usr/bin"), recursive: true)
        try await fs.writeFileContents(core.developerPath.path.join("usr/bin/actool")) { $0 <<< "binary" }
        try await fs.writeFileContents(core.developerPath.path.join("usr/bin/ibtool")) { $0 <<< "binary" }

        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
        try fs.createDirectory(Path("/tmp/Test/aProject/Stickers.xcstickers/Sticker Pack.stickerpack"), recursive: true)
        try fs.createDirectory(platformPath.join("Library/Application Support/MessagesApplicationStub"), recursive: true)
        try fs.write(platformPath.join("Library/Application Support/MessagesApplicationStub/MessagesApplicationStub"), contents: "MessagesApplicationStub")
        try fs.createDirectory(platformPath.join("Library/Application Support/MessagesApplicationExtensionStub"), recursive: true)
        try fs.write(platformPath.join("Library/Application Support/MessagesApplicationExtensionStub/MessagesApplicationExtensionStub"), contents: "MessagesApplicationExtensionStub")
        try fs.createDirectory(tester.workspace.projects[0].sourceRoot, recursive: true)
        try fs.write(tester.workspace.projects[0].sourceRoot.join("Info.plist"), contents: "<dict/>")

        await tester.checkBuild(runDestination: .iOS, fs: fs) { results in
            results.checkNoDiagnostics()

            func checkProductTypeInfoPlistAdditions(target: ConfiguredTarget, expectedContent: PropertyListItem) {
                // TODO: This seems a little fragile. Is there some way we can check the result (i.e. what's in the resulting Info.plist?) instead of the specific implementation details?

                let infoPlistAdditionsPath = Path("/tmp/Test/aProject/build/aProject.build/Debug-iphoneos/\(target.target.name).build/ProductTypeInfoPlistAdditions.plist")

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", infoPlistAdditionsPath.str])) { task, contents in
                    guard let plist = try? PropertyList.fromBytes(contents.bytes) else { Issue.record("failed to parse plist from info contents"); return }
                    #expect(plist == expectedContent)
                }

                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkCommandLineContains([infoPlistAdditionsPath.str])
                    task.checkInputs(contain: [.path(infoPlistAdditionsPath.str)])
                }
            }

            results.checkTarget("AppTarget") { target in
                // Implied stub binary
                results.checkTask(.matchTarget(target), .matchRule(["CopyAndPreserveArchs", "/tmp/Test/aProject/build/Debug-iphoneos/AppTarget.app/AppTarget"])) { task in
                    task.checkCommandLineMatches([
                        "lipo",
                        .equal(platformPath.join("Library/Application Support/MessagesApplicationStub/MessagesApplicationStub").str),
                        "-output",
                        "/tmp/Test/aProject/build/Debug-iphoneos/AppTarget.app/AppTarget",
                        "-extract",
                        "arm64"
                    ])
                }

                // Implied Info.plist content
                checkProductTypeInfoPlistAdditions(target: target, expectedContent: .plDict([
                    "LSApplicationLaunchProhibited": .plBool(true),
                ]))
            }

            results.checkTarget("StickerTarget") { target in
                // Implied stub binary
                results.checkTask(.matchTarget(target), .matchRule(["CopyAndPreserveArchs", "/tmp/Test/aProject/build/Debug-iphoneos/StickerTarget.appex/StickerTarget"])) { task in
                    task.checkCommandLineMatches([
                        "lipo",
                        "\(core.developerPath.path.str)/Platforms/iPhoneOS.platform/Library/Application Support/MessagesApplicationExtensionStub/MessagesApplicationExtensionStub",
                        "-output",
                        "/tmp/Test/aProject/build/Debug-iphoneos/StickerTarget.appex/StickerTarget",
                        "-extract",
                        "arm64"
                    ])
                }

                // Implied Info.plist content
                checkProductTypeInfoPlistAdditions(target: target, expectedContent: .plDict([
                    "LSApplicationIsStickerProvider": .plBool(true),
                ]))

                // Strings files matching a sticker pack base name should be folded into the actool task
                for variant in ["thinned", "unthinned"] {
                    results.checkTask(.matchTarget(target), .matchRule(["CompileAssetCatalogVariant", variant, "/tmp/Test/aProject/build/Debug-iphoneos/StickerTarget.appex", "/tmp/Test/aProject/Stickers.xcstickers"])) { task in
                        task.checkCommandLineContainsUninterrupted(["--sticker-pack-strings-file", "Sticker Pack:Base:/tmp/Test/aProject/Base.lproj/Sticker Pack.strings"])
                        task.checkCommandLineContainsUninterrupted(["--sticker-pack-strings-file", "Sticker Pack:en:/tmp/Test/aProject/en.lproj/Sticker Pack.strings"])

                        task.checkInputs(contain: [
                            NodePattern.name("Stickers.xcstickers/"),
                            NodePattern.path("/tmp/Test/aProject/Base.lproj/Sticker Pack.strings"),
                            NodePattern.path("/tmp/Test/aProject/en.lproj/Sticker Pack.strings"),
                        ])
                    }
                }

                // And they shouldn't be processed normally
                results.checkNoTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/Debug-iphoneos/StickerTarget.appex/Base.lproj/Sticker Pack.strings", "/tmp/Test/aProject/Base.lproj/Sticker Pack.strings"]))
                results.checkNoTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/Debug-iphoneos/StickerTarget.appex/en.lproj/Sticker Pack.strings", "/tmp/Test/aProject/en.lproj/Sticker Pack.strings"]))

                // Unrelated strings files should get processed normally
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/Test/aProject/build/Debug-iphoneos/StickerTarget.appex/Other.strings", "/tmp/Test/aProject/Other.strings"])) { _ in }
            }

            results.checkTarget("MessagesExtensionTarget") { target in
                // Compiled binary (instead of copied)
                results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("Ld")) { _ in }
            }
        }
    }

    // MARK: macCatalyst

    /// Basic test of building an macCatalyst app.
    @Test(.requireSDKs(.macOS, .iOS))
    func macCatalystBasics() async throws {
        let IPHONEOS_DEPLOYMENT_TARGET = "13.1"
        let archs = ["arm64", "x86_64"]
        let swiftCompilerPath = try await self.swiftCompilerPath

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("ClassOne.m"),
                    TestFile("ClassTwo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS[sdk=iphoneos*]": "arm64",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "iphoneos",
                    "IPHONEOS_DEPLOYMENT_TARGET": IPHONEOS_DEPLOYMENT_TARGET,
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "SUPPORTS_MACCATALYST": "YES",
                    "CLANG_USE_RESPONSE_FILE": "NO",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.m",
                            "ClassTwo.swift",
                        ]),
                        TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "Foo", contents: "echo \"Running script\"\nexit 0\n", alwaysOutOfDate: true),
                    ]),
            ]
        )
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Perform a basic build.
        let macosOverrides = [
            "ARCHS": archs.joined(separator: " "),
        ]
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: macosOverrides), runDestination: .anyMacCatalyst) { results in
            results.checkNoDiagnostics()

            // Match tasks we know we're not interested in.
            results.consumeTasksMatchingRuleTypes(["Gate", "CreateBuildDirectory", "MkDir", "SymLink"])
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".hmap"))) { _ in }

            results.checkTarget("AppTarget") { target in
                // Check each arch.
                for arch in archs {
                    // There should be a clang task for the ObjC file.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem(arch)) { task in
                        let expectedClangOptions = ["clang",
                                                    "-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)-macabi",
                                                    "-isysroot", core.loadSDK(.macOS).path.str,
                                                    "-isystem", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/include",
                                                    "-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks",
                                                    "-c", "\(SRCROOT)/Sources/ClassOne.m",
                                                    "-o", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/\(arch)/ClassOne.o",
                        ]
                        task.checkCommandLineContains(expectedClangOptions)
                    }

                    // Check the Swift compilation task and the tasks to copy its outputs.
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"), .matchRuleItem(arch)) { task in
                        let expectedSwiftOptions = [swiftCompilerPath.str,
                                                    "-module-name", "AppTarget",
                                                    "-sdk", core.loadSDK(.macOS).path.str,
                                                    "-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)-macabi",
                                                    "-Fsystem", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks",
                                                    "-c",
                                                    "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/\(arch)/AppTarget-OutputFileMap.json",
                                                    "-serialize-diagnostics",
                                                    "-emit-dependencies",
                                                    "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/\(arch)/AppTarget.swiftmodule",
                                                    "-Xcc", "-isystem", "-Xcc", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/include",
                                                    "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/\(arch)/AppTarget-Swift.h",
                        ]
                        task.checkCommandLineContains(expectedSwiftOptions)
                    }

                    // Check the link task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem(arch)) { task in
                        let expectedLinkerOptions = ["clang",
                                                     "-target", "\(arch)-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)-macabi",
                                                     "-isysroot", core.loadSDK(.macOS).path.str,
                                                     "-L\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/lib",
                                                     "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/maccatalyst",
                                                     "-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks",
                                                     "-o", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/\(arch)/Binary/AppTarget",
                        ]
                        task.checkCommandLineContains(expectedLinkerOptions)
                    }
                }

                // Check the lipo task.
                results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary"), .matchRuleItem("\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/MacOS/AppTarget")) { _ in }

                // Check the shell script task.
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItemBasename("Script-Foo.sh")) { task in
                    // Check export of build settings for macCatalyst.
                    task.checkEnvironment([
                        "IS_MACCATALYST": .equal("YES"),
                    ])
                }
            }
        }

        // Test building for iOS, to make sure nothing surprising creeps in for targets that can build for both iOS and macCatalyst.
        let fs = PseudoFS()
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()

            // Match tasks we know we're not interested in.
            results.consumeTasksMatchingRuleTypes(["Gate", "CreateBuildDirectory", "MkDir", "SymLink"])
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".hmap"))) { _ in }

            results.checkTarget("AppTarget") { target in
                // check that we have tasks building for the iOS SDK and arch.
                // There should be a clang task for the ObjC file.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    let expectedClangOptions = ["clang",
                                                "-target", "arm64-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)",
                                                "-isysroot", core.loadSDK(.iOS).path.str,
                                                "-c", "\(SRCROOT)/Sources/ClassOne.m",
                                                "-o", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/Objects-normal/arm64/ClassOne.o",
                    ]
                    task.checkCommandLineContains(expectedClangOptions)
                }

                // Check the Swift compilation task and the tasks to copy its outputs.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    let expectedSwiftOptions = [swiftCompilerPath.str,
                                                "-module-name", "AppTarget",
                                                "-sdk", core.loadSDK(.iOS).path.str,
                                                "-target", "arm64-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)",
                                                "-c",
                                                "-output-file-map", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/Objects-normal/arm64/AppTarget-OutputFileMap.json",
                                                "-serialize-diagnostics",
                                                "-emit-dependencies",
                                                "-emit-module", "-emit-module-path", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/Objects-normal/arm64/AppTarget.swiftmodule",
                                                "-emit-objc-header", "-emit-objc-header-path", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AppTarget.build/Objects-normal/arm64/AppTarget-Swift.h",
                    ]
                    task.checkCommandLineContains(expectedSwiftOptions)
                }

                // Check the link task.
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    let expectedLinkerOptions = ["clang",
                                                 "-target", "arm64-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)",
                                                 "-isysroot", core.loadSDK(.iOS).path.str,
                                                 "-o", "\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/AppTarget",
                    ]
                    task.checkCommandLineContains(expectedLinkerOptions)
                }

                // Check the shell script task.
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItemBasename("Script-Foo.sh")) { task in
                    task.checkEnvironment([
                        // Make sure that we're *not* exporting any macCatalyst-related build settings in the environment.
                        "SDK_VARIANT": .none,
                        "IS_MACCATALYST": .none,
                    ])
                }
            }
        }
    }

    /// Test that required macCatalyst search paths are passed to the compilers even when the target is overriding them.
    @Test(.requireSDKs(.macOS, .iOS))
    func macCatalystSearchPaths() async throws {
        let IPHONEOS_DEPLOYMENT_TARGET = "13.1"
        let swiftCompilerPath = try await self.swiftCompilerPath
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("ClassOne.m"),
                    TestFile("ClassTwo.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "iphoneos",
                    "IPHONEOS_DEPLOYMENT_TARGET": IPHONEOS_DEPLOYMENT_TARGET,
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "CODE_SIGN_IDENTITY": "",
                    "SUPPORTS_MACCATALYST": "YES",

                    // These settings are the point of the test: They mask out the values from the SDK variant because they're not using $(inherited).
                    "LIBRARY_SEARCH_PATHS": "/usr/local/lib",
                    "SYSTEM_HEADER_SEARCH_PATHS": "/usr/local/include",
                    "SYSTEM_FRAMEWORK_SEARCH_PATHS": "/Library/Frameworks",
                    "CLANG_USE_RESPONSE_FILE": "NO",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ClassOne.m",
                            "ClassTwo.swift",
                        ]),
                    ]),
            ]
        )
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Test with the public SDK.
        await tester.checkBuild(runDestination: .macCatalyst) { results in
            results.checkNoDiagnostics()

            // Match tasks we know we're not interested in.
            results.consumeTasksMatchingRuleTypes(["Gate", "CreateBuildDirectory", "MkDir", "SymLink"])
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".hmap"))) { _ in }

            results.checkTarget("AppTarget") { target in
                // There should be a clang task for the ObjC file.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    let expectedClangOptions = ["clang",
                                                "-target", "x86_64-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)-macabi",
                                                "-isysroot", core.loadSDK(.macOS).path.str,
                                                "-isystem", "/usr/local/include",
                                                "-isystem", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/include",
                                                "-iframework", "/Library/Frameworks",
                                                "-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks",
                                                "-c", "\(SRCROOT)/Sources/ClassOne.m",
                                                "-o", "\(SRCROOT)/build/aProject.build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.build/Objects-normal/x86_64/ClassOne.o",
                    ]
                    task.checkCommandLineContains(expectedClangOptions)
                }

                // Check the Swift compilation task and the tasks to copy its outputs.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    let expectedSwiftOptions = [swiftCompilerPath.str,
                                                "-module-name", "AppTarget",
                                                "-sdk", core.loadSDK(.macOS).path.str,
                                                "-target", "x86_64-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)-macabi",
                                                "-F", "/Library/Frameworks",
                                                "-Fsystem", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks",
                                                "-c",
                                                "-Xcc", "-isystem", "-Xcc", "/usr/local/include",
                                                "-Xcc", "-isystem", "-Xcc", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/include",
                    ]
                    task.checkCommandLineContains(expectedSwiftOptions)
                }

                // Check the link task.
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    let expectedLinkerOptions = ["clang",
                                                 "-target", "x86_64-apple-ios\(IPHONEOS_DEPLOYMENT_TARGET)-macabi",
                                                 "-isysroot", core.loadSDK(.macOS).path.str,
                                                 "-L/usr/local/lib",
                                                 "-L\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/lib",
                                                 "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/maccatalyst",
                                                 "-iframework", "/Library/Frameworks",
                                                 "-iframework", "\(core.loadSDK(.macOS).path.str)/System/iOSSupport/System/Library/Frameworks",
                                                 "-o", "\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/MacOS/AppTarget",
                    ]
                    task.checkCommandLineContains(expectedLinkerOptions)
                }
            }
        }
    }

    /// Ensure that macOS and macCatalyst targets can build without stomping on each other.
    @Test(.requireSDKs(.macOS))
    func macOSMacCatalystCoexistence() async throws {
        let core = try await getCore()
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestAggregateTarget(
                    "Umbrella",
                    dependencies: [
                        "MacTarget",
                        "MacCatalystTarget",
                    ]
                ),

                // Expect this to build for macosx.
                TestStandardTarget(
                    "MacTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "macosx",
                                "PRODUCT_NAME": "Product",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                    ]
                ),

                // Expect this to build for macCatalyst.
                // Note that it has the same product name as "MacTarget", so this is intended to test that those don't collide!
                TestStandardTarget(
                    "MacCatalystTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "macosx",
                                "SDK_VARIANT": MacCatalystInfo.sdkVariantName,
                                "PRODUCT_NAME": "Product",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                    ]
                ),
            ])
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget("MacTarget") { target in
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/Test/aProject/build/Debug/Product.framework"])) { _ in }
            }

            results.checkTarget("MacCatalystTarget") { target in
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/Test/aProject/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Product.framework"])) { _ in }
            }
        }
    }
}
