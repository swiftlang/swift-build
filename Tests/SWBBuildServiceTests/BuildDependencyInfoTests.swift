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
import struct SWBProtocol.RunDestinationInfo
import SWBUtil
import SWBCore
import SWBBuildService
import SWBTestSupport
import Foundation

@Suite fileprivate struct BuildDependencyInfoTests: CoreBasedTests {

    /// A basic test which exercises several kinds of produced outputs, and inputs based on the contents of the Frameworks build phase.
    @Test(.requireSDKs(.iOS)) func frameworksPhaseInputs() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/aProject"),
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // Sources
                    TestFile("AppClass.swift"),
                    TestFile("FwkClass.swift"),
                    TestFile("DylibClass.swift"),
                    TestFile("StaticLibClass.swift"),
                    TestFile("Copied.txt"),

                    // Linked libraries
                    TestFile("AppKit.framework"),
                    TestFile("Foundation.framework"),
                    TestFile("libFoo.dylib"),
                    TestFile("libBar.a"),
                    TestFile("libBaz.a"),
                    TestFile("libQux.tbd"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                TestAggregateTarget(
                    "AggregateTarget",
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                            buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            "Copied.txt",
                        ], destinationSubfolder: .absolute, destinationSubpath: "/tmp/OtherFiles"),
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                            buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AppClass.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "FwkTarget.framework",
                            "AppKit.framework",
                        ])
                    ],
                    dependencies: ["FrameworkTarget"]
                ),
                TestStandardTarget(
                    "FwkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                            buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "FwkClass.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "Foundation.framework",
                            "libFoo.dylib",
                            "libDylibTarget.dylib",
                            "libStaticLibTarget.a",
                        ])
                    ]
                ),
                TestStandardTarget(
                    "DylibTarget",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                            buildSettings: [
                                "EXECUTABLE_PREFIX": "lib",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "DylibClass.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "Foundation.framework",
                            "libBar.a",
                            "libQux.tbd",
                        ])
                    ]
                ),
                TestStandardTarget(
                    "StaticLibTarget",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                            buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "StaticLibClass.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "Foundation.framework",
                            "libBaz.a",
                        ])
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try BuildDependencyInfoTester(core, testProject)
        let workspace = tester.workspace

        // Create dependency info for a release build and check the results.
        let runDestination = RunDestinationInfo.iOS
        let CONFIGURATION = "Config"
        let buildType = "Release"
        let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
        let parameters = BuildParameters(configuration: CONFIGURATION, activeRunDestination: runDestination, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
            ])
        let targets = workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: targets, dependencyScope: .workspace, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        try await tester.checkBuildDependencyInfo(buildRequest: buildRequest) { results in
            // We emit an entry for the aggregate target, even though it has no inputs and no outputs.
            results.checkTargetInfo("AggregateTarget") { target in
                #expect(target.platformName == "iphoneos")
                results.checkNoMoreTargetInputs(target)
                results.checkNoMoreTargetOutputPaths(target)
            }
            results.checkTargetInfo("AppTarget") { target in
                #expect(target.platformName == "iphoneos")

                results.checkTargetInputName(target, .name("FwkTarget.framework")) { input in
                    #expect(input.inputType == .framework)
                    #expect(input.linkType == .searchPath)
                }
                results.checkTargetInputName(target, .name("AppKit.framework")) { input in
                    #expect(input.inputType == .framework)
                    #expect(input.linkType == .searchPath)
                }
                results.checkNoMoreTargetInputs(target)

                results.checkTargetOutputPath(target, "/Applications/AppTarget.app")
                results.checkNoMoreTargetOutputPaths(target)
            }
            results.checkTargetInfo("FwkTarget") { target in
                #expect(target.platformName == "iphoneos")

                results.checkTargetInputName(target, .name("Foundation.framework")) { input in
                    #expect(input.inputType == .framework)
                    #expect(input.linkType == .searchPath)
                }
                results.checkTargetInputName(target, .name("libFoo.dylib")) { input in
                    #expect(input.inputType == .library)
                    #expect(input.linkType == .searchPath)
                }
                results.checkTargetInputName(target, .name("libDylibTarget.dylib")) { input in
                    #expect(input.inputType == .library)
                    #expect(input.linkType == .searchPath)
                }
                results.checkTargetInputName(target, .name("libStaticLibTarget.a")) { input in
                    #expect(input.inputType == .library)
                    #expect(input.linkType == .searchPath)
                }
                results.checkNoMoreTargetInputs(target)

                results.checkTargetOutputPath(target, "/Library/Frameworks/FwkTarget.framework")
                results.checkNoMoreTargetOutputPaths(target)
            }
            results.checkTargetInfo("DylibTarget") { target in
                #expect(target.platformName == "iphoneos")

                results.checkTargetInputName(target, .name("Foundation.framework")) { input in
                    #expect(input.inputType == .framework)
                    #expect(input.linkType == .searchPath)
                }
                results.checkTargetInputName(target, .name("libBar.a")) { input in
                    #expect(input.inputType == .library)
                    #expect(input.linkType == .searchPath)
                }
                results.checkTargetInputName(target, .name("libQux.tbd")) { input in
                    #expect(input.inputType == .library)
                    #expect(input.linkType == .searchPath)
                }
                results.checkNoMoreTargetInputs(target)

                results.checkTargetOutputPath(target, "/usr/local/lib/libDylibTarget.dylib")
                results.checkNoMoreTargetOutputPaths(target)
            }
            results.checkTargetInfo("StaticLibTarget") { target in
                #expect(target.platformName == "iphoneos")

                results.checkTargetInputName(target, .name("Foundation.framework")) { input in
                    #expect(input.inputType == .framework)
                    #expect(input.linkType == .searchPath)
                }
                results.checkTargetInputName(target, .name("libBaz.a")) { input in
                    #expect(input.inputType == .library)
                    #expect(input.linkType == .searchPath)
                }
                results.checkNoMoreTargetInputs(target)

                results.checkTargetOutputPath(target, "/usr/local/lib/libStaticLibTarget.a")
                results.checkNoMoreTargetOutputPaths(target)
            }
            results.checkNoMoreTargetInfos()
            results.checkNoErrors()
        }
    }

    /// A basic test which exercises extracting inputs from build settings.
    @Test(.requireSDKs(.iOS)) func buildSettingsInputs() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/aProject"),
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // Sources
                    TestFile("AppClass.swift"),
                    TestFile("Copied.txt"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                TestAggregateTarget(
                    "AggregateTarget",
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                            buildSettings: [
                                "OTHER_LDFLAGS": [
                                    "-framework Foo",
                                    "-lBar",
                                ].joined(separator: " ")
                            ]),
                    ],
                    buildPhases: [
                        TestCopyFilesBuildPhase([
                            "Copied.txt",
                        ], destinationSubfolder: .absolute, destinationSubpath: "/tmp/OtherFiles"),
                    ],
                    dependencies: ["AppTarget"]
                ),
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                            buildSettings: [
                                "OTHER_LDFLAGS": [
                                    // Test framework linkages.
                                    "-framework Fwk",
                                    "-weak_framework WeakFwk",
                                    "-reexport_framework ReexportFwk",
                                    "-merge_framework MergeFwk",
                                    "-no_merge_framework NoMergeFwk",
                                    "-lazy_framework LazyFwk",

                                    // Apparently both of these uses of -Xlinker are valid
                                    "-Xlinker -reexport_framework -Xlinker XlinkXlinkFwk",
                                    "-Xlinker -reexport_framework XlinkFwk",

                                    "-Wl,-reexport_framework,QuoteFwk",
                                    "-Wl,-reexport_framework -Wl,QuoteQuoteFwk",

                                    // Test library linkages
                                    "-lLib",
                                    "-weak-lWeakLib",
                                    "-reexport-lReexportLib",
                                    "-merge-lMergeLib",
                                    "-no_merge-lNoMergeLib",
                                    "-lazy-lLazyLib",

                                    "-Xlinker -reexport-lXlinkerLib",
                                    "-Wl,-reexport-lQuoteLib",

                                    // TODO: we should support positional arguments as well but that requires a complete understanding of all possible linker args, will come back to this
                                ].joined(separator: " ")
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AppClass.swift",
                        ]),
                        // No frameworks build phase because we should capture info from OTHER_LDFLAGS even if there isn't one.
                    ],
                    dependencies: []
                ),
            ])
        let core = try await getCore()
        let tester = try BuildDependencyInfoTester(core, testProject)
        let workspace = tester.workspace

        /// Create dependency info for a release build and check the results.
        let runDestination = RunDestinationInfo.iOS
        let CONFIGURATION = "Config"
        let buildType = "Release"
        let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
        let parameters = BuildParameters(configuration: CONFIGURATION, activeRunDestination: runDestination, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
            ])
        let targets = workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: targets, dependencyScope: .workspace, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        try await tester.checkBuildDependencyInfo(buildRequest: buildRequest) { results in
            // We emit an entry for the aggregate target, even though it has no inputs and no outputs.
            results.checkTargetInfo("AggregateTarget") { target in
                #expect(target.platformName == "iphoneos")
                results.checkNoMoreTargetInputs(target)
                results.checkNoMoreTargetOutputPaths(target)
            }
            results.checkTargetInfo("AppTarget") { target in
                #expect(target.platformName == "iphoneos")

                // Check framework linkage
                for fwkStem in ["Fwk", "WeakFwk", "ReexportFwk", "MergeFwk", "NoMergeFwk", "LazyFwk"] {
                    results.checkTargetInputName(target, .stem(fwkStem)) { input in
                        #expect(input.inputType == .framework)
                        #expect(input.linkType == .searchPath)
                    }
                }

                // Check framework linkage with different -Xlinker pass-throughs
                for fwkStem in ["XlinkXlinkFwk", "XlinkFwk"] {
                    results.checkTargetInputName(target, .stem(fwkStem)) { input in
                        #expect(input.inputType == .framework)
                        #expect(input.linkType == .searchPath)
                    }
                }

                // Check framework linkage with different -Wl, pass-throughs
                for fwkStem in ["QuoteFwk", "QuoteQuoteFwk"] {
                    results.checkTargetInputName(target, .stem(fwkStem)) { input in
                        #expect(input.inputType == .framework)
                        #expect(input.linkType == .searchPath)
                    }
                }

                // Check library linkage
                for fwkStem in ["Lib", "WeakLib", "ReexportLib", "MergeLib", "NoMergeLib", "LazyLib"] {
                    results.checkTargetInputName(target, .stem(fwkStem)) { input in
                        #expect(input.inputType == .library)
                        #expect(input.linkType == .searchPath)
                    }
                }

                // Check quoted library linkage.
                for fwkStem in ["XlinkerLib", "QuoteLib"] {
                    results.checkTargetInputName(target, .stem(fwkStem)) { input in
                        #expect(input.inputType == .library)
                        #expect(input.linkType == .searchPath)
                    }
                }

                results.checkNoMoreTargetInputs(target)

                results.checkTargetOutputPath(target, "/Applications/AppTarget.app")
                results.checkNoMoreTargetOutputPaths(target)
            }
            results.checkNoMoreTargetInfos()
            results.checkNoErrors()
        }
    }

    @Test(.requireSDKs(.iOS)) func serialization() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/aProject"),
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    // Sources
                    TestFile("AppClass.swift"),

                    // Linked libraries
                    TestFile("Cocoa.framework"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                        "CODE_SIGN_IDENTITY": "-",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "iphoneos",
                        "SWIFT_INSTALL_OBJC_HEADER": "NO",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Config",
                            buildSettings: [
                                "OTHER_LDFLAGS": [
                                    "-framework Foo",
                                    "-lBar",
                                ].joined(separator: " ")
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "AppClass.swift",
                        ]),
                        TestFrameworksBuildPhase([
                            "Cocoa.framework",
                        ])
                    ],
                    dependencies: []
                ),
            ])
        let core = try await getCore()
        let tester = try BuildDependencyInfoTester(core, testProject)
        let workspace = tester.workspace

        /// Create dependency info for a release build and check the results.
        let runDestination = RunDestinationInfo.iOS
        let CONFIGURATION = "Config"
        let buildType = "Release"
        let (SYMROOT, OBJROOT, DSTROOT) = buildDirs(in: Path("/tmp/buildDir"), for: buildType)
        let parameters = BuildParameters(configuration: CONFIGURATION, activeRunDestination: runDestination, overrides: [
                "SYMROOT": SYMROOT,
                "OBJROOT": OBJROOT,
                "DSTROOT": DSTROOT,
                "DEPLOYMENT_POSTPROCESSING": "YES",
                "DEPLOYMENT_LOCATION": "YES",
            ])
        let targets = workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: targets, dependencyScope: .workspace, continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)
        try await tester.checkBuildDependencyInfo(buildRequest: buildRequest) { origResults in
            func check(results: BuildDependencyInfoTester.Results, file: StaticString = #filePath, line: UInt = #line, sourceLocation: SourceLocation = #_sourceLocation) {
                results.checkTargetInfo("AppTarget") { target in
                    #expect(target.platformName == "iphoneos", sourceLocation: sourceLocation)

                    results.checkTargetInputName(target, .name("Cocoa.framework"), sourceLocation: sourceLocation) { input in
                        #expect(input.inputType == .framework, sourceLocation: sourceLocation)
                        #expect(input.linkType == .searchPath, sourceLocation: sourceLocation)
                    }
                    results.checkTargetInputName(target, .stem("Foo"), sourceLocation: sourceLocation) { input in
                        #expect(input.inputType == .framework, sourceLocation: sourceLocation)
                        #expect(input.linkType == .searchPath, sourceLocation: sourceLocation)
                    }
                    results.checkTargetInputName(target, .stem("Bar"), sourceLocation: sourceLocation) { input in
                        #expect(input.inputType == .library, sourceLocation: sourceLocation)
                        #expect(input.linkType == .searchPath, sourceLocation: sourceLocation)
                    }
                    results.checkNoMoreTargetInputs(target, sourceLocation: sourceLocation)

                    results.checkTargetOutputPath(target, "/Applications/AppTarget.app", sourceLocation: sourceLocation)
                    results.checkNoMoreTargetOutputPaths(target, sourceLocation: sourceLocation)
                }
                results.checkNoMoreTargetInfos(sourceLocation: sourceLocation)
                results.checkNoErrors(sourceLocation: sourceLocation)
            }

            // Check the original results and then encode them.
            check(results: origResults)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(origResults.info)

            // Useful for debugging.
//            if let prettyPrintedString = String(data:data, encoding: String.Encoding.utf8) {
//                print("\(prettyPrintedString)")
//            }
            // TODO: Check that the JSON we produce is correct.  We don't do this yet so we can iterate on the format rapidly.

            // Round-trip the data back to a BuildDependencyInfo object and check it.
            let roundTripInfo = try JSONDecoder().decode(BuildDependencyInfo.self, from: data)
            let roundTripResults = BuildDependencyInfoTester.Results(roundTripInfo)

            check(results: roundTripResults)
        }
    }

}


// MARK: - Testing infrastructure


fileprivate final class BuildDependencyInfoTester {
    class Results {
        let info: BuildDependencyInfo

        var uncheckedTargets: [BuildDependencyInfo.TargetDependencyInfo.Target: BuildDependencyInfo.TargetDependencyInfo]

        var uncheckedInputsByTarget: [BuildDependencyInfo.TargetDependencyInfo.Target: Set<BuildDependencyInfo.TargetDependencyInfo.Input>]

        var uncheckedOutputPathsByTarget: [BuildDependencyInfo.TargetDependencyInfo.Target: Set<String>]

        init(_ info: BuildDependencyInfo) {
            self.info = info

            self.uncheckedTargets = info.targets.reduce(into: [BuildDependencyInfo.TargetDependencyInfo.Target: BuildDependencyInfo.TargetDependencyInfo](), { $0[$1.target] = $1 })
            self.uncheckedInputsByTarget = info.targets.reduce(into: [BuildDependencyInfo.TargetDependencyInfo.Target: Set<BuildDependencyInfo.TargetDependencyInfo.Input>](), { $0[$1.target] = Set($1.inputs) })
            self.uncheckedOutputPathsByTarget = info.targets.reduce(into: [BuildDependencyInfo.TargetDependencyInfo.Target: Set<String>](), { $0[$1.target] = Set($1.outputPaths) })
        }

        func checkTargetInfo(_ targetName: String, projectName: String? = nil, sourceLocation: SourceLocation = #_sourceLocation, check: (BuildDependencyInfo.TargetDependencyInfo.Target) -> Void) {
            let matchedTargets = uncheckedTargets.compactMap { (target, info) in
                (target.targetName == targetName && (projectName == nil || target.projectName == projectName)) ? (target, info) : nil
            }
            if let (target, _) = matchedTargets.only {
                uncheckedTargets.removeValue(forKey: target)
                // We pass the Target back here to save on boilerplate in the tests' checker blocks, but if we add more stuff to TargetDependencyInfo in the future we may want to pass that instead, unless we end up adding more infrastructure to this class like we have for the inputs and outputs.
                check(target)
            }
            else if matchedTargets.isEmpty {
                Issue.record(Comment(rawValue: "unable to find target with name '\(targetName)'" + (projectName != nil ? " in project '\(projectName!)" : "")), sourceLocation: sourceLocation)
            } else {
                Issue.record(Comment(rawValue: "found multiple targets with name '\(targetName)'" + (projectName != nil ? " in project '\(projectName!)" : "") + ": \(matchedTargets.map({ $0.0 }))"), sourceLocation: sourceLocation)
            }
        }

        public func checkNoMoreTargetInfos(sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(uncheckedTargets.isEmpty, "found \(uncheckedTargets.count) unmatched infos: \(uncheckedTargets.map({ $0.0 }).sorted(by: \.targetName))", sourceLocation: sourceLocation)
        }

        func checkTargetInputName(_ target: BuildDependencyInfo.TargetDependencyInfo.Target, _ name: BuildDependencyInfo.TargetDependencyInfo.Input.NameType, sourceLocation: SourceLocation = #_sourceLocation, check: (BuildDependencyInfo.TargetDependencyInfo.Input) -> Void) {
            guard var inputs = uncheckedInputsByTarget[target] else {
                Issue.record("unable to find inputs for target '\(target.targetName)'", sourceLocation: sourceLocation)
                return
            }
            let matchedInputs = inputs.filter { $0.name == name }
            if let input = matchedInputs.only {
                inputs.remove(input)
                uncheckedInputsByTarget[target] = inputs
                check(input)
            }
            else if matchedInputs.isEmpty {
                Issue.record(Comment("unable to find input named '\(name.stringForm)' for target '\(target.targetName)', among inputs: \(inputs)"), sourceLocation: sourceLocation)
            } else {
                Issue.record(Comment("found multiple inputs named '\(name.stringForm)' for target '\(target.targetName)': \(matchedInputs)"), sourceLocation: sourceLocation)
            }
        }

        public func checkNoMoreTargetInputs(_ target: BuildDependencyInfo.TargetDependencyInfo.Target, sourceLocation: SourceLocation = #_sourceLocation) {
            if let inputs = uncheckedInputsByTarget[target] {
                #expect(inputs.isEmpty, "found \(inputs.count) unmatched inputs for target '\(target.targetName)': \(inputs.sorted(by: \.name.stringForm))", sourceLocation: sourceLocation)
            }
        }

        func checkTargetOutputPath(_ target: BuildDependencyInfo.TargetDependencyInfo.Target, _ path: String, sourceLocation: SourceLocation = #_sourceLocation) {
            guard var outputPaths = uncheckedOutputPathsByTarget[target] else {
                Issue.record("unable to find outputPaths for target '\(target.targetName)'", sourceLocation: sourceLocation)
                return
            }
            let matchedOutputPaths = outputPaths.filter { $0 == path }
            if let outputPath = matchedOutputPaths.only {
                outputPaths.remove(outputPath)
                uncheckedOutputPathsByTarget[target] = outputPaths
            }
            else if matchedOutputPaths.isEmpty {
                Issue.record(Comment("unable to find output path '\(path)' for target '\(target.targetName)'"), sourceLocation: sourceLocation)
            } else {
                Issue.record(Comment("found multiple output path '\(path)' for target '\(target.targetName)'"), sourceLocation: sourceLocation)
            }
        }

        public func checkNoMoreTargetOutputPaths(_ target: BuildDependencyInfo.TargetDependencyInfo.Target, sourceLocation: SourceLocation = #_sourceLocation) {
            if let outputs = uncheckedOutputPathsByTarget[target] {
                #expect(outputs.isEmpty, "found \(outputs.count) unmatched inputs for target '\(target.targetName)': \(outputs.sorted())", sourceLocation: sourceLocation)
            }
        }

        public func checkNoErrors(sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(info.errors.isEmpty, "unexpected errors: \(info.errors)", sourceLocation: sourceLocation)
        }
    }

    let core: Core
    public let workspace: Workspace
    let workspaceContext: WorkspaceContext

    public init(_ core: Core, _ testWorkspace: TestWorkspace) throws {
        self.core = core
        self.workspace = try testWorkspace.load(core)
        self.workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: ProcessExecutionCache())
    }

    /// Convenience initializer for single project workspace tests.
    public convenience init(_ core: Core, _ testProject: TestProject) throws {
        try self.init(core, TestWorkspace("\(testProject.name)Workspace", sourceRoot: testProject.sourceRoot, projects: [testProject]))
    }

    /// The main entry point to construct dependency info for a build, calling back to the checker block with the `Results` object.
    public func checkBuildDependencyInfo(buildRequest: BuildRequest, file: StaticString = #filePath, line: UInt = #line, check: (Results) async throws -> Void) async throws {
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let operation = BuildDependencyInfoOperation(workspace: workspace)

        let info = try await BuildDependencyInfo(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, operation: operation)

        let results = Results(info)

        try await check(results)
    }

}
