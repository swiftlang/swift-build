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
import SWBTestSupport
import SwiftBuild
import SwiftBuildTestSupport
import SWBUtil
import Testing
import SWBCore

@Suite(.requireHostOS(.macOS))
fileprivate struct DeferredExecutionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS), .requireXcode16(), arguments: [true, false])
    func testDeferredExecution(isOn: Bool) async throws {
        try await withTemporaryDirectory { tmpDir in
            let fs: any FSProxy = localFS

            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("assets.xcassets"),
                        TestFile("foo.c"),
                        TestFile("foo.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "NO",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ONLY_ACTIVE_ARCH": "YES",
                        "SDKROOT": "macosx",
                        "SWIFT_VERSION": "5.0",
                        // Disable explicit modules here so we generate a consistent number of swift-frontend invocations that doesn't depend on the structure of the SDK
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "NO",
                        "_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES": "NO",

                        // TAPI can't read the "world's smallest dylib", so don't run that
                        "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",
                        // Since we don't get the linker's SDK imports output here, skip it.
                        "ENABLE_SDK_IMPORTS": "NO",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "Foo",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "assets.xcassets",
                                "foo.c",
                                "foo.swift",
                            ])
                        ]),
                ])

            let SRCROOT = tmpDir.str

            try await fs.writeAssetCatalog(Path(SRCROOT).join("assets.xcassets"))
            try fs.write(Path(SRCROOT).join("foo.c"), contents: "")
            try fs.write(Path(SRCROOT).join("foo.swift"), contents: "")

            let testWorkspace = TestWorkspace("aWorkspace", sourceRoot: tmpDir, projects: [testProject])

            try await withConfirmations(invert: !isOn) { assetCatalogExpectation, codeSignExpectation, clangExpectation, swiftExpectation, linkerExpectation, touchExpectation, derqExpectation in
                final class MockBuildOperationDelegate: SWBPlanningOperationDelegate {
                    let assetCatalogExpectation: Confirmation
                    let codeSignExpectation: Confirmation
                    let clangExpectation: Confirmation
                    let swiftExpectation: Confirmation
                    let linkerExpectation: Confirmation
                    let touchExpectation: Confirmation
                    let derqExpectation: Confirmation

                    init(assetCatalogExpectation: Confirmation, codeSignExpectation: Confirmation, clangExpectation: Confirmation, swiftExpectation: Confirmation, linkerExpectation: Confirmation, touchExpectation: Confirmation, derqExpectation: Confirmation) {
                        self.assetCatalogExpectation = assetCatalogExpectation
                        self.codeSignExpectation = codeSignExpectation
                        self.clangExpectation = clangExpectation
                        self.swiftExpectation = swiftExpectation
                        self.linkerExpectation = linkerExpectation
                        self.touchExpectation = touchExpectation
                        self.derqExpectation = derqExpectation
                    }

                    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
                        let signedEntitlements = provisioningSourceData.entitlementsDestination == "Signature"
                        ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
                        : [:]

                        let simulatedEntitlements = provisioningSourceData.entitlementsDestination == "__entitlements"
                        ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
                        : [:]

                        return SWBProvisioningTaskInputs(identityHash: "-", identityName: "-", profileName: nil, profileUUID: nil, profilePath: nil, designatedRequirements: nil, signedEntitlements: signedEntitlements.merging(provisioningSourceData.sdkRoot.contains("simulator") ? ["get-task-allow": .plBool(true)] : [:], uniquingKeysWith: { _, new  in new }), simulatedEntitlements: simulatedEntitlements, appIdentifierPrefix: nil, teamIdentifierPrefix: nil, isEnterpriseTeam: false, keychainPath: nil, errors: [], warnings: [])
                    }

                    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> SWBExternalToolResult {
                        switch commandLine.first.map(Path.init)?.basename {
                        case "actool" where commandLine.dropFirst() == ["--version", "--output-format", "xml1"]:
                            break
                        case "actool":
                            assetCatalogExpectation.confirm()
                        case "codesign":
                            defer { codeSignExpectation.confirm() }
                            return .result(status: .exit(0), stdout: Data(), stderr: Data())
                        case "clang" where commandLine.dropFirst().first == "-v": // version info
                            break
                        case "clang" where !commandLine.contains("-c"): // linker-as-clang
                            defer { linkerExpectation.confirm() }

                            let outputBinary = try #require(commandLine.last.map(Path.init))
                            try localFS.write(outputBinary, contents: ByteString(smallestMachoBytes))

                            let dependencyInfo = try #require(commandLine.first(where: { $0.hasSuffix("/Foo_dependency_info.dat") }).map(Path.init))
                            try localFS.write(dependencyInfo, contents: ByteString(DependencyInfo(version: "1").asBytes()))

                            return .result(status: .exit(0), stdout: Data(), stderr: Data())
                        case "clang":
                            clangExpectation.confirm()
                        case "ld" where commandLine.dropFirst() == ["-version_details"]:
                            break
                        case "swiftc" where commandLine.dropFirst().first == "--version":
                            break
                        case "swift-frontend":
                            swiftExpectation.confirm()
                        case "touch":
                            defer { touchExpectation.confirm() }

                            let target = try #require(commandLine.last.map(Path.init))
                            try localFS.touch(target)

                            return .result(status: .exit(0), stdout: Data(), stderr: Data())
                        case "derq":
                            defer { derqExpectation.confirm() }
                            return .result(status: .exit(0), stdout: Data(), stderr: Data())
                        default:
                            Issue.record("Unexpected deferred execution request for command line: \(commandLine), workingDirectory: \(String(describing: workingDirectory)), environment: \(environment)")
                        }
                        return .deferred
                    }
                }

                try await withTester(testWorkspace, fs: fs, userPreferences: UserPreferences.defaultForTesting.with(allowsExternalToolExecution: isOn)) { tester in
                    try await tester.checkBuild(SWBBuildParameters(configuration: "Debug", activeRunDestination: .macOS, overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES", "CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-"]), delegate: MockBuildOperationDelegate(assetCatalogExpectation: assetCatalogExpectation, codeSignExpectation: codeSignExpectation, clangExpectation: clangExpectation, swiftExpectation: swiftExpectation, linkerExpectation: linkerExpectation, touchExpectation: touchExpectation, derqExpectation: derqExpectation)) { results in
                        results.checkNoFailedTasks()
                        results.checkNoDiagnostics()
                    }
                }
            }

            // Check for evidence that actool actually ran (it doesn't always create a .car file)
            #expect(fs.exists(Path(SRCROOT).join("build/aProject.build/Debug/Foo.build/assetcatalog_generated_info.plist")))

            let binaryContents = try fs.read(Path(SRCROOT).join("build/Debug/Foo.framework/Versions/A/Foo"))
            if isOn {
                // Assert that the execution actually was deferred
                #expect(binaryContents == ByteString(smallestMachoBytes))
            } else {
                // Assert that the execution was not deferred and there is a real Mach-O
                #expect(binaryContents != ByteString(smallestMachoBytes))
                #expect(binaryContents.bytes[0..<4] == [0xcf, 0xfa, 0xed, 0xfe])
            }
        }
    }
}

fileprivate func withConfirmations(invert: Bool, _ body: (_ assetCatalogExpectation: Confirmation, _ codeSignExpectation: Confirmation, _ clangExpectation: Confirmation, _ swiftExpectation: Confirmation, _ linkerExpectation: Confirmation, _ touchExpectation: Confirmation, _ derqExpectation: Confirmation) async throws -> Void) async rethrows {
    let expectedCount = invert ? 0 : 1
    let swiftExpectedCount = invert ? 0 : 2
    try await confirmation("Asset catalog deferred execution requested", expectedCount: expectedCount) { assetCatalogExpectation in
        try await confirmation("Codesign deferred execution requested", expectedCount: expectedCount) { codeSignExpectation in
            try await confirmation("Clang deferred execution requested", expectedCount: expectedCount) { clangExpectation in
                try await confirmation("Swift deferred execution requested", expectedCount: swiftExpectedCount) { swiftExpectation in
                    try await confirmation("Linker deferred execution requested", expectedCount: expectedCount) { linkerExpectation in
                        try await confirmation("Touch deferred execution requested", expectedCount: expectedCount) { touchExpectation in
                            try await confirmation("derq deferred execution requested", expectedCount: expectedCount) { derqExpectation in
                                try await body(assetCatalogExpectation, codeSignExpectation, clangExpectation, swiftExpectation, linkerExpectation, touchExpectation, derqExpectation)
                            }
                        }
                    }
                }
            }
        }
    }
}

fileprivate let smallestMachoBytes: [UInt8] = [
    0xcf, 0xfa, 0xed, 0xfe, // magic
    0x00, 0x00, 0x00, 0x00, // cputype
    0x00, 0x00, 0x00, 0x00, // cpusubtype
    0x06, 0x00, 0x00, 0x00, // filetype
    0x00, 0x00, 0x00, 0x00, // ncmds
    0x00, 0x00, 0x00, 0x00, // sizeofcmds
    0x00, 0x00, 0x00, 0x00, // flags
]
