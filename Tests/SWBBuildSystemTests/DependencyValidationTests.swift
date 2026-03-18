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
import SWBTestSupport
import SWBUtil
import Testing
import SWBProtocol

@Suite
fileprivate struct DependencyValidationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func dependencyValidation() async throws {
        try await testDependencyValidation(BuildParameters(configuration: "Debug"))
    }

    @Test(.requireSDKs(.macOS))
    func dependencyValidationError() async throws {
        try await testDependencyValidation(BuildParameters(configuration: "Debug", overrides: ["VALIDATE_DEPENDENCIES": "YES_ERROR"]))
    }

    @Test(.requireSDKs(.macOS))
    func dependencyValidationWarning() async throws {
        try await testDependencyValidation(BuildParameters(configuration: "Debug", overrides: ["VALIDATE_DEPENDENCIES": "YES"]))
    }

    @Test(.requireSDKs(.macOS))
    func dependencyValidationNone() async throws {
        try await testDependencyValidation(BuildParameters(configuration: "Debug", overrides: ["VALIDATE_DEPENDENCIES": "NO"]))
    }

    func testDependencyValidation(_ parameters: BuildParameters) async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "AppTarget",
                    children: [
                        TestGroup(
                            "Sources",
                            children: [
                                TestFile("test.c"),
                            ]
                        )
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)"
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "HEADER_SEARCH_PATHS": "$(DERIVED_SOURCES_DIR)",
                                ]
                            )
                        ],
                        buildPhases: [
                            TestShellScriptBuildPhase(
                                name: "Script1",
                                originalObjectID: "Script1",
                                contents: "touch \"$DERIVED_SOURCES_DIR/other.c\" && touch \"$SCRIPT_OUTPUT_FILE_0\"",
                                outputs: [
                                    "$(DERIVED_SOURCES_DIR)/order"
                                ]
                            ),
                            TestShellScriptBuildPhase(
                                name: "Script2",
                                originalObjectID: "Script2",
                                contents: "touch \"$DERIVED_SOURCES_DIR/header.h\" && touch \"$SCRIPT_OUTPUT_FILE_0\"",
                                inputs: [
                                    "$(DERIVED_SOURCES_DIR)/order",
                                    "$(DERIVED_SOURCES_DIR)/other.c"
                                ],
                                outputs: [
                                    "$(DERIVED_SOURCES_DIR)/order.h",
                                ]
                            ),
                            TestSourcesBuildPhase([
                                "test.c"
                            ])
                        ]
                    )
                ]
            )

            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDir, projects: [testProject])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try tester.fs.createDirectory(tmpDir.join("aProject/Sources"), recursive: true)
            try await tester.fs.writeFileContents(tmpDir.join("aProject/Sources/test.c")) {
                $0 <<< "#include \"header.h\"\n"
                $0 <<< "int main() { return 0; }\n"
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkTask(.matchRule(["PhaseScriptExecution", "Script2", "\(tmpDir.str)/aProject/build/aProject.build/Debug/AppTarget.build/Script-Script2.sh"])) { task in
                    // The second script phase should produce an error because its declared input is not _declared_ to be produced by the first script phase even though they are otherwise ordered correctly via the "$(DERIVED_SOURCES_DIR)/order" mock node.
                    let pattern: StringPattern = .suffix("Missing creator task for input node: '\(tmpDir.str)/aProject/build/aProject.build/Debug/AppTarget.build/DerivedSources/other.c'. Did you forget to declare this node as an output of a script phase or custom build rule which produces it? (for task: [\"PhaseScriptExecution\", \"Script2\", \"\(tmpDir.str)/aProject/build/aProject.build/Debug/AppTarget.build/Script-Script2.sh\"])")

                    switch parameters.overrides["VALIDATE_DEPENDENCIES"] {
                    case "YES_ERROR":
                        results.checkTaskResult(task, expected: .failedSetup)
                        results.checkError(pattern)
                    case "YES":
                        results.checkTaskResult(task, expected: .succeeded(metrics: nil))
                        results.checkWarning(pattern)
                    case nil:
                        results.checkTaskResult(task, expected: .succeeded(metrics: nil))
                        // TODO: rdar://80796520 (Re-enable dependency validator)
                        break
                    default:
                        break
                    }
                }

                results.checkTask(.matchRule(["CompileC", "\(tmpDir.str)/aProject/build/aProject.build/Debug/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/test.o", "\(tmpDir.str)/aProject/Sources/test.c", "normal", "\(results.runDestinationTargetArchitecture)", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { task in
                    // The C compilation task should produce an error because the header.h file from its discovered dependencies is not declared to be produced by the script phase even though they are otherwise ordered correctly via the "$(DERIVED_SOURCES_DIR)/order.h" mock node.
                    let pattern: StringPattern = .suffix("Missing creator task for discovered dependency input node: '\(tmpDir.str)/aProject/build/aProject.build/Debug/AppTarget.build/DerivedSources/header.h'. Did you forget to declare this node as an output of a script phase or custom build rule which produces it? (for task: [\"CompileC\", \"\(tmpDir.str)/aProject/build/aProject.build/Debug/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/test.o\", \"\(tmpDir.str)/aProject/Sources/test.c\", \"normal\", \"\(results.runDestinationTargetArchitecture)\", \"c\", \"com.apple.compilers.llvm.clang.1_0.compiler\"])")

                    switch parameters.overrides["VALIDATE_DEPENDENCIES"] {
                    case "YES_ERROR":
                        results.checkTaskResult(task, expected: .failedSetup)
                        results.checkError(pattern)
                    case "YES":
                        results.checkTaskResult(task, expected: .succeeded(metrics: nil))
                        results.checkWarning(pattern)
                    case nil:
                        results.checkTaskResult(task, expected: .succeeded(metrics: nil))
                        // TODO: rdar://80796520 (Re-enable dependency validator)
                        break
                    default:
                        break
                    }
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func dependencyValidationWithSymlinks() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "AppTarget",
                    children: [
                        TestGroup(
                            "Sources",
                            children: [
                                TestFile("test.c"),
                                TestFile("test.h"),
                                TestFile("Framework.h"),
                            ]
                        )
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "DEPLOYMENT_POSTPROCESSING": "NO",
                        "INSTALL_OWNER": "",
                        "INSTALL_GROUP": "",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "USE_HEADERMAP": "NO",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "test.c"
                            ]),
                            TestFrameworksBuildPhase([
                                "Framework.framework"
                            ])
                        ],
                        dependencies: ["Framework"]
                    ),
                    TestStandardTarget(
                        "Framework",
                        type: .framework,
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("Framework.h", headerVisibility: .public),
                                TestBuildFile("test.h", headerVisibility: .public)
                            ]),
                            TestSourcesBuildPhase([
                                "test.c"
                            ])
                        ]
                    )
                ]
            )

            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDir, projects: [testProject])
            let parameters = BuildParameters(action: .install, configuration: "Debug", overrides: [
                "DSTROOT": tmpDir.join("DSTROOT").str,
                "OBJROOT": tmpDir.join("OBJROOT").str,
                "SYMROOT": tmpDir.join("SYMROOT").str,
                "VALIDATE_DEPENDENCIES": "YES_ERROR",
            ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try tester.fs.createDirectory(tmpDir.join("aProject/Sources"), recursive: true)
            try await tester.fs.writeFileContents(tmpDir.join("aProject/Sources/test.c")) {
                $0 <<< "#include <Framework/Framework.h>\n"
                $0 <<< "int main() { return 0; }\n"
            }
            try await tester.fs.writeFileContents(tmpDir.join("aProject/Sources/test.h")) { _ in }
            try await tester.fs.writeFileContents(tmpDir.join("aProject/Sources/Framework.h")) {
                $0 <<< "#include <Framework/test.h>\n"
            }

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS) { results in
                var exists = false
                #expect(tester.fs.isSymlink(tmpDir.join("SYMROOT").join("Debug").join("Framework.framework"), &exists))
                #expect(exists)

                let testDependencies = try tester.fs.read(tmpDir.join("OBJROOT").join("aProject.build/Debug/AppTarget.build/Objects-normal/\(results.runDestinationTargetArchitecture)/test.d"))
                #expect(testDependencies.unsafeStringValue.split(separator: "\n") == [
                    "dependencies: \\",
                    "  \(tmpDir.str)/aProject/Sources/test.c \\",
                    "  \(tmpDir.str)/SYMROOT/Debug/Framework.framework/Headers/Framework.h \\",
                    "  \(tmpDir.str)/SYMROOT/Debug/Framework.framework/Headers/test.h"
                ])

                // Even though the Makefile dependencies point to symlinks for the headers, we should resolve them and still find the producer tasks.
                results.checkNoDiagnostics()
            }
        }
    }

    /// Tests that files within `MODULE_CACHE_DIR` are never considered as missing inputs, even if `MODULE_CACHE_DIR` is a subpath of one of the target's other "root paths" (DSTROOT/OBJROOT/SYMROOT).
    @Test(.requireSDKs(.macOS))
    func dependencyValidationModuleCache() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup(
                    "AppTarget",
                    children: [
                        TestGroup(
                            "Sources",
                            children: [
                                TestFile("test.c"),
                            ]
                        )
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "DEPLOYMENT_POSTPROCESSING": "NO",
                        "INSTALL_OWNER": "",
                        "INSTALL_GROUP": "",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "USE_HEADERMAP": "NO",
                        "DSTROOT": tmpDir.join("dstroot").str,
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "test.c"
                            ]),
                            TestShellScriptBuildPhase(
                                name: "Foo",
                                originalObjectID: "Foo",
                                contents: "touch $SCRIPT_OUTPUT_FILE_0",
                                outputs: ["$(TARGET_TEMP_DIR)/foo"],
                                dependencyInfo: .dependencyInfo(.string(tmpDir.join("dd").join("foo.d").str)))
                        ]
                    )
                ]
            )

            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDir, projects: [testProject])
            let parameters = BuildParameters(action: .install, configuration: "Debug", overrides: [
                "VALIDATE_DEPENDENCIES": "YES_ERROR",
            ], arena: .init(derivedDataPath: tmpDir.join("dd"), buildProductsPath: tmpDir.join("dd").join("Products"), buildIntermediatesPath: tmpDir.join("dd"), pchPath: tmpDir.join("dd"), indexRegularBuildProductsPath: nil, indexRegularBuildIntermediatesPath: nil, indexPCHPath: tmpDir.join("dd"), indexDataStoreFolderPath: nil, indexEnableDataStore: false))
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            try tester.fs.createDirectory(tmpDir.join("aProject/Sources"), recursive: true)
            try await tester.fs.writeFileContents(tmpDir.join("aProject/Sources/test.c")) {
                $0 <<< "int main() { return 0; }\n"
            }

            try tester.fs.createDirectory(tmpDir.join("dd").join("ModuleCache.noindex"), recursive: true)
            try await tester.fs.writeFileContents(tmpDir.join("dd").join("ModuleCache.noindex/foo.pcm")) {
                $0 <<< ""
            }

            try await tester.fs.writeFileContents(tmpDir.join("dd").join("foo.d")) {
                try $0 <<< DependencyInfo(version: "none", inputs: [tmpDir.join("dd").join("ModuleCache.noindex/foo.pcm").str]).asBytes()
            }

            try tester.fs.setCreatedByBuildSystemAttribute(tmpDir.join("dd"))

            try await tester.checkBuild(parameters: parameters, runDestination: .macOS) { results in
                results.checkNoDiagnostics()
            }
        }
    }
}
