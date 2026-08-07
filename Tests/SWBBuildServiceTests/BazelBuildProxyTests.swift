//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing
@testable import SWBBuildService
import SWBProtocol
import SWBUtil

@Suite
struct BazelBuildProxyTests {
    @Test
    func locatesGeneratedManifestFromXcodeProjectContainer() {
        let expected = "/tmp/App.xcodeproj/rules_xcodeproj/bazel/build_proxy_manifest.json"
        let request = BuildRequestMessagePayload(
            parameters: .init(
                action: "build",
                configuration: "Debug",
                activeRunDestination: nil,
                activeArchitecture: nil,
                arenaInfo: nil,
                overrides: .init(
                    synthesized: [:],
                    commandLine: [:],
                    commandLineConfigPath: nil,
                    commandLineConfig: [:],
                    environmentConfigPath: nil,
                    environmentConfig: [:],
                    toolchainOverride: nil
                )
            ),
            configuredTargets: [],
            dependencyScope: .workspace,
            continueBuildingAfterErrors: false,
            hideShellScriptEnvironment: true,
            useParallelTargets: true,
            useImplicitDependencies: true,
            useDryRun: false,
            showNonLoggedProgress: true,
            recordBuildBacktraces: nil,
            generatePrecompiledModulesReport: nil,
            buildPlanDiagnosticsDirPath: nil,
            buildCommand: .build(style: .buildOnly, skipDependencies: false),
            schemeCommand: nil,
            containerPath: Path("/tmp/App.xcodeproj"),
            buildDescriptionID: nil,
            qos: nil,
            schedulerLaneWidthOverride: nil,
            jsonRepresentation: nil
        )

        #expect(
            BazelBuildProxyManifestLocator.resolve(
                request: request,
                environment: [:],
                fileExists: { $0 == expected }
            ) == expected)
    }

    @Test
    func decodesRulesXcodeprojManifestContract() throws {
        let data = Data(#"{"capabilities":{"actions":["build","clean","indexbuild","preview"]},"ignoredXcodeTargetGUIDs":["FF0100000000000000000001"],"invocation":{"adapterPath":"rules_xcodeproj/bazel/generate_bazel_dependencies.sh","bazelPath":"/usr/local/bin/bazel","bazelrcPath":"rules_xcodeproj/bazel/xcodeproj.bazelrc","environmentKeys":["BAZEL_CONFIG","SRCROOT"],"generatorLabel":"//app:AppProject","receiptSchemaVersion":1},"project":{"containerName":"App.xcodeproj","identity":"//app:AppProject"},"schemaVersion":2,"targets":[]}"#.utf8)
        let manifest = try JSONDecoder().decode(BazelBuildProxyManifest.self, from: data)

        #expect(manifest.schemaVersion == 2)
        #expect(manifest.invocation.adapterPath == "rules_xcodeproj/bazel/generate_bazel_dependencies.sh")
        #expect(manifest.invocation.generatorLabel == "//app:AppProject")
        #expect(manifest.invocation.bazelrcPath == "rules_xcodeproj/bazel/xcodeproj.bazelrc")
    }

    @Test
    func resolvesMappedTargetWhileIgnoringBazelDependencies() throws {
        let data = Data(#"{"capabilities":{"actions":["build","clean","indexbuild","preview"]},"ignoredXcodeTargetGUIDs":["FF0100000000000000000001"],"invocation":{"adapterPath":"rules_xcodeproj/bazel/generate_bazel_dependencies.sh","bazelPath":"/usr/local/bin/bazel","bazelrcPath":"rules_xcodeproj/bazel/xcodeproj.bazelrc","environmentKeys":["BAZEL_CONFIG","SRCROOT"],"generatorLabel":"//app:AppProject","receiptSchemaVersion":1},"project":{"containerName":"App.xcodeproj","identity":"//app:AppProject"},"schemaVersion":2,"targets":[{"action":"build","bazelLabel":"@@//app:app","configuration":"Debug","indexOutputGroups":["bc @@//app:app sim-arm64","bi @@//app:app sim-arm64"],"outputGroup":"bp @@//app:app sim-arm64","previewOutputGroups":["bc @@//app:app sim-arm64","bp @@//app:app sim-arm64","bl @@//app:app sim-arm64"],"product":{"basename":"App.app","materialization":"copy_tree","name":"App","path":"bazel-out/App.app","type":"com.apple.product-type.application"},"targetID":"@@//app:app sim-arm64","variant":{"arch":"arm64","minimumOSVersion":"15.0","platform":"iphonesimulator"},"xcodeTargetGUID":"0000AAAAAAAA000000000001"}]}"#.utf8)
        let manifest = try JSONDecoder().decode(BazelBuildProxyManifest.self, from: data)
        let parameters = BuildParametersMessagePayload(
            action: "build",
            configuration: "Debug",
            activeRunDestination: nil,
            activeArchitecture: "undefined_arch",
            arenaInfo: nil,
            overrides: .init(
                synthesized: [:],
                commandLine: [:],
                commandLineConfigPath: nil,
                commandLineConfig: [:],
                environmentConfigPath: nil,
                environmentConfig: [:],
                toolchainOverride: nil
            )
        )
        let request = BuildRequestMessagePayload(
            parameters: parameters,
            configuredTargets: [
                .init(guid: "FF0100000000000000000001", parameters: parameters),
                .init(guid: "0000AAAAAAAA000000000001", parameters: parameters),
            ],
            dependencyScope: .workspace,
            continueBuildingAfterErrors: false,
            hideShellScriptEnvironment: true,
            useParallelTargets: true,
            useImplicitDependencies: true,
            useDryRun: false,
            showNonLoggedProgress: true,
            recordBuildBacktraces: nil,
            generatePrecompiledModulesReport: nil,
            buildPlanDiagnosticsDirPath: nil,
            buildCommand: .build(style: .buildOnly, skipDependencies: false),
            schemeCommand: nil,
            containerPath: Path("/tmp/App.xcodeproj"),
            buildDescriptionID: nil,
            qos: nil,
            schedulerLaneWidthOverride: nil,
            jsonRepresentation: nil
        )

        #expect(
            try manifest.resolve(
                request,
                selectors: [
                    .init(
                        bazelLabel: nil,
                        serviceTargetGUID: "hashed-integration-guid",
                        targetID: nil,
                        targetName: "BazelDependencies"
                    ),
                    .init(
                        bazelLabel: "@@//app:app",
                        serviceTargetGUID: "hashed-service-guid",
                        targetID: "@@//app:app sim-arm64",
                        targetName: "App"
                    ),
                ])?.map(\.xcodeTargetGUID) == ["0000AAAAAAAA000000000001"])

        let indexParameters = BuildParametersMessagePayload(
            action: "indexbuild",
            configuration: "Debug",
            activeRunDestination: nil,
            activeArchitecture: "undefined_arch",
            arenaInfo: nil,
            overrides: parameters.overrides
        )
        let indexRequest = BuildRequestMessagePayload(
            parameters: indexParameters,
            configuredTargets: [.init(guid: "0000AAAAAAAA000000000001", parameters: indexParameters)],
            dependencyScope: .workspace,
            continueBuildingAfterErrors: false,
            hideShellScriptEnvironment: true,
            useParallelTargets: true,
            useImplicitDependencies: true,
            useDryRun: false,
            showNonLoggedProgress: true,
            recordBuildBacktraces: nil,
            generatePrecompiledModulesReport: nil,
            buildPlanDiagnosticsDirPath: nil,
            buildCommand: .build(style: .buildOnly, skipDependencies: false),
            schemeCommand: nil,
            containerPath: Path("/tmp/App.xcodeproj"),
            buildDescriptionID: nil,
            qos: nil,
            schedulerLaneWidthOverride: nil,
            jsonRepresentation: nil
        )
        #expect(
            try manifest.resolve(
                indexRequest,
                selectors: [
                    .init(
                        bazelLabel: "@@//app:app",
                        serviceTargetGUID: "hashed-service-guid",
                        targetID: "@@//app:app sim-arm64",
                        targetName: "App"
                    )
                ])?.map(\.xcodeTargetGUID) == ["0000AAAAAAAA000000000001"])
    }

    @Test
    func parsesAllowlistedBEPProgressAndCompletion() {
        #expect(
            BazelBuildProxyBEPParser.parse(line: #"{"progress":{"stderr":"[7 / 19] Compiling App.swift\n"}}"#) == [
                .progress(completed: 7, total: 19)
            ])
        #expect(
            BazelBuildProxyBEPParser.parse(line: #"{"buildMetrics":{"actionSummary":{"actionsExecuted":"19"}}}"#) == [
                .actionCount(19)
            ])
        #expect(
            BazelBuildProxyBEPParser.parse(line: #"{"finished":{"overallSuccess":true}}"#) == [
                .finished(succeeded: true)
            ])
        #expect(
            BazelBuildProxyBEPParser.parse(
                line: #"{"id":{"actionCompleted":{"configuration":"sim-arm64","label":"//app:app","primaryOutput":"bazel-out/App.app"}},"completed":{"success":true}}"#
            ) == [
                .actionCompleted(identity: "//app:app|bazel-out/App.app|sim-arm64")
            ])
    }

    @Test
    func ignoresEnvironmentBearingBEPEvents() {
        let line = #"{"id":{"unstructuredCommandLine":{}},"unstructuredCommandLine":{"args":["--client_env=SECRET_TOKEN=do-not-retain"]}}"#
        #expect(BazelBuildProxyBEPParser.parse(line: line).isEmpty)
        #expect(
            BazelActiveBuildOperation.sanitizedBEPEvent([
                "id": ["unstructuredCommandLine": [:]],
                "unstructuredCommandLine": ["args": ["--client_env=SECRET_TOKEN=do-not-retain"]],
            ]) == nil
        )
        let sanitizedProgress = BazelActiveBuildOperation.sanitizedBEPEvent([
            "progress": ["stderr": "SECRET_TOKEN=do-not-retain"]
        ])
        #expect(sanitizedProgress?["progress"] != nil)
        #expect(!String(describing: sanitizedProgress).contains("SECRET_TOKEN"))
    }

    @Test
    func parsesFileAndGlobalDiagnostics() {
        #expect(
            BazelBuildProxyDiagnosticParser.parse(line: "/tmp/App.swift:12:8: error: use of unresolved identifier 'broken'")
                == .init(
                    kind: .error,
                    path: "/tmp/App.swift",
                    line: 12,
                    column: 8,
                    message: "use of unresolved identifier 'broken'"
                ))
        #expect(
            BazelBuildProxyDiagnosticParser.parse(line: "WARNING: cache is unavailable")
                == .init(
                    kind: .warning,
                    path: nil,
                    line: nil,
                    column: nil,
                    message: "cache is unavailable"
                ))
    }

    @Test
    func sanitizedEnvironmentUsesAnAllowlist() {
        let environment = BazelBuildProxyInvocation.sanitizedEnvironment(
            [
                "PATH": "/bin",
                "HOME": "/tmp/home",
                "SECRET_TOKEN": "do-not-forward",
                "GITHUB_TOKEN": "do-not-forward",
            ],
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            workspace: "/tmp/workspace"
        )

        #expect(environment["PATH"] == "/bin")
        #expect(environment["HOME"] == "/tmp/home")
        #expect(environment["DEVELOPER_DIR"] == "/Applications/Xcode.app/Contents/Developer")
        #expect(environment["BUILD_WORKSPACE_DIRECTORY"] == "/tmp/workspace")
        #expect(environment["SECRET_TOKEN"] == nil)
        #expect(environment["GITHUB_TOKEN"] == nil)
    }

    @Test
    func invocationBuildsGeneratorOutputGroups() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-build-bazel-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let integrationDirectory = workspace.appendingPathComponent("rules_xcodeproj/bazel", isDirectory: true)
        try FileManager.default.createDirectory(at: integrationDirectory, withIntermediateDirectories: true)
        let adapter = integrationDirectory.appendingPathComponent("generate_bazel_dependencies.sh")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: adapter)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adapter.path)

        let invocation = try BazelBuildProxyInvocation(
            action: "build",
            adapterURL: adapter,
            environmentKeys: ["BAZEL_CONFIG", "BAZEL_REAL", "DEVELOPER_DIR"],
            evaluatedEnvironment: [
                "BAZEL_CONFIG": "rules_xcodeproj",
                "BAZEL_REAL": "/opt/homebrew/bin/bazelisk",
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
            ],
            integrationDirectory: integrationDirectory.path,
            isClean: false,
            labels: ["//lib:lib", "//app:app"],
            outputGroups: ["bp //app:app sim_arm64", "bp //lib:lib sim_arm64"],
            targetIDs: ["//lib:lib sim_arm64", "//app:app sim_arm64"],
            workspace: workspace.path
        )
        defer { invocation.removeTemporaryFiles() }

        #expect(invocation.executableURL == adapter)
        #expect(invocation.arguments.isEmpty)
        let requestDirectory = URL(
            fileURLWithPath: try #require(invocation.environment["SWIFTBUILD_BAZEL_PROXY_REQUEST_DIR"]),
            isDirectory: true
        )
        #expect(
            (try FileManager.default.attributesOfItem(atPath: requestDirectory.path)[.posixPermissions] as? NSNumber)?
                .intValue == 0o700
        )
        #expect(try String(contentsOf: requestDirectory.appendingPathComponent("labels"), encoding: .utf8) == "//app:app\n//lib:lib\n")
        #expect(
            (try FileManager.default.attributesOfItem(
                atPath: requestDirectory.appendingPathComponent("labels").path
            )[.posixPermissions] as? NSNumber)?.intValue == 0o600
        )
        #expect(try String(contentsOf: requestDirectory.appendingPathComponent("output_groups"), encoding: .utf8) == "bp //app:app sim_arm64\nbp //lib:lib sim_arm64\n")
        #expect(try String(contentsOf: requestDirectory.appendingPathComponent("target_ids"), encoding: .utf8) == "//app:app sim_arm64\n//lib:lib sim_arm64\n")
        #expect(invocation.environment["SWIFTBUILD_BAZEL_PROXY_BEP_PATH"] == invocation.eventFileURL.path)
        #expect(invocation.environment["SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT"] == invocation.receiptFileURL.path)
        #expect(invocation.environment["BAZEL_REAL"] == "/opt/homebrew/bin/bazelisk")
        #expect(!invocation.displayString.contains("SECRET_TOKEN"))
    }

    @Test
    func explicitBazelOverrideWinsAndMustBeExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-build-bazel-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("fake-bazel")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = try BazelBuildProxyInvocation.resolveBazelReal(
            configuredPath: "/usr/bin/false",
            manifestProxyPath: "/tmp/proxy-bazel",
            environment: [BazelBuildProxyEnvironment.bazelPath: executable.path]
        )
        #expect(resolved == executable.path)

        let nonExecutable = directory.appendingPathComponent("not-executable")
        try Data().write(to: nonExecutable)
        #expect(throws: (any Error).self) {
            try BazelBuildProxyInvocation.resolveBazelReal(
                configuredPath: nil,
                manifestProxyPath: "/tmp/proxy-bazel",
                environment: [BazelBuildProxyEnvironment.bazelPath: nonExecutable.path]
            )
        }
    }

    @Test
    func materializedTreeBecomesOwnerWritableWithoutLosingExistingModes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-build-materialization-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("resource")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("resource".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)

        try BazelActiveBuildOperation.makeTreeOwnerWritable(root, fileManager: .default)

        #expect(
            (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?
                .intValue == 0o700
        )
        #expect(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?
                .intValue == 0o600
        )
    }

    @Test
    func eventLedgerWritesAuditableLifecycleWithoutPayloads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-build-bazel-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let ledger = try BazelBuildProxyEventLedger(url: url, operationID: "42")
        ledger.record("preparationCompleted")
        ledger.record("operationStarted")
        ledger.record("targetStarted", entityID: "1")
        ledger.record("taskStarted", entityID: "1")
        ledger.record("progress", percentComplete: 25)
        ledger.record("diagnostic")
        ledger.record("taskEnded", entityID: "1")
        ledger.record("targetEnded", entityID: "1")
        ledger.record("operationEnded", status: "succeeded")

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        #expect(lines.count == 9)
        for (index, line) in lines.enumerated() {
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            #expect(object["sequence"] as? Int == index + 1)
            #expect(object["operationID"] as? String == "42")
            #expect(object["message"] == nil)
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
}
