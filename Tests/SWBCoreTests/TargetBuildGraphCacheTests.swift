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
@_spi(Testing) import SWBCore
import SWBProtocol
import SWBTestSupport
@_spi(Testing) import SWBUtil
import Foundation

@Suite fileprivate struct TargetBuildGraphCacheTests: CoreBasedTests {

    /// Verify that two workspace signatures differing only in
    /// _subobjects= suffix produce DIFFERENT cache signatures.
    @Test(.requireSDKs(.host))
    func workspaceSignatureIncludesSubobjects() async throws {
        let core = try await getCore()

        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [TestFile("S1.c")]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug", buildSettings: [:]
                        ),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)

        let buildParameters = BuildParameters(
            configuration: "Debug"
        )
        let t1 = BuildRequest.BuildTargetInfo(
            parameters: buildParameters,
            target: try #require(workspace.target(named: "T1"))
        )
        let buildRequest = BuildRequest(
            parameters: buildParameters,
            buildTargets: [t1],
            dependencyScope: .workspace,
            continueBuildingAfterErrors: true,
            useParallelTargets: false,
            useImplicitDependencies: false,
            useDryRun: false
        )

        let identity = ObjectIdentifier(workspace)

        let sig1 = TargetBuildGraphCache.computeSignature(
            workspaceSignature:
                "hash_subobjects=guid1_guid2_guid3",
            workspaceIdentity: identity,
            buildRequest: buildRequest,
            purpose: .build
        )
        let sig2 = TargetBuildGraphCache.computeSignature(
            workspaceSignature:
                "hash_subobjects=guid4_guid5_guid6",
            workspaceIdentity: identity,
            buildRequest: buildRequest,
            purpose: .build
        )

        #expect(
            sig1 != sig2,
            "Different _subobjects= suffixes must produce "
                + "different signatures"
        )
    }

    /// Verify that identical workspace signatures produce the same
    /// cache signature.
    @Test(.requireSDKs(.host))
    func identicalWorkspaceSignaturesMatch() async throws {
        let core = try await getCore()

        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [TestFile("S1.c")]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug", buildSettings: [:]
                        ),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)

        let buildParameters = BuildParameters(
            configuration: "Debug"
        )
        let t1 = BuildRequest.BuildTargetInfo(
            parameters: buildParameters,
            target: try #require(workspace.target(named: "T1"))
        )
        let buildRequest = BuildRequest(
            parameters: buildParameters,
            buildTargets: [t1],
            dependencyScope: .workspace,
            continueBuildingAfterErrors: true,
            useParallelTargets: false,
            useImplicitDependencies: false,
            useDryRun: false
        )

        let identity = ObjectIdentifier(workspace)
        let sig1 = TargetBuildGraphCache.computeSignature(
            workspaceSignature:
                "hash_subobjects=guid1_guid2_guid3",
            workspaceIdentity: identity,
            buildRequest: buildRequest,
            purpose: .build
        )
        let sig2 = TargetBuildGraphCache.computeSignature(
            workspaceSignature:
                "hash_subobjects=guid1_guid2_guid3",
            workspaceIdentity: identity,
            buildRequest: buildRequest,
            purpose: .build
        )

        #expect(
            sig1 == sig2,
            "Identical signatures must produce identical "
                + "cache signatures"
        )
    }

    /// Verify that different purposes produce different signatures.
    @Test(.requireSDKs(.host))
    func differentPurposesProduceDifferentSignatures()
        async throws
    {
        let core = try await getCore()

        let workspace = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [TestFile("S1.c")]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug", buildSettings: [:]
                        ),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)

        let buildParameters = BuildParameters(
            configuration: "Debug"
        )
        let t1 = BuildRequest.BuildTargetInfo(
            parameters: buildParameters,
            target: try #require(workspace.target(named: "T1"))
        )
        let buildRequest = BuildRequest(
            parameters: buildParameters,
            buildTargets: [t1],
            dependencyScope: .workspace,
            continueBuildingAfterErrors: true,
            useParallelTargets: false,
            useImplicitDependencies: false,
            useDryRun: false
        )

        let identity = ObjectIdentifier(workspace)
        let sigBuild = TargetBuildGraphCache.computeSignature(
            workspaceSignature: "ws_sig_123",
            workspaceIdentity: identity,
            buildRequest: buildRequest,
            purpose: .build
        )
        let sigDepGraph = TargetBuildGraphCache.computeSignature(
            workspaceSignature: "ws_sig_123",
            workspaceIdentity: identity,
            buildRequest: buildRequest,
            purpose: .dependencyGraph
        )

        #expect(
            sigBuild != sigDepGraph,
            "Different purposes must produce different signatures"
        )
    }

    // MARK: - Content signature remap tests

    /// Verify that content signatures match across PIF re-transfers
    /// (different workspace objects with the same structure).
    @Test(.requireSDKs(.host))
    func contentSignatureMatchesAcrossWorkspaceObjects()
        async throws
    {
        let core = try await getCore()

        let testWS = TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [TestFile("S1.c")]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug", buildSettings: [:]
                        ),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        ),
                    ]
                ),
            ]
        )

        // Load twice — simulates PIF re-transfer.
        let ws1 = try testWS.load(core)
        let ws2 = try testWS.load(core)

        #expect(ObjectIdentifier(ws1) != ObjectIdentifier(ws2))

        let buildParameters = BuildParameters(
            configuration: "Debug"
        )
        let t1a = BuildRequest.BuildTargetInfo(
            parameters: buildParameters,
            target: try #require(ws1.targets(named: "T1").first)
        )
        let buildRequest1 = BuildRequest(
            parameters: buildParameters,
            buildTargets: [t1a],
            dependencyScope: .workspace,
            continueBuildingAfterErrors: true,
            useParallelTargets: false,
            useImplicitDependencies: false,
            useDryRun: false
        )

        let t1b = BuildRequest.BuildTargetInfo(
            parameters: buildParameters,
            target: try #require(ws2.targets(named: "T1").first)
        )
        let buildRequest2 = BuildRequest(
            parameters: buildParameters,
            buildTargets: [t1b],
            dependencyScope: .workspace,
            continueBuildingAfterErrors: true,
            useParallelTargets: false,
            useImplicitDependencies: false,
            useDryRun: false
        )

        // Full signatures must differ.
        let fullSig1 = TargetBuildGraphCache.computeSignature(
            workspaceSignature: ws1.signature,
            workspaceIdentity: ObjectIdentifier(ws1),
            buildRequest: buildRequest1,
            purpose: .build
        )
        let fullSig2 = TargetBuildGraphCache.computeSignature(
            workspaceSignature: ws2.signature,
            workspaceIdentity: ObjectIdentifier(ws2),
            buildRequest: buildRequest2,
            purpose: .build
        )
        #expect(
            fullSig1 != fullSig2,
            "Full signatures must differ across workspace objects"
        )

        // Content signatures must match.
        let contentSig1 =
            TargetBuildGraphCache.computeContentSignature(
                workspaceSignature: ws1.signature,
                buildRequest: buildRequest1,
                purpose: .build
            )
        let contentSig2 =
            TargetBuildGraphCache.computeContentSignature(
                workspaceSignature: ws2.signature,
                buildRequest: buildRequest2,
                purpose: .build
            )
        #expect(
            contentSig1 == contentSig2,
            "Content signatures must match for same PIF content"
        )
    }

    /// Verify that remapGraph produces a valid graph when the PIF is
    /// re-transferred with new Target objects.
    @Test(.requireSDKs(.host))
    func remapProducesValidGraphOnPIFRetransfer()
        async throws
    {
        let core = try await getCore()

        let testWS = TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [TestFile("S1.c")]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug", buildSettings: [:]
                        ),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        ),
                    ]
                ),
            ]
        )

        let ws1 = try testWS.load(core)
        let ws2 = try testWS.load(core)

        let t1ws1 = try #require(
            ws1.targets(named: "T1").first
        )
        let t1ws2 = try #require(
            ws2.targets(named: "T1").first
        )

        #expect(t1ws1 !== t1ws2)
        #expect(t1ws1.guid == t1ws2.guid)

        let buildParameters = BuildParameters(
            configuration: "Debug"
        )
        let ct1 = ConfiguredTarget(
            parameters: buildParameters, target: t1ws1
        )

        let cached = TargetBuildGraphCache.CachedDependencyGraph(
            contentSignature: 42,
            allTargets: OrderedSet([ct1]),
            targetDependencies: [:],
            targetsToLinkedReferencesToProducingTargets: [:],
            dynamicallyBuildingTargets: [],
            diagnostics: [],
            lastAccess: 0
        )

        let remapped = try #require(
            TargetBuildGraphCache.remapGraph(cached, to: ws2)
        )

        #expect(remapped.allTargets.count == 1)

        let remappedCT = try #require(
            remapped.allTargets.first
        )
        #expect(remappedCT.target === t1ws2)
        #expect(remappedCT.target !== t1ws1)
    }

    /// Verify that remapGraph returns nil when a target was removed.
    @Test(.requireSDKs(.host))
    func remapFailsWhenTargetRemoved() async throws {
        let core = try await getCore()

        let ws1 = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("S1.c"),
                            TestFile("S2.c"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug", buildSettings: [:]
                        ),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        ),
                        TestStandardTarget(
                            "T2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S2.c"])
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)

        // ws2 only has T1
        let ws2 = try TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [TestFile("S1.c")]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug", buildSettings: [:]
                        ),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        ),
                    ]
                ),
            ]
        ).load(core)

        let buildParameters = BuildParameters(
            configuration: "Debug"
        )
        let t1 = ConfiguredTarget(
            parameters: buildParameters,
            target: ws1.targets(named: "T1").first!
        )
        let t2 = ConfiguredTarget(
            parameters: buildParameters,
            target: ws1.targets(named: "T2").first!
        )

        let cached = TargetBuildGraphCache.CachedDependencyGraph(
            contentSignature: 42,
            allTargets: OrderedSet([t1, t2]),
            targetDependencies: [:],
            targetsToLinkedReferencesToProducingTargets: [:],
            dynamicallyBuildingTargets: [],
            diagnostics: [],
            lastAccess: 0
        )

        let remapped = TargetBuildGraphCache.remapGraph(
            cached, to: ws2
        )
        #expect(
            remapped == nil,
            "remapGraph must return nil when a cached target "
                + "is missing from the new workspace"
        )
    }

    /// Anti-regression: verify remapped graph keys work with
    /// freshly-constructed ConfiguredTargets from the new workspace.
    @Test(.requireSDKs(.host))
    func noRegressionStaleReferences() async throws {
        let core = try await getCore()

        let testWS = TestWorkspace(
            "Workspace",
            projects: [
                TestProject(
                    "P1",
                    groupTree: TestGroup(
                        "G1",
                        children: [
                            TestFile("S1.c"),
                            TestFile("S2.c"),
                        ]
                    ),
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug", buildSettings: [:]
                        ),
                    ],
                    targets: [
                        TestStandardTarget(
                            "T1",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S1.c"])
                            ]
                        ),
                        TestStandardTarget(
                            "T2",
                            type: .framework,
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "PRODUCT_NAME":
                                            "$(TARGET_NAME)"
                                    ]
                                ),
                            ],
                            buildPhases: [
                                TestSourcesBuildPhase(["S2.c"])
                            ]
                        ),
                    ]
                ),
            ]
        )

        let ws1 = try testWS.load(core)
        let ws2 = try testWS.load(core)

        let buildParameters = BuildParameters(
            configuration: "Debug"
        )
        let ct1ws1 = ConfiguredTarget(
            parameters: buildParameters,
            target: ws1.targets(named: "T1").first!
        )
        let ct2ws1 = ConfiguredTarget(
            parameters: buildParameters,
            target: ws1.targets(named: "T2").first!
        )

        let cached = TargetBuildGraphCache.CachedDependencyGraph(
            contentSignature: 42,
            allTargets: OrderedSet([ct2ws1, ct1ws1]),
            targetDependencies: [ct1ws1: [], ct2ws1: []],
            targetsToLinkedReferencesToProducingTargets: [:],
            dynamicallyBuildingTargets: [],
            diagnostics: [],
            lastAccess: 0
        )

        // Before remap: ws2 keys must NOT match ws1 graph
        let ct1ws2 = ConfiguredTarget(
            parameters: buildParameters,
            target: ws2.targets(named: "T1").first!
        )
        let ct2ws2 = ConfiguredTarget(
            parameters: buildParameters,
            target: ws2.targets(named: "T2").first!
        )
        #expect(
            cached.targetDependencies[ct1ws2] == nil,
            "Before remap, ws2 keys must not match ws1 graph"
        )

        // After remap: ws2 keys should match
        let remapped = try #require(
            TargetBuildGraphCache.remapGraph(cached, to: ws2)
        )

        #expect(
            remapped.targetDependencies[ct1ws2] != nil,
            "After remap, ws2 keys must match remapped graph"
        )
        #expect(
            remapped.targetDependencies[ct2ws2] != nil,
            "After remap, ws2 keys must match remapped graph"
        )

        #expect(remapped.allTargets.contains(ct1ws2))
        #expect(remapped.allTargets.contains(ct2ws2))
        #expect(!remapped.allTargets.contains(ct1ws1))
        #expect(!remapped.allTargets.contains(ct2ws1))
    }
}
