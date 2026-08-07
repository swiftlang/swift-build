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
        let data = Data(#"{"capabilities":{"actions":["build"]},"ignoredXcodeTargetGUIDs":["FF0100000000000000000001"],"invocation":{"bazelPath":"/usr/local/bin/bazel","bazelrcPath":"rules_xcodeproj/bazel/xcodeproj.bazelrc","generatorLabel":"//app:AppProject"},"schemaVersion":1,"targets":[]}"#.utf8)
        let manifest = try JSONDecoder().decode(BazelBuildProxyManifest.self, from: data)

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.invocation.generatorLabel == "//app:AppProject")
        #expect(manifest.invocation.bazelrcPath == "rules_xcodeproj/bazel/xcodeproj.bazelrc")
    }

    @Test
    func resolvesMappedTargetWhileIgnoringBazelDependencies() throws {
        let data = Data(#"{"capabilities":{"actions":["build"]},"ignoredXcodeTargetGUIDs":["FF0100000000000000000001"],"invocation":{"bazelPath":"/usr/local/bin/bazel","bazelrcPath":"rules_xcodeproj/bazel/xcodeproj.bazelrc","generatorLabel":"//app:AppProject"},"schemaVersion":1,"targets":[{"action":"build","bazelLabel":"@@//app:app","configuration":"Debug","outputGroup":"bp @@//app:app sim-arm64","product":{"basename":"App.app","name":"App","path":"bazel-out/App.app","type":"com.apple.product-type.application"},"targetID":"@@//app:app sim-arm64","variant":{"arch":"arm64","minimumOSVersion":"15.0","platform":"iphonesimulator"},"xcodeTargetGUID":"0000AAAAAAAA000000000001"}]}"#.utf8)
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
    }

    @Test
    func ignoresEnvironmentBearingBEPEvents() {
        let line = #"{"id":{"unstructuredCommandLine":{}},"unstructuredCommandLine":{"args":["--client_env=SECRET_TOKEN=do-not-retain"]}}"#
        #expect(BazelBuildProxyBEPParser.parse(line: line).isEmpty)
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

        let invocation = try BazelBuildProxyInvocation(
            bazelPath: "/usr/bin/true",
            bazelRealPath: "/opt/homebrew/bin/bazelisk",
            bazelConfig: "rules_xcodeproj",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            generatorLabel: "//app:AppProject",
            integrationDirectory: nil,
            isClean: false,
            outputBase: nil,
            outputGroups: ["bp //app:app sim_arm64", "bp //lib:lib sim_arm64"],
            workspace: workspace.path,
            xcodeBuildVersion: "17F42"
        )
        defer { invocation.removeTemporaryFiles() }

        #expect(invocation.arguments.contains("//app:AppProject"))
        #expect(invocation.arguments.contains("--config=_rules_xcodeproj_build"))
        #expect(invocation.arguments.contains("--build_event_json_file=\(invocation.eventFileURL.path)"))
        #expect(invocation.arguments.contains("--output_groups=bp //app:app sim_arm64,bp //lib:lib sim_arm64"))
        #expect(invocation.environment["BAZEL_REAL"] == "/opt/homebrew/bin/bazelisk")
        #expect(!invocation.displayString.contains("SECRET_TOKEN"))
    }
}
