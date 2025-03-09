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
import SWBMacro

// MARK: Unit tests

@Suite fileprivate struct FilePathResolverTests {
    fileprivate final class FilePathResolverTestsMacros {
        static let filePathResolverTestsNamespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: "FilePathResolverTests")

        static func declareBooleanMacro(_ name: String) -> BooleanMacroDeclaration {
            return try! filePathResolverTestsNamespace.declareBooleanMacro(name)
        }
        static func declareStringMacro(_ name: String) -> StringMacroDeclaration {
            return try! filePathResolverTestsNamespace.declareStringMacro(name)
        }
        static func declareStringListMacro(_ name: String) -> StringListMacroDeclaration {
            return try! filePathResolverTestsNamespace.declareStringListMacro(name)
        }

        static let CURRENT_ARCH = FilePathResolverTestsMacros.declareStringMacro("CURRENT_ARCH")
        static let SOURCE_TREE_ONE = FilePathResolverTestsMacros.declareStringMacro("SOURCE_TREE_ONE")
        static let RELATIVE_SOURCE_TREE = FilePathResolverTestsMacros.declareStringMacro("RELATIVE_SOURCE_TREE")
        static let EMPTY_SOURCE_TREE = FilePathResolverTestsMacros.declareStringMacro("EMPTY_SOURCE_TREE")
    }

    private let resolver: FilePathResolver
    private let pifLoader: PIFLoader

    init() {
        // Create a MacroValueAssignmentTable to use during lookup, and then wrap it in a MacroEvaluationScope.
        var table: MacroValueAssignmentTable = MacroValueAssignmentTable(namespace: FilePathResolverTestsMacros.filePathResolverTestsNamespace)
        table.push(BuiltinMacros.PROJECT_DIR, literal: Path.root.join("tmp/SomeProject").str)
        table.push(BuiltinMacros.SRCROOT, literal: Path.root.join("tmp/SrcRoot").str)
        table.push(BuiltinMacros.SOURCE_ROOT, literal: Path.root.join("tmp/SourceRoot").str)
        table.push(BuiltinMacros.SYSTEM_LIBRARY_DIR, literal: Path.root.join("System/Library").str)
        table.push(BuiltinMacros.TARGET_BUILD_DIR, literal: "build/Debug")
        table.push(FilePathResolverTestsMacros.CURRENT_ARCH, literal: "x86_64")
        table.push(FilePathResolverTestsMacros.SOURCE_TREE_ONE, literal: Path.root.join("tmp/somewhere").str)
        table.push(FilePathResolverTestsMacros.RELATIVE_SOURCE_TREE, literal: "RelativeDir")
        table.push(FilePathResolverTestsMacros.EMPTY_SOURCE_TREE, literal: "")
        let scope = MacroEvaluationScope(table: table)

        // Now create a file path resolver containing the scope.
        resolver = FilePathResolver(scope: scope)

        // Create a new PIFLoader for each test case, and discard it at the end.
        pifLoader = PIFLoader(data: .plArray([]), namespace: BuiltinMacros.namespace)
    }

    @Test
    func absolutePath() throws {
        let model = try TestFile(Path.root.join("tmp/SomeProject/SomeProject/ClassOne.m").str, sourceTree: .absolute).toProtocol()
        let fileRef = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileReference)

        // Get the absolute path for the reference and test it.
        let resolvedPath = resolver.resolveAbsolutePath(fileRef)
        #expect(resolvedPath == Path.root.join("tmp/SomeProject/SomeProject/ClassOne.m"))
    }

    @Test
    func groupTreePaths() throws {
        let model = try TestGroup("SomeProject", sourceTree: .buildSetting("PROJECT_DIR"),
                                  children: [
                                    TestGroup("SomeFiles", children: [
                                        TestGroup("OtherFiles",
                                                  children: [TestFile("SourceFile.m"), TestFile("HeaderFile.h")]),
                                        TestFile("SourceFile2.c", sourceTree: .buildSetting("SOURCE_TREE_ONE")),
                                        TestFile("Frameworks/Cocoa.framework", sourceTree: .buildSetting("SYSTEM_LIBRARY_DIR")),
                                        TestVariantGroup("View.xib",
                                                         children: [TestFile("Base.lproj/View.xib"), TestFile("fr.lproj/View.strings", regionVariantName: "fr")])
                                    ])
                                  ]).toProtocol()
        let rootGroup = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileGroup)

        // Test the individual references.
        // We do all this twice in order to exercise the cache mechanism.
        for _ in 1...2 {
            let childGroup = try #require(rootGroup.children.first as? FileGroup)
            let grandchildGroup = try #require(childGroup.children[0] as? FileGroup)
            let variantGroupRef = try #require(childGroup.children[3] as? VariantGroup)
            let resolvedPaths = [
                resolver.resolveAbsolutePath(rootGroup),
                resolver.resolveAbsolutePath(childGroup),
                resolver.resolveAbsolutePath(grandchildGroup),
                resolver.resolveAbsolutePath(try #require(grandchildGroup.children[0] as? FileReference)),
                resolver.resolveAbsolutePath(try #require(grandchildGroup.children[1] as? FileReference)),
                resolver.resolveAbsolutePath(try #require(childGroup.children[1] as? FileReference)),
                resolver.resolveAbsolutePath(try #require(childGroup.children[2] as? FileReference)),
                resolver.resolveAbsolutePath(variantGroupRef),
                resolver.resolveAbsolutePath(try #require(variantGroupRef.children[0] as? FileReference)),
                resolver.resolveAbsolutePath(try #require(variantGroupRef.children[1] as? FileReference)),
            ];
            let expectedPaths = [
                Path.root.join("tmp/SomeProject"),
                Path.root.join("tmp/SomeProject/SomeFiles"),
                Path.root.join("tmp/SomeProject/SomeFiles/OtherFiles"),
                Path.root.join("tmp/SomeProject/SomeFiles/OtherFiles/SourceFile.m"),
                Path.root.join("tmp/SomeProject/SomeFiles/OtherFiles/HeaderFile.h"),
                Path.root.join("tmp/somewhere/SourceFile2.c"),
                Path.root.join("System/Library/Frameworks/Cocoa.framework"),
                Path.root.join("tmp/SomeProject/SomeFiles"),
                Path.root.join("tmp/SomeProject/SomeFiles/Base.lproj/View.xib"),
                Path.root.join("tmp/SomeProject/SomeFiles/fr.lproj/View.strings"),
            ];
            #expect(resolvedPaths == expectedPaths)
        }
    }

    @Test
    func relativeSourceTree() throws {
        let model = try TestFile("ClassTwo.m", sourceTree: .buildSetting("RELATIVE_SOURCE_TREE")).toProtocol()
        let fileRef = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileReference)

        // Get the absolute path for the reference and test it.
        let resolvedPath = resolver.resolveAbsolutePath(fileRef)
        #expect(resolvedPath == Path.root.join("tmp/SomeProject/RelativeDir/ClassTwo.m"))
    }

    @Test
    func emptySourceTree() throws {
        let model = try TestFile("ClassThree.m", sourceTree: .buildSetting("EMPTY_SOURCE_TREE")).toProtocol()
        let fileRef = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileReference)

        // Get the absolute path for the reference and test it.
        // An empty source tree is
        let resolvedPath = resolver.resolveAbsolutePath(fileRef)
        #expect(resolvedPath == Path.root.join("tmp/SomeProject/ClassThree.m"))
    }

    @Test
    func undefinedSourceTree() throws {
        let model = try TestFile("ClassFour.m", sourceTree: .buildSetting("UNDEFINED_SOURCE_TREE")).toProtocol()
        let fileRef = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileReference)

        // Get the absolute path for the reference and test it.
        let resolvedPath = resolver.resolveAbsolutePath(fileRef)
        #expect(resolvedPath == Path.root.join("tmp/SomeProject/ClassFour.m"))
    }

    @Test
    func nullSourceTree() throws {
        let model = try TestFile("ClassThree.m", sourceTree: .buildSetting("")).toProtocol()
        let fileRef = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileReference)

        // Get the absolute path for the reference and test it.
        // An empty source tree is
        let resolvedPath = resolver.resolveAbsolutePath(fileRef)
        #expect(resolvedPath == Path.root.join("tmp/SomeProject/ClassThree.m"))
    }

    @Test
    func buildSettingEmbeddedInPath() throws {
        let model = try TestFile("Sources/Arch_$(CURRENT_ARCH)/ClassFive.m", sourceTree: .buildSetting("PROJECT_DIR")).toProtocol()
        let fileRef = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileReference)

        // Get the absolute path for the reference and test it.
        let resolvedPath = resolver.resolveAbsolutePath(fileRef)
        #expect(resolvedPath == Path.root.join("tmp/SomeProject/Sources/Arch_x86_64/ClassFive.m"))
    }

    @Test
    func dotDotEmbeddedInFileReferencePath() throws {
        let model = try TestFile("Sources/SubDir/../ClassSix.m", sourceTree: .buildSetting("PROJECT_DIR")).toProtocol()
        let fileRef = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileReference)

        // Get the absolute path for the reference and test it.
        let resolvedPath = resolver.resolveAbsolutePath(fileRef)
        #expect(resolvedPath == Path.root.join("tmp/SomeProject/Sources/ClassSix.m"))
    }

    @Test
    func dotDotEmbeddedInFileGroupPath() throws {
        let model = try TestGroup("SomeProject", sourceTree: .buildSetting("PROJECT_DIR"), children: [
            TestGroup("Sources", children: [
                TestGroup("../OtherFiles", children: [
                    TestFile("Resource.txt")
                ]),
            ])
        ]).toProtocol()
        let rootGroup = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileGroup)

        // Get the absolute path for the reference and test it.
        let childGroup = try #require(rootGroup.children[0] as? FileGroup)
        let grandchildGroup = try #require(childGroup.children[0] as? FileGroup)
        let fileRef = try #require(grandchildGroup.children[0] as? FileReference)
        let resolvedPath = resolver.resolveAbsolutePath(fileRef)
        #expect(resolvedPath == Path.root.join("tmp/SomeProject/OtherFiles/Resource.txt"))
    }

    @Test
    func productReference() throws {
        let model = try TestStandardTarget("anApp", type: .application).toProtocol()
        let target = try #require(Target.create(model, pifLoader, signature: "Mock") as? StandardTarget)

        // Get the absolute path for the productreference and test it.
        let productReference = target.productReference
        let resolvedPath = resolver.resolveAbsolutePath(productReference)
        #expect(resolvedPath == Path.root.join("tmp/SomeProject/build/Debug/anApp.app"))
    }

    @Test(.skipHostOS(.windows, "This hits an interesting edge case"), .bug("https://github.com/apple/swift-system/issues/188"))
    func sourceRootToProjectDir() throws {
        let testData = [
            (TestFile("Sources/ClassFive.m", sourceTree: .buildSetting("SOURCE_ROOT")), Path.root.join("tmp/SomeProject/Sources/ClassFive.m").str),
            (TestFile("Sources/$(SOURCE_ROOT)/ClassFive.m", sourceTree: .buildSetting("SOURCE_ROOT")), Path.root.join("tmp/SomeProject/Sources/tmp/SourceRoot/ClassFive.m").str),
            (TestFile("Sources/$(SRCROOT)/ClassFive.m", sourceTree: .buildSetting("SOURCE_ROOT")), Path.root.join("tmp/SomeProject/Sources/tmp/SrcRoot/ClassFive.m").str),
        ]

        for (inputFile, expectedPathString) in testData {
            let model = try inputFile.toProtocol()
            let fileRef = try #require(Reference.create(model, pifLoader, isRoot: true) as? FileReference)

            // Get the absolute path for the reference and test it.
            let resolvedPath = resolver.resolveAbsolutePath(fileRef)
            #expect(resolvedPath.normalize().str == expectedPathString)
        }
    }

}
