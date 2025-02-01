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
import SWBTestSupport
import Testing

@Suite fileprivate struct ModuleVerifierFrameworkTests: CoreBasedTests {
    var specLookupContext: any SpecLookupContext {
        get async throws {
            try await SpecLookupCtxt(specRegistry: getCore().specRegistry, platform: nil)
        }
    }

    fileprivate func assert(_ frameworkInstance: ModuleVerifierFramework,
                            path: Path,
                            inSDK: Bool,
                            framework: String,
                            name: String,
                            headersPath: Path,
                            privateHeadersPath: Path,
                            publicHeaderNames: [String],
                            privateHeaderNames: [String],
                            hasPublicModuleMap: Bool,
                            hasPrivateModuleMap: Bool,
                            hasPublicUmbrellaHeader: Bool,
                            hasPrivateUmbrellaHeader: Bool,
                            additionalModuleMapsCount: Int,
                            additionalModuleFilesCount: Int) {

        #expect(frameworkInstance.directory == path,
                "path is \(frameworkInstance.directory), should be \(path)")

        #expect(frameworkInstance.inSDK == inSDK,
                "inSDK is \(frameworkInstance.inSDK), should be \(inSDK)")

        #expect(frameworkInstance.framework == framework,
                "framework is \(frameworkInstance.framework), should be \(framework)")

        #expect(frameworkInstance.name == name,
                "name is \(frameworkInstance.name), should be \(name)")

        #expect(frameworkInstance.headersDirectory == headersPath,
                "headersPath is \(frameworkInstance.headersDirectory), should be \(headersPath)")

        #expect(frameworkInstance.privateHeadersDirectory == privateHeadersPath,
                "privateHeadersPath is \(frameworkInstance.privateHeadersDirectory), should be \(privateHeadersPath)")

        #expect(frameworkInstance.publicHeaderNames == publicHeaderNames,
                "publicHeaderNames is \(frameworkInstance.publicHeaderNames), should be \(publicHeaderNames)")

        #expect(frameworkInstance.privateHeaderNames == privateHeaderNames,
                "privateHeaderNames is \(frameworkInstance.privateHeaderNames), should be \(privateHeaderNames)")

        if hasPublicModuleMap {
            #expect(frameworkInstance.publicModuleMap != nil,
                    "publicModuleMap is nil")
        } else {
            #expect(frameworkInstance.publicModuleMap == nil,
                    "hasPublicModuleMap should be nil instead of \(frameworkInstance.publicModuleMap?.path.str ?? "")")
        }

        if hasPrivateModuleMap {
            #expect(frameworkInstance.privateModuleMap != nil,
                    "privateModuleMap is nil")
        } else {
            #expect(frameworkInstance.privateModuleMap == nil,
                    "hasPrivateModuleMap should be nil instead of \(frameworkInstance.privateModuleMap?.path.str ?? "")")
        }

        if hasPublicUmbrellaHeader {
            #expect(frameworkInstance.publicUmbrellaHeader != nil, "publicUmbrellaHeader is nil")
        } else {
            #expect(frameworkInstance.publicUmbrellaHeader == nil, "publicUmbrellaHeader should be nil instead of \(frameworkInstance.publicUmbrellaHeader?.file.str ?? "")")
        }

        if hasPrivateUmbrellaHeader {
            #expect(frameworkInstance.privateUmbrellaHeader != nil, "privateUmbrellaHeader is nil")
        } else {
            #expect(frameworkInstance.privateUmbrellaHeader == nil, "privateUmbrellaHeader should be nil instead of \(frameworkInstance.publicUmbrellaHeader?.file.str ?? "")")
        }

        #expect(frameworkInstance.additionalModuleMaps.count == additionalModuleMapsCount,
                "path is \(frameworkInstance.additionalModuleMaps.count), should be \(additionalModuleMapsCount).  additionalModuleMaps=\(frameworkInstance.additionalModuleMaps.map { $0.path.str })")

        #expect(frameworkInstance.additionalModuleFiles.count == additionalModuleFilesCount,
                "additionalModuleFilesCount is \(frameworkInstance.additionalModuleFiles.count), should be \(additionalModuleFilesCount).  additionalModuleFiles=\(frameworkInstance.additionalModuleFiles.map { $0.str })")
    }

    @Test
    func badFramework() async throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let framework = "BadFramework.framework"
        let frameworkPath = tmpDir.join(framework)
        try fs.createDirectory(frameworkPath.join("Headers"), recursive: true)
        try fs.createDirectory(frameworkPath.join("Modules"), recursive: true)
        try fs.write(frameworkPath.join("Headers/BadHeader.h"), contents: """
            #if THIS_MACRO_IS_NOT_DEFINED
            int x = 1;
            #endif

            #if TARGET_OS_MAC
            int y = 2;
            #endif

            void bad_function( int );

            inline void inline_function(void) {
                unsigned char z;
            }
            """)
        try fs.write(frameworkPath.join("Modules/module.modulemap"), contents: """
            framework module BadFramework {
                umbrella "Headers"
                export *
                module * { export * }
            }
            """)
        try fs.write(frameworkPath.join("module.map"), contents: """
            framework module BadFramework {
                umbrella "Headers"
                export *
                module * { export * }
            }
            """)
        try fs.write(frameworkPath.join("Modules/additionalFile"), contents: """
            framework module BadFramework {
                umbrella "Headers"
                export *
                module * { export * }
            }
            """)
        let testFramework = try await ModuleVerifierFramework(directory: frameworkPath, fs: fs, inSDK: false, specLookupContext: specLookupContext)

        self.assert(testFramework,
                    path: frameworkPath,
                    inSDK: false,
                    framework: framework,
                    name: framework.replacingOccurrences(of: ".framework", with: ""),
                    headersPath: frameworkPath.join("Headers"),
                    privateHeadersPath: frameworkPath.join("PrivateHeaders"),
                    publicHeaderNames: ["BadHeader.h"],
                    privateHeaderNames: [],
                    hasPublicModuleMap: true,
                    hasPrivateModuleMap: false,
                    hasPublicUmbrellaHeader: false,
                    hasPrivateUmbrellaHeader: false,
                    additionalModuleMapsCount: 1,
                    additionalModuleFilesCount: 1)
    }

    @Test
    func newFramework() async throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let framework = "NewFramework.framework"
        let frameworkPath = tmpDir.join(framework)
        try fs.createDirectory(frameworkPath.join("Headers"), recursive: true)
        try fs.createDirectory(frameworkPath.join("Modules"), recursive: true)
        try fs.write(frameworkPath.join("Headers/NewHeader.h"), contents: """
            #if THIS_MACRO_IS_NOT_DEFINED
            int x = 1;
            #endif

            void new_function( int );
            """)
        try fs.write(frameworkPath.join("Modules/module.modulemap"), contents: """
            framework module NewFramework {
                umbrella "Headers"
                export *
                module * { export * }
            }
            """)
        let testFramework = try await ModuleVerifierFramework(directory: frameworkPath, fs: fs, inSDK: false, specLookupContext: specLookupContext)

        self.assert(testFramework,
                    path: frameworkPath,
                    inSDK: false,
                    framework: framework,
                    name: framework.replacingOccurrences(of: ".framework", with: ""),
                    headersPath: frameworkPath.join("Headers"),
                    privateHeadersPath: frameworkPath.join("PrivateHeaders"),
                    publicHeaderNames: ["NewHeader.h"],
                    privateHeaderNames: [],
                    hasPublicModuleMap: true,
                    hasPrivateModuleMap: false,
                    hasPublicUmbrellaHeader: false,
                    hasPrivateUmbrellaHeader: false,
                    additionalModuleMapsCount: 0,
                    additionalModuleFilesCount: 0)
    }

    @Test
    func perfectFramework() async throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let framework = "PerfectFramework.framework"
        let frameworkPath = tmpDir.join(framework)
        try fs.createDirectory(frameworkPath.join("Headers"), recursive: true)
        try fs.createDirectory(frameworkPath.join("PrivateHeaders"), recursive: true)
        try fs.createDirectory(frameworkPath.join("Modules"), recursive: true)
        try fs.write(frameworkPath.join("Headers/PerfectFramework.h"), contents: """
            #import <PerfectFramework/PerfectHeader.h>
            """)
        try fs.write(frameworkPath.join("Headers/PerfectHeader.h"), contents: """
            void perfect_function( int );
            """)
        try fs.write(frameworkPath.join("PrivateHeaders/PerfectFramework_Private.h"), contents: """
            #import <PerfectFramework/PerfectPrivateHeader.h>
            """)
        try fs.write(frameworkPath.join("PrivateHeaders/PerfectPrivateHeader.h"), contents: """
            void perfect_private_function( int );
            """)
        try fs.write(frameworkPath.join("Modules/module.modulemap"), contents: """
            framework module PerfectFramework [system] [extern_c] {
                umbrella header "PerfectFramework.h"
                export *
                module * { export * }
            }
            """)
        try fs.write(frameworkPath.join("Modules/module.private.modulemap"), contents: """
            framework module PerfectFramework_Private [system] [extern_c] {
                umbrella header "PerfectFramework_Private.h"
                export *
                module * { export * }
            }
            """)
        try fs.write(frameworkPath.join("PerfectFramework.tbd"), contents: "")

        let testFramework = try await ModuleVerifierFramework(directory: frameworkPath, fs: fs, inSDK: false, specLookupContext: specLookupContext)

        self.assert(testFramework,
                    path: frameworkPath,
                    inSDK: false,
                    framework: framework,
                    name: framework.replacingOccurrences(of: ".framework", with: ""),
                    headersPath: frameworkPath.join("Headers"),
                    privateHeadersPath: frameworkPath.join("PrivateHeaders"),
                    publicHeaderNames: ["PerfectFramework.h", "PerfectHeader.h"],
                    privateHeaderNames: ["PerfectFramework_Private.h", "PerfectPrivateHeader.h"],
                    hasPublicModuleMap: true,
                    hasPrivateModuleMap: true,
                    hasPublicUmbrellaHeader: true,
                    hasPrivateUmbrellaHeader: true,
                    additionalModuleMapsCount: 0,
                    additionalModuleFilesCount: 0)
    }

    @Test
    func privateOnlyPublicModuleFramework() async throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let framework = "PrivateOnlyPublicModule.framework"
        let frameworkPath = tmpDir.join(framework)
        try fs.createDirectory(frameworkPath.join("PrivateHeaders"), recursive: true)
        try fs.createDirectory(frameworkPath.join("Modules"), recursive: true)
        try fs.write(frameworkPath.join("PrivateHeaders/PrivateOnlyPublicModule_Private.h"), contents: """
            #import <PrivateOnlyPublicModule/PrivateHeader.h>
            """)
        try fs.write(frameworkPath.join("PrivateHeaders/PrivateHeader.h"), contents: """
            void perfect_private_function( int );
            """)
        try fs.write(frameworkPath.join("Modules/module.modulemap"), contents: """
            framework module PrivateOnlyPublicModule_Private [system] [extern_c] {
                umbrella header "PrivateOnlyPublicModule_Private.h"
                export *
                module * { export * }
            }
            """)
        let testFramework = try await ModuleVerifierFramework(directory: frameworkPath, fs: fs, inSDK: false, specLookupContext: specLookupContext)

        self.assert(testFramework,
                    path: frameworkPath,
                    inSDK: false,
                    framework: framework,
                    name: framework.replacingOccurrences(of: ".framework", with: ""),
                    headersPath: frameworkPath.join("Headers"),
                    privateHeadersPath: frameworkPath.join("PrivateHeaders"),
                    publicHeaderNames: [],
                    privateHeaderNames: ["PrivateHeader.h", "PrivateOnlyPublicModule_Private.h"],
                    hasPublicModuleMap: false,
                    hasPrivateModuleMap: true,
                    hasPublicUmbrellaHeader: false,
                    hasPrivateUmbrellaHeader: true,
                    additionalModuleMapsCount: 0,
                    additionalModuleFilesCount: 0)
    }

    @Test
    func privateOnlyPublicPrivateModule() async throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let framework = "PrivateOnlyPublicPrivateModule.framework"
        let frameworkPath = tmpDir.join(framework)
        try fs.createDirectory(frameworkPath.join("PrivateHeaders"), recursive: true)
        try fs.createDirectory(frameworkPath.join("Modules"), recursive: true)
        try fs.write(frameworkPath.join("PrivateHeaders/PrivateOnlyPublicPrivateModule_Private.h"), contents: """
            #import <PrivateOnlyPublicModule/PrivateHeader.h>
            """)
        try fs.write(frameworkPath.join("PrivateHeaders/PrivateHeader.h"), contents: """
            void private_function( int );
            """)
        try fs.write(frameworkPath.join("Modules/module.modulemap"), contents: "")
        try fs.write(frameworkPath.join("Modules/module.private.modulemap"), contents: """
            framework module PrivateOnlyPublicPrivateModule [system] {
                umbrella header "PrivateOnlyPublicPrivateModule_Private.h"
                export *
                module * { export * }
            }
            """)
        let testFramework = try await ModuleVerifierFramework(directory: frameworkPath, fs: fs, inSDK: false, specLookupContext: specLookupContext)

        self.assert(testFramework,
                    path: frameworkPath,
                    inSDK: false,
                    framework: framework,
                    name: framework.replacingOccurrences(of: ".framework", with: ""),
                    headersPath: frameworkPath.join("Headers"),
                    privateHeadersPath: frameworkPath.join("PrivateHeaders"),
                    publicHeaderNames: [],
                    privateHeaderNames: ["PrivateHeader.h", "PrivateOnlyPublicPrivateModule_Private.h"],
                    hasPublicModuleMap: true,
                    hasPrivateModuleMap: true,
                    hasPublicUmbrellaHeader: false,
                    hasPrivateUmbrellaHeader: true,
                    additionalModuleMapsCount: 0,
                    additionalModuleFilesCount: 0)
    }

    @Test
    func headerIncludes() async throws {
        let fs = PseudoFS()
        let tmpDir = Path.root.join("tmp")
        let framework = "FrameworkWithNonModularHeaders.framework"
        let frameworkPath = tmpDir.join(framework)
        try fs.createDirectory(frameworkPath.join("Headers"), recursive: true)
        try fs.createDirectory(frameworkPath.join("PrivateHeaders"), recursive: true)
        try fs.createDirectory(frameworkPath.join("Modules"), recursive: true)
        try fs.write(frameworkPath.join("Headers/FrameworkWithNonModularHeaders.h"), contents: "")
        try fs.write(frameworkPath.join("Headers/NonModular.h"), contents: "")
        try fs.write(frameworkPath.join("PrivateHeaders/Modular.h"), contents: """
            #import <PerfectFramework/PerfectPrivateHeader.h>
            """)
        try fs.write(frameworkPath.join("PrivateHeaders/Private.h"), contents: """
            void perfect_private_function( int );
            """)
        try fs.write(frameworkPath.join("PrivateHeaders/PrivateTextual.h"), contents: """
            void perfect_private_function( int );
            """)
        try fs.write(frameworkPath.join("PrivateHeaders/Excluded.h"), contents: """
            void perfect_private_function( int );
            """)
        try fs.write(frameworkPath.join("Modules/module.modulemap"), contents: """
            framework module FrameworkWithNonModularHeaders [system] {
              umbrella header "FrameworkWithNonModularHeaders.h"

              exclude header "NonModular.h"

              export *
              module * { export * }
            }
            """)
        try fs.write(frameworkPath.join("Modules/module.private.modulemap"), contents: """
            framework module FrameworkWithNonModularHeaders_Private [system] {
              umbrella "PrivateHeaders"

              exclude header "Excluded.h"
              private header "Private.h"
              private  textual   header    "PrivateTextual.h"

              module * { export * }
            }
            """)
        let testFramework = try await ModuleVerifierFramework(directory: frameworkPath, fs: fs, inSDK: false, specLookupContext: specLookupContext)

        let publicIncludes = testFramework.allHeaderIncludes(language: .c)
        #expect(publicIncludes.contains("FrameworkWithNonModularHeaders.h"))
        #expect(publicIncludes.contains("NonModular.h"))

        let privateIncludes = testFramework.allPrivateHeaderIncludes(language: .c)
        #expect(privateIncludes.contains("Modular.h"))
        #expect(privateIncludes.contains("Excluded.h"))
        #expect(privateIncludes.contains("Private.h"))
        #expect(privateIncludes.contains("PrivateTextual.h"))

        let publicModularIncludes = testFramework.allModularHeaderIncludes(language: .c)
        #expect(publicModularIncludes.contains("FrameworkWithNonModularHeaders.h"))
        #expect(!publicModularIncludes.contains("NonModular.h"))

        let privateModularIncludes = testFramework.allModularPrivateHeaderIncludes(language: .c)
        #expect(privateModularIncludes.contains("Modular.h"))
        #expect(!privateModularIncludes.contains("Excluded.h"))
        #expect(!privateModularIncludes.contains("Private.h"))
        #expect(!privateModularIncludes.contains("PrivateTextual.h"))
    }
}
