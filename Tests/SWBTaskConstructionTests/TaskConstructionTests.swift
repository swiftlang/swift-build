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

import struct Foundation.Data

import Testing

@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

import class SWBMacro.StringMacroDeclaration

@Suite
fileprivate struct TaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func appBasics() async throws {
        try await withTemporaryDirectory { tmpDir in
            // Test the basics of task construction for an app.
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.m"),
                        // See EXCLUDED/INCLUDED patterns for Debug config.
                        TestFile("SourceFile-Matched-Excluded.m"),
                        TestFile("SourceFile-Matched-Included.m"),
                        TestFile("Project.fake-lang-settings"),
                        TestFile("Custom.fake-lang"),
                        TestFile("Custom.fake-lang-settings"),
                        TestFile("en.lproj/Standard.fake-lang"),
                        TestFile("en.lproj/Standard.fake-lang-settings"),
                        TestFile("HeaderFile.h"),
                        TestFile("HeaderFile.fake-lang-header"),
                        TestFile("FileToCopy.txt"),
                        TestFile("PlistFileToCopy.plist"),
                        TestFile("FileToCopyOnlyDeploy.txt"),
                        TestFile("StringsResource.strings", fileTextEncoding: .utf8),
                        TestFile("SingleResImage.png"),
                        TestFile("SingleResTiffImage.tiff"),
                        TestFile("Image.png"),
                        TestFile("Image@2x.png"),
                        TestFile("NonUnique.m"),
                        TestFile("NonUnique.mm"),
                        TestFile("Lex.l"),
                        TestFile("Yacc.y"),
                        TestFile("FWToCopy.framework"),
                        TestFile("libstatic.a"),
                        TestFile("libdynamic.dylib"),
                        TestFile("Framework.framework"),
                        TestFile("AppCore.h"),
                        TestFile("MyIcons.iconset"),
                        TestFile("Prefix.pch"),
                        TestFile("SourceFile_MRR.m"),
                        TestFile("AppExtensions.framework"),
                        TestFile("Framework-Matched-Excluded.framework"),
                        TestFile("Framework-Matched-Included.framework"),
                        TestFile("Info.plist"),
                        TestFile("Stuff.dat"),
                        TestFile("Script-Input-File.txt"),
                        TestFile("AlternatePermissions.txt"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "EXCLUDED_SOURCE_FILE_NAMES": "Sources/*-Matched-*",
                            "INCLUDED_SOURCE_FILE_NAMES": "Sources/$(INCLUDED_SOURCE_FILE_NAMES_$(variant))",
                            "INCLUDED_SOURCE_FILE_NAMES_normal": "$(INCLUDED_SOURCE_FILE_NAMES_$(variant)_$(arch))",
                            "INCLUDED_SOURCE_FILE_NAMES_normal_x86_64": "*-Included*",
                            "COMBINE_HIDPI_IMAGES": "YES",
                            "LEXFLAGS": "-DOTHER_LEX_FLAG",
                            "GCC_PREFIX_HEADER": "Sources/Prefix.pch",
                            "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                            "CLANG_ENABLE_OBJC_ARC": "YES",
                        ]),
                    TestBuildConfiguration("Release", buildSettings: [
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALTERNATE_OWNER": "fooOwner",
                        "ALTERNATE_GROUP": "",
                        "ALTERNATE_MODE": "",
                        "GENERATE_MASTER_OBJECT_FILE": "YES",
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                "GENERATE_PKGINFO_FILE": "YES",
                            ]),
                            TestBuildConfiguration("Release", buildSettings: [
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                                "ALTERNATE_PERMISSIONS_FILES": "AlternatePermissions.txt",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.m",
                                "SourceFile-Matched-Excluded.m",
                                "SourceFile-Matched-Included.m",
                                "NonUnique.m",
                                "NonUnique.mm",
                                TestBuildFile("Lex.l", additionalArgs: ["-LEXFLAG"]),
                                TestBuildFile("Yacc.y",additionalArgs: ["-YACCFLAG"]),
                                "Custom.fake-lang",
                                TestBuildFile("en.lproj/Standard.fake-lang", additionalArgs: ["-CoolStuff", "with a space!", "$(SRCROOT)"]),
                                TestBuildFile("SourceFile_MRR.m", additionalArgs: ["-fno-objc-arc"]),
                            ]),
                            TestHeadersBuildPhase([TestBuildFile("HeaderFile.h", headerVisibility: .public),
                                                   TestBuildFile("HeaderFile.fake-lang-header", headerVisibility: .public)]),
                            TestCopyFilesBuildPhase(["FileToCopy.txt", "PlistFileToCopy.plist"], destinationSubfolder: .frameworks, onlyForDeployment: false),
                            TestCopyFilesBuildPhase(["FileToCopyOnlyDeploy.txt", TestBuildFile("FWToCopy.framework", codeSignOnCopy: true), TestBuildFile("libdynamic.dylib", codeSignOnCopy: true)], destinationSubfolder: .frameworks),
                            TestResourcesBuildPhase(["StringsResource.strings", "SingleResImage.png", "SingleResTiffImage.tiff", "Image@2x.png", "Image.png", "MyIcons.iconset"]),
                            TestShellScriptBuildPhase(name: "Run Script", shellPath: "/bin/super-fancy-shell $(TARGET_NAME)", originalObjectID: "Foo With Spaces", contents: "echo \"Running script\"\nexit 0",
                                                      inputs: ["Foo/../Sources/Script-Input-File.txt", "$(EXPANDS_TO_EMPTY)"],
                                                      dependencyInfo: .makefile(.string("$(DERIVED_FILES_DIR)/super-fancy-shell.d")), alwaysOutOfDate: true),
                            TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "ScriptWithOutput", contents: "echo \"Running script\"\nexit 0",
                                                      outputs: ["$(TARGET_TEMP_DIR)/Script-Output-File.txt"]),
                            TestShellScriptBuildPhase(name: "Copy Stuff", originalObjectID: "Bar", contents: "cp \"${INPUT_FILE_0}\" \"${OUTPUT_FILE_0}\"\nexit 0", inputs: ["Sources/Stuff.dat"], outputs: ["$(DERIVED_FILES_DIR)/Stuff.dat"]),
                            TestShellScriptBuildPhase(name: "Install Script", originalObjectID: "InstallScript", onlyForDeployment: true, alwaysOutOfDate: true),
                            TestFrameworksBuildPhase([
                                "libstatic.a",
                                "libdynamic.dylib",
                                "Framework.framework",
                                "AppCore.framework",
                                TestBuildFile("AppExtensions.framework", shouldLinkWeakly: true),
                                "Framework-Matched-Excluded.framework",
                                "Framework-Matched-Included.framework",
                            ]),
                            TestCopyFilesBuildPhase(["AlternatePermissions.txt"], destinationSubfolder: .absolute, destinationSubpath: "Applications", onlyForDeployment: true),
                        ],
                        buildRules: [TestBuildRule(filePattern: "*/*.fake-lang", script: "echo hi", inputs: [
                            "Sources/Project.fake-lang-settings",
                            "$(INPUT_FILE_PATH)-settings",
                        ], outputs: [
                            "$(DERIVED_FILES_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)/$(INPUT_FILE_REGION_PATH_COMPONENT)foo-$(INPUT_FILE_BASE).h",
                            "$(DERIVED_FILES_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)/$(INPUT_FILE_REGION_PATH_COMPONENT)Script-Output-$(INPUT_FILE_BASE)-SourceFile.c",
                            "$(DERIVED_FILES_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)/$(INPUT_FILE_REGION_PATH_COMPONENT)foo.plist",
                            // Write another fake-lang file, to test recursion.
                            "$(DERIVED_FILES_DIR)-$(CURRENT_VARIANT)/$(CURRENT_ARCH)/$(INPUT_FILE_REGION_PATH_COMPONENT)$(INPUT_FILE_BASE).fake-lang"
                        ]),TestBuildRule(filePattern: "*/*.fake-lang-header", script: "cp ${SCRIPT_INPUT_FILE} ${SCRIPT_OUTPUT_FILE_0}", outputs: [
                            "$(HEADER_OUTPUT_DIR)/$(INPUT_FILE_NAME)"
                        ], dependencyInfo: .makefile(.string("$(DERIVED_FILES_DIR)/$(INPUT_FILE_NAME).d")))],
                        dependencies: ["AppCore"]
                    ),
                    TestStandardTarget(
                        "AppCore",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "DEFINES_MODULE": "YES",
                                "MODULEMAP_PRIVATE_FILE": "AppCore-Private.modulemap",
                            ]),
                            TestBuildConfiguration("Release", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "DEFINES_MODULE": "YES"
                            ]),
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([TestBuildFile("AppCore.h", headerVisibility: .public)]),
                            TestSourcesBuildPhase(["SourceFile.m"]),
                        ])
                ])
            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str
            let MACOSX_DEPLOYMENT_TARGET = core.loadSDK(.macOS).defaultDeploymentTarget

            // Define the private module map file on disk.
            //
            // FIXME: This can be removed, once we land: <rdar://problem/24564960> [Swift Build] Stop ingesting user-defined module map file contents at task construction time
            let fs = PseudoFS()
            try fs.createDirectory(Path(SRCROOT), recursive: true)
            try fs.write(Path(SRCROOT).join("AppCore-Private.modulemap"), contents: "foo")

            try fs.createDirectory(Path(SRCROOT).join("Sources/FWToCopy.framework/Versions/A"), recursive: true)
            try fs.createDirectory(Path(SRCROOT).join("Sources/FWToCopy.framework/Versions/Current"), recursive: true)
            try fs.write(Path(SRCROOT).join("Sources/FWToCopy.framework/Versions/A/FWToCopy"), contents: "binary")

            try await fs.writePlist(Path(SRCROOT).join("Sources/Info.plist"), .plDict([:]))

            try await fs.writePlist(Path(SRCROOT).join("Entitlements.plist"), .plDict([:]))

            // Check the debug build.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["INFOPLIST_PREPROCESS": "YES", "COMBINE_HIDPI_IMAGES": "YES"]), runDestination: .macOS, fs: fs) { results -> Void in
                // There should be two warnings about our custom output files, since we won't reprocess the custom file it generates with the same name.
                results.checkWarning(.prefix("no rule to process file '\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Custom.fake-lang'"))
                results.checkWarning(.prefix("no rule to process file '\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Standard.fake-lang'"))

                // There shouldn't be any task construction diagnostics.
                results.checkNoDiagnostics()

                results.checkTarget("AppTarget") { target -> Void in
                    // There should be a PCH job for C and Objective-C, and one extra Obj-C one for the file with custom flags.
                    results.checkTask(.matchTarget(target), .matchRuleType("ProcessPCH"), .matchRuleItem("c")) { task in
                        task.checkRuleInfo([.equal("ProcessPCH"), .suffix("/Prefix.pch.gch"), .equal("\(SRCROOT)/Sources/Prefix.pch"), .equal("normal"), .equal("x86_64"), .equal("c"), .equal("com.apple.compilers.llvm.clang.1_0.compiler")])
                    }
                    results.checkTasks(.matchTarget(target), .matchRuleType("ProcessPCH"), .matchRuleItem("objective-c")) { tasks in
                        let taskArray = Array(tasks)
                        if taskArray.count != 2 {
                            #expect(taskArray.count == 2)
                            return
                        }

                        // One task should have -fno-objc-arc.
                        let mrrTask: any PlannedTask, arcTask: any PlannedTask
                        if taskArray[0].commandLine.contains("-fno-objc-arc") {
                            mrrTask = taskArray[0]
                            arcTask = taskArray[1]
                        } else if taskArray[1].commandLine.contains("-fno-objc-arc") {
                            mrrTask = taskArray[1]
                            arcTask = taskArray[0]
                        } else {
                            Issue.record("missing PCH task with -fno-objc-arc")
                            return
                        }

                        mrrTask.checkRuleInfo([.equal("ProcessPCH"), .suffix("/Prefix.pch.gch"), .equal("\(SRCROOT)/Sources/Prefix.pch"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .equal("com.apple.compilers.llvm.clang.1_0.compiler")])
                        arcTask.checkRuleInfo([.equal("ProcessPCH"), .suffix("/Prefix.pch.gch"), .equal("\(SRCROOT)/Sources/Prefix.pch"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .equal("com.apple.compilers.llvm.clang.1_0.compiler")])
                    }

                    // There should be an Info.plist processing task, and associated Preprocess (we explicitly enable it).
                    results.checkTask(.matchTarget(target), .matchRuleType("Preprocess")) { task in
                        task.checkRuleInfo(["Preprocess", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/normal/x86_64/Preprocessed-Info.plist", "\(SRCROOT)/Sources/Info.plist"])
                        task.checkCommandLine(["cc", "-E", "-P", "-x", "c", "-Wno-trigraphs", "\(SRCROOT)/Sources/Info.plist", "-F\(SRCROOT)/build/Debug", "-target", "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-o", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/normal/x86_64/Preprocessed-Info.plist"])
                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/Info.plist"),
                            .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-entry")))])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/normal/x86_64/Preprocessed-Info.plist")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                        task.checkRuleInfo(["ProcessInfoPlistFile", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Info.plist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Preprocessed-Info.plist"])
                        task.checkCommandLine(["builtin-infoPlistUtility", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Preprocessed-Info.plist", "-producttype", "com.apple.product-type.application", "-genpkginfo", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PkgInfo", "-expandbuildsettings", "-platform", "macosx", "-o", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Info.plist"])

                        task.checkInputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Preprocessed-Info.plist"),
                            .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-entry")))])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Info.plist"),
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PkgInfo"),
                        ])
                    }


                    // There should be one Lex task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Lex")) { task in
                        task.checkRuleInfo(["Lex", "\(SRCROOT)/Sources/Lex.l"])
                        task.checkCommandLine(["lex", "-DOTHER_LEX_FLAG", "-LEXFLAG", "-o", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/Lex.yy.c", "\(SRCROOT)/Sources/Lex.l"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/Lex.l"),
                            .namePattern(.prefix("target-")),
                            .namePattern(.and(.prefix("target-"), .suffix("-begin-compiling"))),
                            .name("WorkspaceHeaderMapVFSFilesWritten")])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/Lex.yy.c")])
                    }

                    // There should be one Yacc task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Yacc")) { task in
                        task.checkRuleInfo(["Yacc", "\(SRCROOT)/Sources/Yacc.y"])
                        task.checkCommandLine(["yacc", "-YACCFLAG", "-d", "-b", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/y", "\(SRCROOT)/Sources/Yacc.y"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/Yacc.y"),
                            .namePattern(.prefix("target-")),
                            .namePattern(.prefix("target-")),
                            .name("WorkspaceHeaderMapVFSFilesWritten")])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/y.tab.c"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/y.tab.h"),])
                    }

                    // Check the CompileC tasks.
                    results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) { tasks in
                        let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                        if sortedTasks.count != 9 {
                            #expect(sortedTasks.count == 9)
                            return
                        }

                        sortedTasks[0].checkRuleInfo([.equal("CompileC"), .suffix("Lex.yy.o"), .suffix("Lex.yy.c"), .equal("normal"), .equal("x86_64"), .equal("c"), .any])

                        // Check the pair of sources with non-unique names.
                        let nonUniqueASource = Path(sortedTasks[1].ruleInfo[2]).basename
                        let nonUniqueBSource = Path(sortedTasks[2].ruleInfo[2]).basename
                        let nonUniqueAObject = sortedTasks[1].ruleInfo[1]
                        let nonUniqueBObject = sortedTasks[2].ruleInfo[1]
                        #expect(Set<String>([nonUniqueASource, nonUniqueBSource]) == Set<String>(["NonUnique.m", "NonUnique.mm"]))
                        #expect(nonUniqueAObject != nonUniqueBObject)

                        sortedTasks[3].checkRuleInfo([.equal("CompileC"), .suffix("Script-Output-Custom-SourceFile.o"), .suffix("Script-Output-Custom-SourceFile.c"), .equal("normal"), .equal("x86_64"), .equal("c"), .any])
                        sortedTasks[4].checkRuleInfo([.equal("CompileC"), .suffix("Script-Output-Standard-SourceFile.o"), .suffix("Script-Output-Standard-SourceFile.c"), .equal("normal"), .equal("x86_64"), .equal("c"), .any])
                        sortedTasks[5].checkRuleInfo([.equal("CompileC"), .suffix("SourceFile-Matched-Included.o"), .suffix("SourceFile-Matched-Included.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                        sortedTasks[6].checkRuleInfo([.equal("CompileC"), .suffix("SourceFile.o"), .suffix("SourceFile.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                        sortedTasks[7].checkRuleInfo([.equal("CompileC"), .suffix("SourceFile_MRR.o"), .suffix("SourceFile_MRR.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                        sortedTasks[8].checkRuleInfo([.equal("CompileC"), .suffix("y.tab.o"), .suffix("y.tab.c"), .equal("normal"), .equal("x86_64"), .equal("c"), .any])
                    }

                    // Check that the expected separate headermaps are created.
                    results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("AppTarget-project-headers.hmap")) { _ in }
                    results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("AppTarget-generated-files.hmap")) { headermap in
                        headermap.checkEntry("AppTarget/Custom.fake-lang", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Custom.fake-lang")
                        headermap.checkEntry("AppTarget/Standard.fake-lang", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Standard.fake-lang")
                        headermap.checkEntry("AppTarget/Script-Output-Custom-SourceFile.c", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Script-Output-Custom-SourceFile.c")
                        headermap.checkEntry("AppTarget/Script-Output-Standard-SourceFile.c", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Script-Output-Standard-SourceFile.c")
                        headermap.checkEntry("AppTarget/foo-Custom.h", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo-Custom.h")
                        headermap.checkEntry("AppTarget/foo-Standard.h", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo-Standard.h")
                        headermap.checkEntry("AppTarget/foo.plist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo.plist")
                        headermap.checkEntry("AppTarget/y.tab.c", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/y.tab.c")
                        headermap.checkEntry("AppTarget/y.tab.h", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/y.tab.h")
                        headermap.checkEntry("Custom.fake-lang", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Custom.fake-lang")
                        headermap.checkEntry("Standard.fake-lang", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Standard.fake-lang")
                        headermap.checkEntry("Script-Output-Custom-SourceFile.c", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Script-Output-Custom-SourceFile.c")
                        headermap.checkEntry("Script-Output-Standard-SourceFile.c", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Script-Output-Standard-SourceFile.c")
                        headermap.checkEntry("foo-Custom.h", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo-Custom.h")
                        headermap.checkEntry("foo-Standard.h", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo-Standard.h")
                        headermap.checkEntry("foo.plist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo.plist")
                        headermap.checkEntry("y.tab.c", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/y.tab.c")
                        headermap.checkEntry("y.tab.h", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/y.tab.h")

                        headermap.checkNoEntries()
                    }
                    results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("AppTarget-own-target-headers.hmap")) { _ in }
                    results.checkHeadermapGenerationTask(.matchTarget(target), .matchRuleItemBasename("AppTarget-all-target-headers.hmap")) { _ in }

                    // There should be two CopyPlistFile tasks (from the script rule).
                    results.checkTask(.matchTarget(target), .matchRuleType("CopyPlistFile"), .matchRuleItemPattern(.suffix("en.lproj/foo.plist"))) { task in
                        task.checkRuleInfo(["CopyPlistFile", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/en.lproj/foo.plist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo.plist"])
                        task.checkCommandLine(["builtin-copyPlist", "--outdir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/en.lproj", "--", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo.plist"])

                        task.checkInputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo.plist"),
                            .namePattern(.prefix("target-")),
                            .namePattern(.prefix("target-")),
                            .name("WorkspaceHeaderMapVFSFilesWritten")])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/en.lproj/foo.plist"),])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("CopyPlistFile"), .matchRuleItemPattern(.suffix("foo.plist"))) { task in
                        task.checkRuleInfo(["CopyPlistFile", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/foo.plist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo.plist"])
                        task.checkCommandLine(["builtin-copyPlist", "--outdir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources", "--", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo.plist"])

                        task.checkInputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo.plist"),
                            .namePattern(.prefix("target-")),
                            .namePattern(.prefix("target-")),
                            .name("WorkspaceHeaderMapVFSFilesWritten")])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/foo.plist"),])
                    }

                    // There should be two RuleScriptExecution tasks.
                    results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("Custom.fake-lang")) { task in
                        task.checkRuleInfo(["RuleScriptExecution",  "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo-Custom.h", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Script-Output-Custom-SourceFile.c", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo.plist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Custom.fake-lang", "\(SRCROOT)/Sources/Custom.fake-lang", "normal", "x86_64"])
                        task.checkCommandLine(["/bin/sh", "-c", "echo hi"])

                        // Check that we pushed the script rule specific variables correctly.
                        task.checkEnvironment([
                            "INPUT_FILE_BASE": .equal("Custom"),
                            "INPUT_FILE_DIR": .equal("\(SRCROOT)/Sources"),
                            "INPUT_FILE_NAME": .equal("Custom.fake-lang"),
                            "INPUT_FILE_PATH": .equal("\(SRCROOT)/Sources/Custom.fake-lang"),
                            "INPUT_FILE_REGION_PATH_COMPONENT": .equal(""),
                            "INPUT_FILE_SUFFIX": .equal(".fake-lang"),
                            "SCRIPT_INPUT_FILE": .equal("\(SRCROOT)/Sources/Custom.fake-lang"),
                            "SCRIPT_INPUT_FILE_0": .equal("\(SRCROOT)/Sources/Project.fake-lang-settings"),
                            "SCRIPT_INPUT_FILE_1": .equal("\(SRCROOT)/Sources/Custom.fake-lang-settings"),
                            "SCRIPT_INPUT_FILE_COUNT": .equal("2"),
                            "SCRIPT_OUTPUT_FILE_0": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo-Custom.h"),
                            "SCRIPT_OUTPUT_FILE_1": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Script-Output-Custom-SourceFile.c"),
                            "SCRIPT_OUTPUT_FILE_2": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo.plist"),
                            "SCRIPT_OUTPUT_FILE_3": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Custom.fake-lang"),
                            "SCRIPT_OUTPUT_FILE_COUNT": .equal("4"),

                            "SYSTEM_APPS_DIR": .equal("/Applications"),
                            "OBJECT_FILE_DIR_normal": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal"),
                        ])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/Custom.fake-lang"),
                            .path("\(SRCROOT)/Sources/Project.fake-lang-settings"),
                            .path("\(SRCROOT)/Sources/Custom.fake-lang-settings"),
                            .namePattern(.prefix("target-")),
                            .namePattern(.prefix("target-")),
                            .name("WorkspaceHeaderMapVFSFilesWritten")])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo-Custom.h"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Script-Output-Custom-SourceFile.c"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/foo.plist"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/Custom.fake-lang")])
                    }

                    results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("Standard.fake-lang")) { task in
                        task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo-Standard.h", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Script-Output-Standard-SourceFile.c", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo.plist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Standard.fake-lang", "\(SRCROOT)/Sources/en.lproj/Standard.fake-lang", "normal", "x86_64"])
                        task.checkCommandLine(["/bin/sh", "-c", "echo hi"])

                        // Check that we pushed the script rule specific variables correctly.
                        task.checkEnvironment([
                            "INPUT_FILE_BASE": .equal("Standard"),
                            "INPUT_FILE_DIR": .equal("\(SRCROOT)/Sources/en.lproj"),
                            "INPUT_FILE_NAME": .equal("Standard.fake-lang"),
                            "INPUT_FILE_PATH": .equal("\(SRCROOT)/Sources/en.lproj/Standard.fake-lang"),
                            "INPUT_FILE_REGION_PATH_COMPONENT": .equal("en.lproj/"),
                            "INPUT_FILE_SUFFIX": .equal(".fake-lang"),
                            "OTHER_INPUT_FILE_FLAGS": .equal("-CoolStuff with\\ a\\ space\\! \(SRCROOT)"),
                            "SCRIPT_INPUT_FILE": .equal("\(SRCROOT)/Sources/en.lproj/Standard.fake-lang"),
                            "SCRIPT_INPUT_FILE_0": .equal("\(SRCROOT)/Sources/Project.fake-lang-settings"),
                            "SCRIPT_INPUT_FILE_1": .equal("\(SRCROOT)/Sources/en.lproj/Standard.fake-lang-settings"),
                            "SCRIPT_INPUT_FILE_COUNT": .equal("2"),
                            "SCRIPT_OUTPUT_FILE_0": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo-Standard.h"),
                            "SCRIPT_OUTPUT_FILE_1": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Script-Output-Standard-SourceFile.c"),
                            "SCRIPT_OUTPUT_FILE_2": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo.plist"),
                            "SCRIPT_OUTPUT_FILE_3": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Standard.fake-lang"),
                            "SCRIPT_OUTPUT_FILE_COUNT": .equal("4"),

                            "SYSTEM_APPS_DIR": .equal("/Applications"),
                            "OBJECT_FILE_DIR_normal": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal"),
                        ])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/en.lproj/Standard.fake-lang"),
                            .path("\(SRCROOT)/Sources/Project.fake-lang-settings"),
                            .path("\(SRCROOT)/Sources/en.lproj/Standard.fake-lang-settings"),
                            .namePattern(.prefix("target-")),
                            .namePattern(.prefix("target-")),
                            .name("WorkspaceHeaderMapVFSFilesWritten")])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo-Standard.h"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Script-Output-Standard-SourceFile.c"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo.plist"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/Standard.fake-lang")])
                    }

                    // There should be one file copy of the strings file.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/Sources/PlistFileToCopy.plist")) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/PlistFileToCopy.plist", "\(SRCROOT)/Sources/PlistFileToCopy.plist"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/PlistFileToCopy.plist"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase1-compile-sources"))),
                            .namePattern(.prefix("target-"))])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/PlistFileToCopy.plist"),
                            .name("Copy \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/PlistFileToCopy.plist"),
                        ])
                    }

                    // There should be one other file copy rule.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy")) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/FileToCopy.txt", "\(SRCROOT)/Sources/FileToCopy.txt"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/FileToCopy.txt"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase1-compile-sources"))),
                            .namePattern(.prefix("target-"))])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/FileToCopy.txt"),
                            .name("Copy \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/FileToCopy.txt"),
                        ])
                    }

                    // There should be one link task, and a task to generate its link file list.
                    results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList"])) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget", "normal"])
                        task.checkCommandLine(["clang++", "-Xlinker", "-reproducible", "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList", "-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_dependency_info.dat", "-fobjc-arc", "-fobjc-link-runtime", "-lstatic", "-ldynamic", "-framework", "Framework", "-framework", "AppCore", "-weak_framework", "AppExtensions", "-framework", "Framework-Matched-Included", "-o", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget"])

                        task.checkInputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/SourceFile.o"),
                            .any,
                            .any,
                            .any,
                            .any,
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/Lex.yy.o"),
                            .any,
                            .any,
                            .any,
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList"),
                            .path("\(SRCROOT)/build/Debug"),
                            .namePattern(.and(.prefix("target-"), .suffix("-generated-headers"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-swift-generated-headers"))),
                            .namePattern(.prefix("target-")),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget"),
                            .namePattern(.prefix("Linked Binary \(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS/AppTarget")),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_lto.o"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Objects-normal/x86_64/AppTarget_dependency_info.dat"),
                        ])
                    }

                    // There should be two CpHeader tasks.
                    results.checkTasks(.matchTarget(target), .matchRuleType("CpHeader"), body: { (tasks) -> Void in
                        let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                        #expect(sortedTasks.count == 2)

                        sortedTasks[0].checkRuleInfo(["CpHeader", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers/HeaderFile.fake-lang-header", "\(SRCROOT)/Sources/HeaderFile.fake-lang-header"])

                        sortedTasks[0].checkInputs([
                            .path("\(SRCROOT)/Sources/HeaderFile.fake-lang-header"),
                            .namePattern(.suffix("-immediate")),])

                        sortedTasks[0].checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers/HeaderFile.fake-lang-header"),])

                        sortedTasks[1].checkRuleInfo(["CpHeader", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers/HeaderFile.h", "\(SRCROOT)/Sources/HeaderFile.h"])

                        sortedTasks[1].checkInputs([
                            .path("\(SRCROOT)/Sources/HeaderFile.h"),
                            .namePattern(.suffix("-immediate")),])

                        sortedTasks[1].checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers/HeaderFile.h"),])
                    })

                    // There should be one strings file copy (from the resources phase).
                    results.checkTask(.matchTarget(target), .matchRuleType("CopyStringsFile")) { task in
                        task.checkRuleInfo(["CopyStringsFile", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/StringsResource.strings", "\(SRCROOT)/Sources/StringsResource.strings"])
                        task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outfilename", "StringsResource.strings", "--outdir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources", "--", "\(SRCROOT)/Sources/StringsResource.strings"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/StringsResource.strings"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase3-copy-files"))),
                            .namePattern(.prefix("target-")),])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/StringsResource.strings"),])
                    }

                    // There should be one copy-png operation (for the image that just has one resolution).
                    results.checkTask(.matchTarget(target), .matchRuleType("CopyPNGFile")) { task in
                        task.checkRuleInfo(["CopyPNGFile", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/SingleResImage.png", "\(SRCROOT)/Sources/SingleResImage.png"])
                        // FIXME: Obviously this command line is wrong...
                        task.checkCommandLine(["copypng", "\(SRCROOT)/Sources/SingleResImage.png", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/SingleResImage.png"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/SingleResImage.png"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase3-copy-files"))),
                            .namePattern(.prefix("target-"))])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/SingleResImage.png")])
                    }

                    // There should be one combine-images operation (for the 1x and 2x resolution images).
                    results.checkTask(.matchTarget(target), .matchRuleType("TiffUtil")) { task in
                        task.checkRuleInfo(["TiffUtil", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/Image.tiff"])
                        // FIXME: Obviously this command line is wrong...
                        task.checkCommandLine(["tiffutil", "-cathidpicheck", "\(SRCROOT)/Sources/Image@2x.png", "\(SRCROOT)/Sources/Image.png", "-out", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/Image.tiff"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/Image@2x.png"),
                            .path("\(SRCROOT)/Sources/Image.png"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase3-copy-files"))),
                            .namePattern(.prefix("target-")),])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/Image.tiff"),])
                    }
                    // There should be one CopyTiffFile operation (for the non-HiDPI image).
                    results.checkTask(.matchTarget(target), .matchRuleType("CopyTiffFile")) { task in
                        task.checkRuleInfo(["CopyTiffFile", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/SingleResTiffImage.tiff", "\(SRCROOT)/Sources/SingleResTiffImage.tiff"])
                        task.checkCommandLine(["builtin-copyTiff", "--outdir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources", "--", "\(SRCROOT)/Sources/SingleResTiffImage.tiff"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/SingleResTiffImage.tiff"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase3-copy-files"))),
                            .namePattern(.prefix("target-")),])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/SingleResTiffImage.tiff"),])
                    }

                    // There should be one ConvertIconsetFile task.
                    results.checkTask(.matchTarget(target), .matchRuleType("ConvertIconsetFile")) { task in
                        task.checkRuleInfo(["ConvertIconsetFile", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/MyIcons.icns", "\(SRCROOT)/Sources/MyIcons.iconset"])
                        task.checkCommandLine(["iconutil", "--convert", "icns", "--output", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/MyIcons.icns", "\(SRCROOT)/Sources/MyIcons.iconset"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/MyIcons.iconset"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase3-copy-files"))),
                            .namePattern(.prefix("target-")),])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources/MyIcons.icns"),])
                    }

                    // There should be a PhaseScriptExecution operation with no outputs, and a WriteAuxiliaryFile task to generate its contents.
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Foo With Spaces.sh")) { task, contents, permissions in
                        task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Foo With Spaces.sh"])

                        task.checkInputs([
                            .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Foo With Spaces.sh"),])

                        #expect(contents == (OutputByteStream()
                                             <<< "#!/bin/super-fancy-shell AppTarget\n"
                                             <<< "echo \"Running script\"\n"
                                             <<< "exit 0\n").bytes)
                        #expect(permissions == 0o755)

                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Foo With Spaces.sh")) { task in
                        task.checkRuleInfo(["PhaseScriptExecution", "Run Script", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Foo With Spaces.sh"])
                        task.checkCommandLine(["/bin/sh", "-c", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Foo\\ With\\ Spaces.sh"])

                        task.checkInputs([
                            // Check that we normalized the path passed to the script.
                            .path("\(SRCROOT)/Sources/Script-Input-File.txt"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Foo With Spaces.sh"),
                            .namePattern(.suffix("-phase4-copy-bundle-resources")),
                            .namePattern(.prefix("target-")),
                        ])
                        task.checkOutputs([
                            // Verify the command has a virtual output node that can be used as a dependency.
                            .namePattern(.prefix("execute-shell-script-")),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/super-fancy-shell.d")
                        ])

                        // Validate that the task has a reasonable environment.
                        // This check is used both to verify behaviors specific to this test, and also important behaviors which apply to all scripts which we want to ensure are tested.
                        var scriptVariables: [String: StringPattern?] = [
                            "ACTION": .equal("build"),
                            "TARGET_NAME": .equal("AppTarget"),
                            "SCRIPT_INPUT_FILE_0": .equal("\(SRCROOT)/Sources/Script-Input-File.txt"),
                            // The empty string here is expected, Xcode doesn't filter out empty input strings, but does take care not to convert them to paths into the SRCROOT.
                            "SCRIPT_INPUT_FILE_1": .equal(""),
                            "SCRIPT_INPUT_FILE_COUNT": .equal("2"),
                            "SCRIPT_OUTPUT_FILE_COUNT": .equal("0"),
                            "TOOLCHAIN_DIR": .equal("\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain"),
                        ]
                        // Validate that MACOSX_DEPLOYMENT_TARGET is present in the environment, but deployment targets for other platforms are not.
                        scriptVariables["MACOSX_DEPLOYMENT_TARGET"] = StringPattern.equal(MACOSX_DEPLOYMENT_TARGET)
                        for platform in core.platformRegistry.platforms {
                            if let otherPlatformDeploymentTargetName = platform.deploymentTargetMacro?.name {
                                if otherPlatformDeploymentTargetName != "MACOSX_DEPLOYMENT_TARGET" {
                                    scriptVariables[otherPlatformDeploymentTargetName] = .none      // Set the value to nil, don't remove the entry
                                }
                            }
                        }
                        // Make sure that we're *not* exporting any macCatalyst-related build settings in the environment.
                        scriptVariables.addContents(of: [
                            "IS_MACCATALYST": .equal("NO"),
                        ])

                        task.checkEnvironment(scriptVariables)
                        task.checkDependencyData(
                            .makefile(Path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/super-fancy-shell.d")))

                    }

                    // There should be a shell script phase with an output, too.
                    results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-ScriptWithOutput.sh")) { task in
                        task.checkEnvironment([
                            "SCRIPT_INPUT_FILE_COUNT": .equal("0"),
                            "SCRIPT_OUTPUT_FILE_COUNT": .equal("1"),
                            "SCRIPT_OUTPUT_FILE_0": .equal("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Output-File.txt"),
                        ])
                    }

                    // There should be a PhaseScriptExecution operation to copy a .dat file, and a WriteAuxiliaryFile task to generate its contents.
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Bar.sh")) { task, contents in
                        task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Bar.sh"])

                        task.checkInputs([
                            .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Bar.sh"),])

                        #expect(contents == "#!/bin/sh\ncp \"${INPUT_FILE_0}\" \"${OUTPUT_FILE_0}\"\nexit 0\n")
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Bar.sh")) { task in
                        task.checkRuleInfo(["PhaseScriptExecution", "Copy Stuff", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Bar.sh"])

                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/Stuff.dat"),
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/Script-Bar.sh"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase6-run-script"))),
                            .namePattern(.prefix("target-")),])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/DerivedSources/Stuff.dat"),])
                    }

                    // There shouldn't be a PhaseScriptExecution for the install script.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("Install Script"))

                    // There shouldn't be any 'Strip' tasks.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Strip"))

                    // There should be no chown / chmod tasks.
                    results.checkNoTask(.matchRuleType("SetOwnerAndGroup"))
                    results.checkNoTask(.matchRuleType("SetOwner"))
                    results.checkNoTask(.matchRuleType("SetGroup"))
                    results.checkNoTask(.matchRuleType("SetMode"))

                    // There should be the expected mkdir tasks for the app.
                    results.checkTask(.matchRule(["MkDir", "\(SRCROOT)/build/Debug/AppTarget.app"])) { task in
                        task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppTarget.app"])
                    }
                    results.checkTask(.matchRule(["MkDir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents"])) { task in
                        task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppTarget.app/Contents"])
                    }
                    results.checkTask(.matchRule(["MkDir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks"])) { task in
                        task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks"])
                    }
                    results.checkTask(.matchRule(["MkDir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers"])) { task in
                        task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Headers"])
                    }
                    results.checkTask(.matchRule(["MkDir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS"])) { task in
                        task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/MacOS"])
                    }
                    results.checkTask(.matchRule(["MkDir", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources"])) { task in
                        task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Resources"])
                    }
                    results.checkNoTask(.matchRule(["MkDir"]))

                    // There should be a 'Touch' task.
                    results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug/AppTarget.app"])) { _ in }

                    // There should be an 'RegisterWithLaunchServices' task.
                    results.checkTask(.matchTarget(target), .matchRuleType("RegisterWithLaunchServices")) { task in
                        task.checkRuleInfo(["RegisterWithLaunchServices", "\(SRCROOT)/build/Debug/AppTarget.app"])
                    }
                }

                results.checkTarget("AppCore") { target in
                    // There should be the expected mkdir tasks for the framework.
                    results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { (tasks) -> Void in
                        let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                        #expect(sortedTasks.count == 5)
                        sortedTasks[0].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCore.framework")])
                        sortedTasks[1].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCore.framework/Versions")])
                        sortedTasks[2].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCore.framework/Versions/A")])
                        sortedTasks[3].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Headers")])
                        if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value {
                            sortedTasks[4].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Resources")])
                        }

                        // Validate we also construct command lines.
                        sortedTasks[0].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCore.framework"])
                        sortedTasks[1].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCore.framework/Versions"])
                        sortedTasks[2].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCore.framework/Versions/A"])
                        sortedTasks[3].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Headers"])
                        if SWBFeatureFlag.enableDefaultInfoPlistTemplateKeys.value {
                            sortedTasks[4].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Resources"])
                        }
                    })

                    // And a CpHeader task.
                    results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Headers/AppCore.h", "\(SRCROOT)/Sources/AppCore.h"])) { task in
                        task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/Sources/AppCore.h", "\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Headers"])
                    }

                    // We should be generating the module map file.
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/AppCore.build/module.modulemap")) { task, contents in
                        task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/AppCore.build/module.modulemap"])

                        task.checkInputs([
                            .namePattern(.and(.prefix("target-"), .suffix("-immediate"))),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppCore.build/module.modulemap")])

                        #expect(contents == "framework module AppCore {\n  umbrella header \"AppCore.h\"\n  export *\n\n  module * { export * }\n}\n")
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Modules/module.modulemap")) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Debug/AppCore.build/module.modulemap"])

                        task.checkInputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppCore.build/module.modulemap"),
                            .namePattern(.prefix("target-AppCore")),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Modules/module.modulemap")])
                    }

                    // We should be copying the private module map file.
                    results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/aProject.build/Debug/AppCore.build/module.private.modulemap", "\(SRCROOT)/AppCore-Private.modulemap"])) { task in
                        task.checkInputs([
                            .path("\(SRCROOT)/AppCore-Private.modulemap"),
                            .namePattern(.prefix("target-AppCore")),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppCore.build/module.private.modulemap")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Modules/module.private.modulemap")) { task in
                        task.checkRuleInfo(["Copy", "\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Modules/module.private.modulemap", "\(SRCROOT)/build/aProject.build/Debug/AppCore.build/module.private.modulemap"])

                        task.checkInputs([
                            .path("\(SRCROOT)/build/aProject.build/Debug/AppCore.build/module.private.modulemap"),
                            .namePattern(.prefix("target-AppCore")),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppCore.framework/Versions/A/Modules/module.private.modulemap")])
                    }
                }

                // Check there are no other targets.
                #expect(results.otherTargets == [])
            }

            try localFS.createDirectory(Path(SRCROOT).join("Sources/FWToCopy.framework/Versions/A"), recursive: true)
            try localFS.symlink(Path(SRCROOT).join("Sources/FWToCopy.framework/Versions/Current"), target: Path("A"))
            try localFS.write(Path(SRCROOT).join("Sources/FWToCopy.framework/Versions/A/FWToCopy"), contents: "binary")
            try await localFS.writePlist(Path(SRCROOT).join("Entitlements.plist"), .plDict([:]))

            // Check an install release build.
            try await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS, fs: localFS) { results -> Void in
                try results.checkTarget("AppTarget") { target -> Void in
                    // There should be a symlink task.
                    try results.checkTask(.matchTarget(target), .matchRuleType("SymLink")) { task in
                        let path = try AbsolutePath.init(validating: "/tmp/aProject.dst/Applications/AppTarget.app").relative(to: AbsolutePath(validating: "\(SRCROOT)/build/Release"))
                        task.checkRuleInfo(["SymLink", "\(SRCROOT)/build/Release/AppTarget.app", path.path.str])
                    }

                    // Check the copy tasks.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/Sources/AlternatePermissions.txt")) { task in
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AlternatePermissions.txt"),
                            .name("Copy /tmp/aProject.dst/Applications/AlternatePermissions.txt"),
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/Sources/FWToCopy.framework")) { task in
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A/FWToCopy"),
                            .name("Copy /tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework"),
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/Sources/FileToCopy.txt")) { task in
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FileToCopy.txt"),
                            .name("Copy /tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FileToCopy.txt"),
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/Sources/FileToCopyOnlyDeploy.txt")) { task in
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FileToCopyOnlyDeploy.txt"),
                            .name("Copy /tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FileToCopyOnlyDeploy.txt"),
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/Sources/PlistFileToCopy.plist")) { task in
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/PlistFileToCopy.plist"),
                            .name("Copy /tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/PlistFileToCopy.plist"),
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/Sources/libdynamic.dylib")) { task in
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/libdynamic.dylib"),
                            .name("Copy /tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/libdynamic.dylib"),
                        ])
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"))

                    // There should be one master object link task.
                    results.checkTask(.matchTarget(target), .matchRuleType("MasterObjectLink")) { task in
                        task.checkRuleInfo(["MasterObjectLink", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/AppTarget-x86_64-master.o"])
                        let nonUniqueObjs = task.commandLineAsStrings.filter { $0.contains("NonUnique") }
                        if nonUniqueObjs.count != 2 {
                            #expect(nonUniqueObjs.count == 2)
                            return
                        }

                        #expect(nonUniqueObjs[0] != nonUniqueObjs[1])
                        task.checkCommandLineMatches([StringPattern.suffix("ld"), "-r", "-arch", "x86_64", "-syslibroot", .equal(core.loadSDK(.macOS).path.str), .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/SourceFile.o"), .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/SourceFile-Matched-Excluded.o"), .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/SourceFile-Matched-Included.o"), .equal(nonUniqueObjs[0]), .equal(nonUniqueObjs[1]), .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/SourceFile_MRR.o"), .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/Lex.yy.o"), .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/y.tab.o"), .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/Script-Output-Custom-SourceFile.o"), .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/Script-Output-Standard-SourceFile.o"), "-o", .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/AppTarget-x86_64-master.o")])

                        task.checkInputs([
                            .path("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/SourceFile.o"),
                            .any,
                            .any,
                            .any,
                            .any,
                            .path("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/SourceFile_MRR.o"),
                            .path("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/Lex.yy.o"),
                            .any,
                            .any,
                            .any,
                            // Note that there is no link file list.
                            .namePattern(.and(.prefix("target-"), .suffix("-generated-headers"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-swift-generated-headers"))),
                            .namePattern(.prefix("target-")),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/AppTarget-x86_64-master.o"),])

                    }

                    // There should be one link task, and a task to generate its link file list.
                    results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList"])) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/MacOS/AppTarget", "normal"])
                    }

                    // There should be two CpHeader tasks.
                    results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/Headers/HeaderFile.fake-lang-header", "\(SRCROOT)/Sources/HeaderFile.fake-lang-header"])) { task in
                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/HeaderFile.fake-lang-header"),
                            .namePattern(.suffix("-immediate"))
                        ])
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Headers/HeaderFile.fake-lang-header")
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/Headers/HeaderFile.h", "\(SRCROOT)/Sources/HeaderFile.h"])) { task in
                        task.checkInputs([
                            .path("\(SRCROOT)/Sources/HeaderFile.h"),
                            .namePattern(.suffix("-immediate")),
                        ])
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Headers/HeaderFile.h")
                        ])
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CpHeader"))

                    // There *should* be a PhaseScriptExecution for the install script.
                    results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("Install Script")) { task in }

                    // There should be one dSYM task (and associated Touch).
                    var dsymutilTask: (any PlannedTask)? = nil
                    results.checkTask(.matchTarget(target), .matchRuleType("GenerateDSYMFile")) { task in
                        task.checkRuleInfo(["GenerateDSYMFile", "\(SRCROOT)/build/Release/AppTarget.app.dSYM", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/MacOS/AppTarget"])
                        results.checkTaskFollows(task, .matchRule(["ProcessInfoPlistFile", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/Info.plist", "\(SRCROOT)/Sources/Info.plist"]))
                        dsymutilTask = task
                    }

                    // There should be a chown and chmod task.
                    results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { task in
                        task.checkRuleInfo(["SetOwnerAndGroup", "exampleUser:exampleGroup", "/tmp/aProject.dst/Applications/AppTarget.app"])
                        task.checkCommandLine(["/usr/sbin/chown", "-RH", "exampleUser:exampleGroup", "/tmp/aProject.dst/Applications/AppTarget.app"])

                        task.checkInputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app"),
                            .namePattern(.and(.prefix("target-"), .suffix("-Barrier-StripSymbols"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                            // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                            .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                        ])

                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app"),
                            .name("SetOwner /tmp/aProject.dst/Applications/AppTarget.app")])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { task in
                        task.checkRuleInfo(["SetMode", "u+w,go-w,a+rX", "/tmp/aProject.dst/Applications/AppTarget.app"])
                        task.checkCommandLine(["/bin/chmod", "-RH", "u+w,go-w,a+rX", "/tmp/aProject.dst/Applications/AppTarget.app"])

                        task.checkInputs([
                            // Set mode artificially orders itself relative to the chown task.
                            .path("/tmp/aProject.dst/Applications/AppTarget.app"),
                            .name("SetOwner /tmp/aProject.dst/Applications/AppTarget.app"),
                            .namePattern(.and(.prefix("target-"), .suffix("-Barrier-StripSymbols"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                            // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                            .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                        ])

                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app"),
                            .name("SetMode /tmp/aProject.dst/Applications/AppTarget.app")])
                    }

                    // There should be a chown task targeting the file in the the ALTERNATE_PERMISSIONS_FILES build setting.
                    results.checkTask(.matchTarget(target), .matchRuleType("SetOwner")) { task in
                        task.checkRuleInfo(["SetOwner", "fooOwner", "/tmp/aProject.dst/Applications/AlternatePermissions.txt"])
                        task.checkCommandLine(["/usr/sbin/chown", "-RH", "fooOwner", "/tmp/aProject.dst/Applications/AlternatePermissions.txt"])

                        task.checkInputs([
                            .path("/tmp/aProject.dst/Applications/AlternatePermissions.txt"),
                            .namePattern(.and(.prefix("target-"), .suffix("-Barrier-ChangePermissions"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                            // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                            .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                        ])

                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AlternatePermissions.txt"),
                            .name("SetOwner /tmp/aProject.dst/Applications/AlternatePermissions.txt")])
                    }

                    // There shouldn't be any copy tasks.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"))

                    // There should be a strip of the binary.
                    results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { task in
                        task.checkRuleInfo(["Strip", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/MacOS/AppTarget"])
                        task.checkCommandLineMatches([StringPattern.suffix("strip"), "-D", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/MacOS/AppTarget"])

                        task.checkInputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/MacOS/AppTarget"),
                            .name("GenerateDSYMFile \(SRCROOT)/build/Release/AppTarget.app.dSYM/Contents/Resources/DWARF/AppTarget"),
                            .namePattern(.and(.prefix("target-"), .suffix("-Barrier-CopyAside"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                            // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                            .namePattern(.and(.prefix("target-"), .suffix("-entry")))])

                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/MacOS/AppTarget"),
                            .name("Strip /tmp/aProject.dst/Applications/AppTarget.app/Contents/MacOS/AppTarget")])

                        // Make sure the strip task is ordered after the dsymutil task.
                        if let dsymutilTask {
                            results.checkTaskFollows(task, antecedent: dsymutilTask)
                        }
                    }

                    // There should be one product packaging task (for the entitlements file).
                    results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging")) { task in
                        task.checkRuleInfo(["ProcessProductPackaging", "\(SRCROOT)/Entitlements.plist", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/AppTarget.app.xcent"])
                        task.checkCommandLine(["builtin-productPackagingUtility", "\(SRCROOT)/Entitlements.plist", "-entitlements", "-format", "xml", "-o", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/AppTarget.app.xcent"])

                        task.checkAdditionalOutput([
                            "Entitlements:",
                            "",
                            "{\n    \"application-identifier\" = \"F154D0C.com.apple.dt.AppTarget\";\n    \"com.apple.developer.team-identifier\" = F154D0C;\n    \"get-task-allow\" = 1;\n    \"keychain-access-groups\" =     (\n        \"F154D0C.com.apple.dt.AppTarget\"\n    );\n}",
                        ])

                        #expect(task.inputs.contains{ $0.path.str == "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources/Entitlements.plist" })

                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/AppTarget.app.xcent"),])
                    }

                    // There should be three codesign tasks (one for the copied FW, one for the copied dylib, one for the app), two of which should be re-signing tasks.
                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A"])) { task in
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", "--generate-entitlement-der", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A"])
                        task.checkInputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A"),
                            .name("Copy /tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A/FWToCopy"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase2-copy-files"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                        ])
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A/FWToCopy"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A/_CodeSignature"),
                            .name("CodeSign /tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/FWToCopy.framework/Versions/A"),
                        ])

                        task.checkAdditionalOutput([
                            "Signing Identity:     \"-\"",
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/libdynamic.dylib"])) { task in
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", "--generate-entitlement-der", "/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/libdynamic.dylib"])
                        task.checkInputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/libdynamic.dylib"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/libdynamic.dylib"),
                            .name("Copy /tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/libdynamic.dylib"),
                            .namePattern(.and(.prefix("target-"), .suffix("-phase2-copy-files"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-entry")))
                        ])
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/libdynamic.dylib"),
                            .name("CodeSign /tmp/aProject.dst/Applications/AppTarget.app/Contents/Frameworks/libdynamic.dylib"),
                        ])

                        task.checkAdditionalOutput([
                            "Signing Identity:     \"-\"",
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Applications/AppTarget.app"])) { task in
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/AppTarget.app.xcent", "--generate-entitlement-der", "/tmp/aProject.dst/Applications/AppTarget.app"])
                        task.checkInputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app"),
                            .path("\(SRCROOT)/Sources/FWToCopy.framework"),
                            .path("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/AppTarget.app.xcent"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/Info.plist"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/MacOS/AppTarget"),
                            .namePattern(.and(.prefix("target-"), .suffix("-Barrier-ChangeAlternatePermissions"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                        ])
                        task.checkOutputs([
                            .path("/tmp/aProject.dst/Applications/AppTarget.app"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/Contents/MacOS/AppTarget"),
                            .path("/tmp/aProject.dst/Applications/AppTarget.app/_CodeSignature"),
                            .name("CodeSign /tmp/aProject.dst/Applications/AppTarget.app"),
                        ])

                        task.checkAdditionalOutput([
                            "Signing Identity:     \"-\"",
                        ])
                    }
                    results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"))

                    // There should be one product touch task.
                    results.checkTask(.matchTarget(target), .matchRule(["Touch", "/tmp/aProject.dst/Applications/AppTarget.app"])) { _ in }
                }

                results.checkTarget("AppCore") { _ in }

                // Check there are no other targets.
                #expect(results.otherTargets == [])

                // no match since a rule producing an output of the same type it accepts would be infinitely recursive
                results.checkWarning(.equal("no rule to process file '\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)/Custom.fake-lang' of type 'file' for architecture '\(results.runDestinationTargetArchitecture)' (in target 'AppTarget' from project 'aProject')"))
                results.checkWarning(.equal("no rule to process file '\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)/en.lproj/Standard.fake-lang' of type 'file' for architecture '\(results.runDestinationTargetArchitecture)' (in target 'AppTarget' from project 'aProject')"))
            }

            // Check additional behaviors for an install release build.
            do {
                let parameters = BuildParameters(action: .install, configuration: "Release", overrides: [
                    "RETAIN_RAW_BINARIES": "YES",
                ])
                await tester.checkBuild(parameters, runDestination: .macOS, fs: localFS) {
                    results in
                    results.checkTarget("AppTarget") { target in
                        // Check that there is a "copy aside" task.
                        results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/AppTarget.app", "/tmp/aProject.dst/Applications/AppTarget.app"])) { _ in }
                    }

                    // no match since a rule producing an output of the same type it accepts would be infinitely recursive
                    results.checkWarning(.equal("no rule to process file '\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)/Custom.fake-lang' of type 'file' for architecture '\(results.runDestinationTargetArchitecture)' (in target 'AppTarget' from project 'aProject')"))
                    results.checkWarning(.equal("no rule to process file '\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)/en.lproj/Standard.fake-lang' of type 'file' for architecture '\(results.runDestinationTargetArchitecture)' (in target 'AppTarget' from project 'aProject')"))
                }
            }

            // Check behavior of APPLY_RULES_IN_COPY_FILES setting.
            do {
                let parameters = BuildParameters(configuration: "Release", overrides: [
                    "APPLY_RULES_IN_COPY_FILES": "YES",
                ])
                await tester.checkBuild(parameters, runDestination: .macOS, fs: localFS) {
                    results in
                    results.checkTarget("AppTarget") { target in
                        // There should be only one Copy.
                        results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/Sources/FileToCopy.txt")) { task in }

                        // There should be two plist copy (one for the plist in the phase, one for the shell script rule).
                        results.checkTasks(.matchTarget(target), .matchRuleType("CopyPlistFile")) { tasks in
                            let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                            #expect(sortedTasks.count == 3)
                            sortedTasks[0].checkRuleInfo(["CopyPlistFile", "\(SRCROOT)/build/Release/AppTarget.app/Contents/Frameworks/PlistFileToCopy.plist", "\(SRCROOT)/Sources/PlistFileToCopy.plist"])
                            sortedTasks[1].checkRuleInfo(["CopyPlistFile", "\(SRCROOT)/build/Release/AppTarget.app/Contents/Resources/en.lproj/foo.plist", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/x86_64/en.lproj/foo.plist"])
                            sortedTasks[2].checkRuleInfo(["CopyPlistFile", "\(SRCROOT)/build/Release/AppTarget.app/Contents/Resources/foo.plist", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/x86_64/foo.plist"])
                        }
                    }

                    // no match since a rule producing an output of the same type it accepts would be infinitely recursive
                    results.checkWarning(.equal("no rule to process file '\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)/Custom.fake-lang' of type 'file' for architecture '\(results.runDestinationTargetArchitecture)' (in target 'AppTarget' from project 'aProject')"))
                    results.checkWarning(.equal("no rule to process file '\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)/en.lproj/Standard.fake-lang' of type 'file' for architecture '\(results.runDestinationTargetArchitecture)' (in target 'AppTarget' from project 'aProject')"))
                }
            }

            // Check behavior of APPLY_RULES_IN_COPY_HEADERS setting.
            do {
                let parameters = BuildParameters(configuration: "Release", overrides: [
                    "APPLY_RULES_IN_COPY_HEADERS": "YES",
                ])
                await tester.checkBuild(parameters, runDestination: .macOS, fs: localFS) {
                    results in
                    results.checkTarget("AppTarget") { target in
                        // There should be only one CpHeader.
                        results.checkTask(.matchTarget(target), .matchRuleType("CpHeader")) { task in
                            task.checkRuleInfo(["CpHeader", "\(SRCROOT)/build/Release/AppTarget.app/Contents/Headers/HeaderFile.h", "\(SRCROOT)/Sources/HeaderFile.h"])

                            task.checkInputs([
                                .path("\(SRCROOT)/Sources/HeaderFile.h"),
                                .namePattern(.suffix("-immediate")),])

                            task.checkOutputs([
                                .path("\(SRCROOT)/build/Release/AppTarget.app/Contents/Headers/HeaderFile.h"),])
                        }


                        results.checkTask(.matchTarget(target), .matchRuleType("RuleScriptExecution"), .matchRuleItemBasename("HeaderFile.fake-lang-header")) { task in
                            task.checkRuleInfo(["RuleScriptExecution", "\(SRCROOT)/build/Release/AppTarget.app/Contents/Headers/HeaderFile.fake-lang-header", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources/HeaderFile.fake-lang-header.d", "\(SRCROOT)/Sources/HeaderFile.fake-lang-header", "normal", "undefined_arch"])

                            // Check that we pushed the script rule specific variables correctly.
                            task.checkEnvironment([
                                "INPUT_FILE_BASE": .equal("HeaderFile"),
                                "INPUT_FILE_DIR": .equal("\(SRCROOT)/Sources"),
                                "INPUT_FILE_NAME": .equal("HeaderFile.fake-lang-header"),
                                "INPUT_FILE_PATH": .equal("\(SRCROOT)/Sources/HeaderFile.fake-lang-header"),
                                "INPUT_FILE_REGION_PATH_COMPONENT": .equal(""),
                                "INPUT_FILE_SUFFIX": .equal(".fake-lang-header"),
                                "SCRIPT_HEADER_VISIBILITY": .equal("public"),
                                "HEADER_OUTPUT_DIR": .equal("\(SRCROOT)/build/Release/AppTarget.app/Contents/Headers"),
                                "SCRIPT_INPUT_FILE": .equal("\(SRCROOT)/Sources/HeaderFile.fake-lang-header"),
                                "SCRIPT_OUTPUT_FILE_0": .equal("\(SRCROOT)/build/Release/AppTarget.app/Contents/Headers/HeaderFile.fake-lang-header"),
                                "SCRIPT_OUTPUT_FILE_COUNT": .equal("1"),

                                "SYSTEM_APPS_DIR": .equal("/Applications"),
                                "OBJECT_FILE_DIR_normal": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal"),
                            ])

                            task.checkInputs([
                                .path("\(SRCROOT)/Sources/HeaderFile.fake-lang-header"),
                                .namePattern(.prefix("target-"))])
                            task.checkOutputs([
                                .path("\(SRCROOT)/build/Release/AppTarget.app/Contents/Headers/HeaderFile.fake-lang-header"),
                                .path("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources/HeaderFile.fake-lang-header.d")])
                            task.checkDependencyData(
                                .makefile(Path("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources/HeaderFile.fake-lang-header.d")))
                        }
                    }

                    // no match since a rule producing an output of the same type it accepts would be infinitely recursive
                    results.checkWarning(.equal("no rule to process file '\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)/Custom.fake-lang' of type 'file' for architecture '\(results.runDestinationTargetArchitecture)' (in target 'AppTarget' from project 'aProject')"))
                    results.checkWarning(.equal("no rule to process file '\(SRCROOT)/build/aProject.build/Release/AppTarget.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)/en.lproj/Standard.fake-lang' of type 'file' for architecture '\(results.runDestinationTargetArchitecture)' (in target 'AppTarget' from project 'aProject')"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func frameworkBasics() async throws {
        // Test the basics of task construction for a framework.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceOne.m"),
                    TestFile("SourceTwo.m"),
                    TestFile("ProjectHeaderFile.h"),
                    TestFile("PrivateHeaderFile.h"),
                    TestFile("PublicHeaderFile.h"),
                    TestFile("FrameworkTarget.h"),
                    TestFile("StringsResource.strings"),
                    TestFile("libstatic.a"),
                    TestFile("libdynamic.dylib"),
                    TestFile("MyInfo.plist"),
                    TestFile("Exports.exp"),
                    TestFile("Unexports.exp"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "DEFINES_MODULE": "YES",

                    ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "DEFINES_MODULE": "YES",
                    "CODE_SIGN_IDENTITY": "-",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "EXPORTED_SYMBOLS_FILE": "Exports.exp",
                    "UNEXPORTED_SYMBOLS_FILE": "Unexports.exp",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "FrameworkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                        TestBuildConfiguration("Release", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                            "SourceTwo.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                            TestBuildFile("PublicHeaderFile.h", headerVisibility: .public),
                            TestBuildFile("PrivateHeaderFile.h", headerVisibility: .private),
                            TestBuildFile("ProjectHeaderFile.h"),   // visibility: project
                        ]),
                        TestResourcesBuildPhase([
                            "StringsResource.strings",
                        ]),
                        TestFrameworksBuildPhase([
                            "libstatic.a",
                            "libdynamic.dylib",
                        ])
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let MACOSX_DEPLOYMENT_TARGET = core.loadSDK(.macOS).defaultDeploymentTarget

        // Check the debug build.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("FrameworkTarget") { target in
                // There should be an Info.plist processing task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkRuleInfo(["ProcessInfoPlistFile", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Resources/Info.plist", "\(SRCROOT)/MyInfo.plist"])
                }

                // Check the CompileC tasks.
                let compileTasks = results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) { tasks -> [any PlannedTask] in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    #expect(sortedTasks.count == 2)
                    sortedTasks[safe: 0]?.checkRuleInfo([.equal("CompileC"), .suffix("SourceOne.o"), .suffix("SourceOne.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                    sortedTasks[safe: 1]?.checkRuleInfo([.equal("CompileC"), .suffix("SourceTwo.o"), .suffix("SourceTwo.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                    return sortedTasks
                }

                // There should be one link task, and a task to generate its link file list.
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget.LinkFileList"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/FrameworkTarget", "normal"])
                    task.checkCommandLine([
                        ["clang"],
                        ["-Xlinker", "-reproducible"],
                        ["-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)"],
                        ["-dynamiclib", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget.LinkFileList", "-install_name", "/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget"],
                        ["-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget_lto.o", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget_dependency_info.dat", "-fobjc-link-runtime", "-lstatic", "-ldynamic", "-Xlinker", "-no_adhoc_codesign", "-o", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/FrameworkTarget"]
                    ].reduce([], +))
                }

                // There should be three CpHeader tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/PrivateHeaders/PrivateHeaderFile.h", "\(SRCROOT)/PrivateHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PrivateHeaderFile.h", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/PrivateHeaders"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Headers/PublicHeaderFile.h", "\(SRCROOT)/PublicHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PublicHeaderFile.h", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Headers"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Headers/FrameworkTarget.h", "\(SRCROOT)/FrameworkTarget.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/FrameworkTarget.h", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Headers"])
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpHeader"))

                // There should be one strings file copy (from the resources phase).
                results.checkTask(.matchTarget(target), .matchRuleType("CopyStringsFile")) { task in
                    task.checkRuleInfo(["CopyStringsFile", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Resources/StringsResource.strings", "\(SRCROOT)/StringsResource.strings"])
                }

                // We should be generating the module map file.
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build/module.modulemap"])) { moduleMapTask in
                    for task in compileTasks {
                        results.checkTaskDependsOn(task, antecedent: moduleMapTask)
                    }
                }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Debug/FrameworkTarget.build/module.modulemap"])) { moduleMapTask in
                    for task in compileTasks {
                        results.checkTaskDependsOn(task, antecedent: moduleMapTask)
                    }
                }

                // There shouldn't be any 'Strip' tasks.
                results.checkNoTask(.matchTarget(target), .matchRuleType("Strip"))

                // There should be no chown / chmod tasks.
                results.checkNoTask(.matchRuleType("SetOwnerAndGroup"))
                results.checkNoTask(.matchRuleType("SetOwner"))
                results.checkNoTask(.matchRuleType("SetGroup"))
                results.checkNoTask(.matchRuleType("SetMode"))

                // There should be the expected mkdir tasks for the framework.
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/FrameworkTarget.framework"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/FrameworkTarget.framework"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Headers"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Headers"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/PrivateHeaders"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/PrivateHeaders"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Resources"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/A/Resources"])
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("MkDir"))

                // There should be the expected symlink creation tasks for the framework.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/FrameworkTarget", "Versions/Current/FrameworkTarget"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/FrameworkTarget", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/FrameworkTarget"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Headers", "Versions/Current/Headers"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/Headers", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Headers"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Modules", "Versions/Current/Modules"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/Modules", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Modules"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/PrivateHeaders", "Versions/Current/PrivateHeaders"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/PrivateHeaders", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/PrivateHeaders"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Resources", "Versions/Current/Resources"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/Resources", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Resources"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/Current", "A"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "A", "\(SRCROOT)/build/Debug/FrameworkTarget.framework/Versions/Current"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/EagerLinkingTBDs/Debug/FrameworkTarget.framework/FrameworkTarget.tbd", "/tmp/Test/aProject/build/EagerLinkingTBDs/Debug/FrameworkTarget.framework/Versions/A/FrameworkTarget.tbd"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "/tmp/Test/aProject/build/EagerLinkingTBDs/Debug/FrameworkTarget.framework/Versions/A/FrameworkTarget.tbd", "/tmp/Test/aProject/build/EagerLinkingTBDs/Debug/FrameworkTarget.framework/FrameworkTarget.tbd"])
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("SymLink"))

                // There should be a 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "\(SRCROOT)/build/Debug/FrameworkTarget.framework"])) { _ in }
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }

        // Check an install release build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS) { results in
            results.checkTarget("FrameworkTarget") { target in
                // There should be an Info.plist processing task.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    task.checkRuleInfo(["ProcessInfoPlistFile", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Resources/Info.plist", "\(SRCROOT)/MyInfo.plist"])
                }

                // Check the CompileC tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("CompileC")) { tasks in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    #expect(sortedTasks.count == 2)
                    sortedTasks[safe: 0]?.checkRuleInfo([.equal("CompileC"), .suffix("SourceOne.o"), .suffix("SourceOne.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                    sortedTasks[safe: 1]?.checkRuleInfo([.equal("CompileC"), .suffix("SourceTwo.o"), .suffix("SourceTwo.m"), .equal("normal"), .equal("x86_64"), .equal("objective-c"), .any])
                }

                // There should be one link task, and a task to generate its link file list.
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget.LinkFileList"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkRuleInfo(["Ld", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget", "normal"])
                    task.checkCommandLine([
                        ["clang"],
                        ["-Xlinker", "-reproducible"],
                        ["-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)"],
                        ["-dynamiclib", "-isysroot", core.loadSDK(.macOS).path.str, "-Os", "-L\(SRCROOT)/build/EagerLinkingTBDs/Release", "-L\(SRCROOT)/build/Release", "-F\(SRCROOT)/build/EagerLinkingTBDs/Release", "-F\(SRCROOT)/build/Release", "-filelist", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget.LinkFileList", "-exported_symbols_list", "Exports.exp", "-unexported_symbols_list", "Unexports.exp", "-install_name", "/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget"],
                        ["-Xlinker", "-object_path_lto", "-Xlinker", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget_lto.o", "-Xlinker", "-final_output", "-Xlinker", "/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget", "-Xlinker", "-dependency_info", "-Xlinker", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget_dependency_info.dat", "-fobjc-link-runtime", "-lstatic", "-ldynamic", "-Xlinker", "-no_adhoc_codesign", "-o", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget"]
                    ].reduce([], +))

                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/SourceOne.o"),
                        .path("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/SourceTwo.o"),
                        .path("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget.LinkFileList"),
                        .path("\(SRCROOT)/Exports.exp"),
                        .path("\(SRCROOT)/Unexports.exp"),
                        .path("\(SRCROOT)/build/Release"),
                        .namePattern(.and(.prefix("target-"), .suffix("-generated-headers"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-swift-generated-headers"))),
                        .namePattern(.prefix("target-")),
                        .namePattern(.prefix("target-")),
                    ])
                    task.checkOutputs([
                        .path("/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget"),
                        .name("Linked Binary /tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget"),
                        .path("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget_lto.o"),
                        .path("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/FrameworkTarget_dependency_info.dat"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { task in
                    task.checkCommandLine(["tapi", "stubify", "-isysroot", core.loadSDK(.macOS).path.str, "-F/tmp/Test/aProject/build/Release", "-L/tmp/Test/aProject/build/Release", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget", "-o", "/tmp/Test/aProject/build/EagerLinkingTBDs/Release/FrameworkTarget.framework/Versions/A/FrameworkTarget.tbd"])
                }

                // There should be three CpHeader tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders/PrivateHeaderFile.h", "\(SRCROOT)/PrivateHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PrivateHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/PublicHeaderFile.h", "\(SRCROOT)/PublicHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PublicHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/FrameworkTarget.h", "\(SRCROOT)/FrameworkTarget.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/FrameworkTarget.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CpHeader"))

                // There should be one strings file copy (from the resources phase).
                results.checkTask(.matchTarget(target), .matchRuleType("CopyStringsFile")) { task in
                    task.checkRuleInfo(["CopyStringsFile", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Resources/StringsResource.strings", "\(SRCROOT)/StringsResource.strings"])
                }

                // There should be a chown and chmod task.
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { task in
                    task.checkRuleInfo(["SetOwnerAndGroup", "exampleUser:exampleGroup", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { task in
                    task.checkRuleInfo(["SetMode", "u+w,go-w,a+rX", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])
                }

                // We should be generating the module map file.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap"])) { _ in }

                // There should be a strip of the binary.
                results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { task in
                    task.checkRuleInfo(["Strip", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget"])
                }

                // There should be one codesign task.
                // But no product packaging tasks, because frameworks don't need entitlements.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    #expect(task.ruleInfo[1] == "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A")
                }


                // There should be the expected mkdir tasks for the framework.
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Resources"])) { task in
                    task.checkCommandLine(["/bin/mkdir", "-p", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Resources"])
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("MkDir"))

                // There should be the expected symlink creation tasks for the framework.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Release/FrameworkTarget.framework", "../../../../aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "../../../../aProject.dst/Library/Frameworks/FrameworkTarget.framework", "\(SRCROOT)/build/Release/FrameworkTarget.framework"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/FrameworkTarget", "Versions/Current/FrameworkTarget"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/FrameworkTarget", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/FrameworkTarget"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Headers", "Versions/Current/Headers"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/Headers", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Headers"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Modules", "Versions/Current/Modules"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/Modules", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Modules"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/PrivateHeaders", "Versions/Current/PrivateHeaders"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/PrivateHeaders", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/PrivateHeaders"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Resources", "Versions/Current/Resources"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "Versions/Current/Resources", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Resources"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/Current", "A"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "A", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/Current"])
                }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/EagerLinkingTBDs/Release/FrameworkTarget.framework/FrameworkTarget.tbd", "/tmp/Test/aProject/build/EagerLinkingTBDs/Release/FrameworkTarget.framework/Versions/A/FrameworkTarget.tbd"])) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "/tmp/Test/aProject/build/EagerLinkingTBDs/Release/FrameworkTarget.framework/Versions/A/FrameworkTarget.tbd", "/tmp/Test/aProject/build/EagerLinkingTBDs/Release/FrameworkTarget.framework/FrameworkTarget.tbd"])
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("SymLink"))

                // There should be a 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }


                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }

    @Test(.requireSDKs(.host))
    func toolBasics() async throws {
        // Test the basics of task construction for a command line tool which uses a static library.
        let runDestination: RunDestinationInfo = .host
        let libtoolPath = try await runDestination == .windows ? self.llvmlibPath : self.libtoolPath
        let versioningSupported: Bool = runDestination == .windows ? false : true

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("SupportSourceFile.m"),
                    TestFile("PerArchFile.m"),
                    TestFile("Prefix.pch"),
                    TestFile("Tool.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "LIBTOOL": libtoolPath.str,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "GCC_PREFIX_HEADER": "Prefix.pch",
                    "CLANG_USE_RESPONSE_FILE": "NO",]),
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
                    "INFOPLIST_FILE": "Tool.plist",
                    "INFOPLIST_PREPROCESS": "YES",
                    "CLANG_USE_RESPONSE_FILE": "NO",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile.m",
                            TestBuildFile("PerArchFile.m", additionalArgs: ["-D", "check-that-we-can-reference-a-$(CURRENT_ARCH)-macro"]),
                        ]),
                    ],
                    dependencies: ["Support"]
                ),
                TestStandardTarget(
                    "Support",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: versioningSupported ? ["VERSIONING_SYSTEM": "apple-generic", "CURRENT_PROJECT_VERSION": "3.1"] : [:]),
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SupportSourceFile.m"]),
                    ]
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let MACOSX_DEPLOYMENT_TARGET = runDestination == .macOS ? core.loadSDK(.macOS).defaultDeploymentTarget : ""

        // MacOS is the only platform where we can create universal binaries
        let architectures = runDestination == .macOS ?  ["arm64", "x86_64"] : [runDestination.targetArchitecture]

        // Check the debug build.
        let overrides = [
            "ARCHS": architectures.joined(separator: " "),
        ]

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: overrides), runDestination: runDestination == .macOS ? .anyMac: .host) { results in
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Gate", "MkDir", "Touch", "RegisterExecutionPolicyException"])
            results.checkTarget("Tool") { target in
                let effectivePlatformName = results.builtProductsDirSuffix(target)
                let targetBuildDir = Path("\(SRCROOT)/build/Debug\(effectivePlatformName)")
                let targetObjectsPerArchBuildBaseDir = Path("\(SRCROOT)/build/aProject.build/Debug\(effectivePlatformName)/Tool.build/Objects-normal/")
                architectures.forEach { arch in

                    let targetObjectsPerArchBuildDir = targetObjectsPerArchBuildBaseDir.join(arch)

                    // Expected tasks to compile SourceFile.m.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("SourceFile.m"), .matchRuleItem(arch)) { _ in }
                    // Check the PerArchFile compilation tasks, to make sure the expected additional option is being passed.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("PerArchFile.m"), .matchRuleItem(arch)) { task in
                        task.checkCommandLineContainsUninterrupted(["-D", "check-that-we-can-reference-a-\(arch)-macro"])
                    }
                    // There should be link tasks (one per arch), and tasks to generate their link file lists.
                    results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile",
                                                                        targetObjectsPerArchBuildDir.join("Tool.LinkFileList").str])) { _ in }

                    results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem(architectures.count > 1 ? arch: "normal")) { task in
                        if architectures.count > 1 {
                            task.checkRuleInfo(["Ld", targetObjectsPerArchBuildDir.join("Binary/Tool").str, "normal", arch])
                        } else {
                            task.checkRuleInfo(["Ld", targetBuildDir.join("Tool\(runDestination == .windows ? ".exe" : "")").str, "normal"])
                        }
                    }
                }


                if architectures.count > 1 {
                    // There should be one lipo task if there are multiple architectures
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkRuleInfo(["CreateUniversalBinary", targetBuildDir.join("Tool").str, "normal", architectures.joined(separator: " ")])
                        task.checkCommandLine(["lipo",
                                               "-create",
                                               targetObjectsPerArchBuildBaseDir.join("\(architectures[0])/Binary/Tool").str,
                                               targetObjectsPerArchBuildBaseDir.join("\(architectures[1])/Binary/Tool").str,
                                               "-output",
                                               targetBuildDir.join("Tool").str])

                        task.checkInputs([
                            .path(targetObjectsPerArchBuildBaseDir.join("\(architectures[0])/Binary/Tool").str),
                            .path(targetObjectsPerArchBuildBaseDir.join("\(architectures[1])/Binary/Tool").str),
                            .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))])

                        task.checkOutputs([
                            .path(targetBuildDir.join("Tool").str),
                            .name("Linked Binary \(targetBuildDir.join("Tool").str)")
                        ])
                    }
                }

                // Consume headermap generation tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".hmap"))) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".yaml"))) { _ in }

                // Consume metadata dependency generate task.
                results.checkTasks(.matchTarget(target),.matchRuleType("WriteAuxiliaryFile"),.matchRuleItemPattern(.suffix(".DependencyMetadataFileList"))) { _ in }
                results.checkTasks(.matchTarget(target),.matchRuleType("WriteAuxiliaryFile"),.matchRuleItemPattern(.suffix(".DependencyStaticMetadataFileList"))) { _ in }

                // There shouldn't be any other tasks.
                results.checkNoTask(.matchTarget(target))
            }

            results.checkTarget("Support") { target in
                let effectivePlatformName = results.builtProductsDirSuffix(target)
                let targetBuildDir = Path("\(SRCROOT)/build/Debug\(effectivePlatformName)")
                let targetObjectsPerArchBuildBaseDir = Path("\(SRCROOT)/build/aProject.build/Debug\(effectivePlatformName)/Support.build/Objects-normal/")
                let libSupportFileName = runDestination == .windows ? "Support.lib" : "libSupport.a"

                if versioningSupported {
                    results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Support_vers.c")) { _ in }
                }

                architectures.forEach { arch in
                    let targetObjectsPerArchBuildDir = targetObjectsPerArchBuildBaseDir.join(arch)

                    if versioningSupported {
                        results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("Support_vers.c"), .matchRuleItem(arch)) { task in
                            // Verify we don't use the PCH in the versioning stub.
                            let includeArgs = task.commandLine.filter({ $0 == "-include" })
                            #expect(includeArgs == [])
                        }
                    }
                    // Expected compile tasks for the other source file.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("SupportSourceFile.m"), .matchRuleItem(arch)) { task in
                        // Verify we *do* have a PCH use here (to ensure negative check above is testing the right thing.
                        let includeArgs = task.commandLine.filter({ $0 == "-include" })
                        #expect(includeArgs == ["-include"])
                    }


                    // There should be a libtool task (one per arch), with a link file list written for each.
                    results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", targetObjectsPerArchBuildDir.join("Support.LinkFileList").str])) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Libtool"), .matchRuleItem(architectures.count > 1 ? arch : "normal")) { task in

                        if architectures.count > 1 {
                            task.checkRuleInfo(["Libtool", targetObjectsPerArchBuildDir.join("Binary/\(libSupportFileName)").str, "normal", arch])
                        } else {
                            task.checkRuleInfo(["Libtool", targetBuildDir.join(libSupportFileName).str, "normal"])
                        }
                        switch runDestination {
                        case .macOS:
                            task.checkCommandLine([libtoolPath.str, "-static", "-arch_only", arch, "-D", "-syslibroot", core.loadSDK(.macOS).path.str,
                                                   "-L\(SRCROOT)/build/Debug", "-filelist", targetObjectsPerArchBuildDir.join("Support.LinkFileList").str,
                                                   "-dependency_info", targetObjectsPerArchBuildDir.join("Support_libtool_dependency_info.dat").str,
                                                   "-o", targetObjectsPerArchBuildDir.join("Binary/\(libSupportFileName)").str
                                                  ])
                        case .linux:
                            task.checkCommandLine(["llvm-ar", "rcs", targetBuildDir.join(libSupportFileName).str, "@\(targetObjectsPerArchBuildDir.join("Support.LinkFileList").str)"])
                        case .windows:
                            task.checkCommandLine(["llvm-lib.exe",
                                                   "/out:\(architectures.count > 1 ? targetObjectsPerArchBuildDir.join("Binary/\(libSupportFileName)").str : targetBuildDir.join(libSupportFileName).str)",
                                                   "@\(targetObjectsPerArchBuildDir.join("Support.LinkFileList").str)"])
                        default:
                            #expect(Bool(false), "Unsupported destination: \(runDestination)")
                        }

                        // Check input files
                        let inputFiles: [NodePattern] = [
                            .path(targetObjectsPerArchBuildDir.join("Support_vers.o").str),
                            .path(targetObjectsPerArchBuildDir.join("SupportSourceFile.o").str),
                            .path(targetObjectsPerArchBuildDir.join("Support.LinkFileList").str),
                            .namePattern(.and(.prefix("target-"), .suffix("Producer"))),
                            .namePattern(.prefix("target-"))
                        ]
                        task.checkInputs(versioningSupported ? inputFiles: Array(inputFiles[1...]))

                        if runDestination == .macOS {
                            task.checkOutputs([
                                .path(architectures.count > 1 ? targetObjectsPerArchBuildDir.join("Binary/\(libSupportFileName)").str : targetBuildDir.join(libSupportFileName).str),
                                .path(targetObjectsPerArchBuildDir.join("Support_libtool_dependency_info.dat").str)
                            ])
                            task.checkEnvironment([
                                "MACOSX_DEPLOYMENT_TARGET": .equal(MACOSX_DEPLOYMENT_TARGET),
                            ], exact: true)
                        } else {
                            // There are two outputs, a PathNode and a VirtualNode on non-mac platforms
                            task.checkOutputs([
                                .path(architectures.count > 1 ? targetObjectsPerArchBuildDir.join("Binary/\(libSupportFileName)").str : targetBuildDir.join(libSupportFileName).str),
                                .namePattern(.prefix("Linked Binary \(architectures.count > 1 ? targetObjectsPerArchBuildDir.join("Binary/\(libSupportFileName)").str : targetBuildDir.join(libSupportFileName).str)")),
                            ])
                        }
                    }
                }


                if architectures.count > 1 {
                    // There should be one libtool task to create the universal binary.
                    results.checkTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary")) { task in
                        task.checkRuleInfo(["CreateUniversalBinary", targetBuildDir.join(libSupportFileName).str, "normal", "arm64 x86_64"])
                        task.checkCommandLineMatches([.suffix("lipo"),
                                                      "-create",
                                                      .equal(targetObjectsPerArchBuildBaseDir.join("arm64/Binary/\(libSupportFileName)").str),
                                                      .equal(targetObjectsPerArchBuildBaseDir.join("x86_64/Binary/\(libSupportFileName)").str),
                                                      "-output",
                                                      .equal(targetBuildDir.join(libSupportFileName).str)
                                                     ])
                    }
                }

                // Consume headermap generation tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".hmap"))) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".yaml"))) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".DependencyMetadataFileList"))) { _ in }
                results.checkTasks(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(".DependencyStaticMetadataFileList"))) { _ in }

                // There shouldn't be any other tasks.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There should be no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install release build, with signing enabled.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .host) { results in
            results.checkTarget("Tool") { target in
                let effectivePlatformName = results.builtProductsDirSuffix(target)
                let targetBuildDir = Path("\(SRCROOT)/build/Release\(effectivePlatformName)")
                let targetPerArchBuildBaseDir = Path("\(SRCROOT)/build/aProject.build/Release\(effectivePlatformName)/Tool.build/normal/")
                let targetObjectsPerArchBuildBaseDir = Path("\(SRCROOT)/build/aProject.build/Release\(effectivePlatformName)/Tool.build/Objects-normal/")


                if runDestination != .windows {
                    // There should be a symlink task.
                    results.checkTask(.matchTarget(target), .matchRuleType("SymLink")) { task in
                        task.checkRuleInfo(["SymLink", targetBuildDir.join("Tool").str, "../../../../aProject.dst/usr/local/bin/Tool"])
                        switch runDestination {
                        case .macOS, .linux:
                            task.checkCommandLine(["/bin/ln", "-sfh", "../../../../aProject.dst/usr/local/bin/Tool", targetBuildDir.join("Tool").str])
                        case .windows:
                            task.checkCommandLine(["/bin/ln", "-sfh", "../../../../aProject.dst/usr/local/bin/Tool", targetBuildDir.join("Tool").str])
                        default:
                            #expect(Bool(false), "Unsupported destination: \(runDestination)")
                        }
                        // Validate that the symlink task doesn't pretend the contents are an input.
                        task.checkInputs([
                            .namePattern(.prefix("target-")),
                            .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])
                    }
                }

                if runDestination == .macOS {
                    // There should be an Info.plist processing task, and associated Preprocess (we explicitly enable it).
                    results.checkTask(.matchTarget(target), .matchRuleType("Preprocess")) { task in
                        task.checkRuleInfo(["Preprocess", targetPerArchBuildBaseDir.join("x86_64/Preprocessed-Info.plist").str, "\(SRCROOT)/Tool.plist"])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                        task.checkRuleInfo(["ProcessInfoPlistFile", targetObjectsPerArchBuildBaseDir.join("x86_64/Processed-Info.plist").str, targetPerArchBuildBaseDir.join("x86_64/Preprocessed-Info.plist").str])
                        task.checkCommandLine(["builtin-infoPlistUtility", targetPerArchBuildBaseDir.join("x86_64/Preprocessed-Info.plist").str, "-producttype", "com.apple.product-type.tool", "-expandbuildsettings", "-platform", "macosx", "-o", targetObjectsPerArchBuildBaseDir.join("x86_64/Processed-Info.plist").str])
                    }

                    // There should be a link task which incorporates the Info.plist file, and a task to generate its link file list.
                    results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", targetObjectsPerArchBuildBaseDir.join("x86_64/Tool.LinkFileList").str])) { _ in }
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "/tmp/aProject.dst/usr/local/bin/Tool", "normal"])
                        task.checkCommandLineContainsUninterrupted(["-sectcreate", "__TEXT", "__info_plist", targetObjectsPerArchBuildBaseDir.join("x86_64/Processed-Info.plist").str])
                        task.checkInputs(contain: [
                            .path(targetObjectsPerArchBuildBaseDir.join("x86_64/SourceFile.o").str),
                            .path(targetObjectsPerArchBuildBaseDir.join("x86_64/PerArchFile.o").str),
                            .path(targetObjectsPerArchBuildBaseDir.join("x86_64/Tool.LinkFileList").str),
                            .path(targetObjectsPerArchBuildBaseDir.join("x86_64/Processed-Info.plist").str),
                        ])
                    }

                    // There should be one codesign task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                        XCTAssertMatch(task.ruleInfo[1], .suffix("/tmp/aProject.dst/usr/local/bin/Tool"))
                    }
                }
            }
            results.checkTarget("Support") { target in
                // There should be no codesign task (disabled by product type).
                results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test building an app target which depends on and embeds the products of framework, XPC services and application extension targets.
    @Test(.requireSDKs(.macOS))
    func extensionTargetBasics() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("AppSource.m"),
                    TestFile("FwkSource.m"),
                    TestFile("XPCSource.m"),
                    TestFile("AppExSource.m"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration( "Debug", buildSettings: [
                    "INFOPLIST_FILE": "Info.plist",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "INFOPLIST_FILE": "Sources/Info.plist",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AppSource.m",
                        ]),
                        TestFrameworksBuildPhase([]),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("FwkTarget.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                        // The destination here matches how the "XPCServices" popup in the build phase UI populates it.  See <rdar://problem/15366863>
                        TestCopyFilesBuildPhase([
                            TestBuildFile("Serviceable.xpc", codeSignOnCopy: true),
                        ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/XPCServices", onlyForDeployment: false),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("Extending.appex", codeSignOnCopy: true),
                        ], destinationSubfolder: .plugins, onlyForDeployment: false),
                    ],
                    dependencies: ["FwkTarget", "Serviceable", "Extending"]
                ),
                TestStandardTarget(
                    "FwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            // This is a somewhat-common model of specifying the dylib install name for a framework.
                            "DYLIB_INSTALL_NAME_BASE": "@executable_path/../Frameworks",
                            "LD_DYLIB_INSTALL_NAME": "$(DYLIB_INSTALL_NAME_BASE:standardizepath)/$(EXECUTABLE_PATH)",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "FwkSource.m",
                        ]),
                        TestFrameworksBuildPhase([]),
                    ]
                ),
                TestStandardTarget(
                    "Serviceable",
                    type: .xpcService,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "XPCSource.m",
                        ]),
                        TestFrameworksBuildPhase([]),
                    ]
                ),
                TestStandardTarget(
                    "Extending",
                    type: .applicationExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AppExSource.m",
                        ]),
                        TestFrameworksBuildPhase([]),
                    ]
                ),
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("Info.plist"), contents: "<dict/>")

        // Check the debug build.
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkTarget("FwkTarget") { target in
                // The linker task should have the expected value for -install_path.
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("\(SRCROOT)/build/Debug/FwkTarget.framework/Versions/A/FwkTarget")) { task in
                    task.checkCommandLineContains(["-install_name", "@executable_path/../Frameworks/FwkTarget.framework/Versions/A/FwkTarget"])
                }
                // There should be one codesign task.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/FwkTarget.framework/Versions/A")) { task in
                }
            }
            results.checkTarget("Serviceable") { target in
                // There should be one codesign task.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/Serviceable.xpc")) { task in
                }
            }
            results.checkTarget("Extending") { target in
                // There should be one codesign task.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/Extending.appex")) { task in
                }
            }
            results.checkTarget("AppTarget") { target in
                // For the framework, there should be a copy task, and a signing task.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/FwkTarget.framework"), .matchRuleItem("\(SRCROOT)/build/Debug/FwkTarget.framework")) { task in
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/FwkTarget.framework/Versions/A")) { task in
                }

                // For the XPC service, there should be a copy task, and no signing task.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/XPCServices/Serviceable.xpc"), .matchRuleItem("\(SRCROOT)/build/Debug/Serviceable.xpc")) { task in
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/XPCServices/Serviceable.xpc"))

                // For the appex, there should be a copy task, no signing task, and a validation task.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/Extending.appex"), .matchRuleItem("\(SRCROOT)/build/Debug/Extending.appex")) { task in
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/Extending.appex"))

                results.checkTask(.matchTarget(target), .matchRuleType("ValidateEmbeddedBinary"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/Extending.appex")) { task in
                    // Check that ValidateEmbeddedBinary depends on the containing app's CodeSign task
                    results.checkTaskFollows(task, [.matchRule(["CodeSign", "\(SRCROOT)/build/Debug/AppTarget.app"])])
                }

                // There should be a codesign task for the app.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app")) { task in
                    // Check that the containing app's CodeSign task does NOT depend on the ValidateEmbeddedBinary task
                    results.checkTaskDoesNotFollow(task, [.matchRule(["ValidateEmbeddedBinary", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/Extending.appex"])])
                }

                // There should be no more codesign or validate tasks for the app target.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("ValidateEmbeddedBinary"))
            }

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows, "not yet working"))
    func emptyTarget() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles"),
            buildConfigurations: [TestBuildConfiguration("Release")],
            targets: [
                TestStandardTarget("EmptyTool",
                                   type: .commandLineTool,
                                   buildConfigurations: [TestBuildConfiguration("Release")],
                                   buildPhases: [])
            ])

        let parameters = BuildParameters(action: .install, configuration: "Release", overrides: [
            "RETAIN_RAW_BINARIES": "YES",
            "INSTALL_USER": "root",
        ])
        let runDestination = RunDestinationInfo.host
        try await TaskConstructionTester(getCore(), testProject).checkBuild(parameters, runDestination: runDestination) { results in
            // There should be no tasks.
            //
            // FIXME: This isn't true yet, we test for the absence of particular tasks.
            results.checkNoTask(.matchRuleType("Copy"))
            results.checkNoTask(.matchRuleType("Strip"))
            results.checkNoTask(.matchRuleType("SetOwnerAndGroup"))
            results.checkNoTask(.matchRuleType("SetOwner"))
            results.checkNoTask(.matchRuleType("SetGroup"))
            results.checkNoTask(.matchRuleType("SetMode"))

            // Make sure that the target start gate task and the target end gate task are connected.  This link is needed for targets which don't run any tasks (e.g., aggregate targets) in order to preserve dependencies among targets.
            results.checkTasks(.matchRuleType("Gate")) { tasks in
                var targetEntryTask: (any PlannedTask)? = nil
                var targetExitTask: (any PlannedTask)? = nil
                for task in tasks {
                    if task.ruleInfo.count > 1 {
                        let gateName = task.ruleInfo[1]

                        // Target start task
                        if gateName.hasPrefix("target-") && gateName.hasSuffix("-entry") {
                            targetEntryTask = task
                        }

                        // Target end task
                        if gateName.hasPrefix("target-") && gateName.hasSuffix("-end") {
                            targetExitTask = task
                        }
                    }
                }
                #expect(targetEntryTask != nil)
                if let task = targetEntryTask {
                    if results.buildRequest.enableStaleFileRemoval {
                        task.checkInputs([
                            .namePattern(.and(.prefix("target-"), .suffix("-stale-file-removal"))),
                            .namePattern(.prefix("CreateBuildDirectory-/tmp/aProject.dst")),
                            .namePattern(.prefix("CreateBuildDirectory-/tmp/Test/aProject/build")),
                            .namePattern(.prefix("CreateBuildDirectory-/tmp/Test/aProject/build")),
                            .namePattern(.prefix("CreateBuildDirectory-/tmp/Test/aProject/build/Release\(runDestination.builtProductsDirSuffix)/BuiltProducts")),
                            .namePattern(.prefix("CreateBuildDirectory-/tmp/Test/aProject/build/EagerLinkingTBDs")),
                            .namePattern(.and(.prefix("target"), .suffix("-begin-compiling"))),
                        ])
                    } else {
                        task.checkInputs([
                            .namePattern(.prefix("CreateBuildDirectory-/tmp/aProject.dst")),
                            .namePattern(.prefix("CreateBuildDirectory-/tmp/Test/aProject/build")),
                            .namePattern(.prefix("CreateBuildDirectory-/tmp/Test/aProject/build")),
                            .namePattern(.prefix("CreateBuildDirectory-/tmp/Test/aProject/build/Release\(runDestination.builtProductsDirSuffix)/BuiltProducts")),
                            .namePattern(.and(.prefix("target"), .suffix("-begin-compiling"))),
                        ])
                    }
                    task.checkOutputs([
                        .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                    ])
                }
                #expect(targetExitTask != nil)
                if let task = targetExitTask {
                    task.checkInputs([
                        .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                    ])
                    task.checkOutputs([
                        .namePattern(.and(.prefix("target-"), .suffix("-end"))),
                    ])
                }
            }

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows, "not yet working"))
    func emptySourcesTarget() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles"),
            buildConfigurations: [TestBuildConfiguration("Release")],
            targets: [
                TestStandardTarget("EmptyTool",
                                   type: .commandLineTool,
                                   buildConfigurations: [TestBuildConfiguration("Release", buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "RETAIN_RAW_BINARIES": "YES",
                                    "CODE_SIGN_IDENTITY": "-",
                                   ])],
                                   buildPhases: [
                                    TestSourcesBuildPhase([]),
                                   ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let parameters = BuildParameters(action: .install, configuration: "Release", overrides: [
            "INSTALL_USER": "root",
        ])
        await tester.checkBuild(parameters, runDestination: .host) { results in
            // There should be no tasks other than gate and auxiliary file tasks (writing headermaps).
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            // FIXME: Right now, we have an extraneous ProcessProductPackaging task.
            results.checkTasks(.matchRuleType("ProcessProductPackaging")) { _ in }

            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows, "not yet working"))
    func copyFilesOnlyOnDeploymentTarget() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "ScriptsToInstall",
                children: [
                    TestFile("script.txt")
                ]
            ),
            buildConfigurations: [TestBuildConfiguration("Release")],
            targets: [
                TestStandardTarget("EmptyTool",
                                   type: .commandLineTool,
                                   buildConfigurations: [TestBuildConfiguration("Release", buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "RETAIN_RAW_BINARIES": "YES",
                                    "CODE_SIGN_IDENTITY": "-",
                                   ])],
                                   buildPhases: [
                                    TestCopyFilesBuildPhase([
                                        TestBuildFile("script.txt", codeSignOnCopy: true),
                                    ], destinationSubfolder: .plugins, onlyForDeployment: true),
                                   ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Test a regular build.  Since `only-for-deployment` is set, this should not result in any tasks.
        let buildParameters = BuildParameters(action: .build, configuration: "Debug", overrides: [:])
        await tester.checkBuild(buildParameters, runDestination: .host) { results in
            // We need to filter out boilerplate tasks such as `Gate` and `WriteAuxiliaryFile`, but there should be no others besides those.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            // FIXME: Right now, we have an extraneous ProcessProductPackaging task.
            results.checkTasks(.matchRuleType("ProcessProductPackaging")) { _ in }

            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Test an install.  In this case, we should end up with tasks to copy `script.txt` to the destination and to sign it.
        let installParameters = BuildParameters(action: .install, configuration: "Release", overrides: [
            "INSTALL_USER": "root",
        ])
        await tester.checkBuild(installParameters, runDestination: .host) { results in
            // We need to filter out boilerplate tasks such as `Gate` and `WriteAuxiliaryFile`.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            // Besides those, we should only have a task to copy the script file, another to generate a .xcent file, and another to sign the script file.
            results.checkTasks(.matchRuleType("Copy")) { _ in }
            results.checkTasks(.matchRuleType("ProcessProductPackaging")) { _ in }
            results.checkTasks(.matchRuleType("CodeSign")) { _ in }
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows, "not yet working"))
    func externalBuildTarget() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles"),
            buildConfigurations: [
                TestBuildConfiguration("Release"),
                TestBuildConfiguration("SkipInstall"),
            ],
            targets: [
                TestExternalTarget("External",
                                   toolPath: "fooBar",
                                   arguments: "this $(ACTION) and that",
                                   workingDirectory: "/tmp",
                                   buildConfigurations: [
                                    TestBuildConfiguration("Release"),
                                    TestBuildConfiguration("SkipInstall", buildSettings: [
                                        "SKIP_INSTALL": "YES",
                                    ]),
                                   ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        @PluginExtensionSystemActor func pluginSearchPaths() -> [Path] {
            core.pluginManager.extensions(of: SpecificationsExtensionPoint.self).flatMap { ext in
                ext.specificationSearchPaths(resourceSearchPaths: core.resourceSearchPaths).compactMap { try? $0.filePath }
            }.sorted()
        }

        let searchPaths = await pluginSearchPaths().map(\.str)

        let runDestination = RunDestinationInfo.host

        // Check a debug build.
        await tester.checkBuild(BuildParameters(configuration: "Release"), runDestination: runDestination, processEnvironment: ["PATH": "/usr/local/bin"]) { results in
            results.checkTarget("External") { target in
                // There should be one main task.
                results.checkTask(.matchRuleType("ExternalBuildToolExecution")) { task in
                    // FIXME: These paths are not right yet.
                    task.checkRuleInfo(["ExternalBuildToolExecution", "External"])
                    task.checkCommandLine(["fooBar", "this", "and", "that"])
                    #expect(task.workingDirectory == Path.root.join("tmp"))

                    let developerPath = core.developerPath

                    // Check interesting environment variables.
                    task.checkEnvironment([
                        "ACTION": .equal(""),                                       // No ACTION is passed for a 'build' action.
                        "TARGET_BUILD_DIR": .equal("\(SRCROOT)/build/Release\(runDestination.builtProductsDirSuffix)"),
                        "BUILT_PRODUCTS_DIR": .equal("\(SRCROOT)/build/Release\(runDestination.builtProductsDirSuffix)"),
                        // Check that we don't export SDK_VARIANT or macCatalyst settings.
                        "SDK_VARIANT": .none,
                        "IS_MACCATALYST": .none,
                    ])

                    let platformSearchPaths: [Path]
                    switch runDestination.platform {
                    case "macosx":
                        platformSearchPaths = [
                            developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/bin"),
                            developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/local/bin"),
                            developerPath.path.join("Toolchains/XcodeDefault.xctoolchain/usr/libexec"),
                            developerPath.path.join("Platforms/MacOSX.platform/usr/bin"),
                            developerPath.path.join("Platforms/MacOSX.platform/usr/local/bin"),
                            developerPath.path.join("Platforms/MacOSX.platform/Developer/usr/bin"),
                            developerPath.path.join("Platforms/MacOSX.platform/Developer/usr/local/bin"),
                        ]
                    default:
                        platformSearchPaths = []
                    }

                    for path in searchPaths + platformSearchPaths.map(\.str) + [
                        developerPath.path.join("usr/bin").str,
                        developerPath.path.join("usr/local/bin").str,
                        "/usr/local/bin"
                    ] {
                        #expect(task.environment.bindingsDictionary["PATH"]?.contains(path) == true, "PATH environment variable did not contain entry: \(path)")
                    }
                }

                // Ignore all Gate and build directory tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

                // There should be no other tasks.
                results.checkNoTask()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: runDestination) { results in
            results.checkTarget("External") { target in
                // There should be one main task.
                results.checkTask(.matchRuleType("ExternalBuildToolExecution")) { task in
                    // FIXME: These paths are not right yet.
                    task.checkRuleInfo(["ExternalBuildToolExecution", "External"])
                    task.checkCommandLine(["fooBar", "this", "install", "and", "that"])
                    #expect(task.workingDirectory == Path.root.join("tmp"))

                    // Check interesting environment variables.
                    task.checkEnvironment([
                        "ACTION": .equal("install"),
                        "TARGET_BUILD_DIR": .equal("/tmp/aProject.dst"),
                        "BUILT_PRODUCTS_DIR": .equal("\(SRCROOT)/build/Release\(runDestination.builtProductsDirSuffix)"),
                        // Check that we don't export SDK_VARIANT or macCatalyst settings.
                        "SDK_VARIANT": .none,
                        "IS_MACCATALYST": .none,
                    ])
                }

                // Ignore all Gate and build directory tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

                // There should be no other tasks.
                results.checkNoTask()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install build in which INSTALLED_PRODUCT_ASIDES is defined in the environment.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: runDestination, processEnvironment: ["INSTALLED_PRODUCT_ASIDES": "YES"]) { results in
            results.checkTarget("External") { target in
                // There should be one main task.
                results.checkTask(.matchRuleType("ExternalBuildToolExecution")) { task in
                    // FIXME: These paths are not right yet.
                    task.checkRuleInfo(["ExternalBuildToolExecution", "External"])
                    task.checkCommandLine(["fooBar", "this", "install", "and", "that"])
                    #expect(task.workingDirectory == Path.root.join("tmp"))

                    // Check interesting environment variables.
                    task.checkEnvironment([
                        "ACTION": .equal("install"),
                        "TARGET_BUILD_DIR": .equal("/tmp/aProject.dst"),
                        "BUILT_PRODUCTS_DIR": .equal("\(SRCROOT)/build/Release\(runDestination.builtProductsDirSuffix)/BuiltProducts"),
                    ])
                }

                // Ignore all Gate and build directory tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

                // There should be no other tasks.
                results.checkNoTask()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }

        // Check an install build in which SKIP_INSTALL is defined.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "SkipInstall"), runDestination: runDestination) { results in
            results.checkTarget("External") { target in
                // There should be one main task.
                results.checkTask(.matchRuleType("ExternalBuildToolExecution")) { task in
                    // FIXME: These paths are not right yet.
                    task.checkRuleInfo(["ExternalBuildToolExecution", "External"])
                    task.checkCommandLine(["fooBar", "this", "install", "and", "that"])
                    #expect(task.workingDirectory == Path.root.join("tmp"))

                    // Check interesting environment variables.
                    task.checkEnvironment([
                        "ACTION": .equal("install"),
                        "TARGET_BUILD_DIR": .equal("\(SRCROOT)/build/UninstalledProducts/\(runDestination.platform)"),
                        "BUILT_PRODUCTS_DIR": .equal("\(SRCROOT)/build/SkipInstall\(runDestination.builtProductsDirSuffix)"),
                    ])
                }

                // Ignore all Gate and build directory tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

                // There should be no other tasks.
                results.checkNoTask()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.host), .skipHostOS(.windows, "not yet working"))
    func externalBuildTargetDependencies() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.c")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release"),
            ],
            targets: [
                TestStandardTarget("EmptyTool",
                                   type: .commandLineTool,
                                   buildConfigurations: [TestBuildConfiguration("Release", buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "RETAIN_RAW_BINARIES": "YES",
                                    "CODE_SIGN_IDENTITY": "-",
                                   ])],
                                   buildPhases: [
                                    TestSourcesBuildPhase([TestBuildFile("main.c")])
                                   ],
                                   dependencies: ["External"]),
                TestExternalTarget("External",
                                   toolPath: "fooBar",
                                   arguments: "this $(ACTION) and that",
                                   workingDirectory: "/tmp",
                                   buildConfigurations: [
                                    TestBuildConfiguration("Release"),
                                   ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check a release build.
        await tester.checkBuild(BuildParameters(configuration: "Release"), runDestination: .host, processEnvironment: ["PATH": "/usr/local/bin"]) { results in
            results.checkTarget("EmptyTool") { target in
                // Check that the EmptyTool target depends on the ExternalBuildToolExecution.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { compileTask in
                    results.checkTarget("External") { externalTarget in
                        results.checkTaskFollows(compileTask, .matchTarget(externalTarget), .matchRuleType("ExternalBuildToolExecution"))
                    }
                }
            }

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, "mig is Apple-only"))
    func outputFileProcessing() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Interfaces.defs")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "MIG_EXEC": migPath.str,
                ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "MIG_EXEC": migPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("Interfaces.defs", migCodegenFiles: .both)]),
                    ]
                )
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check the debug build.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                // There should be one Mig task.
                results.checkTask(.matchTarget(target), .matchRuleType("Mig")) { task in
                    task.checkRuleInfo(["Mig", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/Interfaces.h", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/InterfacesUser.c", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/InterfacesServer.h", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/InterfacesServer.c", "\(SRCROOT)/Interfaces.defs", "normal", "x86_64"])

                    // Check that the outputs are correct.
                    XCTAssertMatch(task.outputs.map { $0.path.str }, [
                            .suffix("/Interfaces.h"),
                            .suffix("/InterfacesUser.c"),
                            .suffix("/InterfacesServer.h"),
                            .suffix("/InterfacesServer.c"),
                        ])
                }

                // There should be two compile of the Mig-generated client and server.
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/Objects-normal/x86_64/InterfacesServer.o", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/InterfacesServer.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/Objects-normal/x86_64/InterfacesUser.o", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/DerivedSources/x86_64/InterfacesUser.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in }
                results.checkNoTask(.matchRuleType("CompileC"))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, "multi-arch builds are Apple-specific"))
    func perArchIncludedSourceFileNames() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("foo_normal_x86_64.c"),
                    TestFile("foo_normal_x86_64h.c"),
                    TestFile("foo_normal_arm64.c"),
                    TestFile("foo_normal_arm64e.c"),
                    TestFile("foo_debug_x86_64.c"),
                    TestFile("foo_debug_x86_64h.c"),
                    TestFile("foo_debug_arm64.c"),
                    TestFile("foo_debug_arm64e.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "ARCHS": "x86_64 x86_64h arm64 arm64e",
                        "VALID_ARCHS": "x86_64 x86_64h arm64 arm64e",
                        "BUILD_VARIANTS": "normal debug",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "EXCLUDED_SOURCE_FILE_NAMES": "*",
                        "INCLUDED_SOURCE_FILE_NAMES": "foo_$(CURRENT_VARIANT)_$(CURRENT_ARCH).c",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "foo_normal_x86_64.c",
                            "foo_normal_x86_64h.c",
                            "foo_normal_arm64.c",
                            "foo_normal_arm64e.c",
                            "foo_debug_x86_64.c",
                            "foo_debug_x86_64h.c",
                            "foo_debug_arm64.c",
                            "foo_debug_arm64e.c",
                        ]),
                    ]
                ),
            ])
        try await TaskConstructionTester(getCore(), testProject).checkBuild(BuildParameters(configuration: "Debug"), runDestination: .anyMac, userPreferences: UserPreferences.defaultForTesting.with(enableDebugActivityLogs: true)) { results in
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo_normal_x86_64.c")) { _ in }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo_normal_x86_64h.c")) { _ in }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo_normal_arm64.c")) { _ in }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo_normal_arm64e.c")) { _ in }

            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo_debug_x86_64.c")) { _ in }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo_debug_x86_64h.c")) { _ in }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo_debug_arm64.c")) { _ in }
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("foo_debug_arm64e.c")) { _ in }

            results.checkNoTask(.matchRuleType("CompileC"))

            let allSources = Set([
                "foo_normal_x86_64.c",
                "foo_normal_x86_64h.c",
                "foo_normal_arm64.c",
                "foo_normal_arm64e.c",
                "foo_debug_x86_64.c",
                "foo_debug_x86_64h.c",
                "foo_debug_arm64.c",
                "foo_debug_arm64e.c",
            ])

            // Every source will be skipped...
            for skippedSource in allSources {
                // ...in the context of compiling each of the other sources
                for source in allSources.subtracting(Set([skippedSource])) {
                    results.checkNote(.equal("Skipping '/tmp/Test/aProject/\(skippedSource)' because it is excluded by EXCLUDED_SOURCE_FILE_NAMES pattern: *\nEXCLUDED_SOURCE_FILE_NAMES: *\nINCLUDED_SOURCE_FILE_NAMES: \(source) (in target 'AppTarget' from project 'aProject')"))
                }
            }

            // There shouldn't be any other diagnostics.
            results.checkNoDiagnostics()
        }
    }

    // Test vagaries of build variant handling.
    @Test(.requireSDKs(.macOS))
    func buildVariants() async throws {
        let variants = ["normal", "debug"]
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Foo.c"),
                    TestFile("FrameworkSource.swift"),
                    TestFile("AppSource.swift"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "BUILD_VARIANTS": variants.joined(separator: " "),
                    "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_IDENTITY": "-",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                ]),
            ],
            targets: [
                TestAggregateTarget(
                    "All",
                    dependencies: ["Tool", "Framework", "Application", "VersioningStubOnly", "NoSources"]
                ),
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Foo.c"]),
                        TestFrameworksBuildPhase(["Framework.framework"]),
                    ]
                ),
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["FrameworkSource.swift"]),
                    ]
                ),
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["AppSource.swift"]),
                    ]
                ),
                // Test a target with an empty sources build phase but which generates a versioning stub file.
                TestStandardTarget(
                    "VersioningStubOnly",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "VERSIONING_SYSTEM": "apple-generic",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                    ]
                ),
                // Test a target with no sources build phase.  There will still be a product since we'll be copying an Info.plist file into it.
                TestStandardTarget(
                    "NoSources",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check an install build to examine per-variant postprocessing steps.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS) { results in
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("Tool") { target in
                // There should be two strip tasks, one per variant.
                results.checkTasks(.matchTarget(target), .matchRuleType("Strip")) { tasks in
                    #expect(tasks.count == 2)
                }

                // There should be two codesign tasks, one per variant.
                results.checkTasks(.matchTarget(target), .matchRuleType("CodeSign")) { tasks in
                    #expect(tasks.count == 2)
                }

                // There should be two symlink tasks, one per variant.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Release/Tool", "../../../../aProject.dst/usr/local/bin/Tool"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Release/Tool_debug", "../../../../aProject.dst/usr/local/bin/Tool_debug"])) { _ in }

                results.checkTasks(.matchTarget(target)) { _ in }
            }

            results.checkTarget("Framework") { target in
                // There should be one task each for unvarianted content.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/Framework.framework/Versions/A/Modules/Framework.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Release/Framework.build/Objects-normal/x86_64/Framework.swiftmodule"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/Framework.framework/Versions/A/Modules/Framework.swiftmodule/x86_64-apple-macos.swiftmodule", "\(SRCROOT)/build/aProject.build/Release/Framework.build/Objects-debug/x86_64/Framework.swiftmodule"]))

                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/Framework.framework/Versions/A/Modules/Framework.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Release/Framework.build/Objects-normal/x86_64/Framework.swiftdoc"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/Framework.framework/Versions/A/Modules/Framework.swiftmodule/x86_64-apple-macos.swiftdoc", "\(SRCROOT)/build/aProject.build/Release/Framework.build/Objects-debug/x86_64/Framework.swiftdoc"]))

                results.checkTask(.matchTarget(target), .matchRule(["SwiftMergeGeneratedHeaders", "/tmp/aProject.dst/Library/Frameworks/Framework.framework/Versions/A/Headers/Framework-Swift.h", "\(SRCROOT)/build/aProject.build/Release/Framework.build/Objects-normal/x86_64/Framework-Swift.h"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Library/Frameworks/Framework.framework/Versions/A/Headers/Framework-Swift.h", "\(SRCROOT)/build/aProject.build/Release/Framework.build/Objects-debug/x86_64/Framework-Swift.h"]))

                // There should be two strip tasks, one per variant.
                results.checkTasks(.matchTarget(target), .matchRuleType("Strip")) { tasks in
                    #expect(tasks.count == 2)
                }

                // There should be two codesign tasks, one per variant.  The binary for the debug variant should be signed explicitly, and the framework as a whole should be signed (implicitly signing the normal variant).
                var debugSigningTask: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Library/Frameworks/Framework.framework/Versions/A/Framework_debug"])) { task in
                    debugSigningTask = task
                }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Library/Frameworks/Framework.framework/Versions/A"])) { task in
                    if let debugSigningTask {
                        results.checkTaskFollows(task, antecedent: debugSigningTask)
                    }
                    else {
                        Issue.record("no task to sign the debug variant binary")
                    }
                }

                results.checkTasks(.matchTarget(target)) { _ in }
            }

            results.checkTarget("Application") { target in
                // There should be two strip tasks, one per variant.
                results.checkTasks(.matchTarget(target), .matchRuleType("Strip")) { tasks in
                    #expect(tasks.count == 2)
                }

                // There should be one ProcessProductPackaging task to create the macOS entitlements file, which is used to sign each variant.
                var entitlementsTask: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessProductPackaging")) { task in
                    task.checkRuleInfo(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Release/Application.build/Application.app.xcent"])
                    entitlementsTask = task
                }

                // There should be two codesign tasks, one per variant.  The binary for the debug variant should be signed explicitly, and the app as a whole should be signed (implicitly signing the normal variant).
                var debugSigningTask: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Applications/Application.app/Contents/MacOS/Application_debug"])) { task in
                    task.checkCommandLineContains(["--entitlements", "\(SRCROOT)/build/aProject.build/Release/Application.build/Application.app.xcent", "/tmp/aProject.dst/Applications/Application.app/Contents/MacOS/Application_debug"])
                    if let entitlementsTask {
                        results.checkTaskFollows(task, antecedent: entitlementsTask)
                    }
                    else {
                        Issue.record("no task to generate the entitlements file")
                    }
                    debugSigningTask = task
                }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Applications/Application.app"])) { task in
                    task.checkCommandLineContains(["--entitlements", "\(SRCROOT)/build/aProject.build/Release/Application.build/Application.app.xcent", "/tmp/aProject.dst/Applications/Application.app"])
                    if let entitlementsTask {
                        results.checkTaskFollows(task, antecedent: entitlementsTask)
                    }
                    else {
                        Issue.record("no task to generate the entitlements file")
                    }
                    if let debugSigningTask {
                        results.checkTaskFollows(task, antecedent: debugSigningTask)
                    }
                    else {
                        Issue.record("no task to sign the debug variant binary")
                    }
                }

                results.checkTasks(.matchTarget(target)) { _ in }
            }

            results.checkTarget("VersioningStubOnly") { target in
                // There should be two strip tasks, one per variant.
                results.checkTasks(.matchTarget(target), .matchRuleType("Strip")) { tasks in
                    #expect(tasks.count == 2)
                }

                // There should be two codesign tasks, one per variant.  The binary for the debug variant should be signed explicitly, and the framework as a whole should be signed (implicitly signing the normal variant).
                var debugSigningTask: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Library/Frameworks/VersioningStubOnly.framework/Versions/A/VersioningStubOnly_debug"])) { task in
                    debugSigningTask = task
                }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Library/Frameworks/VersioningStubOnly.framework/Versions/A"])) { task in
                    if let debugSigningTask {
                        results.checkTaskFollows(task, antecedent: debugSigningTask)
                    }
                    else {
                        Issue.record("no task to sign the debug variant binary")
                    }
                }

                results.checkTasks(.matchTarget(target)) { _ in }
            }

            results.checkTarget("NoSources") { target in
                // There should be no strip tasks.
                results.checkNoTask(.matchTarget(target), .matchRuleType("Strip"))

                // There should be one codesign task, for the framework as a whole.
                results.checkTask(.matchTarget(target), .matchRuleType("CodeSign")) { task in
                    task.checkRuleInfo(["CodeSign", "/tmp/aProject.dst/Library/Frameworks/NoSources.framework/Versions/A"])
                }

                results.checkTasks(.matchTarget(target)) { _ in }
            }

            results.checkTaskExists(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml"))

            // There shouldn't be any other tasks.
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildVariantsWillNotProduceDuplicatedTasks() async throws {
        let variants = ["normal", "asan"]
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("FrameworkSource.swift"),
                    TestFile("DockServerDefs.defs"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "BUILD_VARIANTS": variants.joined(separator: " "),
                    "CODE_SIGN_IDENTITY": "-",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "MIG_EXEC": migPath.str,
                    "DEFINES_MODULE": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["FrameworkSource.swift", "DockServerDefs.defs"]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check an install build to examine per-variant postprocessing steps.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS) { results in
            results.checkTarget("Framework") { target in
                // There should be two strip tasks, one per variant.
                results.checkTasks(.matchTarget(target), .matchRuleType("Strip")) { tasks in
                    #expect(tasks.count == 2)
                }

                // There should be two mig tasks, one for each variant.
                results.checkTasks(.matchTarget(target), .matchRuleType("Mig")) { tasks in
                    #expect(tasks.count == 2)
                }
            }
        }
    }

    /// Check that header generating commands have an enforced order before any commands that might use them.
    @Test(.requireSDKs(.macOS))
    func headerCommandReordering() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.m"),
                    TestFile("foo.y"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CLANG_USE_RESPONSE_FILE": "NO",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "SDKROOT": "macosx",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "foo.y",
                            "main.m"]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            // Ignore all the auxiliary file tasks.
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { tasks in }
            // Ignore all the mkdir and touch tasks.
            results.checkTasks(.matchRuleType("MkDir")) { tasks in }
            results.checkTasks(.matchRuleType("Touch")) { tasks in }

            results.checkTarget("App") { target in
                // Find the CompileC and Yacc tasks.
                var compileTaskOpt: (any PlannedTask)? = nil
                var yaccTaskOpt: (any PlannedTask)? = nil
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("main.m")) { task in
                    compileTaskOpt = task
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Yacc")) { task in
                    yaccTaskOpt = task
                }
                guard let compileTask = compileTaskOpt, let yaccTask = yaccTaskOpt else {
                    Issue.record("unable to find expected tasks")
                    return
                }

                // Validate that they are connected by a gate.
                XCTAssertMatch(compileTask.inputs.map({ $0.name }), [
                        .equal("main.m"),
                        .and(.prefix("target"), .suffix("-generated-headers")),
                        .and(.prefix("target"), .suffix("-swift-generated-headers")),
                        .and(.prefix("target"), .suffix("Producer")),
                        .and(.prefix("target"), .suffix("-begin-compiling")),
                    ])
                guard let generatedHeadersGate = compileTask.inputs[safe: 1] else {
                    Issue.record("missing expected gate")
                    return
                }
                #expect(yaccTask.mustPrecede[0].instance.outputs[0] === generatedHeadersGate)
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test permutations of the versioning stub file.
    @Test(.requireSDKs(.macOS))
    func versioningStub() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "VERSIONING_SYSTEM": "apple-generic",
                        "CURRENT_PROJECT_VERSION": "3.1",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check that setting VERSION_INFO_EXPORT_DECL to 'export' generates the expected file contents.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["VERSION_INFO_EXPORT_DECL": "export"]), runDestination: .macOS) { results in
            // There should be a WriteAuxiliaryFile task to create the versioning file.
            results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/Framework.build/DerivedSources/Framework_vers.c"])) { task, contents in
                task.checkInputs([
                    .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                task.checkOutputs([
                    .path("\(SRCROOT)/build/aProject.build/Debug/Framework.build/DerivedSources/Framework_vers.c"),])

                #expect(contents == "export extern const unsigned char FrameworkVersionString[];\nexport extern const double FrameworkVersionNumber;\n\nexport const unsigned char FrameworkVersionString[] __attribute__ ((used)) = \"@(#)PROGRAM:Framework  PROJECT:aProject-3.1\" \"\\n\";\nexport const double FrameworkVersionNumber __attribute__ ((used)) = (double)3.1;\n")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check that setting VERSION_INFO_EXPORT_DECL to 'static' generates the expected file contents, omitting the 'extern' lines.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["VERSION_INFO_EXPORT_DECL": "static"]), runDestination: .macOS) { results in
            // There should be a WriteAuxiliaryFile task to create the versioning file.
            results.checkWriteAuxiliaryFileTask(.matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/Framework.build/DerivedSources/Framework_vers.c"])) { task, contents in
                task.checkInputs([
                    .namePattern(.and(.prefix("target-"), .suffix("-immediate")))])

                task.checkOutputs([
                    .path("\(SRCROOT)/build/aProject.build/Debug/Framework.build/DerivedSources/Framework_vers.c"),])

                #expect(contents == "static const unsigned char FrameworkVersionString[] __attribute__ ((used)) = \"@(#)PROGRAM:Framework  PROJECT:aProject-3.1\" \"\\n\";\nstatic const double FrameworkVersionNumber __attribute__ ((used)) = (double)3.1;\n")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check that using CURRENT_* macros along with include paths that require prefixing is supported. rdar://problem/46039547 for more details.
    @Test(.requireSDKs(.macOS))
    func remappedHeaderSearchPathsWithCurrentMacros() async throws {
        let archs = ["arm64", "x86_64"]
        let buildVariants = ["normal", "debug"]
        let targetName = "CoreFoo"
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.cpp"),
                    TestFile("SourceFile-2.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "ARCHS": archs.joined(separator: " "),
                                                "BUILD_VARIANTS": buildVariants.joined(separator: " "),
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "macosx",
                                                "SWIFT_VERSION": swiftVersion,
                                                "CLANG_USE_RESPONSE_FILE": "NO",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("SourceFile.cpp"),
                            TestBuildFile("SourceFile-2.swift"),
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        // Choose any include path that's part of the macosx SDK.
        let parameters = BuildParameters(configuration: "Debug", overrides: [
            "HEADER_SEARCH_PATHS": "/usr/include/libxml2 $(CURRENT_VARIANT)/variantbased $(CURRENT_ARCH)/archbased",
        ])

        // Need to use `localFS` so that the remapping logic can find the filesystem SDK in order to check for the presence
        // of the include path that may require remapping.
        await tester.checkBuild(parameters, runDestination: .anyMac, fs: localFS) { results in
            results.checkTarget(targetName) { target in
                for variant in buildVariants {
                    for arch in archs {
                        results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem(arch), .matchRuleItem(variant)) { task in
                            task.checkCommandLineContains([
                                "-I\(core.loadSDK(.macOS).path.str)/usr/include/libxml2",
                                "-I\(variant)/variantbased",
                                "-I\(arch)/archbased",
                            ])
                        }
                        results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation"), .matchRuleItem(arch), .matchRuleItem(variant)) { task in
                            task.checkCommandLineContains([
                                "-Xcc", "-I\(core.loadSDK(.macOS).path.str)/usr/include/libxml2",
                                "-Xcc", "-I\(variant)/variantbased",
                                "-Xcc", "-I\(arch)/archbased",
                            ])
                        }
                    }
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func remappedHeaderSearchPaths() async throws {
        let targetName = "CoreFoo"
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.cpp"),
                    TestFile("SourceFile-2.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "macosx",
                                                "SWIFT_VERSION": swiftVersion,
                                                "CLANG_USE_RESPONSE_FILE": "NO",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("SourceFile.cpp"),
                            TestBuildFile("SourceFile-2.swift"),
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        // Choose any include path that's part of the macosx SDK.
        let parameters = BuildParameters(configuration: "Debug", overrides: [
            "HEADER_SEARCH_PATHS": "/usr/include/libxml2",
        ])

        // Need to use `localFS` so that the remapping logic can find the filesystem SDK in order to check for the presence
        // of the include path that may require remapping.
        await tester.checkBuild(parameters, runDestination: .macOS, fs: localFS) { results in
            results.checkTarget(targetName) { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains([
                        "-I\(core.loadSDK(.macOS).path.str)/usr/include/libxml2",
                    ])
                    task.checkCommandLineDoesNotContain("-I/usr/include/libxml2")
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains([
                        "-Xcc", "-I\(core.loadSDK(.macOS).path.str)/usr/include/libxml2",
                    ])
                    task.checkCommandLineDoesNotContain("-I/usr/include/libxml2")
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func sparseSDKs() async throws {
        try await withTemporaryDirectory { tmpDir in
            // Define a sparse SDK that isn't embedded inside the project directory, and that is referenced by absolute path.  All of the paths defined in the SDK's settings plist will be created in the SDK, and a few extra will also be created to test search-path-remapping behavior.
            let nonEmbeddedSparseSDKPath = tmpDir.join("Sparse1.0.sdk")
            let nonEmbeddedSparseSDKIdentBase = "com.apple.sdk.sparse"
            let nonEmbeddedSparseSDKIdent = "\(nonEmbeddedSparseSDKIdentBase)1.0"
            let nonEmbeddedSparseSDKSettings: [String: PropertyListItem] = [
                "CanonicalName": .plString(nonEmbeddedSparseSDKIdent),
                "DisplayName": "Sparse SDK 1.0",
                "FamilyIdentifier": .plString(nonEmbeddedSparseSDKIdentBase),
                "IsBaseSDK": "NO",
                "HeaderSearchPaths": [
                    "usr/include",
                    "usr/local/include",
                ],
                "LibrarySearchPaths": [
                    "usr/lib",
                    "usr/local/lib",
                ],
                "FrameworkSearchPaths": [
                    "Library/Frameworks",
                    "System/Library/PrivateFrameworks",
                    "System/Library/Frameworks",
                ],
                "CustomProperties": [
                    // None yet - some properties are not allowed in sparse SDKs.
                ],
            ]
            try await writeSDK(name: nonEmbeddedSparseSDKPath.basename, parentDir: nonEmbeddedSparseSDKPath.dirname, settings: nonEmbeddedSparseSDKSettings)
            for searchPathKey in ["HeaderSearchPaths", "LibrarySearchPaths", "FrameworkSearchPaths"] {
                for searchPath in try #require(nonEmbeddedSparseSDKSettings[searchPathKey]?.stringArrayValue) {
                    try localFS.createDirectory(nonEmbeddedSparseSDKPath.join(searchPath), recursive: true)
                }
            }
            // Create paths to locations which typically shouldn't be added as automatic search locations, but which projects opt in to.
            for searchPath in [
                "usr/local/include/one",
                "usr/local/include/two",
                "usr/local/lib/one",
                "usr/local/lib/two",
                "Library/Frameworks/one",
                "Library/Frameworks/two",
            ] {
                try localFS.createDirectory(nonEmbeddedSparseSDKPath.join(searchPath), recursive: true)
            }

            // Define the project.
            let targetName = "CoreFoo"
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.m"),
                        TestFile("SourceFile-2.swift"),
                    ]),
                targets: [
                    TestStandardTarget(
                        targetName,
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                    "SDKROOT": "macosx",
                                                    "ADDITIONAL_SDKS": "\(nonEmbeddedSparseSDKPath.str) $(SRCROOT)/EmbeddedSparseSDK.sdk",
                                                    "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "",
                                                    "CLANG_WARN_COMMA": "",
                                                    "CLANG_WARN_FLOAT_CONVERSION": "",
                                                    "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "",
                                                    "CLANG_WARN_OBJC_LITERAL_CONVERSION": "",
                                                    "CLANG_WARN_STRICT_PROTOTYPES": "",
                                                    "CLANG_WARN_IMPLICIT_FALLTHROUGH": "",
                                                    "FRAMEWORK_SEARCH_PATHS": "/Target/Framework/Search/Path/A /Target/Framework/Search/Path/B",
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "CLANG_USE_RESPONSE_FILE": "NO",
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SourceFile.m"),
                                TestBuildFile("SourceFile-2.swift"),
                            ]),
                            TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "Foo", contents: "echo \"Running script\"\nexit 0\n", alwaysOutOfDate: true),
                        ])
                ])
            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Define a sparse SDK that's embedded inside the project directory, and that is referenced by relative path.
            let embeddedSparseSDKPath = tester.workspace.projects[0].sourceRoot.join("EmbeddedSparseSDK.sdk")
            let embeddedSparseSDKIdentBase = "com.apple.sdk.embedded-sparse-sdk"
            let embeddedSparseSDKIdent = "\(embeddedSparseSDKIdentBase)1.0"
            let embeddedSparseSDKSettings: [String: PropertyListItem] = [
                "CanonicalName": .plString(embeddedSparseSDKIdent),
                "DisplayName": "Embedded Sparse SDK",
                "IsBaseSDK": "NO",
            ]
            try await writeSDK(name: embeddedSparseSDKPath.basename, parentDir: embeddedSparseSDKPath.dirname, settings: embeddedSparseSDKSettings)

            // Check the tasks.
            // What we're checking for here is that the command lines include the expected sparse SDK-driven options.
            await tester.checkBuild(runDestination: .macOS, fs: localFS) { results in
                results.checkTarget(targetName) { target in
                    // Check the search paths in the CompileC task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkRuleInfo(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.o", "\(SRCROOT)/Sources/SourceFile.m", "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"])
                        task.checkCommandLineContains([
                            // The target's explicitly specified search paths
                            "-F/Target/Framework/Search/Path/A",
                            "-F/Target/Framework/Search/Path/B",
                            // Sparse SDK search paths should be ordered after the target's explicitly specified search paths
                            "-isystem", "\(nonEmbeddedSparseSDKPath.str)/usr/include",
                            "-isystem", "\(nonEmbeddedSparseSDKPath.str)/usr/local/include",
                            "-iframework", "\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks",
                            "-iframework", "\(nonEmbeddedSparseSDKPath.str)/System/Library/PrivateFrameworks",
                            "-iframework", "\(nonEmbeddedSparseSDKPath.str)/System/Library/Frameworks",
                        ])
                    }

                    // Check the search paths in the Swift Planning task.
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkRuleInfo(["SwiftDriver Compilation", targetName, "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                        task.checkCommandLineContains([
                            // The build directory
                            "-F", "\(SRCROOT)/build/Debug",
                            // The target's explicitly specified framework search paths
                            "-F", "/Target/Framework/Search/Path/A",
                            "-F", "/Target/Framework/Search/Path/B",
                            // Sparse SDK search paths should be ordered after the target's explicitly specified search paths
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/System/Library/PrivateFrameworks",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/System/Library/Frameworks",
                        ])
                    }

                    // Check the search paths in the link task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            // The target's explicitly specified search paths
                            "-F/Target/Framework/Search/Path/A",
                            "-F/Target/Framework/Search/Path/B",
                            // Sparse SDK search paths should be ordered after the target's explicitly specified search paths
                            "-L", "\(nonEmbeddedSparseSDKPath.str)/usr/lib",
                            "-L", "\(nonEmbeddedSparseSDKPath.str)/usr/local/lib",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/System/Library/PrivateFrameworks",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/System/Library/Frameworks",
                        ])
                    }

                    // Check the PhaseScriptExecution task.
                    results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Script-Foo.sh")) { task in
                        task.checkRuleInfo(["PhaseScriptExecution", "Run Script", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Script-Foo.sh"])
                        task.checkCommandLine(["/bin/sh", "-c", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Script-Foo.sh"])

                        // Validate environment variables we expect to see.
                        task.checkEnvironment([
                            "ADDITIONAL_SDKS": .equal("\(nonEmbeddedSparseSDKPath.str) \(embeddedSparseSDKPath.str)"),
                            "ADDITIONAL_SDK_DIRS": .equal("\(nonEmbeddedSparseSDKPath.str) \(embeddedSparseSDKPath.str)"),
                            "SDK_NAMES": .equal("\(nonEmbeddedSparseSDKIdent) \(embeddedSparseSDKIdent) \(core.loadSDK(.macOS).name)"),
                            "SDK_DIR_" + core.loadSDK(.macOS).name.asLegalCIdentifier: .equal(core.loadSDK(.macOS).path.str),
                            // We don't have a convenient way to access the 'macosx' value from here, so it's hard-coded.
                            "SDK_DIR_" + "macosx": .equal(core.loadSDK(.macOS).path.str),
                            "SDK_DIR_" + nonEmbeddedSparseSDKIdent.asLegalCIdentifier: .equal(nonEmbeddedSparseSDKPath.str),
                            "SDK_DIR_" + nonEmbeddedSparseSDKIdentBase.asLegalCIdentifier: .equal(nonEmbeddedSparseSDKPath.str),
                            "SDK_DIR_" + embeddedSparseSDKIdent.asLegalCIdentifier: .equal(embeddedSparseSDKPath.str),
                            "SDK_DIR_" + embeddedSparseSDKIdentBase.asLegalCIdentifier: .equal(embeddedSparseSDKPath.str),
                        ])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Also check that remapping of search paths get remapped appropriately.
            let parameters = BuildParameters(configuration: "Debug", overrides: [
                "HEADER_SEARCH_PATHS": "/usr/local/include/one $(SDKROOT)/usr/local/include/two $(inherited)",
                "LIBRARY_SEARCH_PATHS": "/usr/local/lib/one $(SDKROOT)/usr/local/lib/two $(inherited)",
                "FRAMEWORK_SEARCH_PATHS": "/Library/Frameworks/one $(SDKROOT)/Library/Frameworks/two $(inherited)",
            ])
            await tester.checkBuild(parameters, runDestination: .macOS, fs: localFS) { results in
                results.checkTarget(targetName) { target in
                    // Check the search paths in the CompileC task.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkRuleInfo(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.o", "\(SRCROOT)/Sources/SourceFile.m", "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"])
                        task.checkCommandLineContains([
                            // The target's explicitly specified search paths, each preceded by the remapping into the sparse SDK where appropriate
                            "-I\(nonEmbeddedSparseSDKPath.str)/usr/local/include/one",
                            "-I/usr/local/include/one",
                            "-I\(nonEmbeddedSparseSDKPath.str)/usr/local/include/two",
                            "-I\(core.loadSDK(.macOS).path.str)/usr/local/include/two",
                            "-F\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks/one",
                            "-F/Library/Frameworks/one",
                            "-F\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks/two",
                            "-F\(core.loadSDK(.macOS).path.str)/Library/Frameworks/two",
                            "-F/Target/Framework/Search/Path/A",
                            "-F/Target/Framework/Search/Path/B",
                            // Sparse SDK search paths should be ordered after the target's explicitly specified search paths
                            "-isystem", "\(nonEmbeddedSparseSDKPath.str)/usr/include",
                            "-isystem", "\(nonEmbeddedSparseSDKPath.str)/usr/local/include",
                            "-iframework", "\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks",
                            "-iframework", "\(nonEmbeddedSparseSDKPath.str)/System/Library/PrivateFrameworks",
                            "-iframework", "\(nonEmbeddedSparseSDKPath.str)/System/Library/Frameworks",
                        ])
                    }

                    // Check the search paths in the SwiftDriver task.
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkRuleInfo(["SwiftDriver Compilation", targetName, "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                        task.checkCommandLineContains([
                            // The build directory
                            "-F", "\(SRCROOT)/build/Debug",
                            // The target's explicitly specified framework search paths, each preceded by the remapping into the sparse SDK where appropriate
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks/one",
                            "-F", "/Library/Frameworks/one",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks/two",
                            "-F", "\(core.loadSDK(.macOS).path.str)/Library/Frameworks/two",
                            "-F", "/Target/Framework/Search/Path/A",
                            "-F", "/Target/Framework/Search/Path/B",
                            // Sparse SDK search paths should be ordered after the target's explicitly specified search paths
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/System/Library/PrivateFrameworks",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/System/Library/Frameworks",
                            // The target's explicitly specified header search paths, each preceded by the remapping into the sparse SDK where appropriate
                            "-Xcc", "-I\(nonEmbeddedSparseSDKPath.str)/usr/local/include/one",
                            "-Xcc", "-I/usr/local/include/one",
                            "-Xcc", "-I\(nonEmbeddedSparseSDKPath.str)/usr/local/include/two",
                            "-Xcc", "-I\(core.loadSDK(.macOS).path.str)/usr/local/include/two",
                        ])
                    }

                    // Check the search paths in the link task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/\(targetName).framework/Versions/A/\(targetName)", "normal"])
                        task.checkCommandLineContains([
                            // The target's explicitly specified search paths, each preceded by the remapping into the sparse SDK where appropriate
                            "-L\(nonEmbeddedSparseSDKPath.str)/usr/local/lib/one",
                            "-L/usr/local/lib/one",
                            "-L\(nonEmbeddedSparseSDKPath.str)/usr/local/lib/two",
                            "-L\(core.loadSDK(.macOS).path.str)/usr/local/lib/two",
                            "-F\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks/one",
                            "-F/Library/Frameworks/one",
                            "-F\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks/two",
                            "-F\(core.loadSDK(.macOS).path.str)/Library/Frameworks/two",
                            "-F/Target/Framework/Search/Path/A",
                            "-F/Target/Framework/Search/Path/B",
                            // Sparse SDK search paths should be ordered after the target's explicitly specified search paths
                            "-L", "\(nonEmbeddedSparseSDKPath.str)/usr/lib",
                            "-L", "\(nonEmbeddedSparseSDKPath.str)/usr/local/lib",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/Library/Frameworks",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/System/Library/PrivateFrameworks",
                            "-F", "\(nonEmbeddedSparseSDKPath.str)/System/Library/Frameworks",
                        ])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func moduleCompilerOptions() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let targetName = "CoreFoo"
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("SwiftFile.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "macosx",
                                                "CLANG_ENABLE_MODULES": "YES",
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                                "TAPI_EXEC": tapiToolPath.str,
                                                "CC": clangCompilerPath.str,
                                                "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                                "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "",
                                                "CLANG_WARN_COMMA": "",
                                                "CLANG_WARN_FLOAT_CONVERSION": "",
                                                "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "",
                                                "CLANG_WARN_OBJC_LITERAL_CONVERSION": "",
                                                "CLANG_WARN_STRICT_PROTOTYPES": "",
                                                "CLANG_WARN_IMPLICIT_FALLTHROUGH": "",
                                                "CLANG_USE_RESPONSE_FILE": "NO",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("SourceFile.m"),
                            TestBuildFile("SwiftFile.swift"),
                        ]),
                    ]),
                TestStandardTarget(
                    "FrameworkWithModule",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "macosx",
                                                "CLANG_ENABLE_MODULES": "YES",
                                                "DEFINES_MODULE": "YES",
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                                "TAPI_EXEC": tapiToolPath.str,
                                                "CC": clangCompilerPath.str,
                                                "CLANG_EXPLICIT_MODULES_LIBCLANG_PATH": libClangPath.str,
                                                "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "",
                                                "CLANG_WARN_COMMA": "",
                                                "CLANG_WARN_FLOAT_CONVERSION": "",
                                                "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "",
                                                "CLANG_WARN_OBJC_LITERAL_CONVERSION": "",
                                                "CLANG_WARN_STRICT_PROTOTYPES": "",
                                                "CLANG_WARN_IMPLICIT_FALLTHROUGH": "",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("SourceFile.m"),
                            TestBuildFile("SwiftFile.swift"),
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let MACOSX_DEPLOYMENT_TARGET = core.loadSDK(.macOS).defaultDeploymentTarget

        // Check a build with both targets; this should use the VFS since one defines a module.
        let derivedData = Path("\(SRCROOT)/DerivedData")
        let arena = ArenaInfo.buildArena(derivedDataRoot: derivedData, enableIndexDataStore: true)
        let products = arena.buildProductsPath
        let intermediates = arena.buildIntermediatesPath
        let parameters = BuildParameters(configuration: "Debug", arena: arena)
        let request1 = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: request1) { results in
            results.checkTarget(targetName) { target in
                // There should be one CompileC task.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo(["CompileC", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.o", "\(SRCROOT)/Sources/SourceFile.m", "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"])
                    task.checkCommandLineContains([
                        [clangCompilerPath.str, "-x", "objective-c"],
                        ["-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)"],
                        ["-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fmodules", "-gmodules", "-fmodules-cache-path=\(derivedData.str)/ModuleCache.noindex", "-fmodules-prune-interval=86400", "-fmodules-prune-after=345600", "-fbuild-session-file=\(derivedData.str)/ModuleCache.noindex/Session.modulevalidation", "-fmodules-validate-once-per-build-session", "-Wnon-modular-include-in-framework-module", "-Werror=non-modular-include-in-framework-module", /* non-module standard flags go here */ "-isysroot", core.loadSDK(.macOS).path.str, "-fasm-blocks", "-fstrict-aliasing", "-Wprotocol", "-Wdeprecated-declarations"],
                        ["-g", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-iquote", "\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-generated-files.hmap", "-I\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-own-target-headers.hmap", "-I\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-all-non-framework-target-headers.hmap", "-ivfsoverlay"], ["-iquote", "\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-project-headers.hmap", "-I\(products.str)/Debug/include", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/DerivedSources-normal/x86_64", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/DerivedSources", "-F\(products.str)/Debug", "-MMD", "-MT", "dependencies", "-MF", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.d", "--serialize-diagnostics", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.dia", "-c", "\(SRCROOT)/Sources/SourceFile.m", "-o", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.o"]
                    ].reduce([], +))
                }

                // There should be one SwiftDriver task.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", targetName, "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                    task.checkCommandLineContains([[swiftCompilerPath.str, "-module-name", targetName, "-O", "@\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName).SwiftFileList", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-g", "-module-cache-path", "\(derivedData.str)/ModuleCache.noindex", /* options from the xcspec which sometimes change appear here */ "-swift-version", swiftVersion, "-I", "\(products.str)/Debug", "-F", "\(products.str)/Debug", "-parse-as-library", "-c", "-j\(compilerParallelismLevel)", "-incremental", "-output-file-map", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName)-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName).swiftmodule", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-generated-files.hmap", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-own-target-headers.hmap", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-all-non-framework-target-headers.hmap", "-Xcc", "-ivfsoverlay", "-Xcc"], ["-Xcc", "-iquote", "-Xcc", "\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-project-headers.hmap", "-Xcc", "-I\(products.str)/Debug/include", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/DerivedSources-normal/x86_64", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName)-Swift.h", "-working-directory", SRCROOT]].reduce([], +))
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName).SwiftFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == ["\(SRCROOT)/Sources/SwiftFile.swift", ""])
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check a build with just the first target -- this should have no VFS.
        let request2 = BuildRequest(parameters: parameters, buildTargets: [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.projects[0].targets[0])], continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: request2) { results in
            results.checkTarget(targetName) { target in
                // There should be one CompileC task.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    task.checkRuleInfo(["CompileC", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.o", "\(SRCROOT)/Sources/SourceFile.m", "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"])
                    task.checkCommandLineContains([
                        [clangCompilerPath.str, "-x", "objective-c"],
                        ["-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)"],
                        ["-fmessage-length=0", "-fdiagnostics-show-note-include-stack", "-fmacro-backtrace-limit=0", "-fmodules", "-gmodules", "-fmodules-cache-path=\(derivedData.str)/ModuleCache.noindex", "-fmodules-prune-interval=86400", "-fmodules-prune-after=345600", "-fbuild-session-file=\(derivedData.str)/ModuleCache.noindex/Session.modulevalidation", "-fmodules-validate-once-per-build-session", "-Wnon-modular-include-in-framework-module", "-Werror=non-modular-include-in-framework-module", /* non-module standard flags go here */ "-isysroot", core.loadSDK(.macOS).path.str, "-fasm-blocks", "-fstrict-aliasing", "-Wprotocol", "-Wdeprecated-declarations"],
                        ["-g", "-Wno-sign-conversion", "-Wno-infinite-recursion", "-iquote", "\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-generated-files.hmap", "-I\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-own-target-headers.hmap", "-I\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-all-target-headers.hmap", "-iquote", "\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-project-headers.hmap", "-I\(products.str)/Debug/include", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/DerivedSources-normal/x86_64", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/DerivedSources", "-F\(products.str)/Debug", "-MMD", "-MT", "dependencies", "-MF", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.d", "--serialize-diagnostics", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.dia", "-c", "\(SRCROOT)/Sources/SourceFile.m", "-o", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/SourceFile.o"]
                    ].reduce([], +))
                }

                // There should be one SwiftDriver task.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", targetName, "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])
                    task.checkCommandLineContains([swiftCompilerPath.str, "-module-name", targetName, "-O", "@\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName).SwiftFileList", "-sdk", core.loadSDK(.macOS).path.str, "-target", "x86_64-apple-macos\(MACOSX_DEPLOYMENT_TARGET)", "-g", "-module-cache-path", "\(derivedData.str)/ModuleCache.noindex", /* options from the xcspec which sometimes change appear here */ "-swift-version", swiftVersion, "-I", "\(products.str)/Debug", "-F", "\(products.str)/Debug", "-parse-as-library", "-c", "-j\(compilerParallelismLevel)", "-incremental", "-output-file-map", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName)-OutputFileMap.json", "-serialize-diagnostics", "-emit-dependencies", "-emit-module", "-emit-module-path", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName).swiftmodule", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-generated-files.hmap", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-own-target-headers.hmap", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(intermediates.str)/aProject.build/Debug/CoreFoo.build/CoreFoo-project-headers.hmap", "-Xcc", "-I\(products.str)/Debug/include", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/DerivedSources-normal/x86_64", "-Xcc", "-I\(intermediates.str)/aProject.build/Debug/\(targetName).build/DerivedSources", "-emit-objc-header", "-emit-objc-header-path", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName)-Swift.h", "-working-directory", SRCROOT])
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(intermediates.str)/aProject.build/Debug/\(targetName).build/Objects-normal/x86_64/\(targetName).SwiftFileList"])) { task, contents in
                    let lines = contents.asString.components(separatedBy: .newlines)
                    #expect(lines == ["\(SRCROOT)/Sources/SwiftFile.swift", ""])
                }
            }
        }
    }

    /// We should be able to build a target with non-.o outputs in its Sources phase without invoking Ld with an empty file list.
    @Test(.requireSDKs(.macOS))
    func compileSourcesWithoutLinkage() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File.metal"),
                ]),
            targets: [
                TestStandardTarget(
                    "aTarget",
                    type: .bundle,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["CODE_SIGN_IDENTITY": ""]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File.metal"),
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check for a set of expected tasks instead of checking for the absence of Ld, because checking checkNoTask("Ld") exposes us to bugs if Ld changes name.
        let expectedTasks = Set(["CompileMetalFile", "MetalLink", "Gate", "WriteAuxiliaryFile", "MkDir", "Touch", "CreateBuildDirectory", "ProcessInfoPlistFile"])
        await tester.checkBuild(runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["RegisterExecutionPolicyException"])
            results.checkNoDiagnostics()
            results.checkTasks() { tasks in
                for task in tasks {
                    #expect(expectedTasks.contains(task.ruleInfo[0]), "Found unexpected task: \(task.ruleInfo[0]): \(task)")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func assemblyCompile() async throws {
        let testProject = TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File.s"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "ARCHS": "x86_64",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File.s"),
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRule(["CompileC", "/tmp/Test/ProjectName/build/ProjectName.build/Debug/TargetName.build/Objects-normal/x86_64/File.o", "/tmp/Test/ProjectName/Sources/File.s", "normal", "x86_64", "assembler-with-cpp", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
        }
    }

    @Test(.requireSDKs(.macOS))
    func indexingWhileBuilding() async throws {
        let clangFeatures = try await self.clangFeatures
        let swiftFeatures = try await self.swiftFeatures
        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File1.m"),
                    TestFile("File2.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "ARCHS": "x86_64",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                            // Indexing while building is only enabled for debug builds.
                            "GCC_OPTIMIZATION_LEVEL": "0",
                            "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
                            "CC": clangCompilerPath.str,
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.m"),
                            TestBuildFile("File2.swift"),
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let arena = ArenaInfo.buildArena(derivedDataRoot: Path("/tmp/DerivedData"), enableIndexDataStore: true)
        let indexDataStoreRoot = try #require(arena.indexDataStoreFolderPath).str
        try await tester.checkBuild(BuildParameters(configuration: "Debug", arena: arena), runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            let file1ObjectRelPath = "ProjectName.build/Debug/TargetName.build/Objects-normal/x86_64/File1.o"
            results.checkTask(.matchRule(["CompileC", arena.buildIntermediatesPath.join(file1ObjectRelPath).str, "\(SRCROOT)/Sources/File1.m", "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in
                task.checkCommandLineContainsUninterrupted(["-index-store-path", indexDataStoreRoot])

                // Check that the index unit output path is relocatable
                if clangFeatures.has(.indexUnitOutputPath) {
                    task.checkCommandLineContainsUninterrupted(["-index-unit-output-path", "/\(file1ObjectRelPath)"])
                }
            }

            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkCommandLineContainsUninterrupted(["-index-store-path", indexDataStoreRoot])
            }

            if swiftFeatures.has(.indexUnitOutputPath) {
                try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("TargetName-OutputFileMap.json")) { task, contents in
                    let plist = try #require(try? PropertyList.fromJSONData(contents))
                    let dict = try #require(plist.dictValue)
                    let file2Dict = try #require(dict["\(SRCROOT)/Sources/File2.swift"]?.dictValue)

                    // Check that the index unit output path is relocatable
                    #expect(file2Dict["index-unit-output-path"]?.stringValue == "/ProjectName.build/Debug/TargetName.build/Objects-normal/x86_64/File2.o")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func indexingWhileBuildingDisabledInRelease() async throws {
        let swiftFeatures = try await self.swiftFeatures
        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File1.m"),
                    TestFile("File2.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "ARCHS": "x86_64",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                            // Indexing while building is disabled for optimized builds, even in debug
                            "GCC_OPTIMIZATION_LEVEL": "s",
                            "SWIFT_OPTIMIZATION_LEVEL": "-Os",
                            "CC": clangCompilerPath.str,
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.m"),
                            TestBuildFile("File2.swift"),
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let arena = ArenaInfo.buildArena(derivedDataRoot: Path("/tmp/DerivedData"), enableIndexDataStore: true)
        try await tester.checkBuild(BuildParameters(configuration: "Debug", arena: arena), runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRule(["CompileC", "\(arena.buildIntermediatesPath.str)/ProjectName.build/Debug/TargetName.build/Objects-normal/x86_64/File1.o", "\(SRCROOT)/Sources/File1.m", "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in
                task.checkCommandLineDoesNotContain("-index-store-path")
                task.checkCommandLineDoesNotContain("-index-unit-output-path")
            }

            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkCommandLineDoesNotContain("-index-store-path")
                task.checkCommandLineDoesNotContain("-index-unit-output-path")
            }

            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("TargetName-OutputFileMap.json")) { task, contents in
                let plist = try #require(try? PropertyList.fromJSONData(contents))
                let dict = try #require(plist.dictValue)
                let file2Dict = try #require(dict["\(SRCROOT)/Sources/File2.swift"]?.dictValue)

                if swiftFeatures.has(.indexUnitOutputPathWithoutWarning) {
                    // We always pass a index-unit-output-path so that the output file map doesn't change between builds with the index store on/off
                    #expect(file2Dict["index-unit-output-path"]?.stringValue == "/ProjectName.build/Debug/TargetName.build/Objects-normal/x86_64/File2.o")
                } else {
                    // index-unit-output-path not included so as to not cause a warning on every build
                    #expect(file2Dict["index-unit-output-path"] == nil)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func fileTextEncoding() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Strings-UTF8.strings", fileTextEncoding: .utf8),
                    TestFile("Strings-UTF16.strings", fileTextEncoding: .utf16),
                    TestFile("Strings-NoEncoding.strings"),
                    TestVariantGroup("Strings.strings", children: [
                        TestFile("de.lproj/Strings.strings", regionVariantName: "de", fileTextEncoding: .utf16),
                        TestFile("en.lproj/Strings.strings", regionVariantName: "en", fileTextEncoding: nil),
                        TestFile("fr.lproj/Strings.strings", regionVariantName: "fr", fileTextEncoding: .utf8),
                    ]),
                    TestVariantGroup("Strings-VariantGroup.strings", children: [
                        TestFile("Strings-UTF99.strings", fileTextEncoding: FileTextEncoding("utf-99"))
                    ])
                ]),
            targets: [
                TestStandardTarget(
                    "Bundle", type: .bundle,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                    ],
                    buildPhases: [
                        TestResourcesBuildPhase(["Strings-UTF8.strings", "Strings-UTF16.strings", "Strings-NoEncoding.strings", "Strings.strings", "Strings-VariantGroup.strings"]),
                    ]
                )])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("Strings-UTF8.strings")) { task in
                task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outfilename", "Strings-UTF8.strings", "--outdir", "\(SRCROOT)/build/Debug/Bundle.bundle/Contents/Resources", "--", "\(SRCROOT)/Sources/Strings-UTF8.strings"])
            }
            results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("Strings-UTF16.strings")) { task in
                task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-16", "--outputencoding", "UTF-16", "--outfilename", "Strings-UTF16.strings", "--outdir", "\(SRCROOT)/build/Debug/Bundle.bundle/Contents/Resources", "--", "\(SRCROOT)/Sources/Strings-UTF16.strings"])
            }
            results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("Strings-NoEncoding.strings")) { task in
                task.checkCommandLine(["builtin-copyStrings", "--validate", "--outputencoding", "UTF-16", "--outfilename", "Strings-NoEncoding.strings", "--outdir", "\(SRCROOT)/build/Debug/Bundle.bundle/Contents/Resources", "--", "\(SRCROOT)/Sources/Strings-NoEncoding.strings"])
            }
            results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemPattern(.suffix("de.lproj/Strings.strings"))) { task in
                task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-16", "--outputencoding", "UTF-16", "--outfilename", "Strings.strings", "--outdir", "\(SRCROOT)/build/Debug/Bundle.bundle/Contents/Resources/de.lproj", "--", "\(SRCROOT)/Sources/de.lproj/Strings.strings"])
            }
            results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemPattern(.suffix("en.lproj/Strings.strings"))) { task in
                task.checkCommandLine(["builtin-copyStrings", "--validate", "--outputencoding", "UTF-16", "--outfilename", "Strings.strings", "--outdir", "\(SRCROOT)/build/Debug/Bundle.bundle/Contents/Resources/en.lproj", "--", "\(SRCROOT)/Sources/en.lproj/Strings.strings"])
            }
            results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemPattern(.suffix("fr.lproj/Strings.strings"))) { task in
                task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outfilename", "Strings.strings", "--outdir", "\(SRCROOT)/build/Debug/Bundle.bundle/Contents/Resources/fr.lproj", "--", "\(SRCROOT)/Sources/fr.lproj/Strings.strings"])
            }
            results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("Strings-UTF99.strings")) { task in
                task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-99", "--outputencoding", "UTF-16", "--outfilename", "Strings-UTF99.strings", "--outdir", "\(SRCROOT)/build/Debug/Bundle.bundle/Contents/Resources", "--", "\(SRCROOT)/Sources/Strings-UTF99.strings"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func searchPathSettings() async throws {
        let targetName = "SearchPaths"
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.m"),
                    TestFile("SwiftFile.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    targetName,
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "macosx",

                                                "HEADER_SEARCH_PATHS": "/Local/Library/Headers ../../Sources",
                                                "SYSTEM_HEADER_SEARCH_PATHS": "/System/Library/Include /Local/Library/Headers",
                                                "FRAMEWORK_SEARCH_PATHS": "/Local/Library/Frameworks ///Local/Foo/./../Library/Frameworks",
                                                "SYSTEM_FRAMEWORK_SEARCH_PATHS": "/System/Library/PrivateFrameworks /Local/Library/Frameworks ///Local/Foo/./../Library/Frameworks",
                                                "LIBRARY_SEARCH_PATHS": "/Local/Library/Libs",

                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                                "TAPI_EXEC": tapiToolPath.str,
                                                "CLANG_USE_RESPONSE_FILE": "NO",
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("SourceFile.m"),
                            TestBuildFile("SwiftFile.swift"),
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check the tasks' search paths.  Note that this will include headermaps, and paths to the built products dir and derived files dir.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget(targetName) { target in
                // Check options in the clang command.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    var searchPaths = [String]()
                    let commandLine = task.commandLine.map({ $0.asString })
                    for (i, arg) in commandLine.enumerated() {
                        // 2-arg search paths.
                        if ["-I", "-isystem", "-iquote", "-F", "-iframework"].contains(arg) {
                            if i<commandLine.count {
                                searchPaths.append(contentsOf: Array(commandLine[i...i+1]))
                            }
                        }
                        // Single-arg search paths.
                        else if arg.hasPrefix("-I") || arg.hasPrefix("-F") {
                            searchPaths.append(arg)
                        }
                    }
                    #expect(searchPaths == ["-iquote", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/\(targetName)-generated-files.hmap", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/\(targetName)-own-target-headers.hmap", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/\(targetName)-all-target-headers.hmap", "-iquote", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/\(targetName)-project-headers.hmap", "-I\(SRCROOT)/build/Debug/include", "-I/Local/Library/Headers", "-I../../Sources", "-isystem", "/System/Library/Include", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources-normal/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/x86_64", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources",  "-F\(SRCROOT)/build/Debug", "-F/Local/Library/Frameworks", "-F/Local/Library/Frameworks", "-iframework", "/System/Library/PrivateFrameworks"])
                }

                // Check options in the swiftc command.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    var searchPaths = [String]()
                    let commandLine = task.commandLine.map({ $0.asString })
                    for (i, arg) in commandLine.enumerated() {
                        // 2-arg search paths, each one of which might be prepended by -Xcc.
                        if ["-I", "-isystem", "-iquote", "-F", "-iframework"].contains(arg) {
                            if i>0, commandLine[i-1] == "-Xcc", i+2<commandLine.count {
                                searchPaths.append(contentsOf: Array(commandLine[i-1...i+2]))
                            }
                            else if i<commandLine.count {
                                searchPaths.append(contentsOf: Array(commandLine[i...i+1]))
                            }
                        }
                        // Single-arg search paths, which might be prepended by -Xcc.
                        else if arg.hasPrefix("-I") || arg.hasPrefix("-F") {
                            if i>0, commandLine[i-1] == "-Xcc" {
                                searchPaths.append(contentsOf: Array(commandLine[i-1...i]))
                            }
                            else {
                                searchPaths.append(arg)
                            }
                        }
                    }
                    #expect(searchPaths == ["-I", "\(SRCROOT)/build/Debug", "-F", "\(SRCROOT)/build/Debug", "-F", "/Local/Library/Frameworks", "-F", "/Local/Library/Frameworks", "-F", "/System/Library/PrivateFrameworks", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/swift-overrides.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/\(targetName)-generated-files.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/\(targetName)-own-target-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/\(targetName)-all-target-headers.hmap", "-Xcc", "-iquote", "-Xcc", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/\(targetName)-project-headers.hmap", "-Xcc", "-I\(SRCROOT)/build/Debug/include", "-Xcc", "-I/Local/Library/Headers", "-Xcc", "-I../../Sources", "-Xcc", "-isystem", "-Xcc", "/System/Library/Include", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources-normal/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources/x86_64", "-Xcc", "-I\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/DerivedSources"])
                }

                // Check options in the link command.
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    var searchPaths = [String]()
                    let commandLine = task.commandLine.map({ $0.asString })
                    for (i, arg) in commandLine.enumerated() {
                        // 2-arg search paths.
                        if ["-L", "-F", "-iframework"].contains(arg) {
                            if i<commandLine.count {
                                searchPaths.append(contentsOf: Array(commandLine[i...i+1]))
                            }
                        }
                        // Single-arg search paths, which might be prepended by -Xcc.
                        else if arg.hasPrefix("-L") || arg.hasPrefix("-F") {
                            searchPaths.append(arg)
                        }
                    }
                    // Note that system framework search paths are presently not deduplicated for the linker args.
                    #expect(searchPaths == ["-L\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-L\(SRCROOT)/build/Debug", "-L/Local/Library/Libs", "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug", "-F\(SRCROOT)/build/Debug", "-F/Local/Library/Frameworks", "-F/Local/Library/Frameworks", "-iframework", "/System/Library/PrivateFrameworks", "-iframework", "/Local/Library/Frameworks", "-iframework", "/Local/Library/Frameworks", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx", "-L/usr/lib/swift"])
                    // FIXME: <rdar://problem/37033578> [Swift Build] Extra "//" in framework search path for Ld command
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Test that we properly generate commands for the compiler sanitizer features.
    @Test(.requireSDKs(.macOS))
    func sanitizers() async throws {
        try await withTemporaryDirectory { tmpDir in
            let targetName = "AppTarget"
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.m"),
                        TestFile("SwiftFile.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug",
                                           buildSettings: [
                                            "INFOPLIST_FILE": "Info.plist",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "CODE_SIGN_IDENTITY": "-",
                                            "SWIFT_VERSION": swiftVersion,
                                            "CLANG_USE_RESPONSE_FILE": "NO",
                                           ])
                ],
                targets: [
                    TestStandardTarget(
                        targetName,
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug"),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.m",
                                "SwiftFile.swift",
                            ]),
                        ]
                    ),
                ])
            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            // Use the local filesystem since the sanitizer logic needs to access clang.
            let fs = localFS

            try fs.write(Path(SRCROOT).join("Info.plist"), contents: "<dict/>")

            let clangTool = try await discoveredClangToolInfo(toolPath: Path("\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"), arch: RunDestinationInfo.macOS.targetArchitecture, sysroot: nil)
            guard let clangLibDarwinPath = clangTool.getLibDarwinPath() else {
                Issue.record("Could not get lib darwin path")
                return
            }

            // Check the LibSystem address sanitizer.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ENABLE_ADDRESS_SANITIZER": "YES","ENABLE_SYSTEM_SANITIZERS": "YES" ]), runDestination: .macOS, fs: fs) { results in
                results.checkTarget(targetName) { target in
                    // There should be one CompileC task, which includes the ASan option, and which puts its output in a -asan directory.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkRuleInfo([.equal("CompileC"), .equal("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-asan/x86_64/SourceFile.o"), .suffix("SourceFile.m"), .any, .any, .any, .any])
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "-fsanitize=address", "-fsanitize-stable-abi", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-asan/x86_64/SourceFile.o"])
                    }
                    //There should be no task to copy dylib. While testing for -fsanitize-stable-abi is a temporary test. This test should remain.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("libclang_rt.asan_osx_dynamic.dylib"))
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-sanitize=address", "-sanitize-stable-abi", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-asan/x86_64/\(targetName)-OutputFileMap.json"])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContains(
                            ["-fsanitize=address", "-fsanitize-stable-abi", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/MacOS/\(targetName)"
                            ])
                    }
                }
            }
            // Check the address sanitizer.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ENABLE_ADDRESS_SANITIZER": "YES"]), runDestination: .macOS, fs: fs) { results in
                results.checkTarget(targetName) { target in
                    // There should be one CompileC task, which includes the ASan option, and which puts its output in a -asan directory.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkRuleInfo([.equal("CompileC"), .equal("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-asan/x86_64/SourceFile.o"), .suffix("SourceFile.m"), .any, .any, .any, .any])
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "-fsanitize=address", "-D_LIBCPP_HAS_NO_ASAN", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-asan/x86_64/SourceFile.o"])
                    }

                    // There should be one CompileSwiftSources task, which includes the ASan option, and which puts its output in a -asan directory.
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-sanitize=address", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-asan/x86_64/\(targetName)-OutputFileMap.json"])
                    }

                    // There should be one Ld task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo([.equal("Ld"), .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/MacOS/\(targetName)"), .any])
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/MacOS/\(targetName)"])
                    }

                    // There should be one task to copy the Asan library into the product.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("libclang_rt.asan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("Copy"),
                                            .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                                            .equal(clangLibDarwinPath.join("libclang_rt.asan_osx_dynamic.dylib").str)])
                        task.checkCommandLineContains(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-resolve-src-symlinks", clangLibDarwinPath.join("libclang_rt.asan_osx_dynamic.dylib").str, "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks"])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                            .name("Copy Address Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                        ])
                        #expect(task.execDescription == "Copy Address Sanitizer library")
                    }

                    // There should be two code signing tasks, one for the library and one for the product.
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("libclang_rt.asan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("CodeSign"), .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib")])
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=identifier,entitlements,flags", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                            .name("Copy Address Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                            .any,
                            .any,
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).app")) { task in
                        task.checkRuleInfo([.equal("CodeSign"), .equal("\(SRCROOT)/build/Debug/\(targetName).app")])
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget.app.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/\(targetName).app"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            let overrides = [
                "BUILD_VARIANTS": "normal asan asan_tsan",
                "ENABLE_ADDRESS_SANITIZER[variant=asan]": "YES",
                "ENABLE_ADDRESS_SANITIZER[variant=asan_tsan]": "YES",
                "ENABLE_THREAD_SANITIZER[variant=asan_tsan]": "YES",
            ]

            // Check sanitizers conditionally enabled by build variants.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: overrides), runDestination: .macOS, fs: fs) { results in
                results.checkTarget(targetName) { target in
                    // There should be one task to copy the ASan library into the product.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("libclang_rt.asan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("Copy"),
                                            .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                                            .equal(clangLibDarwinPath.join("libclang_rt.asan_osx_dynamic.dylib").str),])
                        task.checkCommandLineContains(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-resolve-src-symlinks", clangLibDarwinPath.join("libclang_rt.asan_osx_dynamic.dylib").str, "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks"])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                            .name("Copy Address Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                        ])
                        #expect(task.execDescription == "Copy Address Sanitizer library")
                    }

                    // There should be one task to copy the TSan library into the product.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("libclang_rt.tsan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("Copy"),
                                            .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                                            .equal(clangLibDarwinPath.join("libclang_rt.tsan_osx_dynamic.dylib").str)])
                        task.checkCommandLineContains(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-resolve-src-symlinks", clangLibDarwinPath.join("libclang_rt.tsan_osx_dynamic.dylib").str, "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks"])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                            .name("Copy Thread Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                        ])
                        #expect(task.execDescription == "Copy Thread Sanitizer library")
                    }

                    // There should be one code signing task for the ASan library.
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("libclang_rt.asan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("CodeSign"), .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib")])
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=identifier,entitlements,flags", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                            .name("Copy Address Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.asan_osx_dynamic.dylib"),
                            .any,
                            .any,
                        ])
                    }

                    // There should be one code signing task for the TSan library.
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("libclang_rt.tsan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("CodeSign"), .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib")])
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=identifier,entitlements,flags", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                            .name("Copy Thread Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                            .any,
                            .any,
                        ])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: overrides), runDestination: .macOS, fs: fs) { results in
                results.checkTarget(targetName) { target in
                    // There should not be any tasks to copy these sanitizer libraries into the product because they are enabled
                    // via variant-conditional build settings, and those are ignored for the "install" action.
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("libclang_rt.asan_osx_dynamic.dylib"))
                    results.checkNoTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("libclang_rt.tsan_osx_dynamic.dylib"))
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Check the thread sanitizer.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ENABLE_THREAD_SANITIZER": "YES"]), runDestination: .macOS, fs: fs) { results in
                results.checkTarget(targetName) { target in
                    // There should be one CompileC task, which includes the TSan option, and which puts its output in a -tsan directory.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkRuleInfo([.equal("CompileC"), .equal("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-tsan/x86_64/SourceFile.o"), .suffix("SourceFile.m"), .any, .any, .any, .any])
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "-fsanitize=thread", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-tsan/x86_64/SourceFile.o"])
                    }

                    // There should be one CompileSwiftSources task, which includes the TSan option, and which puts its output in a -tsan directory.
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-sanitize=thread", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-tsan/x86_64/\(targetName)-OutputFileMap.json"])
                    }

                    // There should be one Ld task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo([.equal("Ld"), .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/MacOS/\(targetName)"), .any])
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/MacOS/\(targetName)"])
                    }

                    // There should be one task to copy the TSan library into the product.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("libclang_rt.tsan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("Copy"),
                                            .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                                            .equal(clangLibDarwinPath.join("libclang_rt.tsan_osx_dynamic.dylib").str)])
                        task.checkCommandLineContains(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-resolve-src-symlinks", clangLibDarwinPath.join("libclang_rt.tsan_osx_dynamic.dylib").str, "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks"])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                            .name("Copy Thread Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                        ])
                        #expect(task.execDescription == "Copy Thread Sanitizer library")
                    }

                    // There should be two code signing tasks, one for the library and one for the product.
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("libclang_rt.tsan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("CodeSign"), .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib")])
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=identifier,entitlements,flags", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                            .name("Copy Thread Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.tsan_osx_dynamic.dylib"),
                            .any,
                            .any,
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).app")) { task in
                        task.checkRuleInfo([.equal("CodeSign"), .equal("\(SRCROOT)/build/Debug/\(targetName).app")])
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget.app.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/\(targetName).app"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }

            // Check the undefined behavior sanitizer.
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ENABLE_UNDEFINED_BEHAVIOR_SANITIZER": "YES"]), runDestination: .macOS, fs: fs) { results in
                results.checkTarget(targetName) { target in
                    // There should be one CompileC task, which includes the UBSan option, and which puts its output in a -ubsan directory.
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkRuleInfo([.equal("CompileC"), .equal("\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-ubsan/x86_64/SourceFile.o"), .suffix("SourceFile.m"), .any, .any, .any, .any])
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "-fsanitize=undefined", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-ubsan/x86_64/SourceFile.o"])
                    }

                    // There should be one CompileSwiftSources task, which puts its output in a -ubsan directory.  But the UBSan option is not passed for swift.
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "\(SRCROOT)/build/aProject.build/Debug/\(targetName).build/Objects-normal-ubsan/x86_64/\(targetName)-OutputFileMap.json"])
                    }

                    // There should be one Ld task.
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkRuleInfo([.equal("Ld"), .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/MacOS/\(targetName)"), .any])
                        task.checkCommandLineContains(["\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/MacOS/\(targetName)"])
                    }

                    // There should be one task to copy the UBSan library into the product.
                    results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("libclang_rt.ubsan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("Copy"),
                                            .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.ubsan_osx_dynamic.dylib"),
                                            .equal(clangLibDarwinPath.join("libclang_rt.ubsan_osx_dynamic.dylib").str)])
                        task.checkCommandLineContains(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-resolve-src-symlinks", clangLibDarwinPath.join("libclang_rt.ubsan_osx_dynamic.dylib").str, "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks"])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.ubsan_osx_dynamic.dylib"),
                            .name("Copy Undefined Behavior Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.ubsan_osx_dynamic.dylib"),
                        ])
                        #expect(task.execDescription == "Copy Undefined Behavior Sanitizer library")
                    }

                    // There should be two code signing tasks, one for the library and one for the product.
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("libclang_rt.ubsan_osx_dynamic.dylib")) { task in
                        task.checkRuleInfo([.equal("CodeSign"), .equal("\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.ubsan_osx_dynamic.dylib")])
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=identifier,entitlements,flags", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/\(targetName).app/Contents/Frameworks/libclang_rt.ubsan_osx_dynamic.dylib"])
                        task.checkInputs([
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.ubsan_osx_dynamic.dylib"),
                            .path("\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.ubsan_osx_dynamic.dylib"),
                            .name("Copy Undefined Behavior Sanitizer library \(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/libclang_rt.ubsan_osx_dynamic.dylib"),
                            .any,
                            .any,
                        ])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CodeSign"), .matchRuleItemBasename("\(targetName).app")) { task in
                        task.checkRuleInfo([.equal("CodeSign"), .equal("\(SRCROOT)/build/Debug/\(targetName).app")])
                        task.checkCommandLine(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", "\(SRCROOT)/build/aProject.build/Debug/AppTarget.build/AppTarget.app.xcent", "--timestamp=none", "--generate-entitlement-der", "\(SRCROOT)/build/Debug/\(targetName).app"])
                    }
                }

                // Check there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Check that missing target GUIDs are legal, not crashes.
    ///
    /// This is important because we allowing this to be valid can simplify the client logic in some situations.
    @Test(.requireSDKs(.macOS))
    func missingTargetDependency() async throws {
        let testTarget = TestPackageProductTarget("Foo",
                                                  frameworksBuildPhase: TestFrameworksBuildPhase(),
                                                  dependencies: ["Lib", "MISSING-DEP"])
        let libTarget = TestStandardTarget("Lib", type: .dynamicLibrary,
                                           buildPhases: [
                                            TestSourcesBuildPhase(["foo.c"]),
                                            TestFrameworksBuildPhase(
                                                [TestBuildFile(.target("OTHER-MISSING-DEP"))])])
        let testProject = TestPackageProject(
            "aProject",
            defaultConfigurationName: "Release",
            groupTree: TestGroup("Foo", children: [TestFile("foo.c")]),
            targets: [testTarget, libTarget])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])

        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkError(.prefix("Unable to resolve build file"))
            results.checkNoDiagnostics()
        }
    }

    /// Check task construction cancellation.
    @Test(.requireSDKs(.macOS))
    func buildPlanCancellation() async throws {
        let core = try await getCore()
        // Create a large-ish test workspace.
        let builder = RandomWorkspaceBuilder()
        builder.numTargets = 10
        builder.numFiles = 10
        let workspace = try builder.generate().load(core)

        // Marshal the workspace into a build request from which we can create a product plan.
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        workspaceContext.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid:12345, home: Path("/Users/exampleUser"), environment: [:]))
        workspaceContext.updateSystemInfo(SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: "x86_64"))

        let project = workspace.projects[0]
        let parameters = BuildParameters(configuration: "Debug")
        let buildTargets = project.targets.map{ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
        let buildPlanRequest = BuildPlanRequest(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, buildGraph: buildGraph, provisioningInputs: [:])

        let clientDelegate = MockTestTaskPlanningClientDelegate()

        // We check several scenarios of cancellation.
        do {
            let delegate = CancellingTaskPlanningDelegate(afterNodes: 1, clientDelegate: clientDelegate, workspace: workspace, fs: localFS)
            let plan = await BuildPlan(planRequest: buildPlanRequest, taskPlanningDelegate: delegate)
            #expect(plan == nil)
        }
        do {
            let delegate = CancellingTaskPlanningDelegate(afterTasks: 1, clientDelegate: clientDelegate, workspace: workspace, fs: localFS)
            let plan = await BuildPlan(planRequest: buildPlanRequest, taskPlanningDelegate: delegate)
            #expect(plan == nil)
        }
        do {
            let delegate = CancellingTaskPlanningDelegate(afterTasks: 50, clientDelegate: clientDelegate, workspace: workspace, fs: localFS)
            let plan = await BuildPlan(planRequest: buildPlanRequest, taskPlanningDelegate: delegate)
            #expect(plan == nil)
        }
    }

    @Test(.requireSDKs(.macOS))
    func perVariantSigning() async throws {
        let testProject = TestProject(
            "aProject",
            defaultConfigurationName: "Debug",
            groupTree: TestGroup(
                "Foo",
                children: [
                    TestFile("foo.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "INFOPLIST_FILE": "Info.plist",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "BUILD_VARIANTS": "normal profile",
                        "CODE_SIGN_IDENTITY": "-",
                    ]),
            ],
            targets: [
                TestAggregateTarget(
                    "Aggregate",
                    dependencies: [
                        "Tool",
                        "Framework",
                        "Application",
                    ]
                ),
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"]),
                    ]),
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"]),
                    ]),
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("Info.plist"), contents: "<dict/>")

        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Tool_profile"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Tool"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"))
            }

            results.checkTarget("Framework") { target in
                var profileBinarySigningTask: (any PlannedTask)! = nil
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/Framework_profile"])) { task in
                    profileBinarySigningTask = task
                }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A"])) { task in
                    // Check that the task to sign the framework's Versions/A folder follows the task to sign the profile binary.
                    if profileBinarySigningTask != nil {
                        results.checkTaskFollows(task, antecedent: profileBinarySigningTask)
                    }
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"))
            }

            results.checkTarget("Application") { target in
                var profileBinarySigningTask: (any PlannedTask)! = nil
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Application.app/Contents/MacOS/Application_profile"])) { task in
                    profileBinarySigningTask = task
                }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Application.app"])) { task in
                    // Check that the task to sign the app bundle follows the task to sign the profile binary.
                    if profileBinarySigningTask != nil {
                        results.checkTaskFollows(task, antecedent: profileBinarySigningTask)
                    }
                }
                results.checkNoTask(.matchTarget(target), .matchRuleType("CodeSign"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func pathNormalizationConsistency() async throws {
        let testProject = TestProject(
            "aProject",
            defaultConfigurationName: "Debug",
            groupTree: TestGroup(
                "Foo",
                children: [
                    TestFile("foo.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "INSTALL_PATH": "/foo/../bar", // rdar://32178321
                    ]),
            ],
            targets: [
                TestAggregateTarget(
                    "Aggregate",
                    dependencies: [
                        "Tool",
                    ]
                ),
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["foo.c"]),
                    ]),
            ])

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                // This really just checks that we didn't crash while creating strip with a path containing '/..' (rdar://32178321)
                results.checkTask(.matchTarget(target), .matchRuleType("Strip")) { _ in }
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func trailingSlashInInstallPathCorruption() async throws {
        let testProject = try await TestProject(
            "aProject",
            defaultConfigurationName: "Debug",
            groupTree: TestGroup(
                "Foo",
                children: [
                    TestFile("foo.swift"),
                    TestFile("MyFramework.h"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ]
                ),
            ],
            targets: [
                TestStandardTarget(
                    "MyFramework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                // This path has extra slashes on the end.
                                "INSTALL_PATH": "/foo/bar/",
                                "SKIP_INSTALL": "NO",
                                "DEFINES_MODULE": "YES",
                                "SWIFT_OBJC_INTERFACE_HEADER_NAME": "Header-Swift.h",
                                "SWIFT_INSTALL_OBJC_HEADER" : "YES",
                            ]
                        ),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([
                            TestBuildFile("MyFramework.h", headerVisibility: .public),
                        ]),
                        TestSourcesBuildPhase(["foo.swift"]),
                    ]
                ),
            ]
        )

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTarget("MyFramework") { target in

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("unextended-module-overlay.yaml")) { task, contents in
                    // This is verifying that the slash between Debug and MyFramework has not disappeared,
                    XCTAssertNoMatch(contents.unsafeStringValue, .contains("build/DebugMyFramework.framework/Modules"))
                    //   and also do this to assert that at least one string fragment from whence the slash might have disappeared actually does exist.
                    XCTAssertMatch(contents.unsafeStringValue, .contains("build/Debug/MyFramework.framework/Modules"))
                }
            }

            results.checkNoDiagnostics()
        }
    }

    /// Exercise some unusual behaviors in shell script build phases.
    @Test(.requireSDKs(.macOS))
    func scriptPhaseBehaviors() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.m"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ARCHS": "x86_64",
                    ]),
                TestBuildConfiguration(
                    "Release",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ARCHS": "x86_64 x86_64h",
                        "VALID_ARCHS": "$(inherited) x86_64h",
                        "BUILD_VARIANTS": "normal debug profile",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "Sources/Info.plist"]),
                        TestBuildConfiguration("Release", buildSettings: ["INFOPLIST_FILE": "Sources/Info.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                        TestShellScriptBuildPhase(name: "Run Script", shellPath: "/bin/sh", originalObjectID: "Run Script", contents: "echo \"Running script\"\nexit 0", alwaysOutOfDate: true)
                    ]
                ),
            ]
        )
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Presently we don't perform the Debug build.

        // Check the debug build.
        await tester.checkBuild(BuildParameters(configuration: "Release"), runDestination: .anyMac) { results in

            // Skip all the task types we don't care about.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("CompileC")) { _ in }
            results.checkTasks(.matchRuleType("Ld")) { _ in }
            results.checkTasks(.matchRuleType("CreateUniversalBinary")) { _ in }
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
            results.checkTasks(.matchRuleType("Touch")) { _ in }

            results.checkTarget("AppTarget") { target in
                // Check the RuleScriptExecution task.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Script-Run Script.sh")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution")) { task in
                    task.checkRuleInfo(["PhaseScriptExecution", "Run Script", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Script-Run Script.sh"])
                    task.checkCommandLine(["/bin/sh", "-c", "\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Script-Run\\ Script.sh"])

                    // Checking the settings pushed to the script in the environment.
                    task.checkEnvironment([
                        "LINK_FILE_LIST_normal_x86_64": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64/AppTarget.LinkFileList"),
                        "LINK_FILE_LIST_normal_x86_64h": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal/x86_64h/AppTarget.LinkFileList"),
                        "LINK_FILE_LIST_debug_x86_64": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-debug/x86_64/AppTarget.LinkFileList"),
                        "LINK_FILE_LIST_debug_x86_64h": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-debug/x86_64h/AppTarget.LinkFileList"),
                        "LINK_FILE_LIST_profile_x86_64": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-profile/x86_64/AppTarget.LinkFileList"),
                        "LINK_FILE_LIST_profile_x86_64h": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-profile/x86_64h/AppTarget.LinkFileList"),

                        "OBJECT_FILE_DIR_normal": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-normal"),
                        "OBJECT_FILE_DIR_debug": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-debug"),
                        "OBJECT_FILE_DIR_profile": .equal("\(SRCROOT)/build/aProject.build/Release/AppTarget.build/Objects-profile"),
                    ])
                }

                // Skip other WriteAuxiliaryFiles tasks.
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                // Skip build directory related tasks.
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

                // Skip the validate task.
                results.checkTasks(.matchRuleType("Validate")) { _ in }

                // The should be no other tasks for this target.
                results.checkNoTask(.matchTarget(target))
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There shouldn't be any task construction diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check recursive header search paths.
    @Test(.requireSDKs(.host))
    func recursiveHeaderSearchPaths() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Foo.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "USE_HEADERMAP": "NO",
                        "USER_HEADER_SEARCH_PATHS": "User/** /MissingPath/** OtherMissingPath/**",
                        "HEADER_SEARCH_PATHS": "System/**",
                        "FRAMEWORK_SEARCH_PATHS": "Framework/**",
                        "CLANG_USE_RESPONSE_FILE": "NO",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool", type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.c",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Create recursive header search test directories.
        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT).join("User/FooUser/Bar"), recursive: true)
        try fs.createDirectory(Path(SRCROOT).join("System/FooSystem/Bar"), recursive: true)
        try fs.createDirectory(Path(SRCROOT).join("Framework/FooFramework/Bar"), recursive: true)

        // Check the build.
        await tester.checkBuild(runDestination: .host, fs: fs) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                    let buildProductsDirSuffix = RunDestinationInfo.host.builtProductsDirSuffix
                    let iQuoteArgs = task.commandLine.enumerated().filter { (i, arg) in
                        (task.commandLine[safe: i - 1]?.asString ?? "") == "-iquote"
                    }.map{ $0.1.asString }
                    let capIArgs = task.commandLine.filter{ $0.asString.hasPrefix("-I") }.map{ $0.asString }
                    let capFArgs = task.commandLine.filter{ $0.asString.hasPrefix("-F") }.map{ $0.asString }
                    #expect(iQuoteArgs == [
                        "User", Path("User/FooUser").str, Path("User/FooUser/Bar").str,
                        Path("/MissingPath").str, "OtherMissingPath"])
                    #expect(capIArgs == [
                        "-I\(Path(SRCROOT).join("build/Debug\(buildProductsDirSuffix)/include").str)",
                        "-ISystem", "-I\(Path("System/FooSystem").str)", "-I\(Path("System/FooSystem/Bar").str)",
                        "-I\(Path(SRCROOT).join("build/aProject.build/Debug\(buildProductsDirSuffix)/Tool.build/DerivedSources-normal/\(results.runDestinationTargetArchitecture)").str)",
                        "-I\(Path(SRCROOT).join("build/aProject.build/Debug\(buildProductsDirSuffix)/Tool.build/DerivedSources/\(results.runDestinationTargetArchitecture)").str)",
                        "-I\(Path(SRCROOT).join("build/aProject.build/Debug\(buildProductsDirSuffix)/Tool.build/DerivedSources").str)"])
                    if RunDestinationInfo.host == .macOS {
                        #expect(capFArgs == [
                            "-F\(SRCROOT)/build/Debug",
                            "-FFramework", "-FFramework/FooFramework", "-FFramework/FooFramework/Bar"])
                    }
                }
            }

            // There shouldn't be any task construction diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check recursive search paths for the linker.
    @Test(.requireSDKs(.macOS))
    func recursiveSearchPathsForLinking() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Foo.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "USE_HEADERMAP": "NO",
                        "FRAMEWORK_SEARCH_PATHS": "Framework/**",
                        "LIBRARY_SEARCH_PATHS": "Library/**",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool", type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Foo.c",
                        ]),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Create recursive header search test directories.
        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT).join("Framework/A/B"), recursive: true)
        try fs.createDirectory(Path(SRCROOT).join("Library/A/B"), recursive: true)

        // Check the build.
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    let capLArgs = task.commandLine.filter{ $0.asString.hasPrefix("-L") }.map{ $0.asString }
                    let capFArgs = task.commandLine.filter{ $0.asString.hasPrefix("-F") }.map{ $0.asString }
                    #expect(capLArgs == [
                        "-L\(SRCROOT)/build/EagerLinkingTBDs/Debug",
                        "-L\(SRCROOT)/build/Debug",
                        "-LLibrary", "-LLibrary/A", "-LLibrary/A/B"])
                    #expect(capFArgs == [
                        "-F\(SRCROOT)/build/EagerLinkingTBDs/Debug",
                        "-F\(SRCROOT)/build/Debug",
                        "-FFramework", "-FFramework/A", "-FFramework/A/B"])
                }
            }

            // There shouldn't be any task construction diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func instrumentsPackage() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources", children: [
                    TestFile("PackageDefinition.instrpkg"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                    ]
                )],
            targets: [
                TestStandardTarget(
                    "Measure",
                    type: .instrumentsPackage,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["PackageDefinition.instrpkg"]),
                    ]
                ),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("BuildInstrumentsPackage")) { task in
                task.checkOutputs([
                    .pathPattern(.suffix("Packages/Measure.instrdst")),
                    .namePattern(.prefix("BuildInstrumentsPackage")),
                    .path("\(SRCROOT)/build/aProject.build/Debug/Measure.build/instruments-package-builder.dependencies"),
                    .path("\(SRCROOT)/build/aProject.build/Debug/Measure.build/instrumentbuilder-tmp"),
                ])
            }
            // Ensure that we do not try to generate a dSYM for an instrument package.
            results.checkNoTask(.matchRuleType("GenerateDSYMFile"))
        }
    }

    /// Test building a static library product.
    @Test(.requireSDKs(.macOS))
    func staticLibraries() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("File.c"),
                    TestFile("Object.o"),
                    TestFile("Framework.framework"),
                    TestFile("libAnotherStatic.a"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "arm64",
                    "LIBTOOL": libtoolPath.str,
                ]),
            ],
            targets: [
                // Test building a tool target which links a static library.
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["File.c"]),
                        TestFrameworksBuildPhase(["libStaticLib1.a"]),
                    ],
                    dependencies: ["StaticLib1"]
                ),
                // Test building a static library from several components.
                TestStandardTarget(
                    "StaticLib1",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["File.c"]),
                        TestFrameworksBuildPhase([
                            "libDynamicLib1.dylib",
                            "Object.o",
                            TestBuildFile(.auto("libStaticLib2.a"), shouldLinkWeakly: true),
                            TestBuildFile(.auto("libAnotherStatic.a"), shouldLinkWeakly: false),
                            TestBuildFile("Framework.framework", shouldLinkWeakly: true),
                        ]),
                    ],
                    dependencies: ["StaticLib2", "DynamicLib1"]
                ),
                TestStandardTarget(
                    "StaticLib2",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["File.c"]),
                    ]
                ),
                TestStandardTarget(
                    "DynamicLib1",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["File.c"]),
                    ]
                ),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    // The command line should contain an option to link against libStaticLib1.a, but not libStaticLib2.a.
                    task.checkCommandLineContains(["-lStaticLib1"])
                    task.checkCommandLineDoesNotContain("-lStaticLib2")
                }
            }

            results.checkTarget("StaticLib1") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                    task.checkRuleInfo(["Libtool", "\(SRCROOT)/build/Debug/libStaticLib1.a", "normal"])

                    // Check that the task contains a command line option to link libStaticLib2.a.
                    task.checkCommandLineContains(["-lStaticLib2"])
                    // Check that the task contains a command line option to link Framework.framework.
                    task.checkCommandLineContains(["-framework", "Framework"])
                    // Check that the task does *not* declare libAnotherStatic.a as an input, since it is located via search paths.  Some projects may have a file reference whose path does not refer to a file, but which relies on finding the library via search paths anyway.
                    task.checkNoInputs(contain: [.pathPattern(.suffix("libAnotherStatic.a"))])
                    // Check that the task does *not* declare libStaticLib2.a as an input, since it is located via search paths.  Some projects may have a file reference whose path does not refer to a file, but which relies on finding the library via search paths anyway.
                    task.checkNoInputs(contain: [.pathPattern(.suffix("libStaticLib2.a"))])
                    // Check that the task does *not* contain a command line option to link Object.o (it will be in the LinkFileList instead, checked below), but that it *does* declare it as an input.
                    task.checkCommandLineDoesNotContain("\(SRCROOT)/Object.o")
                    task.checkInputs(contain: [.path("\(SRCROOT)/Object.o")])

                    // Check that the task does *not* have a command line option to find libDynamicLib1.dylib, nor does it declare it as an input, because static libraries can't link against dynamic libraries.  We presently don't emit a diagnostic for this - see LibtoolLinkerSpec.constructLinkerTasks() and <rdar://problem/34314195> for more.
                    task.checkCommandLineDoesNotContain("-lDynamicLib1")
                    task.checkNoInputs(contain: [.pathPattern(.suffix("libDynamicLib1.dylib"))])

                    task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug/libStaticLib1.a")])
                }

                // Check the contents of the LinkFileList.
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix("/StaticLib1.LinkFileList"))) { task, contents in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/StaticLib1.build/Objects-normal/arm64/StaticLib1.LinkFileList"])
                    let contentsLines = contents.asString.dropLast().components(separatedBy: .newlines)
                    #expect(contentsLines == [
                        "\(SRCROOT)/build/aProject.build/Debug/StaticLib1.build/Objects-normal/arm64/File.o",
                        "\(SRCROOT)/Object.o",
                  ])
                }
            }

            results.checkTarget("StaticLib2") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                    task.checkRuleInfo(["Libtool", "\(SRCROOT)/build/Debug/libStaticLib2.a", "normal"])

                    task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug/libStaticLib2.a")])
                }
            }

            // Check that there are warnings about trying to weak-link libraries.
            results.checkWarning("Product libStaticLib1.a cannot weak-link static library libStaticLib2.a (in target 'StaticLib1' from project 'aProject')")
            results.checkWarning("Product libStaticLib1.a cannot weak-link framework Framework.framework (in target 'StaticLib1' from project 'aProject')")

            // Check that there are no other diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func packageProductsNoDuplicatedOutputs() async throws {
        let project = TestPackageProject("aPackage", groupTree: TestGroup("Package", children: [TestFile("File.c")]),
                                         buildConfigurations: [
                                            TestBuildConfiguration("Debug", buildSettings: [
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                            ]),
                                         ], targets: [
                                            TestStandardTarget("Tool", type: .application, buildConfigurations: [ TestBuildConfiguration("Debug") ], buildPhases: [ TestSourcesBuildPhase(["File.c"]), TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibProduct2")), TestBuildFile(.target("PackageLibProduct")) ]), TestCopyFilesBuildPhase([TestBuildFile(.target("PackageLibProduct"))], destinationSubfolder: .frameworks, onlyForDeployment: false) ], dependencies: ["PackageLibProduct2"]),
                                            TestStandardTarget("PackageLib", type: .objectFile),
                                            TestStandardTarget("PackageLib4", type: .objectFile),
                                            TestStandardTarget(
                                                "PackageLibProduct",
                                                type: .framework,
                                                buildConfigurations: [
                                                    // Targets need to opt-in to specialization.
                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                        "SDKROOT": "auto",
                                                        "SDK_VARIANT": "auto",
                                                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    ]),
                                                ],
                                                buildPhases: [TestFrameworksBuildPhase([TestBuildFile(.target("PackageLib"))])],
                                                dependencies: ["PackageLib"]
                                            ),
                                            TestPackageProductTarget(
                                                "PackageLibProduct2",
                                                frameworksBuildPhase: TestFrameworksBuildPhase([ TestBuildFile(.target("PackageLibProduct")), TestBuildFile(.target("PackageLibProduct3")), TestBuildFile(.target("PackageLibProduct4"), platformFilters: PlatformFilter.iOSFilters) ]),
                                                buildConfigurations: [
                                                    // Targets need to opt-in to specialization.
                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                        "SDKROOT": "auto",
                                                        "SDK_VARIANT": "auto",
                                                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    ]),
                                                ],
                                                dependencies: ["PackageLibProduct", "PackageLibProduct3", "PackageLibProduct4"]
                                            ),
                                            TestPackageProductTarget(
                                                "PackageLibProduct3",
                                                frameworksBuildPhase: TestFrameworksBuildPhase([ TestBuildFile(.target("PackageLibProduct4"), platformFilters: PlatformFilter.macOSFilters)]),
                                                buildConfigurations: [
                                                    // Targets need to opt-in to specialization.
                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                        "SDKROOT": "auto",
                                                        "SDK_VARIANT": "auto",
                                                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    ]),
                                                ],
                                                dependencies: ["PackageLibProduct4"]
                                            ),
                                            TestStandardTarget(
                                                "PackageLibProduct4",
                                                type: .framework,
                                                buildConfigurations: [
                                                    // Targets need to opt-in to specialization.
                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                        "SDKROOT": "auto",
                                                        "SDK_VARIANT": "auto",
                                                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    ]),
                                                ],
                                                buildPhases: [TestFrameworksBuildPhase([TestBuildFile(.target("PackageLib4"))])],
                                                dependencies: ["PackageLib4"]
                                            ),
                                         ])

        let tester = try await TaskConstructionTester(getCore(), project)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        func checkResults(_ results: TaskConstructionTester.PlanningResults) {
            results.checkTarget("Tool") { target in
                results.checkTasks(.matchTarget(target), .matchRuleType("Ld")) { tasks in
                    for task in tasks {
                        task.checkCommandLineContains(["-framework", "PackageLibProduct"])
                        task.checkCommandLineContains(["-framework", "PackageLibProduct4"])
                    }
                }
                // Check that there is a copy task to embed the dynamic framework into Tool.app.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("PackageLibProduct.framework")) { task in
                    task.checkInputs(contain: [.path("\(SRCROOT)/build/Debug/PackageLibProduct.framework")])
                    task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug/Tool.app/Contents/Frameworks/PackageLibProduct.framework")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItemBasename("PackageLibProduct4.framework")) { task in
                    task.checkInputs(contain: [.path("\(SRCROOT)/build/Debug/PackageLibProduct4.framework")])
                    task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug/Tool.app/Contents/Frameworks/PackageLibProduct4.framework")])
                }
            }

            // There would be diagnostics here if we ended up with duplicated outputs.
            results.checkNoErrors()
        }

        await tester.checkBuild(runDestination: .macOS) { results in checkResults(results) }
        await tester.checkBuild(runDestination: .iOS) { results in checkResults(results) }
    }

    // Test that we actually link and embed dynamic products if they were requested.
    @Test(.requireSDKs(.macOS, .iOS))
    func dynamicPackageProductGetsLinkedAndEmbedded() async throws {
        try await testDynamicPackageProductGetsLinkedAndEmbedded(destination: .macOS)
        try await testDynamicPackageProductGetsLinkedAndEmbedded(destination: .iOS)
    }

    func testDynamicPackageProductGetsLinkedAndEmbedded(destination: RunDestinationInfo) async throws {
        let core = try await getCore()
        let project = TestPackageProject("aPackage", groupTree: TestGroup("Package", children: [TestFile("File.c")]),
                                         buildConfigurations: [
                                            TestBuildConfiguration("Debug", buildSettings: [
                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
                                            ]),
                                         ], targets: [
                                            TestStandardTarget("Tool", type: .application, buildConfigurations: [ TestBuildConfiguration("Debug", buildSettings: ["SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)"]) ], buildPhases: [ TestSourcesBuildPhase(["File.c"]), TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibProduct")) ]) ], dependencies: ["PackageLibProduct"]),
                                            TestPackageProductTarget(
                                                "PackageLibProduct",
                                                frameworksBuildPhase: TestFrameworksBuildPhase([
                                                    TestBuildFile(.target("PackageLib"))]),
                                                dynamicTargetVariantName: "PackageLibProduct-dynamic",
                                                buildConfigurations: [
                                                    // Targets need to opt-in to specialization.
                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                        "SDKROOT": "auto",
                                                        "SDK_VARIANT": "auto",
                                                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    ]),
                                                ],
                                                dependencies: ["PackageLib"]
                                            ),
                                            TestStandardTarget("PackageLib", type: .objectFile),
                                            TestStandardTarget(
                                                "PackageLibProduct-dynamic",
                                                type: .framework,
                                                buildConfigurations: [
                                                    // Targets need to opt-in to specialization.
                                                    TestBuildConfiguration("Debug", buildSettings: [
                                                        "SDKROOT": "auto",
                                                        "SDK_VARIANT": "auto",
                                                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                    ]),
                                                ],
                                                buildPhases: [TestFrameworksBuildPhase([TestBuildFile(.target("PackageLib"))])],
                                                dependencies: ["PackageLib"]
                                            ),
                                         ])

        // This adds `PACKAGE_BUILD_DYNAMICALLY` as an override to activate dynamic variants of targets.
        let buildParameters = BuildParameters(action: .build, configuration: "Debug", activeRunDestination: RunDestinationInfo.macOS, activeArchitecture: nil, overrides: ["PACKAGE_BUILD_DYNAMICALLY": "YES"], commandLineOverrides: [:], commandLineConfigOverrides: [:], environmentConfigOverrides: [:], toolchainOverride: nil, arena: nil)

        let tester = try TaskConstructionTester(core, project)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // We need to construct a custom build request because `PACKAGE_BUILD_DYNAMICALLY` only works in the per-target parameters.
        let targets = tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: buildParameters.replacing(activeRunDestination: destination, activeArchitecture: nil), target: $0) })
        let buildRequest = BuildRequest(parameters: buildParameters.replacing(activeRunDestination: destination, activeArchitecture: nil), buildTargets: targets, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

        let fs = PseudoFS()
        try fs.createDirectory(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles"), recursive: true)
        try fs.write(Path("/Users/whoever/Library/MobileDevice/Provisioning Profiles/8db0e92c-592c-4f06-bfed-9d945841b78d.mobileprovision"), contents: "profile")

        await tester.checkBuild(buildParameters.replacing(activeRunDestination: destination, activeArchitecture: nil), runDestination: nil, buildRequest: buildRequest, fs: fs) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkCommandLineContains(["-framework", "PackageLibProduct-dynamic"])
                }
                // Check that there is a copy task to embed the dynamic framework into Tool.app.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy")) { task in
                    task.checkInputs(contain: [.path("\(SRCROOT)/build/Debug\(destination.builtProductsDirSuffix)/PackageLibProduct-dynamic.framework")])
                    switch destination {
                    case .macOS:
                        task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug/Tool.app/Contents/Frameworks/PackageLibProduct-dynamic.framework")])
                    default:
                        task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug\(destination.builtProductsDirSuffix)/Tool.app/Frameworks/PackageLibProduct-dynamic.framework")])
                    }
                }
                switch destination {
                case .macOS:
                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/Tool.app/Contents/Frameworks/PackageLibProduct-dynamic.framework/Versions/A"])) { _ in }
                default:
                    results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug\(destination.builtProductsDirSuffix)/Tool.app/Frameworks/PackageLibProduct-dynamic.framework"])) { _ in }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func weakLinking() async throws {
        try await withTemporaryDirectory { (tmpDirPath: Path) in
            let testWorkspace = try await TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [
                TestProject(
                    "aToolProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                            TestFile("SourceFile.swift"),
                            TestFile("Framework.framework"),
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "ARCH": "x86_64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                        ]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "Tool",
                            type: .commandLineTool,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug"),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["SourceFile.swift"]),
                                TestFrameworksBuildPhase([
                                    TestBuildFile(.target("Framework"), shouldLinkWeakly: true)
                                ])
                            ],
                            dependencies: ["Framework"]
                        ),
                    ]),
                TestProject(
                    "aFrameworkProject",
                    groupTree: TestGroup(
                        "SomeFiles",
                        children: [
                        ]),
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "ARCH": "x86_64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "TAPI_EXEC": tapiToolPath.str,
                        ]),
                    ],
                    targets: [
                        TestStandardTarget(
                            "Framework",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug"),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["SourceFile.swift"]),
                            ]
                        ),
                    ])
            ])

            let fs = localFS
            let tester = try await TaskConstructionTester(getCore(), testWorkspace)

            try fs.createDirectory(tmpDirPath.join("aFrameworkProject"), recursive: true)
            try fs.write(tmpDirPath.join("aFrameworkProject").join("SourceFile.swift"), contents: ByteString())

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkTarget("Tool") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineContainsUninterrupted(["-weak_library", "\(tmpDirPath.str)/aFrameworkProject/build/Debug/Framework.framework/Versions/A/Framework"])

                        task.checkInputs(contain: [
                            .path("\(tmpDirPath.str)/aFrameworkProject/build/Debug/Framework.framework/Versions/A/Framework")
                        ])
                    }
                }

                // Check that there are no diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test building an object file as a product.
    @Test(.requireSDKs(.macOS))
    func objectFileProduct() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.swift"),
                    TestFile("OtherObject.o"),
                    TestFile("Framework.framework"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ARCH": "x86_64",
                    "CODE_SIGN_IDENTITY": "-",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                ]),
            ],
            targets: [
                // Test building a tool target that links an object file product.
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.swift"]),
                        TestFrameworksBuildPhase(["ObjectFile1.o"]),
                    ],
                    dependencies: ["ObjectFile1"]
                ),
                // Test building an object file product from several components.
                TestStandardTarget(
                    "ObjectFile1",
                    type: .objectFile,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.swift"]),
                        TestFrameworksBuildPhase([
                            "libDynamicLib1.dylib",
                            "OtherObject.o",
                            TestBuildFile(.auto("ObjectFile2.o"), shouldLinkWeakly: true),
                            TestBuildFile("Framework.framework", shouldLinkWeakly: true),
                        ]),
                    ],
                    dependencies: ["ObjectFile2", "DynamicLib1"]
                ),
                TestStandardTarget(
                    "ObjectFile2",
                    type: .objectFile,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["OTHER_LDFLAGS": "-d"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.swift"]),
                    ]
                ),
                TestStandardTarget(
                    "DynamicLib1",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.swift"]),
                    ]
                ),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("Tool.LinkFileList")) { task, contents in
                    #expect(contents == "/tmp/Test/aProject/build/aProject.build/Debug/Tool.build/Objects-normal/x86_64/SourceFile.o\n/tmp/Test/aProject/build/Debug/ObjectFile1.o\n")
                    task.checkCommandLineDoesNotContain("\(SRCROOT)/build/Debug/ObjectFile2.o")
                }
            }

            results.checkTarget("ObjectFile1") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/ObjectFile1.o", "normal"])

                    // Check that the task contains a command line option to link Framework.framework.
                    task.checkCommandLineContains(["-weak_framework", "Framework"])

                    // Check that the task declare dependency on the object files its linking.
                    task.checkInputs(contain: [.pathPattern(.suffix("ObjectFile2.o"))])
                    task.checkInputs(contain: [.pathPattern(.suffix("OtherObject.o"))])

                    // Check that there aren't any -rpath flags, which aren't allowed for object file outputs.
                    task.checkCommandLineDoesNotContain("-rpath")

                    task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug/ObjectFile1.o")])
                }

                results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("ObjectFile1.LinkFileList")) { task, contents in
                    XCTAssertMatch(contents.unsafeStringValue, .contains("/tmp/Test/aProject/OtherObject.o"))
                    XCTAssertMatch(contents.unsafeStringValue, .contains("/tmp/Test/aProject/build/Debug/ObjectFile2.o"))
                }
            }

            results.checkTarget("ObjectFile2") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                    task.checkRuleInfo(["Ld", "\(SRCROOT)/build/Debug/ObjectFile2.o", "normal"])

                    task.checkCommandLineContains(["-d"])

                    task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug/ObjectFile2.o")])
                }
            }

            // Check that there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check the behavior of case-independent source file name collisions.
    @Test(.requireSDKs(.macOS))
    func caseIndependentSourceFileNameCollision() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("File.c", guid: "UPPER"),
                    TestFile("file.c", guid: "LOWER")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)"])],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["File.c", "file.c"])]
                )])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("File.c")) { task in
                    task.checkCommandLineContains(["\(SRCROOT)/build/aProject.build/Debug/Tool.build/Objects-normal/x86_64/File-\(BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: Path(SRCROOT).join("File.c"))).o"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("file.c")) { task in
                    task.checkCommandLineContains(["\(SRCROOT)/build/aProject.build/Debug/Tool.build/Objects-normal/x86_64/file-\(BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: Path(SRCROOT).join("file.c"))).o"])
                }
            }
        }
    }

    /// Check the working directory honors `sourceRoot`.
    @Test(.requireSDKs(.macOS))
    func workingDirectoryAndSourceRoot() async throws {
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [TestFile("a.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)", "CLANG_USE_RESPONSE_FILE": "NO",])],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["a.c"])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("a.c")) { task in
                #expect(task.workingDirectory == Path("/TEST"))
                #expect(task.inputs[safe: 0]?.path == Path("/TEST/Sources/a.c"))
            }
        }
    }

    /// Check situations where a prefix header should not be used.
    @Test(.requireSDKs(.macOS))
    func nonPrefixHeaderUse() async throws {
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [TestFile("a.s")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "CODE_SIGNING_ALLOWED": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                    "GCC_PREFIX_HEADER": "/tmp/does-not-exist",
                    "VERSIONING_SYSTEM": "apple-generic",
                ])],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["a.s"])])])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("a.s")) { _ in }
            results.checkTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("Tool_vers.c")) { _ in }
            results.checkTasks(.matchRuleType("Ld")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkNoTask(.matchRuleType("ProcessPCH"))
            results.checkNoTask()
        }
    }

    /// Check that we link using full paths for products in referenced projects.
    @Test(.requireSDKs(.macOS))
    func fullPathForLinkedProductsInReferencedProjects() async throws {
        let referencedProject = try await TestProject(
            "ReferencedProject",
            sourceRoot: Path("/TEST/REFERENCED"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [TestFile("Core.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "LIBTOOL": libtoolPath.str,
                ])],
            targets: [TestStandardTarget(
                "Core",
                type: .staticLibrary,
                buildPhases: [TestSourcesBuildPhase(["Core.c"])])])
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [TestFile("main.c"), TestFile("Other.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "LIBTOOL": libtoolPath.str,
                ])],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"]),
                        TestFrameworksBuildPhase(["libCore.a", "libOther.a"])],
                    dependencies: ["Core", "Other"]),
                TestStandardTarget(
                    "Other",
                    type: .staticLibrary,
                    buildPhases: [TestSourcesBuildPhase(["Other.c"])])])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject, referencedProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Libtool"), .matchRuleItemBasename("libCore.a")) { task in
                task.checkCommandLineContains(["-o", "/TEST/REFERENCED/build/Debug/libCore.a"])
            }
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineContains(["-lOther"])
                task.checkCommandLineContains(["/TEST/REFERENCED/build/Debug/libCore.a"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func taskIdentifierCollisionErrors() async throws {
        let testProject = TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.c"),
                    TestFile("lex.l"),
                    TestFile("image.png"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ])],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c", "lex.l"]),
                        TestResourcesBuildPhase(["lex.l"], onlyForDeployment: false),
                        TestCopyFilesBuildPhase(["image.png"], destinationSubfolder: .builtProductsDir, destinationSubpath: "images", onlyForDeployment: false),
                    ],
                    dependencies: ["Tool"]),
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"]),
                        TestCopyFilesBuildPhase(["image.png"], destinationSubfolder: .builtProductsDir, destinationSubpath: "images", onlyForDeployment: false),
                    ])])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS, checkTaskGraphIntegrity: false) { results in
            // The sources and resources build phase generate identical tasks in the same target.
            results.checkError(.equal([
                "Unexpected duplicate tasks",
                "Target 'App' (project 'aProject'): Lex /TEST/Sources/lex.l",
                "Target 'App' (project 'aProject'): Lex /TEST/Sources/lex.l"
            ].joined(separator: "\n")))

            // This is currently an expected warning as a result of putting lex.l in a resources phase
            results.checkWarning("unexpected C compiler invocation with specified outputs: '/TEST/build/Debug/App.app/Contents/Resources/lex.yy.c' (for input: '/TEST/build/aProject.build/Debug/App.build/DerivedSources/lex.yy.c') (in target 'App' from project 'aProject')")

            // Nothing left
            results.checkNoDiagnostics()

            // The App and Tool targets generate identical Copy tasks, but the task identifiers don't collide. This will get flagged downstream by the duplicate output file checker.
            results.checkTarget("App") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/TEST/build/Debug/images/image.png", "/TEST/Sources/image.png"])) { _ in }
            }
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/TEST/build/Debug/images/image.png", "/TEST/Sources/image.png"])) { _ in }
            }
        }
    }

    /// Check that the symlink target on install builds is normalized.
    @Test(.requireSDKs(.macOS))
    func installSymlinkNormalization() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                // This path has extra slashes in it.
                                "INSTALL_PATH": "///foo/bar",
                                "SKIP_INSTALL": "NO",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"]),
                        TestFrameworksBuildPhase([]),
                    ]),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTarget("Tool") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SymLink")) { task in
                    task.checkCommandLine(["/bin/ln", "-sfh", "../../../../aProject.dst/foo/bar/Tool", "/tmp/aWorkspace/aProject/build/Debug/Tool"])
                }
            }

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }

    /// Tests that the VFS overlay has no external-contents values which are not absolute paths
    @Test(.requireSDKs(.macOS))
    func vFSFileHasAbsoluteExternalPaths() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceOne.m"),
                    TestFile("FrameworkTarget.h"),
                    TestFile("MyInfo.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "DEFINES_MODULE": "YES",
                        // Public module map will be automatically generated
                        "MODULEMAP_PRIVATE_FILE": "A/B/private.modulemap",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "FrameworkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                        ]),
                    ]
                ),
            ])

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Define the private module map file on disk.
        //
        // FIXME: This can be removed, once we land: <rdar://problem/24564960> [Swift Build] Stop ingesting user-defined module map file contents at task construction time
        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT + "/A/B"), recursive: true)
        try fs.write(Path(SRCROOT + "/A/B/private.modulemap"), contents: "")

        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkTarget("FrameworkTarget") { target in

                func recursivelyForEachDict(_ item: PropertyListItem, _ body: ([String:PropertyListItem]) -> Void) {
                    if let item = item.dictValue {
                        body(item)
                        for (_, value) in item {
                            recursivelyForEachDict(value, body)
                        }
                    } else if let item = item.arrayValue {
                        for value in item {
                            recursivelyForEachDict(value, body)
                        }
                    }
                }

                results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml")) { task, contents in
                    do {
                        let plistItem = try PropertyList.fromJSONData(contents)
                        recursivelyForEachDict(plistItem) { dict in
                            if let toCheck = dict["external-contents"]?.stringValue {
                                #expect(Path(toCheck).isAbsolute, "Found external-contents path in VFS file which is not absolute")
                            }
                        }
                    } catch {
                        Issue.record("Could not parse VFS file")
                    }
                }
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func vFSFileHasConsistentContents() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Source.swift"),
                    TestFile("SourceOne.m"),
                    TestFile("FrameworkTarget.h"),
                    TestFile("FrameworkTarget2.h"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "DEFINES_MODULE": "YES",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "FrameworkTarget1",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_INSTALL_OBJC_HEADER": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Source.swift",
                            "SourceOne.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "FrameworkTarget2",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "Source.swift",
                            "SourceOne.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("FrameworkTarget2.h", headerVisibility: .public),
                        ]),
                    ]
                ),
            ])

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let parameters = BuildParameters(configuration: "Debug")
        let buildTargets = tester.workspace.projects[0].targets.map{ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }

        func recursivelyForEachDict(_ item: PropertyListItem, _ body: ([String:PropertyListItem]) -> Void) {
            if let item = item.dictValue {
                body(item)
                for (_, value) in item {
                    recursivelyForEachDict(value, body)
                }
            } else if let item = item.arrayValue {
                for value in item {
                    recursivelyForEachDict(value, body)
                }
            }
        }

        let request1 = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        var frame1VFSContents: ByteString?
        try await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: request1) { results in
            try results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml")) { task, contents in
                frame1VFSContents = contents
                var hasFrame1ObjCHeader = false
                let plistItem = try PropertyList.fromJSONData(contents)
                recursivelyForEachDict(plistItem) { dict in
                    if let filename = dict["name"]?.stringValue {
                        if filename == "FrameworkTarget1-Swift.h" {
                            hasFrame1ObjCHeader = true
                        }
                        #expect(filename != "FrameworkTarget2-Swift.h")
                    }
                }
                #expect(hasFrame1ObjCHeader)
            }
            results.checkNoDiagnostics()
        }

        let request2 = BuildRequest(parameters: parameters, buildTargets: buildTargets.reversed(), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: request2) { results in
            results.checkWriteAuxiliaryFileTask(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml")) { task, contents in
                #expect(contents == frame1VFSContents)
            }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func installCompatibilityHeaderAndSwiftinterfaceVerification() async throws {
        for installHeaderSetting in ["NO", "YES", nil] {
            for buildForDistribution in ["NO", "YES", nil] {
                var buildSettings = try await [
                    "CODE_SIGN_IDENTITY": "",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": "5"
                ]
                if let installHeaderSetting {
                    buildSettings["SWIFT_INSTALL_OBJC_HEADER"] = installHeaderSetting
                }
                if let buildForDistribution {
                    buildSettings["BUILD_LIBRARY_FOR_DISTRIBUTION"] = buildForDistribution
                }

                let testProject = TestProject(
                    "MyProject",
                    sourceRoot: Path("/MyProject"),
                    groupTree: TestGroup(
                        "SomeFiles",
                        path: "Sources",
                        children: [TestFile("SourceFile1.swift")]),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: buildSettings)],
                    targets: [
                        TestStandardTarget(
                            "MyFramework1",
                            type: .framework,
                            buildPhases: [
                                TestSourcesBuildPhase(["SourceFile1.swift"])
                            ]
                        )
                    ]
                )

                let tester = try await TaskConstructionTester(getCore(), testProject)
                await tester.checkBuild(runDestination: .macOS) { results in
                    results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                        if installHeaderSetting != "NO" && buildForDistribution == "YES" {
                            task.checkCommandLineContains(["-no-verify-emitted-module-interface"])
                        } else {
                            task.checkCommandLineDoesNotContain("-no-verify-emitted-module-interface")
                        }
                    }
                    results.checkNoDiagnostics()
                }
            }
        }
    }

    /// Tests that clang's PatternsOfFlagsNotAffectingPrecomps don't contribute to PCH hash.
    @Test(.requireSDKs(.macOS))
    func prefixHeaderHashIgnoresNeutralFlags() async throws {
        let testProject = TestProject("MyProject",
                                      sourceRoot: Path("/MyProject"),
                                      groupTree: TestGroup("SomeFiles",
                                                           path: "Sources",
                                                           children: [
                                                            TestFile("Prefix.pch"),
                                                            TestFile("SourceFile.m"),
                                                           ]),
                                      buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "GENERATE_INFOPLIST_FILE": "YES",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                                            "GCC_PREFIX_HEADER": "Prefix.pch",
                                        ])],
                                      targets: [
                                        TestStandardTarget("MyFramework",
                                                           type: .framework,
                                                           buildPhases: [
                                                            TestSourcesBuildPhase([
                                                                "SourceFile.m"
                                                            ])
                                                           ]
                                                          )
                                      ]
        )
        let fs = PseudoFS()
        try fs.createDirectory(Path("/MyProject/"), recursive: true)
        try fs.write(Path("/MyProject/Prefix.pch"), contents: [])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Record the PCH path of the first build.
        var firstBuildPCHPath: String? = nil
        await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: ["GCC_TREAT_WARNINGS_AS_ERRORS": "NO"]), runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("ProcessPCH")) { task in
                firstBuildPCHPath = task.ruleInfo[safe: 1]
            }

            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("SourceFile.m")) { task in
                #expect(!task.commandLine.contains("-Werror"))
            }
        }

        // Introduce a new warning flag that shouldn't effect the PCH hash.
        await tester.checkBuild(BuildParameters(configuration: "Debug", commandLineOverrides: ["GCC_TREAT_WARNINGS_AS_ERRORS": "YES"]), runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("ProcessPCH")) { task in
                #expect(firstBuildPCHPath == task.ruleInfo[safe: 1])
            }

            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("SourceFile.m")) { task in
                #expect(task.commandLine.contains("-Werror"))
            }
        }
    }

    /// <rdar://problem/47433446> Targets with the same DERIVED_FILE_DIR end up sharing precompiled headers even if they requested different prefix headers
    @Test(.requireSDKs(.macOS))
    func prefixHeaderDerivedFileDirCollision() async throws {
        let testProject = try await TestProject(
            "MyProject",
            sourceRoot: Path("/MyProject"),
            groupTree: TestGroup(
                "SomeFiles",
                path: "Sources",
                children: [
                    TestFile("Prefix1.pch"),
                    TestFile("Prefix2.pch"),
                    TestFile("SourceFile1.m"),
                    TestFile("SourceFile2.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                        "DERIVED_FILE_DIR": "$(CONFIGURATION_BUILD_DIR)/DerivedFileDir",
                        "USE_HEADERMAP": "NO",
                        "LIBTOOL": libtoolPath.str,
                    ])],
            targets: [
                TestAggregateTarget(
                    "All",
                    dependencies: [
                        "MyFramework1",
                        "MyFramework2",
                    ]
                ),
                TestStandardTarget(
                    "MyFramework1",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GCC_PREFIX_HEADER": "Prefix1.pch",
                        ])],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile1.m"
                        ])
                    ]
                ),
                TestStandardTarget(
                    "MyFramework2",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GCC_PREFIX_HEADER": "Prefix2.pch",
                        ])],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile2.m"
                        ])
                    ]
                ),
            ]
        )

        let fs = PseudoFS()
        try fs.createDirectory(Path("/MyProject/"), recursive: true)
        try fs.write(Path("/MyProject/Prefix1.pch"), contents: [])
        try fs.write(Path("/MyProject/Prefix2.pch"), contents: [])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("SourceFile1.m")) { task in
                task.checkCommandLineMatches([.suffix("Prefix1.pch")])
            }

            results.checkTask(.matchRuleType("CompileC"), .matchRuleItemBasename("SourceFile2.m")) { task in
                task.checkCommandLineMatches([.suffix("Prefix2.pch")])
            }
        }
    }

    /// Check the dependencies between prefix headers and module maps.
    @Test(.requireSDKs(.macOS))
    func prefixHeaderModuleMapDependencies() async throws {
        let testProject = TestProject("MyProject",
                                      sourceRoot: Path("/MyProject"),
                                      groupTree: TestGroup("SomeFiles",
                                                           path: "Sources",
                                                           children: [
                                                            TestFile("Prefix.pch"),
                                                            TestFile("SourceFile.m"),
                                                           ]),
                                      buildConfigurations: [
                                        TestBuildConfiguration("Debug", buildSettings: [
                                            "CODE_SIGN_IDENTITY": "",
                                            "PRODUCT_NAME": "$(TARGET_NAME)",
                                            "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                                            "GCC_PREFIX_HEADER": "Prefix.pch",
                                            "DEFINES_MODULE": "YES",
                                            "MODULEMAP_FILE": "MyFramework.modulemap",
                                        ])],
                                      targets: [
                                        TestStandardTarget("MyFramework",
                                                           type: .framework,
                                                           buildPhases: [
                                                            TestSourcesBuildPhase([
                                                                "SourceFile.m"
                                                            ])
                                                           ]
                                                          )
                                      ]
        )
        let fs = PseudoFS()
        try fs.createDirectory(Path("/MyProject/"), recursive: true)
        try fs.write(Path("/MyProject/Prefix.pch"), contents: [])
        try fs.write(Path("/MyProject/MyFramework.modulemap"), contents: [])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("Touch")) { _ in }
            results.checkTasks(.matchRuleType("SymLink")) { _ in }
            results.checkTasks(.matchRuleType("GenerateTAPI")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
            results.checkTasks(.matchRuleType("Copy"), .matchRuleItemBasename("module.modulemap")) { _ in }
            // Make sure there was only one precompilation task.
            results.checkTask(.matchRuleType("ProcessPCH"), .matchRuleItemBasename("Prefix.pch")) { task in
                #expect(task.inputs.contains(where: { $0.path.basename == "Prefix.pch" }))
                // Here we will put other dependency assertions if warranted.  Right now there is only the dependency on the prefix header itself.
            }
            results.checkTasks(.matchRuleType("CompileC"), .matchRuleItemBasename("SourceFile.m")) { _ in }
            results.checkTasks(.matchRuleType("Ld"), .matchRuleItemBasename("MyFramework")) { _ in }
            results.checkNoTask()
        }
    }


    // Check that we can emit build plan diagnostics when asked to do so.
    @Test(.requireSDKs(.macOS))
    func buildPlanDumping() async throws {
        let testProject = TestProject(
            "MyToolProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "MyToolTarget",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "INSTALL_PATH": "/foo",
                                "SKIP_INSTALL": "NO",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"]),
                        TestFrameworksBuildPhase([]),
                    ],
                    dependencies: []),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        // We are just trying not to crash here, so no further checks.
        try await tester.checkBuild(runDestination: .macOS) { planningResults in
            let fs = localFS
            try withTemporaryDirectory(fs: fs) { tmpDir in
                // Clear out any existing temporary build plan directory.
                let buildPlanDumpDir = tmpDir.join("build-plans")
                try fs.removeDirectory(buildPlanDumpDir)

                // Ask the build plan to dump diagnostic information into a set of files in a specified directory.
                try planningResults.buildPlan.write(to: buildPlanDumpDir, fs: fs)
                #expect(fs.isDirectory(buildPlanDumpDir))

                // Do some correctness checking on the diagnostic files.
                #expect(fs.isDirectory(buildPlanDumpDir.join("MyToolProject")))
                #expect(fs.exists(buildPlanDumpDir.join("MyToolProject").join("MyToolTarget.txt")))

                // Finally, remove the directory again.
                try fs.removeDirectory(buildPlanDumpDir)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func pCHProcessingFollowsGeneratedHeaders() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("other.m"),
                    TestFile("header.pch")
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                        "GCC_PREFIX_HEADER": "header.pch",
                        "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                        "SWIFT_OBJC_INTERFACE_HEADER_NAME": "Header-Swift.h",
                        "CLANG_USE_RESPONSE_FILE": "NO",
                    ])],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift", "other.m"]),
                    ])])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget("App") { target in
                let compileSwiftTaskOpt = results.getTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                let processPCHTaskOpt = results.getTask(.matchTarget(target), .matchRuleType("ProcessPCH"))
                results.checkTaskExists(.matchTarget(target), .matchRuleType("CompileC"))

                guard let compileSwiftTask = compileSwiftTaskOpt, let processPCHTask = processPCHTaskOpt else {
                    Issue.record("unable to find expected tasks")
                    return
                }

                // Compiling Swift has to happen before processing the PCH, because it generates the `-Swift` header.
                guard let swiftGeneratedHeadersGate = processPCHTask.inputs[safe: 2] else {
                    Issue.record("missing expected gate")
                    return
                }
                #expect(compileSwiftTask.mustPrecede[0].instance.outputs[0] === swiftGeneratedHeadersGate)
            }
        }
    }

    /// Test that the prefix header gets precompiled for the correct dialects.
    @Test(.requireSDKs(.macOS))
    func precompiledHeaderDialectSupport() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Framework-Prefix.pch"),
                    TestFile("FileOne.c"),
                    TestFile("ClassTwo.m"),
                    TestFile("ClassThree.cpp"),
                    TestFile("ClassFour.mm"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ])
            ],
            targets: [
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GCC_PREFIX_HEADER": "Sources/Framework-Prefix.pch",
                                "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "FileOne.c",
                            "ClassTwo.m",
                            "ClassThree.cpp",
                            "ClassFour.mm",
                        ]),
                    ]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        // Test that we get a precompile task for each dialect.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("Framework") { target in
                // Check that there is a task to precompile the prefix header for each dialect.
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessPCH"), .matchRuleItem("c")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessPCH"), .matchRuleItem("objective-c")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessPCH++"), .matchRuleItem("c++")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessPCH++"), .matchRuleItem("objective-c++")) { _ in }

                // Check that there are tasks to compile all four source files.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("FileOne.c"), .matchRuleItem("c")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ClassTwo.m"), .matchRuleItem("objective-c")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ClassThree.cpp"), .matchRuleItem("c++")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ClassFour.mm"), .matchRuleItem("objective-c++")) { _ in }
            }

            results.checkNoDiagnostics()
        }

        // Use GCC_PFE_FILE_C_DIALECTS to only precompile for objective-c++.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["GCC_PFE_FILE_C_DIALECTS": "objective-c++"]), runDestination: .macOS) { results in
            results.checkTarget("Framework") { target in
                // Check that there is a task to precompile the prefix header *only* for ObjC++.
                results.checkNoTask(.matchTarget(target), .matchRuleType("ProcessPCH"), .matchRuleItem("c"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("ProcessPCH"), .matchRuleItem("objective-c"))
                results.checkNoTask(.matchTarget(target), .matchRuleType("ProcessPCH++"), .matchRuleItem("c++"))
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessPCH++"), .matchRuleItem("objective-c++")) { _ in }

                // Check that there are tasks to compile all four source files.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("FileOne.c"), .matchRuleItem("c")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ClassTwo.m"), .matchRuleItem("objective-c")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ClassThree.cpp"), .matchRuleItem("c++")) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ClassFour.mm"), .matchRuleItem("objective-c++")) { _ in }
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func precompiledHeaderDependencyOnModuleMaps() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Framework.h"),
                    TestFile("ClassOne.m"),
                    TestFile("Framework-Prefix.pch"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": swiftVersion,
                        "CLANG_USE_RESPONSE_FILE": "NO",
                    ])
            ],
            targets: [
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GCC_PREFIX_HEADER": "Sources/Framework-Prefix.pch",
                                "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                                "DEFINES_MODULE": "YES",
                                "PRODUCT_MODULE_NAME": "Framework",
                                // The public .modulemap file will be synthesized.
                                "MODULEMAP_PRIVATE_FILE": "Sources/Framework-Private.modulemap",
                            ]),
                    ],
                    buildPhases: [
                        TestHeadersBuildPhase([TestBuildFile("Framework.h", headerVisibility: .public)]),
                        TestSourcesBuildPhase(["ClassOne.m"]),
                    ]
                ),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Define the private module map file on disk.
        //
        // FIXME: This can be removed, once we land: <rdar://problem/24564960> [Swift Build] Stop ingesting user-defined module map file contents at task construction time
        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
        try fs.write(Path(SRCROOT).join("Sources/Framework-Private.modulemap"), contents: "foo")

        try await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Gate"])

            try results.checkTarget("Framework") { target in
                let processPCHTask: any PlannedTask = try results.checkTask(.matchTarget(target), .matchRuleType("ProcessPCH")) { task in
                    task.checkInputs([
                        .path("\(SRCROOT)/Sources/Framework-Prefix.pch"),
                        .path("\(SRCROOT)/build/Debug/Framework.framework/Versions/A/Modules/module.modulemap"),
                        .path("\(SRCROOT)/build/Debug/Framework.framework/Versions/A/Modules/module.private.modulemap"),
                        .any,
                        .any,
                        .any,
                        .any,
                        .any,
                    ])

                    return task
                }

                // Check that there are tasks to generate the .modulemap files, and that the ProcessPCH command depends on the .modulemap files.
                results.checkTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Debug/Framework.build/module.modulemap"])) { task in
                    results.checkTaskDependsOn(processPCHTask, antecedent: task)
                }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Debug/Framework.build/module.modulemap"])) { task in
                    results.checkTaskDependsOn(processPCHTask, antecedent: task)
                }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/aProject.build/Debug/Framework.build/module.private.modulemap", "\(SRCROOT)/Sources/Framework-Private.modulemap"])) { task in
                    results.checkTaskDependsOn(processPCHTask, antecedent: task)
                }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/Debug/Framework.framework/Versions/A/Modules/module.private.modulemap", "\(SRCROOT)/build/aProject.build/Debug/Framework.build/module.private.modulemap"])) { task in
                    results.checkTaskDependsOn(processPCHTask, antecedent: task)
                }

                results.checkTasks(.matchTarget(target)) { _ in }
            }

            results.checkTaskExists(.matchRuleType("WriteAuxiliaryFile"), .matchRuleItemBasename("all-product-headers.yaml"))

            results.checkNoTask()
        }
    }

    @Test(.requireSDKs(.macOS))
    func sourceInputFileFollowsGeneratedHeaders() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.swift"),
                    TestFile("other.m")
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                        "SWIFT_OBJC_INTERFACE_HEADER_NAME": "Header-Swift.h",
                        "RUN_CLANG_STATIC_ANALYZER": "YES",
                        "CLANG_USE_RESPONSE_FILE": "NO",
                    ])],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift", "other.m"]),
                    ])])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget("App") { target in
                let compileSwiftTaskOpt = results.getTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements"))
                let analyzeTaskOpt = results.getTask(.matchTarget(target), .matchRuleType("AnalyzeShallow"))
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { _ in }

                guard let compileSwiftTask = compileSwiftTaskOpt, let analyzeTask = analyzeTaskOpt else {
                    Issue.record("unable to find expected tasks")
                    return
                }

                // Compiling Swift has to happen before analyzing, because it generates the `-Swift` header.
                guard let swiftGeneratedHeadersGate = analyzeTask.inputs[safe: 2] else {
                    Issue.record("missing expected gate")
                    return
                }
                #expect(compileSwiftTask.mustPrecede[0].instance.outputs[0] === swiftGeneratedHeadersGate)
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func requiresArm64Arm64e() async throws {

        // Defines expected required arch for a given ARCHS build setting
        let testScenarios = [
            (archsBuildSetting: "arm64",        requiredArch: "arm64"),
            (archsBuildSetting: "arm64e",       requiredArch: "arm64e"),
            (archsBuildSetting: "arm64 arm64e", requiredArch: "arm64"),
        ]

        for (archsBuildSetting, requiredArch) in testScenarios {
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("Foo.swift"),
                        TestFile("CoreFoo.h"),
                        TestFile("Info.plist"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
                ],
                targets: [
                    TestStandardTarget(
                        "CoreFoo", type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug",
                                                   buildSettings: [
                                                    "CODE_SIGN_IDENTITY": "",
                                                    "SDKROOT": "iphoneos",
                                                    "DEFINES_MODULE": "YES",
                                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                                    "SWIFT_VERSION": swiftVersion,
                                                    "TAPI_EXEC": tapiToolPath.str,
                                                    "ARCHS": archsBuildSetting,
                                                    "INFOPLIST_FILE": "Sources/Info.plist"
                                                   ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["Foo.swift"]),
                            TestHeadersBuildPhase([
                                TestBuildFile("CoreFoo.h", headerVisibility: .public),
                            ]),
                        ])
                ])

            let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
            let tester = try await TaskConstructionTester(getCore(), testWorkspace)

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            await tester.checkBuild(runDestination: .iOS) { results in
                results.checkTarget("CoreFoo") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                        task.checkCommandLine(["builtin-infoPlistUtility", "\(SRCROOT)/Sources/Info.plist", "-producttype", "com.apple.product-type.framework", "-expandbuildsettings", "-format", "binary", "-platform", "iphoneos", "-requiredArchitecture", requiredArch, "-o", "\(SRCROOT)/build/Debug-iphoneos/CoreFoo.framework/Info.plist"])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.watchOS))
    func requiresArm64watchos() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Foo.swift"),
                    TestFile("CoreFoo.h"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)"]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "CODE_SIGN_IDENTITY": "",
                                                "SDKROOT": "watchos",
                                                "DEFINES_MODULE": "YES",
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                                "TAPI_EXEC": tapiToolPath.str,
                                                "ARCHS": "arm64_32",
                                                "INFOPLIST_FILE": "Sources/Info.plist"
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Foo.swift"]),
                        TestHeadersBuildPhase([
                            TestBuildFile("CoreFoo.h", headerVisibility: .public),
                        ]),
                    ])
            ])

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .watchOS) { results in
            results.checkTarget("CoreFoo") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("ProcessInfoPlistFile")) { task in
                    // check that command line does not include -requiredArchitecture
                    task.checkCommandLine(["builtin-infoPlistUtility", "\(SRCROOT)/Sources/Info.plist", "-producttype", "com.apple.product-type.framework", "-expandbuildsettings", "-format", "binary", "-platform", "watchos", "-o", "\(SRCROOT)/build/Debug-watchos/CoreFoo.framework/Info.plist"])
                }
            }
        }
    }

    /// This tests an edge case in which a product is configured with multiple `ARCHS`, but `EXCLUDED_SOURCE_FILE_NAMES` is set to exclude compiling all files for one architecture. So we copy the single-arch binary into the place where we would lipo the multi-arch binary if there were multiple architectures.
    @Test(.requireSDKs(.macOS))
    func multiArchConfigurationYieldsSingleArchBinary() async throws {
        let SDKROOT = "macosx"
        let builtArch = "arm64"
        let skippedArch = "x86_64"

        // Configure the project for the test.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.m"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": SDKROOT,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            // It's hard to find multiple architectures
                            "ARCHS": "\(builtArch) \(skippedArch)",
                            "INFOPLIST_FILE": "Sources/Info.plist",
                            "EXCLUDED_SOURCE_FILE_NAMES[arch=\(skippedArch)]": "*",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "main.m",
                        ]),
                    ])
            ])

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .anyMac) { results in
            results.checkNoDiagnostics()
            results.consumeTasksMatchingRuleTypes(["Gate", "MkDir", "SymLink", "WriteAuxiliaryFile", "Touch", "RegisterWithLaunchServices"])

            results.checkTarget("CoreFoo") { target in
                // Check that we have a compile and link task for the built arch.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem("\(SRCROOT)/Sources/main.m"), .matchRuleItem(builtArch)) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItemBasename("CoreFoo"), .matchRuleItem(builtArch)) { _ in }

                // Check that we do *not* have a compile or link task for the skipped arch, and that we don't have a lipo task either.
                results.checkNoTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem("\(SRCROOT)/Sources/main.m"), .matchRuleItem(skippedArch))
                results.checkNoTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItemBasename("CoreFoo"), .matchRuleItem(skippedArch))
                results.checkNoTask(.matchTarget(target), .matchRuleType("CreateUniversalBinary"))

                // Check that there is a copy task to copy the single-arch binary to the final location.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/CoreFoo.build/Objects-normal/\(builtArch)/Binary/CoreFoo"), .matchRuleItem("\(SRCROOT)/build/Debug/CoreFoo.framework/Versions/A/CoreFoo")) { _ in }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildWarningsForFilesInImproperBuildPhase() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceOne.m"),
                    TestFile("Entitlements.entitlements"),
                    TestFile("MyInfo.plist"),
                    TestFile("LinkOrderFile.txt"),
                    TestFile("Some/Config/Location/ExportedSymbols.exp"),
                    TestFile("UnexportedSymbols.exp")
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.entitlements",
                        "ORDER_FILE": "LinkOrderFile.txt",
                        "EXPORTED_SYMBOLS_FILE": "Some/Config/Location/ExportedSymbols.exp",
                        "UNEXPORTED_SYMBOLS_FILE": "Fake/Location/../../UnexportedSymbols.exp"
                    ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "CODE_SIGN_IDENTITY": "-",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "FrameworkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                        TestBuildConfiguration("Release", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("Entitlements.entitlements"),
                            TestBuildFile("MyInfo.plist"),
                            TestBuildFile("Some/Config/Location/ExportedSymbols.exp"),
                            TestBuildFile("LinkOrderFile.txt"),
                            TestBuildFile("UnexportedSymbols.exp")
                        ]),
                        TestResourcesBuildPhase([
                            "Entitlements.entitlements",
                            "MyInfo.plist",
                            "Some/Config/Location/ExportedSymbols.exp",
                            "LinkOrderFile.txt",
                            "UnexportedSymbols.exp"
                        ]),
                        TestCopyFilesBuildPhase([
                            "Entitlements.entitlements",
                            "MyInfo.plist",
                            "Some/Config/Location/ExportedSymbols.exp",
                            "LinkOrderFile.txt",
                            "UnexportedSymbols.exp"
                        ], destinationSubfolder: .resources, destinationSubpath: "Test", onlyForDeployment: false),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("FrameworkTarget") { target in
                results.checkWarning(.prefix("The Copy Bundle Resources build phase contains this target's entitlements file '\(SRCROOT)/Entitlements.entitlements"))
                results.checkWarning(.prefix("The Copy Bundle Resources build phase contains this target's Info.plist file '\(SRCROOT)/MyInfo.plist"))
                results.checkWarning(.prefix("The Copy Bundle Resources build phase contains this target's exported symbols file '\(SRCROOT)/Some/Config/Location/ExportedSymbols.exp"))
                results.checkWarning(.prefix("The Copy Bundle Resources build phase contains this target's unexported symbols file '\(SRCROOT)/UnexportedSymbols.exp"))
                results.checkWarning(.prefix("The Copy Bundle Resources build phase contains this target's order file '\(SRCROOT)/LinkOrderFile.txt"))

                results.checkWarning(.prefix("The Copy Headers build phase contains this target's entitlements file '\(SRCROOT)/Entitlements.entitlements"))
                results.checkWarning(.prefix("The Copy Headers build phase contains this target's Info.plist file '\(SRCROOT)/MyInfo.plist"))
                results.checkWarning(.prefix("The Copy Headers build phase contains this target's exported symbols file '\(SRCROOT)/Some/Config/Location/ExportedSymbols.exp"))
                results.checkWarning(.prefix("The Copy Headers build phase contains this target's unexported symbols file '\(SRCROOT)/UnexportedSymbols.exp"))
                results.checkWarning(.prefix("The Copy Headers build phase contains this target's order file '\(SRCROOT)/LinkOrderFile.txt"))

                results.checkWarning(.prefix("The Copy Files build phase contains this target's entitlements file '\(SRCROOT)/Entitlements.entitlements"))
                results.checkWarning(.prefix("The Copy Files build phase contains this target's Info.plist file '\(SRCROOT)/MyInfo.plist"))
                results.checkWarning(.prefix("The Copy Files build phase contains this target's exported symbols file '\(SRCROOT)/Some/Config/Location/ExportedSymbols.exp"))
                results.checkWarning(.prefix("The Copy Files build phase contains this target's unexported symbols file '\(SRCROOT)/UnexportedSymbols.exp"))
                results.checkWarning(.prefix("The Copy Files build phase contains this target's order file '\(SRCROOT)/LinkOrderFile.txt"))

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func scriptRuleWithFileLists() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("foo.c.txt"),
                    TestFile("bar.c.txt"),
                    TestFile("baz.c.txt"),
                    TestFile("input1.xcfilelist"),
                    TestFile("input2.xcfilelist"),
                    TestFile("output1.xcfilelist"),
                    TestFile("output2.xcfilelist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestShellScriptBuildPhase(name: "Run Script", shellPath: "/bin/sh", originalObjectID: "FileList", contents: "echo hi", inputs: ["$(SRCROOT)/foo.c.txt"], inputFileLists: ["$(SRCROOT)/input1.xcfilelist", "$(SRCROOT)/input2.xcfilelist"], outputs: ["$(DERIVED_FILE_DIR)/foo.c"], outputFileLists: ["$(SRCROOT)/output1.xcfilelist", "$(SRCROOT)/output2.xcfilelist"])
                    ],
                    buildRules: []),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("input1.xcfilelist"), contents: "$(SRCROOT)/bar.c.txt\n$(SRCROOT)/baz.c.txt")
        try fs.write(Path(SRCROOT).join("input2.xcfilelist"), contents: "\n\n\n")
        try fs.write(Path(SRCROOT).join("output1.xcfilelist"), contents: "$(DERIVED_FILE_DIR)/bar.c\n$(DERIVED_FILE_DIR)/baz.c")
        try fs.write(Path(SRCROOT).join("output2.xcfilelist"), contents: "#A comment to be ignored.\n\n      # whitespace prefixed comment - ignore\n\n\n")

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("Touch")) { _ in }

                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/App.build/Script-FileList.sh")) { task in
                    task.checkRuleInfo(["PhaseScriptExecution", "Run Script", "\(SRCROOT)/build/aProject.build/Debug/App.build/Script-FileList.sh"])
                    task.checkCommandLine(["/bin/sh", "-c", "/tmp/Test/aProject/build/aProject.build/Debug/App.build/Script-FileList.sh"])

                    task.checkInputs([
                        // Check that we normalized the path passed to the script.
                        .path("\(SRCROOT)/foo.c.txt"),
                        .path("\(SRCROOT)/input1.xcfilelist"),
                        .path("\(SRCROOT)/input2.xcfilelist"),
                        .path("\(SRCROOT)/output1.xcfilelist"),
                        .path("\(SRCROOT)/output2.xcfilelist"),
                        .path("\(SRCROOT)/bar.c.txt"),
                        .path("\(SRCROOT)/baz.c.txt"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/InputFileList-FileList-input1-37ee743e55b3c53330093d7b0b8cd56c-resolved.xcfilelist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/InputFileList-FileList-input2-60efd0de639c852aeb6c923fc58fe155-resolved.xcfilelist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/OutputFileList-FileList-output1-9e204e1839af2864ef74daf50be90959-resolved.xcfilelist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/OutputFileList-FileList-output2-49b85065e1ab5f8726dafd7606a852ce-resolved.xcfilelist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Script-FileList.sh"),
                        .any,
                        .any
                    ])

                    #expect(task.inputs.filter({ $0.name == "bar.c.txt" }).count == 1)
                    #expect(task.inputs.filter({ $0.name == "baz.c.txt" }).count == 1)

                    task.checkOutputs([
                        // Verify the command has a virtual output node that can be used as a dependency.
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/foo.c"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/bar.c"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/baz.c"),
                    ])

                    // Validate that the task has a reasonable environment.
                    // This check is used both to verify behaviors specific to this test, and also important behaviors which apply to all scripts which we want to ensure are tested.
                    let scriptVariables: [String: StringPattern?] = [
                        "ACTION": .equal("build"),
                        "TARGET_NAME": .equal("App"),
                        "SCRIPT_INPUT_FILE_0": .equal("\(SRCROOT)/foo.c.txt"),
                        "SCRIPT_INPUT_FILE_COUNT": .equal("1"),

                        "SCRIPT_OUTPUT_FILE_0": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/foo.c"),
                        "SCRIPT_OUTPUT_FILE_COUNT": .equal("1"),

                        "SCRIPT_INPUT_FILE_LIST_0": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/InputFileList-FileList-input1-37ee743e55b3c53330093d7b0b8cd56c-resolved.xcfilelist"),
                        "SCRIPT_INPUT_FILE_LIST_1": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/InputFileList-FileList-input2-60efd0de639c852aeb6c923fc58fe155-resolved.xcfilelist"),
                        "SCRIPT_INPUT_FILE_LIST_COUNT": .equal("2"),

                        "SCRIPT_OUTPUT_FILE_LIST_0": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/OutputFileList-FileList-output1-9e204e1839af2864ef74daf50be90959-resolved.xcfilelist"),
                        "SCRIPT_OUTPUT_FILE_LIST_1": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/OutputFileList-FileList-output2-49b85065e1ab5f8726dafd7606a852ce-resolved.xcfilelist"),
                        "SCRIPT_OUTPUT_FILE_LIST_COUNT": .equal("2"),

                        "TOOLCHAIN_DIR": .equal("\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain"),
                    ]
                    task.checkEnvironment(scriptVariables)
                }
            }
        }

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: ["USE_RECURSIVE_SCRIPT_INPUTS_IN_SCRIPT_PHASES": "YES"]), runDestination: .macOS, fs: fs) { results in
            results.checkTarget("App") { target in
                results.checkNoDiagnostics()
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("Touch")) { _ in }

                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Debug/App.build/Script-FileList.sh")) { task in
                    task.checkRuleInfo(["PhaseScriptExecution", "Run Script", "\(SRCROOT)/build/aProject.build/Debug/App.build/Script-FileList.sh"])
                    task.checkCommandLine(["/bin/sh", "-c", "/tmp/Test/aProject/build/aProject.build/Debug/App.build/Script-FileList.sh"])

                    task.checkInputs([
                        // Check that we normalized the path passed to the script.
                        .path("\(SRCROOT)/foo.c.txt"),
                        .path("\(SRCROOT)/input1.xcfilelist"),
                        .path("\(SRCROOT)/input2.xcfilelist"),
                        .path("\(SRCROOT)/output1.xcfilelist"),
                        .path("\(SRCROOT)/output2.xcfilelist"),
                        .path("\(SRCROOT)/bar.c.txt"),
                        .path("\(SRCROOT)/baz.c.txt"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/InputFileList-FileList-input1-37ee743e55b3c53330093d7b0b8cd56c-resolved.xcfilelist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/InputFileList-FileList-input2-60efd0de639c852aeb6c923fc58fe155-resolved.xcfilelist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/OutputFileList-FileList-output1-9e204e1839af2864ef74daf50be90959-resolved.xcfilelist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/OutputFileList-FileList-output2-49b85065e1ab5f8726dafd7606a852ce-resolved.xcfilelist"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/Script-FileList.sh"),
                        .any,
                        .any
                    ])

                    #expect(task.inputs.filter({ $0.name == "bar.c.txt/" }).count == 1)
                    #expect(task.inputs.filter({ $0.name == "baz.c.txt/" }).count == 1)

                    task.checkOutputs([
                        // Verify the command has a virtual output node that can be used as a dependency.
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/foo.c"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/bar.c"),
                        .path("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/baz.c"),
                    ])

                    // Validate that the task has a reasonable environment.
                    // This check is used both to verify behaviors specific to this test, and also important behaviors which apply to all scripts which we want to ensure are tested.
                    let scriptVariables: [String: StringPattern?] = [
                        "ACTION": .equal("build"),
                        "TARGET_NAME": .equal("App"),
                        "SCRIPT_INPUT_FILE_0": .equal("\(SRCROOT)/foo.c.txt"),
                        "SCRIPT_INPUT_FILE_COUNT": .equal("1"),

                        "SCRIPT_OUTPUT_FILE_0": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/DerivedSources/foo.c"),
                        "SCRIPT_OUTPUT_FILE_COUNT": .equal("1"),

                        "SCRIPT_INPUT_FILE_LIST_0": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/InputFileList-FileList-input1-37ee743e55b3c53330093d7b0b8cd56c-resolved.xcfilelist"),
                        "SCRIPT_INPUT_FILE_LIST_1": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/InputFileList-FileList-input2-60efd0de639c852aeb6c923fc58fe155-resolved.xcfilelist"),
                        "SCRIPT_INPUT_FILE_LIST_COUNT": .equal("2"),

                        "SCRIPT_OUTPUT_FILE_LIST_0": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/OutputFileList-FileList-output1-9e204e1839af2864ef74daf50be90959-resolved.xcfilelist"),
                        "SCRIPT_OUTPUT_FILE_LIST_1": .equal("\(SRCROOT)/build/aProject.build/Debug/App.build/OutputFileList-FileList-output2-49b85065e1ab5f8726dafd7606a852ce-resolved.xcfilelist"),
                        "SCRIPT_OUTPUT_FILE_LIST_COUNT": .equal("2"),

                        "TOOLCHAIN_DIR": .equal("\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain"),
                    ]
                    task.checkEnvironment(scriptVariables)
                }
            }
        }

        // Cleanup the stuff written to disk.
        try fs.removeDirectory(Path(SRCROOT))
    }

    @Test(.requireSDKs(.macOS))
    func scriptRuleWithFileListsAndErrors() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("input1-noexists.xcfilelist"),
                    TestFile("output1-noexists.xcfilelist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestShellScriptBuildPhase(name: "Run Script", shellPath: "/bin/sh", originalObjectID: "FileList", contents: "echo hi", inputs: [], inputFileLists: ["$(SRCROOT)/input1-noexists.xcfilelist"], outputs: [], outputFileLists: ["$(SRCROOT)/output1-noexists.xcfilelist"], alwaysOutOfDate: true)
                    ],
                    buildRules: []),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, fs: PseudoFS()) { results in
            results.checkWarning(.equal("Unable to read contents of XCFileList '\(SRCROOT)/output1-noexists.xcfilelist' (in target 'App' from project 'aProject')"))
            results.checkError(.equal("Unable to load contents of file list: '\(SRCROOT)/input1-noexists.xcfilelist' (in target 'App' from project 'aProject')"))
            results.checkError(.equal("Unable to load contents of file list: '\(SRCROOT)/output1-noexists.xcfilelist' (in target 'App' from project 'aProject')"))
        }
    }

    @Test(.requireSDKs(.macOS))
    func cppHeaderInSourcesPhase() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Foo.cpp"),
                    TestFile("Foo.hpp"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [TestSourcesBuildPhase(["Foo.cpp", "Foo.hpp"])]
                )
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoTask(.matchRuleType("CompileC"), .matchRuleItemBasename("Foo.hpp"))
        }
    }

    /// Test that when a target has multiple input files which would - in the naive case - generate the same output files (same name, same location), that task construction generates an appropriately uniqued output name for each file.
    @Test(.requireSDKs(.macOS))
    func outputFileNameCollisions() async throws {
        let differentDirectoriesObjC1 = TestFile("DifferentDirectories.m", guid: "FR_DifferentDirectories1.m")
        let differentDirectoriesObjC2 = TestFile("DifferentDirectories.m", guid: "FR_DifferentDirectories2.m")
        let differentDirectoriesDifferentCaseObjC1 = TestFile("DifferentDirectoriesDifferentCase.m", guid: "FR_DifferentDirectoriesDifferentCase1.m")
        let differentDirectoriesDifferentCaseObjC2 = TestFile("differentdirectoriesdifferentcase.m", guid: "FR_differentdirectoriesdifferentcase2.m")
        let differentDirectoriesSwift1 = TestFile("DifferentDirectories.swift", guid: "FR_DifferentDirectories1.swift")
        let differentDirectoriesSwift2 = TestFile("DifferentDirectories.swift", guid: "FR_DifferentDirectories2.swift")
        let differentDirectoriesDifferentCaseSwift1 = TestFile("DifferentDirectoriesDifferentCase.swift", guid: "FR_DifferentDirectoriesDifferentCase1.swift")
        let differentDirectoriesDifferentCaseSwift2 = TestFile("differentdirectoriesdifferentcase.swift", guid: "FR_differentdirectoriesdifferentcase2.swift")
        let uniqueSwift = TestFile("UniqueSwift.swift")

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "Sources",
                children: [
                    // Test that an ObjC and an ObjC++ file get unique output filenames.
                    TestFile("ObjCAndObjCPlusPlus.m"),
                    TestFile("ObjCAndObjCPlusPlus.mm"),

                    // Test that files in two different directories get unique output filenames.
                    differentDirectoriesObjC1,
                    differentDirectoriesSwift1,

                    // Test that files in two different directories, but which differ in case, still get unique output filenames.  This is relevant on case-insensitive file systems.
                    differentDirectoriesDifferentCaseObjC1,
                    differentDirectoriesDifferentCaseSwift1,

                    // Child group to hold classes which differ only in case.
                    TestGroup(
                        "MoreSources", path: "MoreSources",
                        children: [
                            differentDirectoriesObjC2,
                            differentDirectoriesSwift2,
                            differentDirectoriesDifferentCaseObjC2,
                            differentDirectoriesDifferentCaseSwift2,
                        ]
                    ),

                    // check that some files which don't have name collisions don't end up with uniquingSuffixes.
                    TestFile("UniqueObjC.m"),
                    uniqueSwift,
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "ObjCAndObjCPlusPlus.m",
                            "ObjCAndObjCPlusPlus.mm",

                            TestBuildFile(differentDirectoriesObjC1),
                            TestBuildFile(differentDirectoriesObjC2),
                            TestBuildFile(differentDirectoriesSwift1),
                            TestBuildFile(differentDirectoriesSwift2),

                            TestBuildFile(differentDirectoriesDifferentCaseObjC1),
                            TestBuildFile(differentDirectoriesDifferentCaseObjC2),
                            TestBuildFile(differentDirectoriesDifferentCaseSwift1),
                            TestBuildFile(differentDirectoriesDifferentCaseSwift2),

                            "UniqueObjC.m",
                            TestBuildFile(uniqueSwift),
                        ])
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            // Filter out some tasks we don't care about for better debugging.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("MkDir")) { _ in }
            results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
            results.checkTasks(.matchRuleType("Touch")) { _ in }

            // There shouldn't be any task construction diagnostics.
            results.checkNoDiagnostics()

            results.checkTarget("AppTarget") { target in
                // Test that an ObjC and an ObjC++ file get unique output filenames.
                do {
                    var objFile1: String? = nil
                    var objFile2: String? = nil
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ObjCAndObjCPlusPlus.m")) { task in
                        objFile1 = Path(task.ruleInfo[1]).basename
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("ObjCAndObjCPlusPlus.mm")) { task in
                        objFile2 = Path(task.ruleInfo[1]).basename
                    }
                    #expect(objFile1 != objFile2)
                }

                // Test that files in two different directories get unique output filenames.
                do {
                    var objFile1: String? = nil
                    var objFile2: String? = nil
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem("\(SRCROOT)/DifferentDirectories.m")) { task in
                        objFile1 = Path(task.ruleInfo[1]).basename
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem("\(SRCROOT)/MoreSources/DifferentDirectories.m")) { task in
                        objFile2 = Path(task.ruleInfo[1]).basename
                    }
                    #expect(objFile1 != objFile2)
                }

                // Test that files in two different directories, but which differ in case, still get unique output filenames.  This is relevant on case-insensitive file systems.
                do {
                    var objFile1: String? = nil
                    var objFile2: String? = nil
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem("\(SRCROOT)/DifferentDirectoriesDifferentCase.m")) { task in
                        objFile1 = Path(task.ruleInfo[1]).basename
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItem("\(SRCROOT)/MoreSources/differentdirectoriesdifferentcase.m")) { task in
                        objFile2 = Path(task.ruleInfo[1]).basename
                    }
                    #expect(objFile1 != objFile2)
                }

                // Test our correctness-check ObjC file.
                results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), .matchRuleItemBasename("UniqueObjC.m")) { task in
                    #expect(Path(task.ruleInfo[1]).basename == "UniqueObjC.o")
                }

                // For Swift, we need to check the actual output files.
                results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkRuleInfo(["SwiftDriver Compilation", "AppTarget", "normal", "x86_64", "com.apple.xcode.tools.swift.compiler"])

                    // Make sure that no path in the outputs occurs more than once.
                    let outputPaths = task.outputs.map({ $0.path })
                    #expect(Set(outputPaths).count == outputPaths.count)

                    // Check that the output paths contain the expected base names.
                    let outputPathBasenames = outputPaths.map({ $0.basename })
                    func checkOutputFileIsPresent(for testFilePath: Path, sourceLocation: SourceLocation = #_sourceLocation) {
                        let rootName = Path(testFilePath.basename).withoutSuffix
                        let objFileName = "\(rootName)-\(BuildPhaseWithBuildFiles.filenameUniquefierSuffixFor(path: testFilePath)).o"
                        #expect(outputPathBasenames.contains(objFileName), "could not find object file named '\(objFileName)' among outputs: \(outputPaths.map { $0.str })", sourceLocation: sourceLocation)
                    }
                    checkOutputFileIsPresent(for:  Path(SRCROOT).join("DifferentDirectories.swift"))
                    checkOutputFileIsPresent(for:  Path(SRCROOT).join("MoreSources").join("DifferentDirectories.swift"))
                    checkOutputFileIsPresent(for: Path(SRCROOT).join("DifferentDirectoriesDifferentCase.swift"))
                    checkOutputFileIsPresent(for: Path(SRCROOT).join("MoreSources").join("differentdirectoriesdifferentcase.swift"))

                    // Test our correctness-check Swift file
                    #expect(outputPathBasenames.contains("UniqueSwift.o"), "could not find object file named 'UniqueSwift.o' among outputs: \(outputPaths.map { $0.str })")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func codelessBundles() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestVersionGroup("Foo.xcdatamodeld", children: [TestFile("Foo.xcdatamodeld")])
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-"
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .bundle,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [TestSourcesBuildPhase(["Foo.xcdatamodeld"])]
                )
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)

        /// Client to generate files from the core data model.
        class TestCoreDataCompilerTaskPlanningClientDelegate: TaskPlanningClientDelegate {
            func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                return .emptyResult
            }
        }

        // <rdar://problem/30298464>
        // "failed - missing creator for mutated node '\(SRCROOT)/build/Debug/App.bundle/Contents/MacOS/App' mutated by task 'CodeSign \(SRCROOT)/build/Debug/App.bundle'"
        _ = tester
    }

    /// Tests that the CopyStringsFile task is arch-neutral and doesn't emit duplicate task errors for multi-arch and/or multi-variant builds.
    @Test(.requireSDKs(.macOS))
    func copyStringsArchNeutral() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                path: "Sources",
                children: [
                    TestFile("mock.c"),
                    TestVariantGroup("Intents.intentdefinition", children: [
                        TestFile("Base.lproj/Intents.intentdefinition"),
                        TestFile("en.lproj/Intents.strings", regionVariantName: "en"),
                        TestFile("de.lproj/Intents.strings", regionVariantName: "de"),
                    ])
                ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "ARCHS": "x86_64 x86_64h",
                    "BUILD_VARIANTS": "normal debug profile",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)"])],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [TestSourcesBuildPhase([
                        "mock.c",
                        "Intents.intentdefinition"
                    ])]),
            ]
        )

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CompileC", "CreateBuildDirectory", "CreateUniversalBinary", "Gate", "IntentDefinitionCompile", "Ld", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "WriteAuxiliaryFile", "GenerateTAPI"])

            results.checkTarget("Foo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aWorkspace/aProject/build/Debug/Foo.framework/Versions/A/Resources/en.lproj/Intents.strings", "/tmp/aWorkspace/aProject/Sources/en.lproj/Intents.strings"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aWorkspace/aProject/build/Debug/Foo.framework/Versions/A/Resources/de.lproj/Intents.strings", "/tmp/aWorkspace/aProject/Sources/de.lproj/Intents.strings"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Ensure that the intents headers are still generated for `installhdrs` and `installapi`  builds.
    @Test(.requireSDKs(.macOS))
    func intentsCodegenForInstallHeadersAndApi() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                path: "Sources",
                children: [
                    TestFile("mock.c"),
                    TestVariantGroup("Intents.intentdefinition", children: [
                        TestFile("Base.lproj/Intents.intentdefinition"),
                        TestFile("en.lproj/Intents.strings", regionVariantName: "en"),
                        TestFile("de.lproj/Intents.strings", regionVariantName: "de"),
                    ])
                ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "ARCHS": "x86_64 x86_64h",
                    "BUILD_VARIANTS": "normal debug profile",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "SKIP_INSTALL": " NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "INTENTS_CODEGEN_LANGUAGE": "Objective-C",
                    "SUPPORTS_TEXT_BASED_API": "YES",
                    "SWIFT_VERSION": "5.2",
                    "TAPI_EXEC": tapiToolPath.str,
                ])],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [TestSourcesBuildPhase([
                        "mock.c",
                        TestBuildFile("Intents.intentdefinition", intentsCodegenVisibility: .public),
                    ])]),
            ]
        )

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        final class Delegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
            override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                if commandLine.first.map(Path.init)?.basename == "intentbuilderc",
                   let outputDir = commandLine.elementAfterElements(["-output"]).map(Path.init),
                   let classPrefix = commandLine.elementAfterElements(["-classPrefix"]),
                   let language = commandLine.elementAfterElements(["-language"]),
                   let visibility = commandLine.elementAfterElements(["-visibility"]) {
                    if visibility != "public" {
                        throw StubError.error("Visibility should be public")
                    }
                    switch language {
                    case "Swift":
                        return .result(status: .exit(0), stdout: Data(outputDir.join("\(classPrefix)Generated.swift").str.utf8), stderr: .init())
                    case "Objective-C":
                        return .result(status: .exit(0), stdout: Data([outputDir.join("\(classPrefix)Generated.h").str, outputDir.join("\(classPrefix)Generated.m").str].joined(separator: "\n").utf8), stderr: .init())
                    default:
                        throw StubError.error("unknown language '\(language)'")
                    }
                }
                return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
            }
        }

        // Explicitly opted-out of header filtering support.
        await tester.checkBuild(BuildParameters(action: .installHeaders, configuration: "Debug"), runDestination: .macOS, clientDelegate: Delegate()) { results in
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory","Gate", "MkDir", "SymLink", "Touch"])
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            // NOTE: This is implicitly ensuring that there is no `IntentDefinitionCodegen` and `IntentDefinitionCompile` tasks as they are not consumed above.

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // Explicitly opted-in to header filtering support.
        await tester.checkBuild(BuildParameters(action: .installHeaders, configuration: "Debug", overrides: ["EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING":"YES"]), runDestination: .macOS, clientDelegate: Delegate()) { results in
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory","Gate", "MkDir", "SymLink", "Touch", "WriteAuxiliaryFile"])

            results.checkTarget("Foo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["IntentDefinitionCodegen", "/tmp/aWorkspace/aProject/Sources/Base.lproj/Intents.intentdefinition"])) { _ in }

                results.checkNoTask(.matchTarget(target), .matchRuleType("IntentDefinitionCompile"))
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }

        // Explicitly opted-in to header filtering support.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug", overrides: ["EXPERIMENTAL_ALLOW_INSTALL_HEADERS_FILTERING":"YES"]), runDestination: .macOS, clientDelegate: Delegate()) { results in
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory","Gate", "MkDir", "SymLink", "Touch", "WriteAuxiliaryFile"])

            results.checkTarget("Foo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["IntentDefinitionCodegen", "/tmp/aWorkspace/aProject/Sources/Base.lproj/Intents.intentdefinition"])) { _ in }

                results.checkNoTask(.matchTarget(target), .matchRuleType("IntentDefinitionCompile"))

                results.checkTasks(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Test that multiple occurrences of the same architecture in ARCHS doesn't produce duplicate tasks.
    @Test(.requireSDKs(.macOS))
    func duplicateArchFiltering() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                path: "Sources",
                children: [
                    TestFile("mock.c"),
                ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "ARCHS": "x86_64 x86_64",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)"])],
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [TestSourcesBuildPhase([
                        "mock.c",
                    ])]),
            ]
        )

        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CreateBuildDirectory", "CreateUniversalBinary", "Gate", "IntentDefinitionCompile", "Ld", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "WriteAuxiliaryFile", "GenerateTAPI"])

            results.checkTarget("Foo") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "/tmp/aWorkspace/aProject/build/aProject.build/Debug/Foo.build/Objects-normal/x86_64/mock.o", "/tmp/aWorkspace/aProject/Sources/mock.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
            }

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Test that missing named references produce an understandable user-friendly diagnostic.
    @Test(.requireSDKs(.macOS))
    func missingNamedReferences() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles"),
            buildConfigurations: [TestBuildConfiguration("Release")],
            targets: [
                TestStandardTarget(
                    "EmptyTool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Release",
                            buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]
                        )
                    ],
                    buildPhases: [
                        TestCopyFilesBuildPhase([TestBuildFile(.namedReference(name: "Foo.framework", fileTypeIdentifier: "wrapper.framework"))], destinationSubfolder: .frameworks),
                        TestFrameworksBuildPhase([TestBuildFile(.namedReference(name: "Foo.framework", fileTypeIdentifier: "wrapper.framework"))]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Gate", "ProcessProductPackaging", "WriteAuxiliaryFile"])

            results.checkNoTask()

            results.checkError(.equal("[targetIntegrity] This Copy Files build phase contains a reference to a missing file 'Foo.framework'. (in target 'EmptyTool' from project 'aProject')"))

            // There shouldn't be any other diagnostics - for frameworks build phases we ignore the missing reference since we'll just attempt to pass `-framework Foo` to the linker and the build will fail later down the line.
            results.checkNoDiagnostics()
        }
    }

    /// Tests that file type lookup by C language dialect returns the correct file types.
    @Test(.requireSDKs(.macOS))
    func fileTypeLookupByDialect() async throws {
        let core = try await getCore()
        let platforms = core.platformRegistry.platforms
        #expect(!platforms.isEmpty)
        for platform in platforms {
            #expect(platform.lookupFileType(languageDialect: .c)?.identifier == "sourcecode.c.c")
            #expect(platform.lookupFileType(languageDialect: .cPlusPlus)?.identifier == "sourcecode.cpp.cpp")
            #expect(platform.lookupFileType(languageDialect: .objectiveC)?.identifier == "sourcecode.c.objc")
            #expect(platform.lookupFileType(languageDialect: .objectiveCPlusPlus)?.identifier == "sourcecode.cpp.objcpp")
            #expect(platform.lookupFileType(languageDialect: .other(dialectName: "none"))?.identifier == nil)
        }
    }

    func _defaultDeploymentTargetInRangeTester(runDestination: RunDestinationInfo) async throws -> TaskConstructionTester {
        let core = try await getCore()
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles", children: [
                TestFile("Test.c")
            ]),
            targets: [
                TestStandardTarget(
                    "Foo",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                // avoid multi-arch builds to make the checkTask formats identical across platforms
                                "ARCHS": "arm64",
                                "ARCHS[sdk=macosx*]": "x86_64",
                                "ARCHS[sdk=driverkit*]": "x86_64",
                                "ARCHS[sdk=watchos*]": "arm64_32",

                                "CODE_SIGNING_ALLOWED": "NO",
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": runDestination.sdk,
                                "SDK_VARIANT": runDestination.sdkVariant ?? "",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                "SUPPORTS_MACCATALYST": "YES",

                                "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
                                "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
                                "TVOS_DEPLOYMENT_TARGET": core.loadSDK(.tvOS).defaultDeploymentTarget,
                                "WATCHOS_DEPLOYMENT_TARGET": core.loadSDK(.watchOS).defaultDeploymentTarget,
                                "XROS_DEPLOYMENT_TARGET": core.loadSDK(.xrOS).defaultDeploymentTarget,
                                "DRIVERKIT_DEPLOYMENT_TARGET": core.loadSDK(.driverKit).defaultDeploymentTarget,
                            ]
                        )
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["Test.c"])
                    ])
            ])
        return try TaskConstructionTester(core, testProject)
    }
    @Test(.requireSDKs(.macOS))
    func defaultDeploymentTargetInRange_macOS() async throws {

        try await _defaultDeploymentTargetInRangeTester(runDestination: .macOS).checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/aProject/build/Debug/Foo.framework/Versions/A/Foo")) { _ in }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func defaultDeploymentTargetInRange_macCatalyst() async throws {

        try await _defaultDeploymentTargetInRangeTester(runDestination: .macCatalyst).checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macCatalyst) { results in
            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/aProject/build/Debug-maccatalyst/Foo.framework/Versions/A/Foo")) { _ in }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.iOS))
    func defaultDeploymentTargetInRange_iOS() async throws {

        try await _defaultDeploymentTargetInRangeTester(runDestination: .iOS).checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .iOS) { results in
            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/aProject/build/Debug-iphoneos/Foo.framework/Foo")) { _ in }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.tvOS))
    func defaultDeploymentTargetInRange_tvOS() async throws {

        try await _defaultDeploymentTargetInRangeTester(runDestination: .tvOS).checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .tvOS) { results in
            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/aProject/build/Debug-appletvos/Foo.framework/Foo")) { _ in }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.watchOS))
    func defaultDeploymentTargetInRange_watchOS() async throws {

        try await _defaultDeploymentTargetInRangeTester(runDestination: .watchOS).checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .watchOS) { results in
            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/aProject/build/Debug-watchos/Foo.framework/Foo")) { _ in }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.xrOS))
    func defaultDeploymentTargetInRange_visionOS() async throws {

        try await _defaultDeploymentTargetInRangeTester(runDestination: .xrOS).checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .xrOS) { results in
            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/aProject/build/Debug-xros/Foo.framework/Foo")) { _ in }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.driverKit))
    func defaultDeploymentTargetInRange_DriverKit() async throws {

        try await _defaultDeploymentTargetInRangeTester(runDestination: .driverKit).checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .driverKit) { results in
            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("/tmp/Test/aProject/build/Debug-driverkit/Foo.framework/Foo")) { _ in }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func alternateFrameworkVersion() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_PKGINFO_FILE": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile.m",
                        ]),
                        TestCopyFilesBuildPhase([TestBuildFile("AppCore.framework", codeSignOnCopy: true)], destinationSubfolder: .frameworks, onlyForDeployment: false),
                    ],
                    dependencies: ["AppCore"]
                ),
                TestStandardTarget(
                    "AppCore",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "FRAMEWORK_VERSION": "B",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Define the private module map file on disk.
        //
        // FIXME: This can be removed, once we land: <rdar://problem/24564960> [Swift Build] Stop ingesting user-defined module map file contents at task construction time
        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("AppCore-Private.modulemap"), contents: "foo")

        // Check the debug build.
        await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
            // There shouldn't be any task construction diagnostics.
            results.checkNoDiagnostics()

            results.checkTarget("AppTarget") { target in
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/AppCore.framework/Versions/B"])) { task in
                    task.checkRuleInfo(["CodeSign", "\(SRCROOT)/build/Debug/AppTarget.app/Contents/Frameworks/AppCore.framework/Versions/B"])
                }
            }

            results.checkTarget("AppCore") { target in
                // There should be the expected mkdir tasks for the framework.
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { (tasks) -> Void in
                    let sortedTasks = tasks.sorted { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }
                    #expect(sortedTasks.count == 4)
                    sortedTasks[0].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCore.framework")])
                    sortedTasks[1].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCore.framework/Versions")])
                    sortedTasks[2].checkRuleInfo([.equal("MkDir"), .equal("\(SRCROOT)/build/Debug/AppCore.framework/Versions/B")])

                    // Validate we also construct command lines.
                    sortedTasks[0].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCore.framework"])
                    sortedTasks[1].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCore.framework/Versions"])
                    sortedTasks[2].checkCommandLine(["/bin/mkdir", "-p", "\(SRCROOT)/build/Debug/AppCore.framework/Versions/B"])
                })
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }

    @Test(.requireSDKs(.macOS))
    func renameInfoPlist() async throws {
        // Test the renaming logic for InfoPlist.strings and InfoPlist.stringsdict.
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("Strings-InfoPlist.strings", fileTextEncoding: .utf8),
                        TestFile("Strings-InfoPlist.stringsdict", fileTextEncoding: .utf8),
                    ]),
                targets: [
                    TestStandardTarget(
                        "Bundle", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INFOPLIST_FILE":"Sources/Strings-Info.plist",
                            ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase(["Strings-InfoPlist.strings", "Strings-InfoPlist.stringsdict"]),
                        ]
                    )])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            let fs = PseudoFS()
            let path = srcRoot.join("Sources/", preserveRoot: true, normalize: true)
            try fs.createDirectory(path, recursive: true)
            try fs.write(path.join("Strings-Info.plist"), contents: "Test")

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("Strings-InfoPlist.strings")) { task in
                    task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outfilename", "InfoPlist.strings", "--outdir", "\(srcRoot.str)/build/Debug/Bundle.bundle/Contents/Resources", "--", "\(srcRoot.str)/Sources/Strings-InfoPlist.strings"])
                }
                results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("Strings-InfoPlist.stringsdict")) { task in
                    task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outfilename", "InfoPlist.stringsdict", "--outdir", "\(srcRoot.str)/build/Debug/Bundle.bundle/Contents/Resources", "--", "\(srcRoot.str)/Sources/Strings-InfoPlist.stringsdict"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func renameLocalizedInfoPlistWhenGenerated() async throws {
        // Test the renaming logic for InfoPlist.strings and InfoPlist.stringsdict.
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("MyBundle-InfoPlist.strings", fileTextEncoding: .utf8),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyBundle", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase(["MyBundle-InfoPlist.strings"]),
                        ]
                    )])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            let fs = PseudoFS()
            let path = srcRoot.join("Sources/", preserveRoot: true, normalize: true)
            try fs.createDirectory(path, recursive: true)
            try fs.write(path.join("MyBundle-Info.plist"), contents: "Test")

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("MyBundle-InfoPlist.strings")) { task in
                    task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outfilename", "InfoPlist.strings", "--outdir", "\(srcRoot.str)/build/Debug/MyBundle.bundle/Contents/Resources", "--", "\(srcRoot.str)/Sources/MyBundle-InfoPlist.strings"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func renameLocalizedInfoPlistWhenTweakedInfoPlistName() async throws {
        // Test the renaming logic for InfoPlist.strings and InfoPlist.stringsdict.
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("Info-MyBundle-InfoPlist.strings", fileTextEncoding: .utf8),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyBundle", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INFOPLIST_FILE":"Sources/Info-MyBundle.plist",
                            ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase(["Info-MyBundle-InfoPlist.strings"]),
                        ]
                    )])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            let fs = PseudoFS()
            let path = srcRoot.join("Sources/", preserveRoot: true, normalize: true)
            try fs.createDirectory(path, recursive: true)
            try fs.write(path.join("Info-MyBundle.plist"), contents: "Test")

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("Info-MyBundle-InfoPlist.strings")) { task in
                    task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outfilename", "InfoPlist.strings", "--outdir", "\(srcRoot.str)/build/Debug/MyBundle.bundle/Contents/Resources", "--", "\(srcRoot.str)/Sources/Info-MyBundle-InfoPlist.strings"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func renameLocalizedInfoPlistWhenDowncaseInfo() async throws {
        // Test the renaming logic for InfoPlist.strings and InfoPlist.stringsdict.
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("InfoPlist.strings", fileTextEncoding: .utf8),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyBundle", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INFOPLIST_FILE":"Sources/info.plist",
                            ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase(["InfoPlist.strings"]),
                        ]
                    )])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            let fs = PseudoFS()
            let path = srcRoot.join("Sources/", preserveRoot: true, normalize: true)
            try fs.createDirectory(path, recursive: true)
            try fs.write(path.join("info.plist"), contents: "Test")

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("InfoPlist.strings")) { task in
                    task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outfilename", "InfoPlist.strings", "--outdir", "\(srcRoot.str)/build/Debug/MyBundle.bundle/Contents/Resources", "--", "\(srcRoot.str)/Sources/InfoPlist.strings"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func renameLocalizedInfoPlistWhenCustomName() async throws {
        // Test the renaming logic for InfoPlist.strings and InfoPlist.stringsdict.
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "aProject",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("MycustominfoPlist.strings", fileTextEncoding: .utf8),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyBundle", type: .bundle,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INFOPLIST_FILE":"Sources/Mycustominfo.plist",
                            ]),
                        ],
                        buildPhases: [
                            TestResourcesBuildPhase(["MycustominfoPlist.strings"]),
                        ]
                    )])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            let fs = PseudoFS()
            let path = srcRoot.join("Sources/", preserveRoot: true, normalize: true)
            try fs.createDirectory(path, recursive: true)
            try fs.write(path.join("Mycustominfo.plist"), contents: "Test")

            await tester.checkBuild(runDestination: .macOS, fs: fs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("CopyStringsFile"), .matchRuleItemBasename("MycustominfoPlist.strings")) { task in
                    task.checkCommandLine(["builtin-copyStrings", "--validate", "--inputencoding", "utf-8", "--outputencoding", "UTF-16", "--outfilename", "InfoPlist.strings", "--outdir", "\(srcRoot.str)/build/Debug/MyBundle.bundle/Contents/Resources", "--", "\(srcRoot.str)/Sources/MycustominfoPlist.strings"])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildingWithRemarks() async throws {
        let testProject = try await TestProject(
            "ProjectName",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File1.m"),
                    TestFile("File2.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "TargetName",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "ProductName",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File1.m"),
                            TestBuildFile("File2.swift"),
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str
        let ObjectsNormal = "\(SRCROOT)/build/ProjectName.build/Debug/TargetName.build/Objects-normal"

        // The basics are:
        // * we pass the flags to clang
        // * we don't pass the flags to swift
        // * we don't pass the flags to ld
        // * we generate a dSYM
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["CLANG_GENERATE_OPTIMIZATION_REMARKS":"YES"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRule(["CompileC", "\(ObjectsNormal)/\(results.runDestinationTargetArchitecture)/File1.o", "/tmp/Test/ProjectName/Sources/File1.m", "normal", "\(results.runDestinationTargetArchitecture)", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in
                task.checkCommandLineContains(["-fsave-optimization-record=bitstream", "-foptimization-record-file=\(ObjectsNormal)/\(results.runDestinationTargetArchitecture)/File1.opt.bitstream"])
            }
            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkCommandLineDoesNotContain("optimization-record")
            }
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineDoesNotContain("optimization-record")
            }
            results.checkTask(.matchRuleType("GenerateDSYMFile")) { _ in }
        }

        // With LTO:
        // * we don't pass the flags to clang
        // * we don't pass the flags to swift
        // * we pass the flags to ld
        // * we generate a dSYM
        for LTOSetting in ["YES", "YES_THIN"] {
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["CLANG_GENERATE_OPTIMIZATION_REMARKS":"YES", "LLVM_LTO":LTOSetting]), runDestination: .macOS) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("CompileC")) { task in
                    task.checkCommandLineDoesNotContain("optimization-record")
                }
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineDoesNotContain("optimization-record")
                }
                results.checkTask(.matchRuleType("Ld")) { task in
                    task.checkCommandLineContains(["-fsave-optimization-record=bitstream", "-foptimization-record-file=\(ObjectsNormal)/\(results.runDestinationTargetArchitecture)/ProductName_lto.o.opt.bitstream"])
                }
                results.checkTask(.matchRuleType("GenerateDSYMFile")) { _ in }
            }
        }

        // Check that we pass the filters properly.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["CLANG_GENERATE_OPTIMIZATION_REMARKS":"YES", "CLANG_GENERATE_OPTIMIZATION_REMARKS_FILTER":"pass0|pass1|pass2"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CompileC")) { task in
                task.checkCommandLineContains(["-fsave-optimization-record=bitstream", "-foptimization-record-file=\(ObjectsNormal)/\(results.runDestinationTargetArchitecture)/File1.opt.bitstream", "-foptimization-record-passes=pass0|pass1|pass2"])
            }
        }

        // Check that no filters doesn't add an empty regex.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["CLANG_GENERATE_OPTIMIZATION_REMARKS":"YES", "CLANG_GENERATE_OPTIMIZATION_REMARKS_FILTER":""]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CompileC")) { task in
                task.checkCommandLineContains(["-fsave-optimization-record=bitstream", "-foptimization-record-file=\(ObjectsNormal)/\(results.runDestinationTargetArchitecture)/File1.opt.bitstream"])
                task.checkCommandLineDoesNotContain("-foptimization-record-passes")
            }
        }

        // Check that we get a dSYM even though we disabled debug info.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["CLANG_GENERATE_OPTIMIZATION_REMARKS":"YES", "GCC_GENERATE_DEBUGGING_SYMBOLS":"NO"]), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("GenerateDSYMFile")) { _ in }
        }
        // Check that we get a dSYM even though we requested just "dwarf".
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["CLANG_GENERATE_OPTIMIZATION_REMARKS":"YES", "GCC_GENERATE_DEBUGGING_SYMBOLS":"YES", "DEBUG_INFORMATION_FORMAT":"dwarf"]), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("GenerateDSYMFile")) { _ in }
        }

        let checkNoRemarks: ((TaskConstructionTester.PlanningResults) -> Void) = {
            let results = $0
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("CompileC")) { task in
                task.checkCommandLineDoesNotContain("optimization-record")
            }
            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkCommandLineDoesNotContain("optimization-record")
            }
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineDoesNotContain("optimization-record")
            }
            results.checkNoTask(.matchRuleType("GenerateDSYMFile"))
        }

        // Check that we don't pass anything if it's disabled.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["CLANG_GENERATE_OPTIMIZATION_REMARKS":"NO"]), runDestination: .macOS, body: checkNoRemarks)
        // Check that we don't pass anything if any other related flag is set.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["CLANG_GENERATE_OPTIMIZATION_REMARKS_FILTER":"pass0"]), runDestination: .macOS, body: checkNoRemarks)
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func packageFrameworksOrdering() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let infoLookup = try await getCore()
            let xcode = try await InstalledXcode.currentlySelected()
            let path1 = try await xcode.compileFramework(path: tmpDirPath.join("macos"), platform: .macOS, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, static: false)
            let path2 = try await xcode.compileFramework(path: tmpDirPath.join("iphoneos"), platform: .iOS, infoLookup: infoLookup, archs: ["arm64", "arm64e"], useSwift: true, static: false)
            let path3 = try await xcode.compileFramework(path: tmpDirPath.join("iphonesimulator"), platform: .iOSSimulator, infoLookup: infoLookup, archs: ["x86_64"], useSwift: true, static: false)

            let outputPath = tmpDirPath.join("Test/aProject/Sources/sample.xcframework")
            let commandLine = ["createXCFramework", "-framework", path1.str, "-framework", path2.str, "-framework", path3.str, "-output", outputPath.str]

            let (result, message) = XCFramework.createXCFramework(commandLine: commandLine, currentWorkingDirectory: tmpDirPath, infoLookup: infoLookup)
            #expect(result, "unable to build xcframework: \(message)")

            // We need a copy inside "aPackageProject/Sources" for the package case.
            let packageOutputPath = tmpDirPath.join("Test/aPackageProject/Sources/sample.xcframework")
            try localFS.createDirectory(packageOutputPath.dirname, recursive: true)
            try localFS.copy(outputPath, to: packageOutputPath)

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
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
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "F4", type: .application,
                                buildPhases: [
                                    TestFrameworksBuildPhase([TestBuildFile(.target("P1Product"))]),
                                ], dependencies: ["P1Product"]),
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
                            ]
                        )],
                        targets: [
                            TestPackageProductTarget(
                                "P1Product",
                                frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile("sample.xcframework", codeSignOnCopy: true)])),
                        ]),
                ])
            let tester = try await TaskConstructionTester(getCore(), testWorkspace)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            let parameters = BuildParameters(configuration: "Debug")
            let packageTarget = try #require(tester.workspace.allTargets.first { $0.name == "F4" })
            let request = BuildRequest(parameters: parameters,
                                       buildTargets: [BuildRequest.BuildTargetInfo(parameters: parameters, target: packageTarget)],
                                       continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

            await tester.checkBuild(runDestination: .macOS, buildRequest: request, fs: localFS) { results in
                results.checkNoDiagnostics()

                // Verify that the code signing task for the framework follows copying the XCFramework.
                results.checkTask(.matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT.str)/build/Debug/F4.app")) { task in
                    results.checkTaskFollows(task, .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT.str)/Sources/sample.xcframework/macos-x86_64/sample.framework"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func createBuildDirectoryOrdering() async throws {
        try await withTemporaryDirectory { tmpDir in
            let buildFolderPaths = [tmpDir.join("build/a"), tmpDir.join("build/a/b"), tmpDir.join("build/a/b/c/d")]

            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup("Sources", children: [ TestFile("foo.c") ]),
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)", "GENERATE_INFOPLIST_FILE": "YES"])],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: ["OBJROOT": buildFolderPaths[0].str, "SYMROOT": buildFolderPaths[0].str, "DSTROOT": buildFolderPaths[0].str])],
                                buildPhases: [TestSourcesBuildPhase(["foo.c"])], dependencies: ["OtherFramework", "OtherFramework2"]),
                            TestStandardTarget(
                                "OtherFramework", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: ["OBJROOT": buildFolderPaths[1].str, "SYMROOT": buildFolderPaths[1].str, "DSTROOT": buildFolderPaths[1].str])],
                                buildPhases: [ TestSourcesBuildPhase(["foo.c"]) ]),
                            TestStandardTarget(
                                "OtherFramework2", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: ["OBJROOT": buildFolderPaths[2].str, "SYMROOT": buildFolderPaths[2].str, "DSTROOT": buildFolderPaths[2].str])],
                                buildPhases: [ TestSourcesBuildPhase(["foo.c"]) ]),
                        ])
                ])
            let tester = try await TaskConstructionTester(getCore(), testWorkspace)

            // CreateBuildDirectory tasks should be ordered such that outer directories are created before inner ones.
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItem("\(tmpDir.str)/build/a/Debug")) { task in
                    task.checkInputs([.path("\(tmpDir.str)/build/a")])
                }

                results.checkTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItem("\(tmpDir.str)/build/a/EagerLinkingTBDs/Debug")) { task in
                    task.checkInputs([.path("\(tmpDir.str)/build/a")])
                }

                results.checkTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItem("\(tmpDir.str)/build/a")) { task in
                    #expect(task.inputs.isEmpty)
                }

                results.checkTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItem("\(tmpDir.str)/build/a/b/Debug")) { task in
                    task.checkInputs([.path("\(tmpDir.str)/build/a/b")])
                }

                results.checkTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItem("\(tmpDir.str)/build/a/b/EagerLinkingTBDs/Debug")) { task in
                    task.checkInputs([.path("\(tmpDir.str)/build/a/b")])
                }

                results.checkTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItem("\(tmpDir.str)/build/a/b")) { task in
                    task.checkInputs([.path("\(tmpDir.str)/build/a")])
                }

                results.checkTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItem("\(tmpDir.str)/build/a/b/c/d/Debug")) { task in
                    task.checkInputs([.path("\(tmpDir.str)/build/a/b/c/d")])
                }

                results.checkTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItem("\(tmpDir.str)/build/a/b/c/d/EagerLinkingTBDs/Debug")) { task in
                    task.checkInputs([.path("\(tmpDir.str)/build/a/b/c/d")])
                }

                results.checkTask(.matchRuleType("CreateBuildDirectory"), .matchRuleItem("\(tmpDir.str)/build/a/b/c/d")) { task in
                    task.checkInputs([.path("\(tmpDir.str)/build/a/b")])
                }

                results.checkNoTask(.matchRuleType("CreateBuildDirectory"))
            }
        }
    }

    /// Check that Swift Build passes -iapi-notes-path iff (a) `GLOBAL_API_NOTES_PATH` is set and (b) it contains an accessible api notes file for the project in question.
    @Test(.requireSDKs(.macOS))
    func globalAPINotes() async throws {
        let clangCompilerPath = try await self.clangCompilerPath
        let clangFeatures = try await self.clangFeatures
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")

            let testProject = TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.m"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "TargetName",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "CC": clangCompilerPath.str,
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("SourceFile.m"),
                            ]),
                        ])
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            let fs = PseudoFS()

            // Create source file
            let path = srcRoot.join("Sources", preserveRoot: true, normalize: true)
            try fs.createDirectory(path, recursive: true)
            try fs.write(path.join("SourceFile.m"), contents: "// nothing")

            // Create exists.accessnotes
            let missingFile = tmpDir.join("missing.apinotes")
            let existingFile = tmpDir.join("exists.apinotes")
            try fs.write(existingFile, contents: "# nothing")

            // Test with no GLOBAL_API_NOTES_PATH
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [:]), runDestination: .macOS, fs: fs) { results in
                results.checkTask(.matchRuleType("CompileC")) { task in
                    task.checkCommandLineDoesNotContain("-iapinotes-path")
                }
            }

            // Test with GLOBAL_API_NOTES_PATH pointing to missing file
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["GLOBAL_API_NOTES_PATH": missingFile.str]), runDestination: .macOS, fs: fs) { results in
                results.checkTask(.matchRuleType("CompileC")) { task in
                    task.checkCommandLineDoesNotContain("-iapinotes-path")
                    task.checkNoInputs(contain: [.path(missingFile.str)])
                }
            }

            // Test with GLOBAL_API_NOTES_PATH pointing to extant file
            if clangFeatures.has(.globalAPINotesPath) {
                await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["GLOBAL_API_NOTES_PATH": existingFile.str]), runDestination: .macOS, fs: fs) { results in
                    results.checkTask(.matchRuleType("CompileC")) { task in
                        task.checkCommandLineContains(["-iapinotes-path", existingFile.str])
                        task.checkInputs(contain: [.path(existingFile.str)])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func ubsanHardening() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: ["CLANG_USE_RESPONSE_FILE": "NO"])
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES"
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.c"
                            ])
                        ]
                    )]
            )

            let fs = PseudoFS()

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            let hardeningSetting = "CLANG_UNDEFINED_BEHAVIOR_SANITIZER_TRAP_ON_SECURITY_ISSUES"
            let gccOptimizationSetting = "GCC_OPTIMIZATION_LEVEL"

            func test(task: any PlannedTask, overrides: [String: String]) -> Void {
                let baseFlags = "signed-integer-overflow,unsigned-integer-overflow,implicit-conversion,bounds,pointer-overflow"
                let baseFlagsVariants = ["-fsanitize=" + baseFlags, "-fsanitize-trap=" + baseFlags]
                let optFlags = "object-size"
                let optFlagsVariants = ["-fsanitize=" + optFlags , "-fsanitize-trap=" + optFlags]
                let allFlags = baseFlagsVariants + optFlagsVariants

                if overrides[hardeningSetting] == "YES" {
                    for flags in baseFlagsVariants {
                        task.checkCommandLineContains([flags])
                    }

                    if overrides[gccOptimizationSetting] == "1" {
                        for flags in optFlagsVariants {
                            task.checkCommandLineContains([flags])
                        }
                    } else if overrides[gccOptimizationSetting] == "0" {
                        for flags in optFlagsVariants {
                            task.checkCommandLineDoesNotContain(flags)
                        }
                    }
                }

                if overrides[hardeningSetting] == "NO" {
                    for flags in allFlags {
                        task.checkCommandLineDoesNotContain(flags)
                    }
                }
            }

            let overrides = [
                [hardeningSetting: "YES", gccOptimizationSetting: "0"],
                [hardeningSetting: "YES", gccOptimizationSetting: "1"],
                [hardeningSetting: "NO", gccOptimizationSetting: "1"],
                [hardeningSetting: "NO", gccOptimizationSetting: "0"],
            ]

            for override in overrides {
                await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: override), runDestination: .macOS, fs: fs) { results -> Void in
                    results.checkTarget("AppTarget") { target -> Void in
                        results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), body: {task in test(task: task, overrides: override)})
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func typedMemoryOperations() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug")
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES"
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.c"
                            ])
                        ]
                    )]
            )

            let fs = PseudoFS()

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            let typedMemoryOperationsC = "CLANG_ENABLE_C_TYPED_ALLOCATOR_SUPPORT";
            let typedMemoryOperationsCXX = "CLANG_ENABLE_CPLUSPLUS_TYPED_ALLOCATOR_SUPPORT";

            func test(task: any PlannedTask, overrides: [String: String]) -> Void {
                if let val = overrides[typedMemoryOperationsC] {
                    if val == "YES" {
                        task.checkCommandLineContains(["-ftyped-memory-operations"])
                    } else if val == "NO" {
                        task.checkCommandLineContains(["-fno-typed-memory-operations"])
                    } else if val == "compiler-default" {
                        task.checkCommandLineDoesNotContain("-ftyped-memory-operations")
                        task.checkCommandLineDoesNotContain("-fno-typed-memory-operations")
                    }
                } else if let val = overrides[typedMemoryOperationsCXX] {
                    if val == "YES" {
                        task.checkCommandLineContains(["-ftyped-cxx-new-delete"])
                    } else if val == "NO" {
                        task.checkCommandLineContains(["-fno-typed-cxx-new-delete"])
                    } else if val == "compiler-default" {
                        task.checkCommandLineDoesNotContain("-ftyped-cxx-new-delete")
                        task.checkCommandLineDoesNotContain("-fno-typed-cxx-new-delete")
                    }
                }
            }

            let overrides = [
                [typedMemoryOperationsC: "YES"],
                [typedMemoryOperationsC: "NO"],
                [typedMemoryOperationsC: "compiler-default"],
                [typedMemoryOperationsCXX: "YES"],
                [typedMemoryOperationsCXX: "NO"],
                [typedMemoryOperationsCXX: "compiler-default"],
            ]

            for override in overrides {
                await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: override), runDestination: .macOS, fs: fs) { results -> Void in
                    results.checkTarget("AppTarget") { target -> Void in
                        results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), body: {task in test(task: task, overrides: override)})
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func unsafeBufferUsage() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.cpp"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug")
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES"
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "SourceFile.cpp"
                            ])
                        ]
                    )]
            )

            let fs = PseudoFS()

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            let unsafeBufferUsageWarn = "CLANG_WARN_UNSAFE_BUFFER_USAGE";

            func test(task: any PlannedTask, overrides: [String: String]) -> Void {
                if let val = overrides[unsafeBufferUsageWarn] {
                    if val == "YES" {
                        task.checkCommandLineContains(["-Wunsafe-buffer-usage"])
                    } else if (val == "NO") {
                        task.checkCommandLineContains(["-Wno-unsafe-buffer-usage"])
                    } else if (val == "YES_ERROR") {
                        task.checkCommandLineContains(["-Werror=unsafe-buffer-usage"])
                    } else if (val == "DEFAULT") {
                        task.checkCommandLineDoesNotContain("-Wunsafe-buffer-usage")
                        task.checkCommandLineDoesNotContain("-Wno-unsafe-buffer-usage")
                    }
                }
            }

            let overrides = [
                [unsafeBufferUsageWarn: "YES"],
                [unsafeBufferUsageWarn: "NO"],
                [unsafeBufferUsageWarn: "YES_ERROR"],
                [unsafeBufferUsageWarn: "DEFAULT"],
            ]

            for override in overrides {
                await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: override), runDestination: .macOS, fs: fs) { results -> Void in
                    results.checkTarget("AppTarget") { target -> Void in
                        results.checkTask(.matchTarget(target), .matchRuleType("CompileC"), body: {task in test(task: task, overrides: override)})
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func warningSuppression() async throws {
        try await withTemporaryDirectory { tmpDir in
            let srcRoot = tmpDir.join("srcroot")
            let testProject = try await TestProject(
                "ProjectName",
                sourceRoot: srcRoot,
                groupTree: TestGroup(
                    "Sources", path: "Sources",
                    children: [
                        TestFile("File1.swift"),
                        TestFile("File2.m"),
                    ]),
                targets: [
                    TestStandardTarget(
                        "MyFramework",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "GENERATE_INFOPLIST_FILE": "YES",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": swiftVersion,
                                "SUPPRESS_WARNINGS": "YES"
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile("File1.swift"),
                                TestBuildFile("File2.m"),
                            ]),
                        ]),
                ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
                results.checkTarget("MyFramework") { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("CompileC")) { task in
                        task.checkCommandLineMatches(["-w"])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")) { task in
                        task.checkCommandLineMatches(["-suppress-warnings"])
                    }
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld")) { task in
                        task.checkCommandLineMatches(["-w"])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.host))
    func deterministicBuildDirectoryInputOrdering() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestPackageProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": try await swiftVersion,
                        "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                        "SDKROOT": "$(HOST_PLATFORM)",
                        "LIBRARY_SEARCH_PATHS": "$(inherited) $(BUILT_PRODUCTS_DIR)/PackageFrameworks"
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "swifttool", type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                        ],
                        dependencies: []
                    ),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)
            try await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .host) { results in
                try results.checkTask(.matchRuleType("Ld")) { task in
                    results.checkNoDiagnostics()
                    let debugIndex = try #require(task.inputs.firstIndex { $0.path.basename.hasPrefix("Debug") })
                    let packageFrameworksIndex = try #require(task.inputs.firstIndex { $0.path.basename == "PackageFrameworks" })
                    // Ensure the build directory input order is stable
                    #expect(debugIndex < packageFrameworksIndex)
                }
            }
        }
    }
}
