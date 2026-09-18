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

import SWBCore
import SWBProtocol
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct VariantAwareStaticLinkingTaskConstructionTests: CoreBasedTests {
    /// With `ENABLE_VARIANT_AWARE_STATIC_LINKING` and a non-normal consumer variant, the linker
    /// command line should include `-image_suffix _<variant>` so LD's path search prefers a
    /// variant-suffixed sibling archive (e.g. `libProducer_debug.a`) over the un-varianted one.
    @Test(.requireSDKs(.macOS))
    func staticArchiveImageSuffixPassedToLinker() async throws {
        let libtoolPath = try await self.libtoolPath
        let buildVariants = ["normal", "debug"]
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles", children: [TestFile("main.c"), TestFile("producer.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "CODE_SIGNING_ALLOWED": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "BUILD_VARIANTS": buildVariants.joined(separator: " "),
                    "ENABLE_VARIANT_AWARE_STATIC_LINKING": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget("Consumer", type: .commandLineTool, buildPhases: [
                    TestSourcesBuildPhase(["main.c"]),
                    TestFrameworksBuildPhase([TestBuildFile(.target("Producer"))]),
                ], dependencies: ["Producer"]),
                TestStandardTarget("Producer", type: .staticLibrary, buildPhases: [
                    TestSourcesBuildPhase(["producer.c"]),
                ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Release"), runDestination: .macOS, targetName: "Consumer") { results in
            results.checkNoDiagnostics()
            results.checkTarget("Consumer") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("debug")) { task in
                    let args = task.commandLine.map(\.asString)
                    let idx = args.firstIndex(of: "-image_suffix")
                    #expect(idx != nil, "expected `-image_suffix` on debug Ld line; got: \(args)")
                    if let idx, idx + 2 < args.count {
                        #expect(args[idx + 2] == "_debug", "expected `_debug` after `-image_suffix`; got: \(args[idx + 2])")
                    }
                    #expect(args.contains("-lProducer"), "expected `-lProducer` on debug Ld line; got: \(args.filter { $0.hasPrefix("-l") })")
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("normal")) { task in
                    let args = task.commandLine.map(\.asString)
                    #expect(!args.contains("-image_suffix"), "normal variant should not emit `-image_suffix`; got: \(args)")
                }
            }
        }
    }

    /// Without `ENABLE_VARIANT_AWARE_STATIC_LINKING`, `-image_suffix` should not be emitted, even
    /// for a non-normal variant.
    @Test(.requireSDKs(.macOS))
    func staticArchiveImageSuffixNotEmittedByDefault() async throws {
        let libtoolPath = try await self.libtoolPath
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles", children: [TestFile("main.c"), TestFile("producer.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "CODE_SIGNING_ALLOWED": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "BUILD_VARIANTS": "normal debug",
                ]),
            ],
            targets: [
                TestStandardTarget("Consumer", type: .commandLineTool, buildPhases: [
                    TestSourcesBuildPhase(["main.c"]),
                    TestFrameworksBuildPhase([TestBuildFile(.target("Producer"))]),
                ], dependencies: ["Producer"]),
                TestStandardTarget("Producer", type: .staticLibrary, buildPhases: [
                    TestSourcesBuildPhase(["producer.c"]),
                ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Release"), runDestination: .macOS, targetName: "Consumer") { results in
            results.checkNoDiagnostics()
            results.checkTarget("Consumer") { target in
                for variant in ["normal", "debug"] {
                    results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem(variant)) { task in
                        let args = task.commandLine.map(\.asString)
                        #expect(!args.contains("-image_suffix"), "\(variant) Ld line should not contain `-image_suffix` when the setting is disabled")
                    }
                }
            }
        }
    }

    /// With `ENABLE_VARIANT_AWARE_STATIC_LINKING` and a consumer linking an object-file package
    /// module whose producer builds the same variants, each variant's link file list should
    /// reference the variant-suffixed `.o` (`E_debug.o` for the debug variant).
    @Test(.requireSDKs(.macOS))
    func objectFileResolvedInPerVariantScope() async throws {
        let libtoolPath = try await self.libtoolPath
        let buildVariants = ["normal", "debug"]
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles", children: [TestFile("main.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "CODE_SIGNING_ALLOWED": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "BUILD_VARIANTS": buildVariants.joined(separator: " "),
                    "ENABLE_VARIANT_AWARE_STATIC_LINKING": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget("Tool", type: .commandLineTool, buildPhases: [
                    TestSourcesBuildPhase(["main.c"]),
                    TestFrameworksBuildPhase([TestBuildFile(.target("SomePackageProduct"))]),
                ], dependencies: ["SomePackageProduct"]),
            ])
        let testPackage = try await TestPackageProject(
            "Package",
            groupTree: TestGroup("OtherFiles", children: [TestFile("foo.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "BUILD_VARIANTS": buildVariants.joined(separator: " "),
                ]),
            ],
            targets: [
                TestPackageProductTarget("SomePackageProduct",
                                         frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("E"))]),
                                         dependencies: ["E"]),
                TestStandardTarget("E", type: .commonObject, buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
            ])
        let workspace = TestWorkspace("aWorkspace", projects: [testProject, testPackage])
        let tester = try await TaskConstructionTester(getCore(), workspace)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Release"), runDestination: .macOS, targetName: "Tool") { results in
            results.checkNoDiagnostics()
            results.checkTarget("Tool") { target in
                let arch = results.runDestinationTargetArchitecture
                for variant in buildVariants {
                    let suffix = variant == "normal" ? "" : "_\(variant)"
                    let listPath = "/tmp/aWorkspace/aProject/build/aProject.build/Release/Tool.build/Objects-\(variant)/\(arch)/Tool.LinkFileList"
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", listPath])) { _, contents in
                        #expect(contents == "/tmp/aWorkspace/aProject/build/aProject.build/Release/Tool.build/Objects-\(variant)/\(arch)/main.o\n/tmp/aWorkspace/Package/build/Release/E\(suffix).o\n")
                    }
                }
            }
        }
    }

    /// When the producer target does not build the consumer's non-normal variant, task
    /// construction emits a warning (unless `DISABLE_VARIANT_AWARE_STATIC_LINKING_FALLBACK_WARNING`
    /// is set).
    @Test(.requireSDKs(.macOS))
    func warningWhenProducerMissesVariant() async throws {
        let libtoolPath = try await self.libtoolPath
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles", children: [TestFile("main.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "CODE_SIGNING_ALLOWED": "NO",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "BUILD_VARIANTS": "normal debug",
                    "ENABLE_VARIANT_AWARE_STATIC_LINKING": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget("Tool", type: .commandLineTool, buildPhases: [
                    TestSourcesBuildPhase(["main.c"]),
                    TestFrameworksBuildPhase([TestBuildFile(.target("SomePackageProduct"))]),
                ], dependencies: ["SomePackageProduct"]),
            ])
        let testPackage = try await TestPackageProject(
            "Package",
            groupTree: TestGroup("OtherFiles", children: [TestFile("foo.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "CODE_SIGN_IDENTITY": "",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "USE_HEADERMAP": "NO",
                    "BUILD_VARIANTS": "normal",
                ]),
            ],
            targets: [
                TestPackageProductTarget("SomePackageProduct",
                                         frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("E"))]),
                                         dependencies: ["E"]),
                TestStandardTarget("E", type: .commonObject, buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
            ])
        let workspace = TestWorkspace("aWorkspace", projects: [testProject, testPackage])
        let tester = try await TaskConstructionTester(getCore(), workspace)

        // Warning emitted for the debug variant.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Release"), runDestination: .macOS, targetName: "Tool") { results in
            results.checkWarning(.contains("target 'Tool' is being built for variant 'debug' but its static-library dependency 'E' does not build that variant"))
            results.checkNoDiagnostics()
        }

        // Silenced by the opt-out flag.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Release", overrides: ["DISABLE_VARIANT_AWARE_STATIC_LINKING_FALLBACK_WARNING": "YES"]), runDestination: .macOS, targetName: "Tool") { results in
            results.checkNoDiagnostics()
        }
    }
}
