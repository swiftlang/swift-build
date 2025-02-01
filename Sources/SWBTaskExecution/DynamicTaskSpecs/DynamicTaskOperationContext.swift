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
package import SWBCore
package import SWBCAS
package import SWBUtil

public final class DynamicTaskOperationContext {
    private let core: Core
    package private(set) var clangModuleDependencyGraph: ClangModuleDependencyGraph
    package private(set) var swiftModuleDependencyGraph: SwiftModuleDependencyGraph
    package private(set) var compilationCachingUploader: CompilationCachingUploader
    package private(set) var compilationCachingDataPruner: CompilationCachingDataPruner
    package let definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>]
    package let cas: ToolchainCAS?

    package init(core: Core, definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>], cas: ToolchainCAS?) {
        self.core = core
        self.clangModuleDependencyGraph = ClangModuleDependencyGraph(core: core, definingTargetsByModuleName: definingTargetsByModuleName)
        self.swiftModuleDependencyGraph = SwiftModuleDependencyGraph()
        self.compilationCachingUploader = CompilationCachingUploader()
        self.compilationCachingDataPruner = CompilationCachingDataPruner()
        self.definingTargetsByModuleName = definingTargetsByModuleName
        self.cas = cas
    }

    @discardableResult package func waitForCompletion() async -> DynamicTaskOperationContextCompletionToken {
        await self.clangModuleDependencyGraph.waitForCompletion()
        await self.swiftModuleDependencyGraph.waitForCompletion()
        await self.compilationCachingUploader.waitForCompletion()
        await self.compilationCachingDataPruner.waitForCompletion()
        return DynamicTaskOperationContextCompletionToken()
    }

    package func reset(completionToken: consuming DynamicTaskOperationContextCompletionToken) {
        completionToken.run {
            self.clangModuleDependencyGraph = ClangModuleDependencyGraph(core: core, definingTargetsByModuleName: clangModuleDependencyGraph.definingTargetsByModuleName)
            self.swiftModuleDependencyGraph = SwiftModuleDependencyGraph()
            self.compilationCachingUploader = CompilationCachingUploader()
            self.compilationCachingDataPruner = CompilationCachingDataPruner()
        }
    }
}

/// Opaque "token" used to enforce that ``DynamicTaskOperationContext/waitForCompletion()`` is always called immediately prior to invoking ``DynamicTaskOperationContext/reset(completionToken:)``.
package struct DynamicTaskOperationContextCompletionToken: Sendable {
    fileprivate init() { }
    consuming fileprivate func run(body: () -> Void) {
        body()
    }
}
