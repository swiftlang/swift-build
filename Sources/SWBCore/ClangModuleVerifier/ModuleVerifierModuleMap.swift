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

// FIXME: Port to Regex
import struct Foundation.NSRange
import class Foundation.NSRegularExpression

@_spi(Testing)
public enum ModuleMapKind: String {
    case publicModule = "public"
    case privateModule =  "private"
}

@_spi(Testing)
public struct ModuleVerifierModuleMap: Hashable {
    @_spi(Testing) public let kind: ModuleMapKind
    @_spi(Testing) public let path: Path
    @_spi(Testing) public let framework: String
    @_spi(Testing) public let modules: [String]
    @_spi(Testing) public let modulesHaveContents: Bool
    @_spi(Testing) public let excludedHeaderNames: [String]
    @_spi(Testing) public let privateHeaderNames: [String]

    @_spi(Testing) public init(moduleMap: Path, fs: any FSProxy, frameworkName: String) throws {
        let moduleContents = try fs.read(moduleMap).asString

        self.path = moduleMap
        self.framework = frameworkName
        self.modules = ModuleVerifierModuleMap.modulesDeclared(in: moduleContents)
        if self.path.strWithPosixSlashes.contains(oneOf: ModuleVerifierModuleMap.publicPaths) {
            self.kind = .publicModule
        } else {
            self.kind = .privateModule
        }

        excludedHeaderNames = findHeaders(withSpecifierPattern: "exclude")
        privateHeaderNames = findHeaders(withSpecifierPattern: "private(?:\\s+textual)?")

        // This is what you would call "quick and dirty". Real dirty. :(
        func findHeaders(withSpecifierPattern specifierPattern: String) -> [String] {
            let pattern = specifierPattern + "\\s+header\\s+\"(.*?)(?<!\\\\)\""
            let regularExpression = try! NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
            // The range conversions are all real awkward, <rdar://78800247&78800081&78800042>.
            let wholeString = NSRange(moduleContents.startIndex..., in: moduleContents)
            return regularExpression.matches(in: moduleContents, range: wholeString).map {match in
                return String(moduleContents[Range(match.range(at: 1), in: moduleContents)!])
            }
        }

        // Even quicker and dirtier. D:
        modulesHaveContents = moduleContents.contains("umbrella") || moduleContents.contains("header")
    }

    @_spi(Testing) public var isInPreferredPath: Bool {
        switch self.kind {
        case .publicModule:
            return self.path.strWithPosixSlashes.contains(ModuleVerifierModuleMap.preferredPublicPath)
        case .privateModule:
            return self.path.strWithPosixSlashes.contains(ModuleVerifierModuleMap.preferredPrivatePath)
        }
    }

    private static let preferredPublicPath = "Modules/module.modulemap"
    private static let publicPaths = [
        preferredPublicPath,
        "module.map",
    ]

    private static let preferredPrivatePath = "Modules/module.private.modulemap"
    private static let privatePaths = [
        preferredPrivatePath,
        "module_private.map",
    ]

    static let paths = publicPaths + privatePaths

    static func preferredMap(_ kind: ModuleMapKind, framework: ModuleVerifierFramework) -> Path {
        switch kind {
        case .publicModule:
            return framework.directory.join(preferredPublicPath)
        case .privateModule:
            return framework.directory.join(preferredPrivatePath)
        }
    }

    static func paths(for kind: ModuleMapKind) -> [String] {
        switch kind {
        case .publicModule:
            return publicPaths
        case .privateModule:
            return privatePaths
        }
    }

    private static func modulesDeclared(in moduleContents: String) -> [String] {
        // Some day we should have a real module parser for now just count the number of things that will match to be a module
        let moduleNamesPrefix = [
            "explicit framework module",
            "explicit module",
            "module",
            "framework module",
        ]

        let notModuleNameFilters = [
            "export *"
        ]

        let lines = moduleContents.components(separatedBy: "\n")
        let moduleNames:[String] = lines.filter { line in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.starts(withOneOf: moduleNamesPrefix) && !line.contains(oneOf: notModuleNameFilters)
        }.compactMap { line in
            var line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            line = line.remove(strings: moduleNamesPrefix, options: .anchored)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let moduleName: String? = line.components(separatedBy: " ").first
            return moduleName
        }

        return moduleNames
    }
}

extension ModuleVerifierModuleMap: Comparable {
    @_spi(Testing)
    public static func < (lhs: ModuleVerifierModuleMap, rhs: ModuleVerifierModuleMap) -> Bool {
        lhs.path < rhs.path
    }

}

extension String {
    fileprivate func contains(oneOf strings:[String]) -> Bool {
        for string in strings {
            if self.contains(string) {
                return true
            }
        }
        return false
    }

    fileprivate func starts(withOneOf strings:[String]) -> Bool {
        for string in strings {
            if self.hasPrefix(string) {
                return true
            }
        }
        return false
    }

    fileprivate func remove(strings:[String], options mask: CompareOptions = []) -> String {
        var finalString = self

        for string in strings {
            if let range = finalString.range(of: string, options: mask) {
                finalString.removeSubrange(range)
            }
        }

        return finalString
    }
}
