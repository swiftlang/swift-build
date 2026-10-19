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
import SWBUtil

@_spi(Testing) import SWBTaskExecution

@Suite
fileprivate struct ClangModuleDependencyGraphTests {
    private let sdk = Path.root.join("sdk")
    private let inSDK = Path.root.join("sdk/usr/include")
    private let outsideSDK = Path.root.join("project/Umbrella")

    @Test
    func directoryDependenciesWithoutFilteringRoot() {
        #expect(ClangModuleDependencyGraph.trackableDirectoryDependencies([inSDK, outsideSDK], filteringRootPath: nil) == [inSDK, outsideSDK])
    }

    @Test
    func directoryDependenciesUnderFilteringRootAreDropped() {
        #expect(ClangModuleDependencyGraph.trackableDirectoryDependencies([inSDK, outsideSDK], filteringRootPath: sdk) == [outsideSDK])
    }

    /// The fallback system SDK on Linux and other generic Unix platforms is rooted at `/`. Filtering by that prefix would drop every directory, so umbrella and framework directory changes would never invalidate a module.
    @Test
    func directoryDependenciesWithRootFilteringRootAreKept() {
        #expect(ClangModuleDependencyGraph.trackableDirectoryDependencies([inSDK, outsideSDK], filteringRootPath: .root) == [inSDK, outsideSDK])
    }
}
