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

import SWBCore
import SWBUtil
import SWBTestSupport
import SWBMacro

// MARK: Performance tests

@Suite(.performance)
fileprivate struct FilePathResolverPerfTests: PerfTests {
    fileprivate final class FilePathResolverPerfTestsMacros {
        static let filePathResolverPerfTestsNamespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: "FilePathResolverPerfTests")

        static func declareBooleanMacro(_ name: String) throws -> BooleanMacroDeclaration { return try filePathResolverPerfTestsNamespace.declareBooleanMacro(name) }
        static func declareStringMacro(_ name: String) throws -> StringMacroDeclaration { return try filePathResolverPerfTestsNamespace.declareStringMacro(name) }
        static func declareStringListMacro(_ name: String) throws -> StringListMacroDeclaration { return try filePathResolverPerfTestsNamespace.declareStringListMacro(name) }
    }

    private let scope: MacroEvaluationScope
    private let resolver: FilePathResolver

    /// A mock PIF loader.
    private let pifLoader: PIFLoader

    init() {
        // Create a MacroValueAssignmentTable to use during lookup, and then wrap it in a MacroEvaluationScope.
        var table: MacroValueAssignmentTable = MacroValueAssignmentTable(namespace: FilePathResolverPerfTestsMacros.filePathResolverPerfTestsNamespace)
        table.push(BuiltinMacros.PROJECT_DIR, literal: "/tmp/SomeProject")
        scope = MacroEvaluationScope(table: table)

        // Now create a file path resolver containing the scope.
        resolver = FilePathResolver(scope: scope)

        // Create a new PIFLoader for each test case, and discard it at the end.
        pifLoader = PIFLoader(data: .plArray([]), namespace: BuiltinMacros.namespace)
    }

    @Test
    func projectRelativeSourceTree_X100000() async throws {
        let model = try TestGroup("SomeProject", path: "", sourceTree: .buildSetting("PROJECT_DIR")).toProtocol()
        let rootGroup = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileGroup)

        await measure {
            // We do each iteration many times in order to samples that are more likely to be statistically significant.
            for _ in 1...100000
            {
                // Create a new resolver each time because we don't want to hit the cache in this test.
                let resolver = FilePathResolver(scope: self.scope)

                // Resolve the path.
                let resolvedPath = resolver.resolveAbsolutePath(rootGroup)
                #expect(resolvedPath == Path("/tmp/SomeProject"))
            }
        }
    }

    @Test
    func projectRelativeSourceTree_Cached_X100000() async throws {
        let model = try TestGroup("SomeProject", sourceTree: .buildSetting("PROJECT_DIR")).toProtocol()
        let rootGroup = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileGroup)

        await measure {
            // We do each iteration many times in order to samples that are more likely to be statistically significant.
            for _ in 1...100000
            {
                // Resolve the path using the resolver property so that all but the first resolution uses its file group cache.
                let resolvedPath = self.resolver.resolveAbsolutePath(rootGroup)
                #expect(resolvedPath == Path("/tmp/SomeProject"))
            }
        }
    }

    @Test
    func absoluteSourceTree_X100000() async throws {
        let model = try TestGroup("SomeProject", path: "/tmp/AbsolutePath", sourceTree: .absolute).toProtocol()
        let rootGroup = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileGroup)

        await measure {
            // We do each iteration many times in order to samples that are more likely to be statistically significant.
            for _ in 1...100000
            {
                // Create a new resolver each time because we don't want to hit the cache in this test.
                let resolver = FilePathResolver(scope: self.scope)

                // Resolve the path.
                let resolvedPath = resolver.resolveAbsolutePath(rootGroup)
                #expect(resolvedPath == Path("/tmp/AbsolutePath"))
            }
        }
    }

    @Test
    func groupRelativeSourceTree_1Level_X100000() async throws {
        let model = try TestGroup("SomeProject", path: "/tmp/SomeProject", sourceTree: .absolute,
                                  children: [TestGroup("AllFiles")]).toProtocol()
        let rootGroup = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileGroup)
        let childGroup = try #require(rootGroup.children[0] as? FileGroup)

        await measure {
            // We do each iteration many times in order to samples that are more likely to be statistically significant.
            for _ in 1...100000
            {
                // Create a new resolver each time because we don't want to hit the cache in this test.
                let resolver = FilePathResolver(scope: self.scope)

                // Resolve the path.
                let resolvedPath = resolver.resolveAbsolutePath(childGroup)
                #expect(resolvedPath == Path("/tmp/SomeProject/AllFiles"))
            }
        }
    }

    @Test
    func groupRelativeSourceTree_2Levels_X100000() async throws {
        let model = try TestGroup("SomeProject", path: "/tmp/SomeProject", sourceTree: .absolute,
                                  children: [TestGroup("AllFiles",
                                                       children: [TestGroup("SomeFiles")])]).toProtocol()
        let rootGroup = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileGroup)
        let childGroup = try #require(rootGroup.children[0] as? FileGroup)
        let grandchildGroup = try #require(childGroup.children[0] as? FileGroup)

        await measure {
            // We do each iteration many times in order to samples that are more likely to be statistically significant.
            for _ in 1...100000
            {
                // Create a new resolver each time because we don't want to hit the cache in this test.
                let resolver = FilePathResolver(scope: self.scope)

                // Resolve the path.
                let resolvedPath = resolver.resolveAbsolutePath(grandchildGroup)
                #expect(resolvedPath == Path("/tmp/SomeProject/AllFiles/SomeFiles"))
            }
        }
    }

    @Test
    func groupRelativeSourceTree_2Levels_Cached_X100000() async throws {
        let model = try TestGroup("SomeProject", path: "/tmp/SomeProject", sourceTree: .absolute,
                                  children: [TestGroup("AllFiles",
                                                       children: [TestGroup("SomeFiles")])]).toProtocol()
        let rootGroup = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileGroup)
        let childGroup = try #require(rootGroup.children[0] as? FileGroup)
        let grandchildGroup = try #require(childGroup.children[0] as? FileGroup)

        await measure {
            // We do each iteration many times in order to samples that are more likely to be statistically significant.
            for _ in 1...100000
            {
                // Resolve the path using the resolver property so that all but the first resolution uses its file group cache.
                let resolvedPath = self.resolver.resolveAbsolutePath(grandchildGroup)
                #expect(resolvedPath == Path("/tmp/SomeProject/AllFiles/SomeFiles"))
            }
        }
    }
}
