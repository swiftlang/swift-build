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
import SWBCore
import SWBLibc
import SWBUtil
import SWBTaskConstruction

import struct SWBProtocol.TargetDependencyRelationship

import SWBTestSupport

@_spi(Testing) import SWBTaskExecution

@Suite
fileprivate struct BuildDescriptionTests: CoreBasedTests {
    var manifestFragment = #"{"client":{"name":"basic","#

    func fullManifest(fileSystem: String) -> String {
        let tmp = Path.root.join("tmp").strWithPosixSlashes
        let deps = Path.root.join("tmp").join("foo.d")
        let signature = BuildDescriptionBuilder.computeShellToolSignature(args: ["true"], environment: EnvironmentBindings(), dependencyData: .makefile(deps), isUnsafeToInterrupt: false, additionalSignatureData: "").unsafeStringValue
        return """
            {"client":{"name":"basic","version":0,"file-system":"\(fileSystem)","perform-ownership-analysis":"\(SWBFeatureFlag.performOwnershipAnalysis.value ? "yes" : "no")"},"targets":{"":["<all>"]},"nodes":{"\(tmp)/filtered/":{"content-exclusion-patterns":["_CodeSignature","*.gitignore"]}},"commands":{"<all>":{"tool":"phony","inputs":[],"outputs":["<all>"]},"P0:::Foo":{"tool":"shell","description":"Foo","inputs":["\(tmp)/all/","\(tmp)/filtered/"],"outputs":[],"args":["true"],"env":{},"working-directory":"\(Path.pathSeparatorString.escapedForJSON)","deps":["\(deps.str.escapedForJSON)"],"deps-style":"makefile","signature":"\(signature)"}}}
            """
    }

    @Test
    func basics() async throws {
        let fs = PseudoFS()

        let builderConstruct = try await BuildDescription.construct(workspace: try TestWorkspace("empty", projects: []).load(getCore()), tasks: [], path: .root, signature: "testBasics()", fs: fs)
        let description = try #require(builderConstruct).buildDescription

        // Check the contents of the manifest.
        let manifestContents = try fs.read(description.manifestPath).bytes.asReadableString()
        #expect(manifestContents.contains(manifestFragment), Comment(rawValue: manifestContents))
    }

    @Test
    func errors() async throws {
        var builder = PlannedTaskBuilder(type: mockTaskType, ruleInfo: ["Foo"], commandLine: ["true"])
        let task = ConstructedTask(&builder, execTask: Task(&builder))

        // Create a trivial description.
        let builderConstruct = try await BuildDescription.construct(workspace: try TestWorkspace("empty", projects: []).load(getCore()), tasks: [task], path: .root, signature: "SIGNATURE", fs: PseudoFS())
        let results = try #require(builderConstruct)

        #expect(results.errors == ["unexpected task with no outputs: 'Foo'"])
    }

    /// Check that build descriptions have a deterministic serialized representation.
    @Test(.skipHostOS(.windows, "taking up to 30 minutes on Windows"))
    func determinism() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let core = try await getCore()
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath,
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", children: [TestFile("a.c"), TestFile("b.c"), TestFile("d.c"), TestFile("e.c")]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: ["INFOPLIST_FILE": "Info.plist"])],
                        targets: [
                            TestStandardTarget(
                                "Foo", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: ["OBJROOT": "/a", "SYMROOT": "/a", "DSTROOT": "/a"])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["a.c", "b.c"]),
                                ]),
                            TestStandardTarget(
                                "Bar", type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: ["OBJROOT": "/b", "SYMROOT": "/b", "DSTROOT": "/b"])],
                                buildPhases: [
                                    TestSourcesBuildPhase(["d.c", "e.c"]),
                                ],
                                dependencies: [TestTargetDependency("Foo")]),
                        ])
                ])
            let workspace1 = try testWorkspace.load(core)

            let taskActionRegistry = try await TaskActionRegistry(pluginManager: core.pluginManager)

            let fs1 = PseudoFS()
            let (description1, _) = try await buildDescription(for: workspace1, activeRunDestination: .macOS, fs: fs1)
            let manifest1Contents = try fs1.read(description1.manifestPath).bytes
            let serialized1 = { () -> ByteString in
                let serializer = MsgPackSerializer(delegate: BuildDescriptionSerializerDelegate(taskActionRegistry: taskActionRegistry))
                description1.serialize(to: serializer)
                return serializer.byteString
            }()

            // We do several iterations to increase probability of hitting issues.
            for _ in 0 ..< 10 {
                let workspace2 = try await testWorkspace.load(getCore())
                let fs2 = PseudoFS()
                let (description2, _) = try await buildDescription(for: workspace2, activeRunDestination: .macOS, fs: fs2)

                #expect(description1.targetDependencies == description2.targetDependencies)

                // Check the contents of the manifest.
                let manifest2Contents = try fs2.read(description2.manifestPath).bytes

                #expect(manifest1Contents == manifest2Contents, "unexpected different manifests")

                // Check the contents of the serialized description.
                let serialized2 = { () -> ByteString in
                    let serializer = MsgPackSerializer(delegate: BuildDescriptionSerializerDelegate(taskActionRegistry: taskActionRegistry))
                    description2.serialize(to: serializer)
                    return serializer.byteString
                }()

                #expect(serialized1 == serialized2, "unexpected different serialized representations")
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func multipleCreators() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath,
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                TestFile("Foo.cpp"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "INFOPLIST_FILE": "Info.plist",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ONLY_ACTIVE_ARCH": "YES",
                            ]),
                        ],
                        targets: [
                            TestAggregateTarget(
                                "Agg",
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                dependencies: ["App1", "App2", "App3"]
                            ),
                            TestStandardTarget(
                                "App1",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                                    "PRODUCT_NAME": "App",
                                ])],
                                buildPhases: [TestSourcesBuildPhase(["Foo.cpp"])]
                            ),
                            TestStandardTarget(
                                "App2",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                                    "PRODUCT_NAME": "App",
                                ])],
                                buildPhases: [TestSourcesBuildPhase(["Foo.cpp"])]
                            ),
                            TestStandardTarget(
                                "App3",
                                type: .framework,
                                buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                                    "PRODUCT_NAME": "App",
                                ])],
                                buildPhases: [TestSourcesBuildPhase(["Foo.cpp"])]
                            )
                        ])
                ])

            let workspace1 = try await testWorkspace.load(getCore())

            let fs1 = PseudoFS()
            let (results, _) = try await buildDescription(for: workspace1, activeRunDestination: .macOS, fs: fs1) as (BuildDescriptionDiagnosticResults, WorkspaceContext)

            let interestingDiagnostics = results.errors.filter({ message -> Bool in
                message.hasPrefix("Multiple commands produce")
            }).sorted()

            #expect(interestingDiagnostics.count == 2)


            #expect(interestingDiagnostics[safe: 0] == """
    Multiple commands produce \'\(tmpDirPath.str)/aProject/build/Debug/App.framework/Versions/A\'
    Target \'App1\' (project \'aProject\') has create directory command with output \'\(tmpDirPath.str)/aProject/build/Debug/App.framework/Versions/A\'
    Target \'App2\' (project \'aProject\') has create directory command with output \'\(tmpDirPath.str)/aProject/build/Debug/App.framework/Versions/A\'
    Target \'App3\' (project \'aProject\') has create directory command with output \'\(tmpDirPath.str)/aProject/build/Debug/App.framework/Versions/A\'
    """)

            #expect(interestingDiagnostics[safe: 1] == """
    Multiple commands produce \'\(tmpDirPath.str)/aProject/build/Debug/App.framework/Versions/A/App\'
    Target \'App1\' (project \'aProject\') has link command with output \'\(tmpDirPath.str)/aProject/build/Debug/App.framework/Versions/A/App\'
    Target \'App2\' (project \'aProject\') has link command with output \'\(tmpDirPath.str)/aProject/build/Debug/App.framework/Versions/A/App\'
    Target \'App3\' (project \'aProject\') has link command with output \'\(tmpDirPath.str)/aProject/build/Debug/App.framework/Versions/A/App\'
    """)
        }
    }

    /// Check targets with overlapping Swift Package Dependencies
    @Test
    func multipleFrameworkTargetsWithSamePackage() async throws {
        try await withTemporaryDirectory { tmpDir in
            let project = TestPackageProject(
                "aPackage",
                sourceRoot: tmpDir,
                groupTree: TestGroup("Package", children: [TestFile("File.c")]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            //"INFOPLIST_FILE": "Info.plist",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "ONLY_ACTIVE_ARCH": "YES",
                            "ALWAYS_SEARCH_USER_PATHS": "NO",

                        ]
                    )
                ],
                targets: [
                    TestStandardTarget(
                        "TestApp1",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                    "CODE_SIGN_IDENTITY": "foo",
                                    "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                                ]
                            )
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["File.c"]),
                            TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibProduct"))]),
                        ],
                        dependencies: ["PackageLibProduct"]
                    ),
                    TestStandardTarget(
                        "TestApp2", type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                    "CODE_SIGN_IDENTITY": "foo",
                                    "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                                ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["File.c"]),
                            TestFrameworksBuildPhase([TestBuildFile(.target("PackageLibProduct"))]),
                        ],
                        dependencies: ["PackageLibProduct"]),
                    TestPackageProductTarget(
                        "PackageLibProduct",
                        frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("PackageLib"))]),
                        dynamicTargetVariantName: "PackageLibProduct-dynamic",
                        buildConfigurations: [
                            // Targets need to opt-in to specialization.
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "auto",
                                    "SDK_VARIANT": "auto",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ])
                        ],
                        dependencies: ["PackageLib"]
                    ),
                    TestStandardTarget(
                        "PackageLibProduct-dynamic", type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "auto",
                                    "SDK_VARIANT": "auto",
                                    "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                ])
                        ],
                        buildPhases: [TestFrameworksBuildPhase([TestBuildFile(.target("PackageLib"))])],
                        dependencies: ["PackageLib"]
                    ),
                    TestStandardTarget("PackageLib", type: .objectFile),
                ]
            )

            let tester = try await TaskConstructionTester(getCore(), project)
            let fs1 = PseudoFS()
            let (results, _) =
            try await buildDescription(for: tester.workspace, activeRunDestination: .macOS, overrides: ["PACKAGE_BUILD_DYNAMICALLY": "YES"], fs: fs1)
            as (BuildDescriptionDiagnosticResults, WorkspaceContext)
            let interestingDiagnostics = results.errors.filter({ message -> Bool in
                message.hasPrefix("Multiple commands produce")
            }).sorted()

            #expect(interestingDiagnostics.count == 0)
        }
    }

    /// Check that build descriptions recompute based on recursive search path changes.
    @Test(.requireSDKs(.host))
    func recursiveSearchPathValidation() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            try await withAsyncDeferrable { deferrable in
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath,
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources", children: [TestFile("a.c"), TestFile("b.c")]),
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "USE_HEADERMAP": "NO",
                                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                                        "USER_HEADER_SEARCH_PATHS": Path.root.join("User/**").strWithPosixSlashes,
                                        "CLANG_USE_RESPONSE_FILE": "NO"])],
                            targets: [
                                TestStandardTarget(
                                    "Tool", type: .commandLineTool,
                                    buildPhases: [
                                        TestSourcesBuildPhase(["a.c", "b.c"]),
                                    ]),
                            ])
                    ])
                let workspace = try await testWorkspace.load(getCore())

                // Use a shared manager.
                let manager = BuildDescriptionManager(fs: PseudoFS(), buildDescriptionMemoryCacheEvictionPolicy: .never)
                await deferrable.addBlock { await manager.waitForBuildDescriptionSerialization() }

                func check(fs: any FSProxy, expected: [String], expectedSource: BuildDescriptionRetrievalSource) async throws {
                    let planRequest = try await self.planRequest(for: workspace, activeRunDestination: .macOS, fs: fs, includingTargets: { _ in true })
                    let info = try await manager.getNewOrCachedBuildDescription(planRequest, clientDelegate: MockTestTaskPlanningClientDelegate())!
                    #expect(info.source == expectedSource)

                    let description = info.buildDescription
                    let compileTasks = description.tasks.filter{ $0.ruleInfo[0] == "CompileC" }
                    guard compileTasks.count > 0 else {
                        Issue.record("unexpected build description")
                        return
                    }

                    let task = compileTasks[0]
                    let iQuoteArgs = task.commandLine.enumerated().filter { (i, arg) in
                        (task.commandLine[safe: i - 1]?.asString ?? "") == "-iquote"
                    }.map{ $0.1.asString }
                    #expect(iQuoteArgs == expected)

                    // We should only see one cached result.
                    #expect(description.recursiveSearchPathResults.count == 1)
                }

                // Check the initial case.
                do {
                    let fs = PseudoFS()
                    try fs.createDirectory(Path.root.join("User/Foo"), recursive: true)
                    try await check(fs: fs, expected: [Path.root.join("User").str, Path.root.join("User/Foo").str], expectedSource: .new)
                    try await check(fs: fs, expected: [Path.root.join("User").str, Path.root.join("User/Foo").str], expectedSource: .inMemoryCache)
                }

                // Check after adding a path.
                do {
                    let fs = PseudoFS()
                    try fs.createDirectory(Path.root.join("User/Foo/Bar"), recursive: true)
                    try await check(fs: fs, expected: [Path.root.join("User").str, Path.root.join("User/Foo").str, Path.root.join("User/Foo/Bar").str], expectedSource: .new)
                    try await check(fs: fs, expected: [Path.root.join("User").str, Path.root.join("User/Foo").str, Path.root.join("User/Foo/Bar").str], expectedSource: .inMemoryCache)
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func bundleWithNoSources() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("SomeFile.txt"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "INFOPLIST_FILE": "Info.plist",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "BUILD_VARIANTS": "normal extra"
                    ])
                ],
                targets: [
                    TestStandardTarget("NoSources",
                                       type: .bundle,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestResourcesBuildPhase(["SomeFile.txt"])])])
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject])
            let workspace = try await testWorkspace.load(getCore())

            let (results, _) = try await buildDescription(for: workspace, activeRunDestination: .macOS) as (BuildDescriptionDiagnosticResults, WorkspaceContext)
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func bundleWithNoArchs() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File.c"),
                        TestFile("SomeFile.txt"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "INFOPLIST_FILE": "Info.plist",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "BUILD_VARIANTS": "normal extra",
                        "ARCHS": "foo",
                        "VALID_ARCHS": "bar"
                    ])
                ],
                targets: [
                    TestStandardTarget("NoArchs",
                                       type: .bundle,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase([]),
                                        TestResourcesBuildPhase(["SomeFile.txt"])])])
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject])
            let workspace = try await testWorkspace.load(getCore())

            let (results, _) = try await buildDescription(for: workspace, activeRunDestination: .macOS) as (BuildDescriptionDiagnosticResults, WorkspaceContext)
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func bundleWithNoArchsAndSourceFile() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File.c"),
                        TestFile("SomeFile.txt"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "INFOPLIST_FILE": "Info.plist",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "BUILD_VARIANTS": "normal extra",
                        "ARCHS": "foo",
                        "VALID_ARCHS": "bar"
                    ])
                ],
                targets: [
                    TestStandardTarget("NoArchs",
                                       type: .bundle,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["File.c"]),
                                        TestResourcesBuildPhase(["SomeFile.txt"])])])
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject])
            let workspace = try await testWorkspace.load(getCore())

            let (results, _) = try await buildDescription(for: workspace, activeRunDestination: .macOS) as (BuildDescriptionDiagnosticResults, WorkspaceContext)
            #expect(results.errors.isEmpty, "Unexpected errors in build description: \(results.errors)")
            #expect(results.warnings == ["None of the architectures in ARCHS (foo) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (bar). (in target \'NoArchs\' from project 'aProject')"])
        }

        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File.c"),
                        TestFile("SomeFile.txt"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "INFOPLIST_FILE": "Info.plist",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "BUILD_VARIANTS": "normal extra",
                        "ARCHS": "foo",
                        "VALID_ARCHS": "bar",
                        "ONLY_ACTIVE_ARCH": "YES"
                    ])
                ],
                targets: [
                    TestStandardTarget("NoArchs",
                                       type: .bundle,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["File.c"]),
                                        TestResourcesBuildPhase(["SomeFile.txt"])])])
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject])
            let workspace = try await testWorkspace.load(getCore())

            let (results, _) = try await buildDescription(for: workspace, activeRunDestination: .macOS) as (BuildDescriptionDiagnosticResults, WorkspaceContext)
            #expect(results.errors.isEmpty, "Unexpected errors in build description: \(results.errors)")
            #expect(results.warnings == ["None of the architectures in ARCHS (foo) are valid. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (bar). (in target \'NoArchs\' from project 'aProject')"])
        }

        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File.c"),
                        TestFile("SomeFile.txt"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "arch": "foo",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "INFOPLIST_FILE": "Info.plist",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "BUILD_VARIANTS": "normal extra",
                        "ARCHS": "foo",
                        "VALID_ARCHS": "bar",
                        "ONLY_ACTIVE_ARCH": "YES"
                    ])
                ],
                targets: [
                    TestStandardTarget("NoArchs",
                                       type: .bundle,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["File.c"]),
                                        TestResourcesBuildPhase(["SomeFile.txt"])])])
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject])
            let workspace = try await testWorkspace.load(getCore())

            let (results, _) = try await buildDescription(for: workspace, activeRunDestination: .macOS) as (BuildDescriptionDiagnosticResults, WorkspaceContext)
            #expect(results.errors.isEmpty, "Unexpected errors in build description: \(results.errors)")
            #expect(results.warnings == ["The active architecture (foo) is not valid - it is the only architecture considered because ONLY_ACTIVE_ARCH is enabled. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (bar). (in target \'NoArchs\' from project 'aProject')"])
        }

        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File.c"),
                        TestFile("SomeFile.txt"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "INFOPLIST_FILE": "Info.plist",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "BUILD_VARIANTS": "normal extra",
                        "ARCHS": "foo",
                        "VALID_ARCHS": " "
                    ])
                ],
                targets: [
                    TestStandardTarget("NoArchs",
                                       type: .bundle,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["File.c"]),
                                        TestResourcesBuildPhase(["SomeFile.txt"])])])
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject])
            let workspace = try await testWorkspace.load(getCore())

            let (results, _) = try await buildDescription(for: workspace, activeRunDestination: .macOS) as (BuildDescriptionDiagnosticResults, WorkspaceContext)
            #expect(results.errors.isEmpty, "Unexpected errors in build description: \(results.errors)")
            #expect(results.warnings == ["There are no architectures to compile for because the VALID_ARCHS build setting is an empty list. (in target \'NoArchs\' from project 'aProject')"])
        }

        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("File.c"),
                        TestFile("SomeFile.txt"),
                        TestFile("Info.plist")
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "INFOPLIST_FILE": "Info.plist",
                        "CODE_SIGN_IDENTITY": "Apple Development",
                        "BUILD_VARIANTS": "normal extra",
                        "ARCHS": " ",
                        "VALID_ARCHS": "bar"
                    ])
                ],
                targets: [
                    TestStandardTarget("NoArchs",
                                       type: .bundle,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase(["File.c"]),
                                        TestResourcesBuildPhase(["SomeFile.txt"])])])
            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDirPath, projects: [testProject])
            let workspace = try await testWorkspace.load(getCore())

            let (results, _) = try await buildDescription(for: workspace, activeRunDestination: .macOS) as (BuildDescriptionDiagnosticResults, WorkspaceContext)
            #expect(results.errors.isEmpty, "Unexpected errors in build description: \(results.errors)")
            #expect(results.warnings == ["There are no architectures to compile for because the ARCHS build setting is an empty list. Consider setting ARCHS to $(ARCHS_STANDARD) or updating it to include at least one value from VALID_ARCHS (bar). (in target \'NoArchs\' from project 'aProject')"])
        }
    }

    /// Check the basic structure of an llbuild manifest.
    @Test
    func manifestStructure() async throws {
        let fs = PseudoFS()
        let type = MockTaskTypeDescription()
        let inputs = [
            MakePlannedDirectoryTreeNode(Path.root.join("tmp/all")),
            MakePlannedDirectoryTreeNode(Path.root.join("tmp/filtered"), excluding: ["_CodeSignature", "*.gitignore"]),
        ]
        var builder = PlannedTaskBuilder(type: type, ruleInfo: ["Foo"], commandLine: ["true"], inputs: inputs, deps: .makefile(Path.root.join("tmp/foo.d")))
        let task = ConstructedTask(&builder, execTask: Task(&builder))

        let buildConstruct = try await BuildDescription.construct(workspace: try TestWorkspace("empty", projects: []).load(getCore()), tasks: [task], path: Path.root.join("tmp"), signature: ByteString(encodingAsUTF8: "signature"), fs: fs)
        _ = try #require(buildConstruct)
        let manifest = try fs.read(Path.root.join("tmp/signature.xcbuilddata/manifest.json")).bytes.asReadableString()
        #expect(manifest == fullManifest(fileSystem: fs.ignoreFileSystemDeviceInodeChanges ? "device-agnostic" : "default"))
    }

    /// Check the basic structure of an llbuild manifest with device agnostic file system.
    @Test
    func manifestWithDeviceAgnosticEnabled() async throws {
        let fs = PseudoFS(ignoreFileSystemDeviceInodeChanges: true)
        let type = MockTaskTypeDescription()

        let inputs = [
            MakePlannedDirectoryTreeNode(Path.root.join("tmp/all")),
            MakePlannedDirectoryTreeNode(Path.root.join("tmp/filtered"), excluding: ["_CodeSignature", "*.gitignore"]),
        ]
        var builder = PlannedTaskBuilder(type: type, ruleInfo: ["Foo"], commandLine: ["true"], inputs: inputs, deps: .makefile(Path.root.join("tmp/foo.d")))

        let task = ConstructedTask(&builder, execTask: Task(&builder))

        let buildConstruct = try await BuildDescription.construct(workspace: try TestWorkspace("empty", projects: []).load(getCore()), tasks: [task], path: Path.root.join("tmp"), signature: ByteString(encodingAsUTF8: "signature"), fs: fs)
        _ = try #require(buildConstruct)

        let manifest = try fs.read(Path.root.join("tmp/signature.xcbuilddata/manifest.json")).bytes.asReadableString()
        #expect(manifest == fullManifest(fileSystem: "device-agnostic"))
    }

    @Test
    func manifestWithDeviceAgnosticDisabled() async throws {
        let fs = PseudoFS(ignoreFileSystemDeviceInodeChanges: false)
        let type = MockTaskTypeDescription()

        let inputs = [
            MakePlannedDirectoryTreeNode(Path.root.join("tmp/all")),
            MakePlannedDirectoryTreeNode(Path.root.join("tmp/filtered"), excluding: ["_CodeSignature", "*.gitignore"]),
        ]
        var builder = PlannedTaskBuilder(type: type, ruleInfo: ["Foo"], commandLine: ["true"], inputs: inputs, deps: .makefile(Path.root.join("tmp/foo.d")))

        let task = ConstructedTask(&builder, execTask: Task(&builder))

        let buildConstruct = try await BuildDescription.construct(workspace: try TestWorkspace("empty", projects: []).load(getCore()), tasks: [task], path: Path.root.join("tmp"), signature: ByteString(encodingAsUTF8: "signature"), fs: fs)

        _ = try #require(buildConstruct)

        let manifest = try fs.read(Path.root.join("tmp/signature.xcbuilddata/manifest.json")).bytes.asReadableString()
        #expect(manifest == fullManifest(fileSystem: "default"))
    }

    @Test
    func manifestWithDeviceAgnosticDefault() async throws {
        let fs = PseudoFS()
        let type = MockTaskTypeDescription()

        let inputs = [
            MakePlannedDirectoryTreeNode(Path.root.join("tmp/all")),
            MakePlannedDirectoryTreeNode(Path.root.join("tmp/filtered"), excluding: ["_CodeSignature", "*.gitignore"]),
        ]
        var builder = PlannedTaskBuilder(type: type, ruleInfo: ["Foo"], commandLine: ["true"], inputs: inputs, deps: .makefile(Path.root.join("tmp/foo.d")))

        let task = ConstructedTask(&builder, execTask: Task(&builder))

        let buildConstruct = try await BuildDescription.construct(workspace: try TestWorkspace("empty", projects: []).load(getCore()), tasks: [task], path: Path.root.join("tmp"), signature: ByteString(encodingAsUTF8: "signature"), fs: fs)
        _ = try #require(buildConstruct)

        let manifest = try fs.read(Path.root.join("tmp/signature.xcbuilddata/manifest.json")).bytes.asReadableString()
        #expect(manifest == fullManifest(fileSystem: fs.ignoreFileSystemDeviceInodeChanges ? "device-agnostic" : "default"))
    }

    @Test(.requireHostOS(.macOS))
    func serializable() async throws {
        try await withTemporaryDirectory { tmpDirPath -> Void in
            let core = try await getCore()
            let testWorkspace = try TestWorkspace("SomeName", sourceRoot: tmpDirPath, projects: [.init("Project1", groupTree: TestGroup.init("Empty"), targets: [TestStandardTarget("Target1", type: .application)])]).load(core)
            let workspaceContext = WorkspaceContext(core: core, workspace: testWorkspace, processExecutionCache: .sharedForTesting)

            let diagnostics: [ConfiguredTarget?: [Diagnostic]] = [
                nil: [
                    Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Test")),
                ]
            ]
            guard let description = try await BuildDescription.construct(workspace: testWorkspace, tasks: [], path: Path.root.join("tmp"), signature: ByteString([]), diagnostics: diagnostics, fs: PseudoFS())?.buildDescription else {
                Issue.record("Expected to be able to construct a build description.")
                return
            }

            let taskActionRegistry = try await TaskActionRegistry(pluginManager: core.pluginManager)
            let delegate = BuildDescriptionSerializerDelegate(taskActionRegistry: taskActionRegistry)
            let taskStoreSerializer = MsgPackSerializer(delegate: delegate)
            taskStoreSerializer.serialize(description.taskStore)
            let serializer = MsgPackSerializer(delegate: delegate)
            serializer.serialize(description)
            let serializedTaskStore = taskStoreSerializer.byteString
            let serializedBuildDescription = serializer.byteString

            let deserializerDelegate = BuildDescriptionDeserializerDelegate(workspace: workspaceContext.workspace, platformRegistry: workspaceContext.core.platformRegistry, sdkRegistry: workspaceContext.core.sdkRegistry, specRegistry: workspaceContext.core.specRegistry, taskActionRegistry: taskActionRegistry)
            let taskStoreDeserializer = MsgPackDeserializer(serializedTaskStore, delegate: deserializerDelegate)
            let taskStore: FrozenTaskStore = try taskStoreDeserializer.deserialize()
            deserializerDelegate.taskStore = taskStore
            let deserializer = MsgPackDeserializer(serializedBuildDescription, delegate: deserializerDelegate)
            let deserializedDescription: BuildDescription = try deserializer.deserialize()

            func dump(_ description: BuildDescription) throws -> String {
                var s = ""
                Swift.dump(description, to: &s)
                do {
                    // Eliminate the dumping of the private lock for the `tasksByTargetCache` object, which is not relevant for the comparison.
                    let regex = RegEx(patternLiteral: "▿ mutex:.*$\n\\ +- pointerValue:.*$", options: .anchorsMatchLines)
                    _ = regex.replace(in: &s, with: "")
                }
                do {
                    // Eliminate the dumping of the cache for the `isBuildDirectoryCache` object, which is not relevant for the comparison.
                    let regex = RegEx(patternLiteral: "▿ isBuildDirectoryCache:.*$\n\\ +- super:.*$\n +▿ cache:.*$\n\\ +- value:.*$\n\\ +- super:.*$", options: .anchorsMatchLines)
                    _ = regex.replace(in: &s, with: "")
                }
                return s
            }

            let s1 = try dump(description)
            let s2 = try dump(deserializedDescription)
            #expect(s1 == s2)
        }
    }

    @Test
    func nodeIdentifier() throws {
        #expect(MakePlannedVirtualNode("name").identifier == "<name>")
        #expect(MakePlannedVirtualNode("<name>").identifier == "<name>")
        #expect(MakePlannedVirtualNode("<<name>").identifier == "<<name>")
        #expect(MakePlannedVirtualNode("<name>>").identifier == "<name>>")

        #expect(MakePlannedPathNode(Path("path")).identifier == "path")
        #expect(MakePlannedPathNode(Path("/temp/path")).identifier == "/temp/path")

        #expect(MakePlannedDirectoryTreeNode(Path("path")).identifier == "path/")
        #expect(MakePlannedDirectoryTreeNode(Path("/temp/path")).identifier == "/temp/path/")
        #expect(MakePlannedDirectoryTreeNode(Path("/temp/path"), excluding: ["*.gitignore", "_CodeSignature"]).identifier == "/temp/path/")
    }

}

private extension BuildDescription {
    static func construct(workspace: Workspace, tasks: [any PlannedTask], path: Path, signature: BuildDescriptionSignature, buildCommand: BuildCommand? = nil, diagnostics: [ConfiguredTarget?: [Diagnostic]] = [:], indexingInfo: [(forTarget: ConfiguredTarget?, path: Path, indexingInfo: any SourceFileIndexingInfo)] = [], fs: any FSProxy = localFS, bypassActualTasks: Bool = false, moduleSessionFilePath: Path? = nil, invalidationPaths: [Path] = [], recursiveSearchPathResults: [RecursiveSearchPathResolver.CachedResult] = [], copiedPathMap: [String: String] = [:], rootPathsPerTarget: [ConfiguredTarget:[Path]] = [:], moduleCachePathsPerTarget: [ConfiguredTarget: [Path]] = [:], staleFileRemovalIdentifierPerTarget: [ConfiguredTarget: String] = [:], settingsPerTarget: [ConfiguredTarget: Settings] = [:], targetDependencies: [TargetDependencyRelationship] = [], definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>] = [:]) async throws -> BuildDescriptionDiagnosticResults? {
        let buildDescription = try await construct(workspace: workspace, tasks: tasks, path: path, signature: signature, buildCommand: buildCommand ?? .build(style: .buildOnly, skipDependencies: false), diagnostics: diagnostics, indexingInfo: indexingInfo, fs: fs, bypassActualTasks: bypassActualTasks, moduleSessionFilePath: moduleSessionFilePath, invalidationPaths: invalidationPaths, recursiveSearchPathResults: recursiveSearchPathResults, copiedPathMap: copiedPathMap, rootPathsPerTarget: rootPathsPerTarget, moduleCachePathsPerTarget: moduleCachePathsPerTarget, staleFileRemovalIdentifierPerTarget: staleFileRemovalIdentifierPerTarget, settingsPerTarget: settingsPerTarget, delegate: MockTestBuildDescriptionConstructionDelegate(), targetDependencies: targetDependencies, definingTargetsByModuleName: definingTargetsByModuleName, capturedBuildInfo: nil, userPreferences: .defaultForTesting)
        return buildDescription.map { BuildDescriptionDiagnosticResults(buildDescription: $0, workspace: workspace) } ?? nil
    }
}

private extension BuildDescriptionManager {
    func getNewOrCachedBuildDescription(_ request: BuildPlanRequest, bypassActualTasks: Bool = false, clientDelegate: any TaskPlanningClientDelegate) async throws -> BuildDescriptionRetrievalInfo? {
        let descRequest = BuildDescriptionRequest.newOrCached(request, bypassActualTasks: bypassActualTasks, useSynchronousBuildDescriptionSerialization: true)
        return try await getNewOrCachedBuildDescription(descRequest, clientDelegate: clientDelegate, constructionDelegate: MockTestBuildDescriptionConstructionDelegate())
    }
}
