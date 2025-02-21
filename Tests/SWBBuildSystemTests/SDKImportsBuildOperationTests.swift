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
import SWBCore
import struct SWBProtocol.RunDestinationInfo
import SWBTestSupport
@_spi(Testing) import SWBUtil
import Testing

@Suite
fileprivate struct SDKImportsBuildOperationTests: CoreBasedTests {
    func makeTester(ldFlags: String = "", tmpDir: Path) async throws -> BuildOperationTester {
        let testProject = try await TestProject(
            "TestProject",
            sourceRoot: tmpDir,
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("main.swift"),
                    TestFile("static.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "ARCHS": "$(ARCHS_STANDARD)",
                    "CODE_SIGNING_ALLOWED": "YES",
                    "CODE_SIGN_IDENTITY": "-",
                    "CODE_SIGN_ENTITLEMENTS": "Entitlements.plist",
                    "DEFINES_MODULE": "YES",
                    "ENABLE_SDK_IMPORTS": "YES",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SDKROOT": "$(HOST_PLATFORM)",
                    "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                    "SWIFT_VERSION": swiftVersion,
                    "OTHER_LDFLAGS": ldFlags,
                ])
            ],
            targets: [
                TestStandardTarget(
                    "tool",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.swift"]),
                        TestFrameworksBuildPhase([
                            TestBuildFile(.target("staticlib")),
                        ])
                    ],
                    dependencies: [
                        "staticlib",
                    ]
                ),
                TestStandardTarget(
                    "staticlib",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["static.swift"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try await BuildOperationTester(core, testProject, simulated: false)

        let projectDir = tester.workspace.projects[0].sourceRoot

        try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
            stream <<< "import staticlib\n"
            stream <<< "staticLib()\n"
            stream <<< "print(\"Hello world\")\n"
        }

        try await tester.fs.writeFileContents(projectDir.join("static.swift")) { stream in
            stream <<< "import Foundation\n"
            stream <<< "public func staticLib() {\n"
            stream <<< "_ = UserDefaults.standard\n"
            stream <<< "}\n"
        }

        try await tester.fs.writePlist(projectDir.join("Entitlements.plist"), .plDict([:]))

        return tester
    }

    @Test(.requireSDKs(.macOS), .requireSDKImports())
    func basic() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let tester = try await makeTester(tmpDir: tmpDir)
            let provisioningInputs = [
                "staticlib": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:])),
                "tool": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:]))
            ]

            let destination: RunDestinationInfo = .host
            try await tester.checkBuild(runDestination: destination, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoErrors()

                let derivedData = tmpDir.join("build/Debug")
                let appResources = derivedData.join("tool.app/Contents/Resources")

                let sdkImportsPath = appResources.join("tool_normal_x86_64_sdk_imports.json")
                let sdkImportsData = try Data(contentsOf: .init(filePath: sdkImportsPath.str))

                struct SDKImports: Codable {
                    let inputs: [Input]

                    struct Input: Codable {
                        let path: String
                    }
                }

                let sdkImports = try JSONDecoder().decode(SDKImports.self, from: sdkImportsData)
                #expect(sdkImports.inputs.map { $0.path }.sorted() == ["libstaticlib.a", "main.o", "objc-file", "stubs-got-file"])
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func plistStamping() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("lib.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": "$(ARCHS_STANDARD)",
                        "CODE_SIGNING_ALLOWED": "NO",
                        "DEFINES_MODULE": "YES",
                        "ENABLE_SDK_IMPORTS": "YES",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "$(HOST_PLATFORM)",
                        "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                        "SWIFT_VERSION": swiftVersion,
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "lib",
                        type: .staticLibrary,
                        buildPhases: [
                            TestSourcesBuildPhase(["lib.swift"]),
                        ], dependencies: [
                            "resources",
                        ]
                    ),
                    TestStandardTarget(
                        "resources",
                        type: .bundle
                    )
                ])
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot
            try await tester.fs.writeFileContents(projectDir.join("lib.swift")) { _ in }

            let destination: RunDestinationInfo = .host
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()

                let derivedData = tmpDir.join("build/Debug")
                let infoPlistPath = derivedData.join("resources.bundle/Contents/Info.plist")
                let infoPlistData = try Data(contentsOf: .init(filePath: infoPlistPath.str))
                let infoPlist = try PropertyListDecoder().decode(PropertyListItem.self, from: infoPlistData)

                guard case .plDict(let infoPlistDict) = infoPlist.propertyListItem else {
                    Issue.record("invalid info plist: \(infoPlist)")
                    return
                }
                guard case .plArray(let libs) = infoPlistDict["DTBundleClientLibraries"]?.propertyListItem else {
                    Issue.record("invalid info plist contents: \(infoPlistDict)")
                    return
                }

                #expect(libs == ["liblib.a"])
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireSDKImports())
    func disabledWhenLdClassicIsInUse() async throws {
        for flags in ["-Xlinker -ld_classic", "-Wl,-ld_classic"] {
            try await withTemporaryDirectory { (tmpDir: Path) in
                let tester = try await makeTester(ldFlags: flags, tmpDir: tmpDir)
                let provisioningInputs = [
                    "staticlib": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:])),
                    "tool": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:]))
                ]

                let destination: RunDestinationInfo = .host
                try await tester.checkBuild(runDestination: destination, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                    results.checkNoErrors()
                    results.checkWarning(.prefix("-ld_classic is deprecated"))

                    let derivedData = tmpDir.join("build/Debug")
                    let appResources = derivedData.join("tool.app/Contents/Resources")

                    let sdkImportsPath = appResources.join("tool_normal_x86_64_sdk_imports.json")
                    #expect(tester.fs.exists(sdkImportsPath) == false)
                }
            }
        }
    }
}

