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
import SWBUtil
import SWBTestSupport
import SWBCore

@Suite fileprivate struct BuildCommandTests {
    @Test
    func equality() throws {
        let paths1: [Path] = [Path("./")]
        let paths2: [Path] = [Path("")]

        let pifLoader = PIFLoader(data: .plArray([]), namespace: BuiltinMacros.namespace)
        let target1 = try Target.create(TestStandardTarget("A", type: .application).toProtocol(), pifLoader, signature: "MOCK1")
        let target2 = try Target.create(TestStandardTarget("B", type: .application).toProtocol(), pifLoader, signature: "MOCK2")
        let targets1 = [target1]
        let targets2 = [target2]

        let testCasesSame: [(BuildCommand, BuildCommand)] = [
            (.build(style: .buildOnly, skipDependencies: false), .build(style: .buildOnly, skipDependencies: false)),
            (.build(style: .buildAndRun, skipDependencies: false), .build(style: .buildAndRun, skipDependencies: false)),
            (.generateAssemblyCode(buildOnlyTheseFiles: paths1), .generateAssemblyCode(buildOnlyTheseFiles: paths1)),
            (.generatePreprocessedFile(buildOnlyTheseFiles: paths1), .generatePreprocessedFile(buildOnlyTheseFiles: paths1)),
            (.singleFileBuild(buildOnlyTheseFiles: paths1), .singleFileBuild(buildOnlyTheseFiles: paths1)),
            (.prepareForIndexing(buildOnlyTheseTargets: targets1, enableIndexBuildArena: true), .prepareForIndexing(buildOnlyTheseTargets: targets1, enableIndexBuildArena: true)),
            (.prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: true), .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: true)),
            (.preview(style: .dynamicReplacement), .preview(style: .dynamicReplacement)),
            (.preview(style: .xojit), .preview(style: .xojit)),
        ]

        for (first, second) in testCasesSame {
            #expect(first == second, "Expected \(first) to be the same as \(second).")
        }

        let testCasesDifferent: [(BuildCommand, BuildCommand)] = [
            (.generateAssemblyCode(buildOnlyTheseFiles: paths1), .generateAssemblyCode(buildOnlyTheseFiles: paths2)),
            (.generatePreprocessedFile(buildOnlyTheseFiles: paths1), .generatePreprocessedFile(buildOnlyTheseFiles: paths2)),
            (.singleFileBuild(buildOnlyTheseFiles: paths1), .singleFileBuild(buildOnlyTheseFiles: paths2)),
            (.prepareForIndexing(buildOnlyTheseTargets: targets1, enableIndexBuildArena: true), .prepareForIndexing(buildOnlyTheseTargets: nil, enableIndexBuildArena: true)),
            (.prepareForIndexing(buildOnlyTheseTargets: targets1, enableIndexBuildArena: true), .prepareForIndexing(buildOnlyTheseTargets: targets2, enableIndexBuildArena: true)),
            (.preview(style: .dynamicReplacement), .build(style: .buildOnly, skipDependencies: false)),
            (.preview(style: .xojit), .build(style: .buildOnly, skipDependencies: false)),
        ]

        for (first, second) in testCasesDifferent {
            #expect(first != second, "Expected \(first) to be different as \(second).")
        }
    }
}
