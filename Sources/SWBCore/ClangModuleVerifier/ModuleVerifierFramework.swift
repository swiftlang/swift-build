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

public import SWBUtil
import Foundation

public struct ModuleVerifierFramework {
    @_spi(Testing) public let directory: Path
    @_spi(Testing) public let inSDK: Bool
    @_spi(Testing) public let framework: String
    @_spi(Testing) public let name: String

    @_spi(Testing) public let headersDirectory: Path
    @_spi(Testing) public let privateHeadersDirectory: Path
    let headers: [ModuleVerifierHeader]
    let privateHeaders: [ModuleVerifierHeader]

    @_spi(Testing) public let publicModuleMap: ModuleVerifierModuleMap?
    @_spi(Testing) public let privateModuleMap: ModuleVerifierModuleMap?
    @_spi(Testing) public let additionalModuleMaps: [ModuleVerifierModuleMap]
    @_spi(Testing) public let additionalModuleFiles: [Path]

    @_spi(Testing) public let publicUmbrellaHeader: ModuleVerifierHeader?
    @_spi(Testing) public let privateUmbrellaHeader: ModuleVerifierHeader?

    // performance helpers
    @_spi(Testing) public let publicHeaderNames: [String]
    @_spi(Testing) public let privateHeaderNames: [String]

    public init(directory: Path, fs: any FSProxy, inSDK: Bool, specLookupContext: any SpecLookupContext) throws {
        self.directory = directory
        self.inSDK = inSDK

        self.framework = self.directory.basename
        let frameworkName = self.directory.basenameWithoutSuffix
        self.name = frameworkName

        self.headersDirectory = self.directory.join("Headers")
        self.privateHeadersDirectory = self.directory.join("PrivateHeaders")

        self.headers = try ModuleVerifierFramework.headers(at: self.headersDirectory, fs: fs, frameworkName: self.name, specLookupContext: specLookupContext)
        self.privateHeaders = try ModuleVerifierFramework.headers(at: self.privateHeadersDirectory, fs: fs, frameworkName: self.name, specLookupContext: specLookupContext)

        self.publicUmbrellaHeader = self.headers.filter({ $0.header == "\(frameworkName).h" }).first

        let privateUmbrellaHeaderNames = ModuleVerifierFramework.privateUmbrellaHeaderNames(with: frameworkName)
        self.privateUmbrellaHeader = self.privateHeaders.filter({ privateUmbrellaHeaderNames.contains($0.header) }).first

        self.publicHeaderNames = self.headers.map({ $0.header })
        self.privateHeaderNames = self.privateHeaders.map({ $0.header })

        var additionalModuleMaps: [ModuleVerifierModuleMap] = []
        var publicModuleMap: ModuleVerifierModuleMap? = nil
        var privateModuleMap: ModuleVerifierModuleMap? = nil

        /*
         *  There are several possible module map scenarios this is trying to sort out
         *    - public and private headers and module maps
         *    - public headers and module maps only
         *    - private headers and module maps only
         *    - private headers only, but a module map named like it was public
         *    - private headers only, but an empty public module map and a normal private module map
         */

        var moduleMaps = try ModuleVerifierFramework.modules(ofKind: .publicModule, rootPath: self.directory, fs: fs, frameworkName: self.name)
        if moduleMaps.count > 0 {
            if self.headers.count > 0 {
                // public headers, public module map
                publicModuleMap = moduleMaps.removeFirst()
            } else {
                // no public headers, public module map
                privateModuleMap = moduleMaps.removeFirst()
            }
            additionalModuleMaps.append(contentsOf: moduleMaps)
        }

        moduleMaps = try ModuleVerifierFramework.modules(ofKind: .privateModule, rootPath: self.directory, fs: fs, frameworkName: self.name)
        if moduleMaps.count > 0 {
            if let privateModuleMap = privateModuleMap {
                // public module map and a private module map, but there were no public headers
                publicModuleMap = privateModuleMap
            }

            // private module map
            privateModuleMap = moduleMaps.removeFirst()
            additionalModuleMaps.append(contentsOf: moduleMaps)
        }

        self.publicModuleMap = publicModuleMap
        self.privateModuleMap = privateModuleMap

        self.additionalModuleMaps = additionalModuleMaps

        self.additionalModuleFiles = try ModuleVerifierFramework.moduleFiles(rootPath: self.directory, fs: fs)
    }

    public var hasPublicHeaders: Bool {
        return self.headers.count > 0
    }

    public var hasPrivateHeaders: Bool {
        return self.privateHeaders.count > 0
    }

    private static func headers(at dir: Path, fs: any FSProxy, frameworkName: String, specLookupContext: any SpecLookupContext) throws -> [ModuleVerifierHeader] {
        if !fs.exists(dir) {
            return []
        }

        let path = try fs.realpath(dir)
        var headers: [ModuleVerifierHeader] = []
        try fs.traverse(path) { path in
            if specLookupContext.lookupFileType(fileName: path.str)?.conformsToAny(specLookupContext.specRegistry.headerFileTypes) == true, !fs.isDirectory(path) {
                headers.append(ModuleVerifierHeader(header: path, frameworkName: frameworkName))
            }
        }
        // Ensure deterministic order.
        headers.sort { $0.file < $1.file }
        return headers
    }

    private static func modules(ofKind kind:ModuleMapKind, rootPath: Path, fs: any FSProxy, frameworkName: String) throws -> [ModuleVerifierModuleMap] {
        var moduleMaps: [ModuleVerifierModuleMap] = []

        for path in ModuleVerifierModuleMap.paths(for: kind) {
            let modulePath = rootPath.join(path)
            if fs.exists(modulePath) {
                moduleMaps.append(try ModuleVerifierModuleMap(moduleMap: modulePath, fs: fs, frameworkName: frameworkName))
            }
        }

        return moduleMaps
    }

    private static func moduleFiles(rootPath: Path, fs: any FSProxy) throws -> [Path] {
        var modulesDir = rootPath.join("Modules")
        if !fs.exists(modulesDir) {
            return []
        }

        modulesDir = try fs.realpath(modulesDir)
        var moduleFiles: [Path] = []
        try fs.traverse(modulesDir) { path in
            if !path.strWithPosixSlashes.hasSuffix(ModuleVerifierModuleMap.paths) {
                moduleFiles.append(path)
            }
        }
        // Ensure a deterministic order.
        moduleFiles.sort()
        return moduleFiles
    }

    static func privateUmbrellaHeaderName(with frameworkName: String) -> String {
        return "\(frameworkName)_Private.h"
    }

    private static func privateUmbrellaHeaderNames(with frameworkName: String) -> [String] {
        return [
            ModuleVerifierFramework.privateUmbrellaHeaderName(with: frameworkName),
            "\(frameworkName)Private.h",
            "\(frameworkName)_Priv.h",
            "\(frameworkName)Priv.h",
        ]
    }
}

extension ModuleVerifierFramework {
    @_spi(Testing)
    public func allHeaderIncludes(language: ModuleVerifierLanguage) -> String {
        self.allHeaderIncludes(language: language, headers: self.headers)
    }

    public func allModularHeaderIncludes(language: ModuleVerifierLanguage) -> String {
        self.allHeaderIncludes(language: language, headers: headers, moduleMap: publicModuleMap)
    }

    @_spi(Testing)
    public func allPrivateHeaderIncludes(language: ModuleVerifierLanguage) -> String {
        self.allHeaderIncludes(language: language, headers: self.privateHeaders)
    }

    public func allModularPrivateHeaderIncludes(language: ModuleVerifierLanguage) -> String {
        self.allHeaderIncludes(language: language, headers: privateHeaders, moduleMap: privateModuleMap)
    }

    private func allHeaderIncludes(language: ModuleVerifierLanguage, headers: [ModuleVerifierHeader], moduleMap: ModuleVerifierModuleMap? = nil) -> String {
        let filteredHeaders: [ModuleVerifierHeader]
        if let moduleMap {
            let excludedHeaders = moduleMap.excludedHeaderNames
            let privateHeaders = moduleMap.privateHeaderNames
            if excludedHeaders.isEmpty && privateHeaders.isEmpty {
                filteredHeaders = headers
            } else {
                filteredHeaders = headers.filter { header in
                    let headerName = header.header
                    return !excludedHeaders.contains(headerName) && !privateHeaders.contains(headerName)
                }
            }
        } else {
            filteredHeaders = headers
        }
        return filteredHeaders.sorted { (lhp, rhp) -> Bool in
            lhp.include(language: language) < rhp.include(language: language)
        }.map {$0.include(language: language)}.joined(separator: "\n").appending("\n")
    }
}

extension String {
    fileprivate func hasSuffix(_ strings:[String]) -> Bool {
        for string in strings {
            if self.hasSuffix(string) {
                return true
            }
        }
        return false
    }
}
