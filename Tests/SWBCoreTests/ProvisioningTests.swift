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
@_spi(Testing) import SWBCore
import SWBTestSupport
import SWBUtil
import SWBMacro
import SWBProtocol

private func createMockProject() throws -> SWBCore.Project {
    let projectPIF: [String: PropertyListItem] = [
        "guid": "some-project-guid",
        "path": "/tmp/SomeProject/aProject.xcodeproj",
        "projectDirectory": "/tmp/SomeOtherPlace",
        "targets": [],
        "groupTree": [
            "guid": "some-fileGroup-guid",
            "type": "group",
            "name": "SomeFiles",
            "sourceTree": "PROJECT_DIR",
            "path": "/tmp/SomeProject/SomeFiles",
        ],
        "buildConfigurations": [],
        "defaultConfigurationName": "Debug",
        "developmentRegion": "English",
    ]

    let pifLoader = PIFLoader(data: [], namespace: BuiltinMacros.namespace)
    return try Project(fromDictionary: projectPIF, signature: "mock", withPIFLoader: pifLoader)
}

private func setupMacroEvaluationScope(_ settings: [MacroDeclaration:String] = [MacroDeclaration:String](), tableSetupHandler: ((inout MacroValueAssignmentTable) -> Void)? = nil) -> MacroEvaluationScope{
    var table = MacroValueAssignmentTable(namespace: BuiltinMacros.namespace)

    for (key, value) in settings {
        switch key {
        case let key as StringMacroDeclaration:
            table.push(key, literal: value)
        case let key as PathMacroDeclaration:
            table.push(key, literal: value)
        default:
            fatalError("Unknown MarcoDeclaration \(key)")
        }
    }

    tableSetupHandler?(&table)

    return MacroEvaluationScope(table: table)
}


@Suite fileprivate struct ProvisioningTests: CoreBasedTests {
    @Test
    func computeBundleIdentifier() {
        let bundleIdentifierFromInfoPlist = BuiltinMacros.namespace.parseString("com.apple.$(PRODUCT_NAME)")
        let scope = setupMacroEvaluationScope([ BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER: "BundleID" ])
        var result = SWBCore.computeBundleIdentifier(from: scope, bundleIdentifierFromInfoPlist: bundleIdentifierFromInfoPlist)
        #expect(result == "BundleID")

        let scopeWithoutBundleID = setupMacroEvaluationScope([ BuiltinMacros.PRODUCT_NAME: "ProductName" ])
        result = SWBCore.computeBundleIdentifier(from: scopeWithoutBundleID, bundleIdentifierFromInfoPlist: bundleIdentifierFromInfoPlist)
        #expect(result == "com.apple.ProductName")
    }

    @Test
    func computeBundleIdentifierForTestRunner() {
        let bundleIdentifierFromInfoPlist = BuiltinMacros.namespace.parseString("com.apple.$(PRODUCT_NAME)")
        var table = MacroValueAssignmentTable(namespace: BuiltinMacros.namespace)
        table.push(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER, literal: "BundleID")
        table.push(BuiltinMacros.USES_XCTRUNNER, literal: true)
        let scope = MacroEvaluationScope(table: table)

        var result = SWBCore.computeBundleIdentifier(from: scope, bundleIdentifierFromInfoPlist: bundleIdentifierFromInfoPlist)
        #expect(result == "BundleID.xctrunner")

        let scopeWithoutBundleID = setupMacroEvaluationScope([ BuiltinMacros.PRODUCT_NAME: "ProductName" ])
        result = SWBCore.computeBundleIdentifier(from: scopeWithoutBundleID, bundleIdentifierFromInfoPlist: bundleIdentifierFromInfoPlist)
        #expect(result == "com.apple.ProductName")
    }

    @Test(.requireSDKs(.iOS))
    func computeSigningCertificateIdentifier() async throws {
        let scope = setupMacroEvaluationScope([ BuiltinMacros.CODE_SIGN_IDENTITY: "MyIdentity" ])
        do {
            if let platform = try await getCore().platformRegistry.lookup(identifier: "com.apple.platform.iphoneos") {
                let result = SWBCore.computeSigningCertificateIdentifier(from: scope, platform: platform)
                #expect(result == "MyIdentity")
            } else {
                Issue.record("couldn't lookup platform com.apple.platform.iphoneos")
            }
        }

        do {
            if let platform = try await getCore().platformRegistry.lookup(identifier: "com.apple.platform.iphonesimulator") {
                let result = SWBCore.computeSigningCertificateIdentifier(from: scope, platform: platform)
                #expect(result == "-") // always Ad-hoc sign for simulator even if CODE_SIGN_IDENTITY has been overridden
            } else {
                Issue.record("couldn't lookup platform com.apple.platform.iphonesimulator")
            }
        }
    }

    @Test(.requireSDKs(.iOS))
    func lookupEntitlementsFilePath() async throws {
        let core = try await getCore()
        let project = try createMockProject()
        guard let sdk = core.sdkRegistry.lookup("iphoneos") else {
            Issue.record("couldn't lookup SDK iphoneos")
            return
        }

        let fs = PseudoFS()
        let entitlementsPath = Path("/Entitlements/entitlements.plist")
        let sdkEntitlementsPath = sdk.path.join(Path("Entitlements.plist"))

        let scope = setupMacroEvaluationScope([ BuiltinMacros.CODE_SIGN_ENTITLEMENTS: entitlementsPath.str ])
        var result = SWBCore.lookupEntitlementsFilePath(from: scope, project: project, sdk: sdk, fs: fs)
        #expect(result == entitlementsPath) // FIXME: Path isn't checked for existence, is that correct?

        try fs.createDirectory(entitlementsPath.dirname, recursive: false)
        try fs.write(entitlementsPath, contents: "foo = bar")
        result = SWBCore.lookupEntitlementsFilePath(from: scope, project: project, sdk: sdk, fs: fs)
        #expect(result == entitlementsPath)

        let emptyScopeWithRequiredEntitlements = setupMacroEvaluationScope() {
            $0.push(BuiltinMacros.ENTITLEMENTS_REQUIRED, literal: true)
        }

        result = SWBCore.lookupEntitlementsFilePath(from: emptyScopeWithRequiredEntitlements, project: project, sdk: sdk, fs: fs)
        #expect(result == nil)

        try fs.createDirectory(sdkEntitlementsPath.dirname, recursive: true)
        try fs.write(sdkEntitlementsPath, contents: "foo = bar")
        result = SWBCore.lookupEntitlementsFilePath(from: emptyScopeWithRequiredEntitlements, project: project, sdk: sdk, fs: fs)
        #expect(result == sdkEntitlementsPath)

        let emptyScope = setupMacroEvaluationScope() {
            $0.push(BuiltinMacros.ENTITLEMENTS_REQUIRED, literal: false)
        }
        result = SWBCore.lookupEntitlementsFilePath(from: emptyScope, project: project, sdk: sdk, fs: fs)
        #expect(result == nil)
    }

    /// Tests overriding the provisioning style using the CODE_SIGN_STYLE build setting.
    @Test
    func provisioningStyle() async throws {
        let core = try await getCore()
        let testWorkspace = try TestWorkspace(
            "aWorkspace",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup(
                        "Sources",
                        children: [
                            TestFile("aClass.m"),
                        ]
                    ),
                    buildConfigurations:[
                        TestBuildConfiguration("Debug", buildSettings: ["PRODUCT_NAME": "$(TARGET_NAME)",])
                    ],
                    targets: [
                        TestStandardTarget(
                            "AppTarget",
                            type: .application,
                            buildConfigurations: [
                                TestBuildConfiguration("Debug"),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["aClass.m"]),
                            ],
                            provisioningSourceData: [
                                ProvisioningSourceData(configurationName: "Debug", provisioningStyle: .automatic, bundleIdentifierFromInfoPlist: "AppTarget"),
                            ]
                        )
                    ]
                )
            ]
        ).load(core)
        let workspaceContext = WorkspaceContext(core: core, workspace: testWorkspace, processExecutionCache: .sharedForTesting)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        guard let target = testWorkspace.projects.first?.targets.first as? SWBCore.StandardTarget else {
            Issue.record("unable to find target in test workspace")
            return
        }

        #expect(target.provisioningSourceData(for: "Debug")?.provisioningStyle == .automatic)

        do {
            let scope = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug", commandLineOverrides: ["CODE_SIGN_STYLE": "Automatic"]), target: target).globalScope
            #expect(target.provisioningSourceData(for: "Debug", scope: scope)?.provisioningStyle == .automatic)
        }

        do {
            let scope = buildRequestContext.getCachedSettings(BuildParameters(configuration: "Debug", commandLineOverrides: ["CODE_SIGN_STYLE": "Manual"]), target: target).globalScope
            #expect(target.provisioningSourceData(for: "Debug", scope: scope)?.provisioningStyle == .manual)
        }
    }
}
