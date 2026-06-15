//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
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

@Suite
fileprivate struct TopLevelLinkingTargetResolverTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func resolvesTopLevelLinkingTargetsThroughReverseDependencies() async throws {
        let targets = try await configuredTargets([
            "App",
            "iOSFwk",
            "PackageLibProduct",
            "PackageLib",
            "PackageLibProduct2",
            "PackageLib2",
            "Common",
        ])

        let app = try #require(targets["App"])
        let iOSFwk = try #require(targets["iOSFwk"])
        let packageLibProduct = try #require(targets["PackageLibProduct"])
        let packageLib = try #require(targets["PackageLib"])
        let packageLibProduct2 = try #require(targets["PackageLibProduct2"])
        let packageLib2 = try #require(targets["PackageLib2"])
        let common = try #require(targets["Common"])

        let resolver = TopLevelLinkingTargetResolver(
            reverseDirectDependenciesByTarget: [
                common: [packageLib, packageLib2],
                packageLib: [packageLibProduct],
                packageLibProduct: [app, iOSFwk],
                packageLib2: [packageLibProduct2],
                packageLibProduct2: [app],
            ],
            topLevelLinkingTargets: [app, iOSFwk],
            isDynamicallyBuildingTarget: { _ in false }
        )

        #expect(resolver.resolve(for: common).map { $0.target.name }.sorted() == [
            "App",
            "iOSFwk",
        ])
    }

    @Test(.requireSDKs(.macOS))
    func stopsAtDynamicallyBuildingTarget() async throws {
        let targets = try await configuredTargets([
            "App",
            "PackageLibProduct",
            "PackageLib",
        ])

        let app = try #require(targets["App"])
        let packageLibProduct = try #require(targets["PackageLibProduct"])
        let packageLib = try #require(targets["PackageLib"])

        let resolver = TopLevelLinkingTargetResolver(
            reverseDirectDependenciesByTarget: [
                packageLib: [packageLibProduct],
                packageLibProduct: [app],
            ],
            topLevelLinkingTargets: [app],
            isDynamicallyBuildingTarget: {
                $0 == packageLibProduct
            }
        )

        #expect(resolver.resolve(for: packageLib).map { $0.target.name }.sorted() == [
            "PackageLibProduct",
        ])
    }

    @Test(.requireSDKs(.macOS))
    func doesNotCacheTruncatedCycleResult() async throws {
        let targets = try await configuredTargets([
            "A",
            "B",
            "D",
        ])

        let a = try #require(targets["A"])
        let b = try #require(targets["B"])
        let d = try #require(targets["D"])

        let resolver = TopLevelLinkingTargetResolver(
            reverseDirectDependenciesByTarget: [
                a: [b, d],
                b: [a],
            ],
            topLevelLinkingTargets: [d],
            isDynamicallyBuildingTarget: { _ in false }
        )

        #expect(resolver.resolve(for: a).map { $0.target.name }.sorted() == ["D"])
        #expect(resolver.resolve(for: b).map { $0.target.name }.sorted() == ["D"])
    }

    private func configuredTargets(
        _ targetNames: [String]
    ) async throws -> [String: ConfiguredTarget] {
        let core = try await getCore()
        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "aProject",
                    groupTree: TestGroup("SomeFiles"),
                    targets: targetNames.map {
                        TestStandardTarget($0, type: .framework)
                    }
                ),
            ]
        )
        .load(core)

        let parameters = BuildParameters(configuration: "Debug")
        let configuredTargets = workspace.projects[0].targets.map {
            ConfiguredTarget(parameters: parameters, target: $0)
        }

        return .init(
            uniqueKeysWithValues: configuredTargets.map {
                ($0.target.name, $0)
            }
        )
    }
}
