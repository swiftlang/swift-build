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

@_spi(Testing) import SWBCore
import SWBUtil
import Testing

@Suite fileprivate struct ModuleVerifierModuleMapTests {
    fileprivate func assert(moduleMap: ModuleVerifierModuleMap, kind: ModuleMapKind, path: Path, frameworkName: String, modules: [String], isInPreferredPath: Bool) {
        #expect(moduleMap.kind == kind, "kind")
        #expect(moduleMap.path == path, "path")
        #expect(moduleMap.framework == frameworkName, "frameworkName")
        #expect(moduleMap.modules == modules, "modules")
        #expect(moduleMap.isInPreferredPath == true, "isInPreferredPath")
    }

    @Test
    func badFrameworkModules() throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let frameworkName = "BadFramework"
        let frameworkPath = tmpDir.join("\(frameworkName).framework")
        let modulemapPath = frameworkPath.join("Versions/A/Modules/module.modulemap")
        try fs.createDirectory(modulemapPath.dirname, recursive: true)
        try fs.write(modulemapPath, contents: """
            framework module BadFramework {
                umbrella "Headers"
                export *
                module * { export * }
            }
            """)

        let moduleMap = try ModuleVerifierModuleMap(moduleMap: modulemapPath, fs: fs, frameworkName: frameworkName)

        assert(moduleMap: moduleMap,
               kind: .publicModule,
               path: modulemapPath,
               frameworkName: frameworkName,
               modules: [frameworkName],
               isInPreferredPath: true)
    }

    @Test
    func newFrameworkModules() throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let frameworkName = "NewFramework"
        let frameworkPath = tmpDir.join("\(frameworkName).framework")
        let modulemapPath = frameworkPath.join("Versions/A/Modules/module.modulemap")
        try fs.createDirectory(modulemapPath.dirname, recursive: true)
        try fs.write(modulemapPath, contents: """
            framework module NewFramework {
                umbrella "Headers"
                export *
                module * { export * }
            }
            """)

        let moduleMap = try ModuleVerifierModuleMap(moduleMap: modulemapPath, fs: fs, frameworkName: frameworkName)

        assert(moduleMap: moduleMap,
               kind: .publicModule,
               path: modulemapPath,
               frameworkName: frameworkName,
               modules: [frameworkName],
               isInPreferredPath: true)
    }

    @Test
    func perfectFrameworkModules() throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let frameworkName = "PerfectFramework"
        let frameworkPath = tmpDir.join("\(frameworkName).framework")
        let modulemapPath = frameworkPath.join("Versions/A/Modules/module.modulemap")
        let modulemapPathPrivate = frameworkPath.join("Versions/A/Modules/module.private.modulemap")
        try fs.createDirectory(modulemapPath.dirname, recursive: true)
        try fs.write(modulemapPath, contents: """
            framework module PerfectFramework [system] [extern_c] {
                umbrella header "PerfectFramework.h"
                export *
                module * { export * }
            }
            """)
        try fs.write(modulemapPathPrivate, contents: """
            framework module PerfectFramework_Private [system] [extern_c] {
                umbrella header "PerfectFramework_Private.h"
                export *
                module * { export * }
            }
            """)

        let publicModuleMap = try ModuleVerifierModuleMap(moduleMap: modulemapPath, fs: fs, frameworkName: frameworkName)

        assert(moduleMap: publicModuleMap,
               kind: .publicModule,
               path: modulemapPath,
               frameworkName: frameworkName,
               modules: [frameworkName],
               isInPreferredPath: true)

        let privateModuleMap = try ModuleVerifierModuleMap(moduleMap: modulemapPathPrivate, fs: fs, frameworkName: frameworkName)

        assert(moduleMap: privateModuleMap,
               kind: .privateModule,
               path: modulemapPathPrivate,
               frameworkName: frameworkName,
               modules: ["\(frameworkName)_Private"],
               isInPreferredPath: true)
    }

    @Test
    func excludedAndPrivateHeaders() throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let frameworkName = "FrameworkWithNonModularHeaders"
        let frameworkPath = tmpDir.join("\(frameworkName).framework")
        let modulemapPath = frameworkPath.join("Versions/A/Modules/module.modulemap")
        let modulemapPathPrivate = frameworkPath.join("Versions/A/Modules/module.private.modulemap")
        try fs.createDirectory(modulemapPath.dirname, recursive: true)
        try fs.write(modulemapPath, contents: """
            framework module FrameworkWithNonModularHeaders [system] {
              umbrella header "FrameworkWithNonModularHeaders.h"

              exclude header "NonModular.h"

              export *
              module * { export * }
            }
            """)
        try fs.write(modulemapPathPrivate, contents: """
            framework module FrameworkWithNonModularHeaders_Private [system] {
              umbrella "PrivateHeaders"

              exclude header "Excluded.h"
              private header "Private.h"
              private  textual   header    "PrivateTextual.h"

              module * { export * }
            }
            """)

        let moduleMap = try ModuleVerifierModuleMap(moduleMap: modulemapPathPrivate, fs: fs, frameworkName: frameworkName)

        #expect(moduleMap.excludedHeaderNames == ["Excluded.h"])

        let privateHeaders = moduleMap.privateHeaderNames
        #expect(privateHeaders.count == 2)
        #expect(privateHeaders.contains("Private.h"))
        #expect(privateHeaders.contains("PrivateTextual.h"))
    }

    @Test
    func moduleContents() throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let frameworkName = "PrivateOnlyPublicNoContentsPrivateModule"
        let frameworkPath = tmpDir.join("\(frameworkName).framework")
        let modulemapPath = frameworkPath.join("Versions/A/Modules/module.modulemap")
        let modulemapPathPrivate = frameworkPath.join("Versions/A/Modules/module.private.modulemap")
        try fs.createDirectory(modulemapPath.dirname, recursive: true)
        try fs.write(modulemapPath, contents: """
            framework module PrivateOnlyPublicNoContentsPrivateModule [system] {
            }
            """)
        try fs.write(modulemapPathPrivate, contents: """
            framework module PrivateOnlyPublicNoContentsPrivateModule_Private [system] {
              umbrella header "PrivateOnlyPublicNoContentsPrivateModule_Private.h"
              export *

              module * { export * }
            }
            """)

        let moduleMap = try ModuleVerifierModuleMap(moduleMap: modulemapPath, fs: fs, frameworkName: frameworkName)
        #expect(!moduleMap.modulesHaveContents)
    }
}
