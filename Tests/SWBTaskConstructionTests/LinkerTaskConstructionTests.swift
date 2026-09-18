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
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct LinkerTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func linkerDriverSelection() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("c.c"),
                    TestFile("cxx.cpp"),
                    TestFile("s.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": try await swiftCompilerPath.str,
                    "SWIFT_VERSION": try await swiftVersion
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Library",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["c.c", "cxx.cpp", "s.swift"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [:]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("clang++"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["EXCLUDED_SOURCE_FILE_NAMES": "cxx.cpp"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("clang"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "swiftc"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("swiftc"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "auto"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("swiftc"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "auto", "EXCLUDED_SOURCE_FILE_NAMES": "s.swift"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("clang++"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "auto", "EXCLUDED_SOURCE_FILE_NAMES": "s.swift cxx.cpp"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("clang"), .anySequence])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func stdlibRpathSuppression() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("s.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": try await swiftCompilerPath.str,
                    "SWIFT_VERSION": try await swiftVersion,
                    "MACOSX_DEPLOYMENT_TARGET": "10.13",
                    "__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR": "NO",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Library",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["s.swift"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "swiftc"]), runDestination: .macOS) { results in
            // The deployment target is deliberately set to a deployment target older than the earliest officially supported one.
            results.checkWarning(.regex(#/^\[targetIntegrity\] The .+ deployment target '[^']+' is set to [\d\.x]+, but the range of supported deployment target versions is [\d\.x]+ to [\d\.x]+. \(in target '[^']+' from project '[^']+'\)$/#), failIfNotFound: false)
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineContains(["-no-stdlib-rpath"])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "clang"]), runDestination: .macOS) { results in
            // The deployment target is deliberately set to a deployment target older than the earliest officially supported one.
            results.checkWarning(.regex(#/^\[targetIntegrity\] The .+ deployment target '[^']+' is set to [\d\.x]+, but the range of supported deployment target versions is [\d\.x]+ to [\d\.x]+. \(in target '[^']+' from project '[^']+'\)$/#), failIfNotFound: false)
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineDoesNotContain("-no-stdlib-rpath")
            }
        }
    }

    @Test(
        .requireSDKs(.host),
        arguments: [
            (
                buildSettingNameUT: "ENABLE_ADDRESS_SANITIZER",
                linkerDriverUT: "clang",
                expectedArgument: "-fsanitize=address",
            ),
            (
                buildSettingNameUT: "ENABLE_ADDRESS_SANITIZER",
                linkerDriverUT: "swiftc",
                expectedArgument: "-sanitize=address",
            ),
            (
                buildSettingNameUT: "ENABLE_THREAD_SANITIZER",
                linkerDriverUT: "clang",
                expectedArgument: "-fsanitize=thread",
            ),
            (
                buildSettingNameUT: "ENABLE_THREAD_SANITIZER",
                linkerDriverUT: "swiftc",
                expectedArgument: "-sanitize=thread",
            ),
            (
                buildSettingNameUT: "ENABLE_LIBFUZZER",
                linkerDriverUT: "clang",
                expectedArgument: "-fsanitize=fuzzer",
            ),
            (
                buildSettingNameUT: "ENABLE_LIBFUZZER",
                linkerDriverUT: "swiftc",
                expectedArgument: "-sanitize=fuzzer",
            ),
        ],
    )
    func ldSanitizerArgumentsAppearsOnCommandLine(
        buildSettingNameUT: String,
        linkerDriverUT: String,
        expectedArgument: String,
    ) async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("c.c"),
                    TestFile("cxx.cpp"),
                    TestFile("s.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": try await swiftCompilerPath.str,
                    "SWIFT_VERSION": try await swiftVersion
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Library",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["c.c", "cxx.cpp", "s.swift"]),
                    ],
                ),
            ],
        )
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(
            BuildParameters(
                configuration: "Debug",
                overrides: [
                    "LINKER_DRIVER": linkerDriverUT,
                    buildSettingNameUT: "YES",
                ],
            ),
            runDestination: .host,
        ) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineContains([expectedArgument])
            }
        }

    }

    @Test(.requireSDKs(.host))
    func dynamicLibraryWithNoSourcesButStaticLibrariesInFrameworksPhase_Xcode() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("source.c"),
                    TestFile("libStaticLib.a"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "LIBTOOL": libtoolPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "DynamicLib",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase(["libStaticLib.a"]),
                    ],
                    dependencies: ["StaticLib"]
                ),
                TestStandardTarget(
                    "StaticLib",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["source.c"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [:]), runDestination: .host) { results in
            results.checkWarning("Target 'DynamicLib' contains a non-empty linked libraries phase, but it contains no object files, and no sources are being compiled. For compatibility, no binary will be produced. Remove unused entries in the linked libraries phase to suppress this warning. (in target 'DynamicLib' from project 'aProject')")
            results.checkNoDiagnostics()
            results.checkTarget("DynamicLib") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("Ld"))
            }
        }
    }

    @Test(.requireSDKs(.host))
    func dynamicLibraryWithNoSourcesButStaticLibrariesInFrameworksPhase_Package() async throws {
        let testProject = try await TestPackageProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("source.c"),
                    TestFile("libStaticLib.a"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "LIBTOOL": libtoolPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "DynamicLib",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase(["libStaticLib.a"]),
                    ],
                    dependencies: ["StaticLib"]
                ),
                TestStandardTarget(
                    "StaticLib",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["source.c"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [:]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTarget("DynamicLib") { target in
                results.checkTaskExists(.matchTarget(target), .matchRuleType("Ld"))
            }
        }
    }

    @Test(.requireSDKs(.host), .requireHostOS(.linux))
    func linuxSoname() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("c.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Library",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "EXECUTABLE_PREFIX": "lib",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["c.c"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [:]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineContains(["-Xlinker", "-soname", "-Xlinker", "libLibrary.so"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func toolchainBackDeployRPathsPredatingOSSupport() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("s.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": try await swiftCompilerPath.str,
                    "SWIFT_VERSION": try await swiftVersion,
                    "MACOSX_DEPLOYMENT_TARGET": "10.13",
                    "__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR": "NO",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["s.swift"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let tester = try TaskConstructionTester(core, testProject)

        // With both settings enabled and a pre-concurrency deployment target, both toolchain rpaths should appear.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [
            "ADD_TOOLCHAIN_CONCURRENCY_BACK_DEPLOY_RPATH": "YES",
            "ADD_TOOLCHAIN_SPAN_BACK_DEPLOY_RPATH": "YES",
        ]), runDestination: .macOS) { results in
            // The deployment target is deliberately set to a deployment target older than the earliest officially supported one.
            results.checkWarning(.regex(#/^\[targetIntegrity\] The .+ deployment target '[^']+' is set to [\d\.x]+, but the range of supported deployment target versions is [\d\.x]+ to [\d\.x]+. \(in target '[^']+' from project '[^']+'\)$/#), failIfNotFound: false)
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"])
                task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "\(defaultToolchain.path.str)/usr/lib/swift-5.5/macosx"])
                task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "\(defaultToolchain.path.str)/usr/lib/swift-6.2/macosx"])
            }
        }

        // With only concurrency enabled, the toolchain rpath should still appear.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [
            "ADD_TOOLCHAIN_CONCURRENCY_BACK_DEPLOY_RPATH": "YES",
            "ADD_TOOLCHAIN_SPAN_BACK_DEPLOY_RPATH": "NO",
        ]), runDestination: .macOS) { results in
            // The deployment target is deliberately set to a deployment target older than the earliest officially supported one.
            results.checkWarning(.regex(#/^\[targetIntegrity\] The .+ deployment target '[^']+' is set to [\d\.x]+, but the range of supported deployment target versions is [\d\.x]+ to [\d\.x]+. \(in target '[^']+' from project '[^']+'\)$/#), failIfNotFound: false)
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"])
                task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "\(defaultToolchain.path.str)/usr/lib/swift-5.5/macosx"])
            }
        }

        // With only span enabled, the toolchain rpath should still appear.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [
            "ADD_TOOLCHAIN_CONCURRENCY_BACK_DEPLOY_RPATH": "NO",
            "ADD_TOOLCHAIN_SPAN_BACK_DEPLOY_RPATH": "YES",
        ]), runDestination: .macOS) { results in
            // The deployment target is deliberately set to a deployment target older than the earliest officially supported one.
            results.checkWarning(.regex(#/^\[targetIntegrity\] The .+ deployment target '[^']+' is set to [\d\.x]+, but the range of supported deployment target versions is [\d\.x]+ to [\d\.x]+. \(in target '[^']+' from project '[^']+'\)$/#), failIfNotFound: false)
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"])
                task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "\(defaultToolchain.path.str)/usr/lib/swift-6.2/macosx"])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [
            "ADD_TOOLCHAIN_CONCURRENCY_BACK_DEPLOY_RPATH": "NO",
            "ADD_TOOLCHAIN_SPAN_BACK_DEPLOY_RPATH": "NO",
        ]), runDestination: .macOS) { results in
            // The deployment target is deliberately set to a deployment target older than the earliest officially supported one.
            results.checkWarning(.regex(#/^\[targetIntegrity\] The .+ deployment target '[^']+' is set to [\d\.x]+, but the range of supported deployment target versions is [\d\.x]+ to [\d\.x]+. \(in target '[^']+' from project '[^']+'\)$/#), failIfNotFound: false)
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineContainsUninterrupted(["-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"])
                task.checkCommandLineDoesNotContain("\(defaultToolchain.path.str)/usr/lib/swift-6.2/macosx")
                task.checkCommandLineDoesNotContain("\(defaultToolchain.path.str)/usr/lib/swift-5.5/macosx")
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireXcode26())
    func toolchainBackDeployRPathsSkippedWhenOSSupportPresent() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("s.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": try await swiftCompilerPath.str,
                    "SWIFT_VERSION": try await swiftVersion,
                    "MACOSX_DEPLOYMENT_TARGET": "26.0",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Library",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["s.swift"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [
            "ADD_TOOLCHAIN_CONCURRENCY_BACK_DEPLOY_RPATH": "YES",
            "ADD_TOOLCHAIN_SPAN_BACK_DEPLOY_RPATH": "YES",
        ]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineDoesNotContain("\(defaultToolchain.path.str)/usr/lib/swift-5.5/macosx")
                task.checkCommandLineDoesNotContain("\(defaultToolchain.path.str)/usr/lib/swift-6.2/macosx")
            }
        }
    }

    @Test(.requireSDKs(.host))
    func toolchainBackDeployRPathsIgnoredOnNonApplePlatforms() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("s.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": try await swiftCompilerPath.str,
                    "SWIFT_VERSION": try await swiftVersion,
                    "MACOSX_DEPLOYMENT_TARGET": "10.13",
                    "__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR": "NO",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["s.swift"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let defaultToolchain = try #require(core.toolchainRegistry.defaultToolchain)
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [
            "ADD_TOOLCHAIN_CONCURRENCY_BACK_DEPLOY_RPATH": "YES",
            "ADD_TOOLCHAIN_SPAN_BACK_DEPLOY_RPATH": "YES",
        ]), runDestination: .host) { results in
            // The deployment target is deliberately set to a deployment target older than the earliest officially supported one.
            results.checkWarning(.regex(#/^\[targetIntegrity\] The .+ deployment target '[^']+' is set to [\d\.x]+, but the range of supported deployment target versions is [\d\.x]+ to [\d\.x]+. \(in target '[^']+' from project '[^']+'\)$/#), failIfNotFound: false)
            results.checkNoDiagnostics()

            results.checkTask(.matchRuleType("Ld")) { task in
                switch core.hostOperatingSystem {
                case .macOS:
                    task.checkCommandLineContains(["\(defaultToolchain.path.str)/usr/lib/swift-5.5/macosx"])
                    task.checkCommandLineContains(["\(defaultToolchain.path.str)/usr/lib/swift-6.2/macosx"])
                default:
                    let args = task.commandLine.map(\.asString)
                    #expect(!args.contains(where: { $0.hasPrefix("\(defaultToolchain.path.str)/usr/lib/swift-5.5") }))
                    #expect(!args.contains(where: { $0.hasPrefix("\(defaultToolchain.path.str)/usr/lib/swift-6.2") }))
                }
            }
        }
    }

    /// With `ENABLE_VARIANT_AWARE_STATIC_LINKING` and a non-normal consumer variant, the linker
    /// command line should include `-image_suffix _<variant>` so LD's path search prefers a
    /// variant-suffixed sibling archive (e.g. `libProducer_debug.a`) over the un-varianted one.
    /// Without the setting, `-image_suffix` should not appear on any variant's link line.
    @Test(.requireSDKs(.macOS))
    func staticArchiveVariantAwareLinking() async throws {
        let libtoolPath = try await self.libtoolPath
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("SomeFiles", children: [TestFile("main.c"), TestFile("producer.c")]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "PRODUCT_NAME": "$(TARGET_NAME)",
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

        await tester.checkBuild(BuildParameters(configuration: "Release", overrides: ["ENABLE_VARIANT_AWARE_STATIC_LINKING": "YES"]), runDestination: .macOS, targetName: "Consumer") { results in
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

        await tester.checkBuild(BuildParameters(configuration: "Release"), runDestination: .macOS, targetName: "Consumer") { results in
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
    /// module: when the producer builds the same variants, each variant's link file list references
    /// the variant-suffixed `.o`; when the producer is missing the variant, a warning is emitted
    /// (silenceable via `DISABLE_VARIANT_AWARE_STATIC_LINKING_FALLBACK_WARNING`).
    @Test(.requireSDKs(.macOS))
    func objectFileVariantAwareLinking() async throws {
        let libtoolPath = try await self.libtoolPath

        func makeWorkspace(producerVariants: String) async throws -> TestWorkspace {
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup("SomeFiles", children: [TestFile("main.c")]),
                buildConfigurations: [
                    TestBuildConfiguration("Release", buildSettings: [
                        "LIBTOOL": libtoolPath.str,
                        "PRODUCT_NAME": "$(TARGET_NAME)",
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
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "BUILD_VARIANTS": producerVariants,
                    ]),
                ],
                targets: [
                    TestPackageProductTarget("SomePackageProduct",
                                             frameworksBuildPhase: TestFrameworksBuildPhase([TestBuildFile(.target("E"))]),
                                             dependencies: ["E"]),
                    TestStandardTarget("E", type: .commonObject, buildPhases: [TestSourcesBuildPhase(["foo.c"])]),
                ])
            return TestWorkspace("aWorkspace", projects: [testProject, testPackage])
        }

        // Producer builds both variants: each variant's link file list picks the suffixed `.o`.
        let matched = try await TaskConstructionTester(getCore(), try await makeWorkspace(producerVariants: "normal debug"))
        await matched.checkBuild(BuildParameters(configuration: "Release"), runDestination: .macOS, targetName: "Tool") { results in
            results.checkNoDiagnostics()
            results.checkTarget("Tool") { target in
                let arch = results.runDestinationTargetArchitecture
                for variant in ["normal", "debug"] {
                    let suffix = variant == "normal" ? "" : "_\(variant)"
                    let listPath = "/tmp/aWorkspace/aProject/build/aProject.build/Release/Tool.build/Objects-\(variant)/\(arch)/Tool.LinkFileList"
                    results.checkWriteAuxiliaryFileTask(.matchTarget(target), .matchRule(["WriteAuxiliaryFile", listPath])) { _, contents in
                        #expect(contents == "/tmp/aWorkspace/aProject/build/aProject.build/Release/Tool.build/Objects-\(variant)/\(arch)/main.o\n/tmp/aWorkspace/Package/build/Release/E\(suffix).o\n")
                    }
                }
            }
        }

        // Producer misses the debug variant: warning emitted, silenced by the opt-out flag.
        let missing = try await TaskConstructionTester(getCore(), try await makeWorkspace(producerVariants: "normal"))
        await missing.checkBuild(BuildParameters(configuration: "Release"), runDestination: .macOS, targetName: "Tool") { results in
            results.checkWarning(.contains("target 'Tool' is being built for variant 'debug' but its static-library dependency 'E' does not build that variant"))
            results.checkNoDiagnostics()
        }
        await missing.checkBuild(BuildParameters(configuration: "Release", overrides: ["DISABLE_VARIANT_AWARE_STATIC_LINKING_FALLBACK_WARNING": "YES"]), runDestination: .macOS, targetName: "Tool") { results in
            results.checkNoDiagnostics()
        }
    }
}
