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

public struct DiscoveredClangToolSpecInfo: DiscoveredCommandLineToolSpecInfo {
    public let toolPath: Path
    public let clangVersion: Version?
    public let llvmVersion: Version?
    public let isAppleClang: Bool

    public var toolVersion: Version? { return self.clangVersion }

    /// `compilerClientsConfig` Clang caching blocklist
    public let clangCachingBlocklist: ClangCachingBlockListInfo?

    public enum FeatureFlag: String, CaseIterable, Sendable {
        case allowPcmWithCompilerErrors = "allow-pcm-with-compiler-errors"
        case vfsDirectoryRemap = "vfs-directory-remap"
        case indexUnitOutputPath = "index-unit-output-path"
        case globalAPINotesPath = "global-api-notes-path"
        case vfsRedirectingWith = "vfs-redirecting-with"
        case vfsstatcache = "vfsstatcache"
        case extractAPIIgnores = "extract-api-ignores"
        case depscanPrefixMap = "depscan-prefix-map"
        case libclangCacheQueries = "libclang-cache-queries"
        case resourceDirUsesMajorVersionOnly = "resource-dir-uses-major-version-only"
        case wSystemHeadersInModule = "Wsystem-headers-in-module"
        case extractAPISupportsCPlusPlus = "extract-api-supports-cpp"
    }
    public var toolFeatures: ToolFeatures<FeatureFlag>
    public func hasFeature(_ feature: String) -> Bool {
        // FIXME: Remove once the feature flag is re-added to clang.
        // rdar://139515136 
        if feature == FeatureFlag.extractAPISupportsCPlusPlus.rawValue {
            return clangVersion > Version(17)
        }
        return toolFeatures.has(feature)
    }

    public func getLibDarwinPath() -> Path? {
        return getResourceDirPath()?.join("lib").join("darwin")
    }

    public func getResourceDirPath() -> Path? {
        let version = hasFeature(FeatureFlag.resourceDirUsesMajorVersionOnly.rawValue) ? llvmVersion?[0].description : llvmVersion?.description
        return version == nil ? nil : toolPath.dirname.dirname.join("lib").join("clang").join(version)
    }
}

public struct ClangCachingBlockListInfo : ProjectFailuresBlockList, Codable, Sendable {
    let KnownFailures: [String]

    enum CodingKeys: String, CodingKey {
        case KnownFailures
    }
}

private let clangVersionRe = RegEx(patternLiteral: #""(?<llvm>[0-9]+(?:\.[0-9]+){0,}) \(clang-(?<clang>[0-9]+(?:\.[0-9]+){0,})\)(?: ((\[.+\])|(\(.+\)))+)?""#)
private let swiftOSSToolchainClangVersionRe = #/"(?<llvm>[0-9]+(?:\.[0-9]+){0,}) \(.* \b([a-f0-9]{40})\b\)(?: ((\[.+\])|(\(.+\)))+)?"/#

/// Creates and returns a discovered info object for the clang compiler for the given path to clang, architecture, SDK, and language.
public func discoveredClangToolInfo(
    _ producer: any CommandProducer,
    _ delegate: any CoreClientTargetDiagnosticProducingDelegate,
    toolPath: Path,
    arch: String,
    sysroot: Path?,
    language: String = "c",
    blocklistsPathOverride: Path?
) async throws -> DiscoveredClangToolSpecInfo {
    // Check that we call a clang variant, 'clang', 'clang++' etc. Note that a test sets `CC` to `/usr/bin/yes` so avoid calling that here.
    guard toolPath.basename.starts(with: "clang") else {
        return DiscoveredClangToolSpecInfo(toolPath: toolPath, clangVersion: nil, llvmVersion: nil, isAppleClang: false, clangCachingBlocklist: nil, toolFeatures: .none)
    }

    // Construct the command line to invoke.
    var commandLine = [toolPath.str]
    commandLine.append("-v")
    commandLine.append("-E")
    commandLine.append("-dM")
    if !arch.isEmpty, arch != "undefined_arch" {
        commandLine.append(contentsOf: ["-arch", arch])
    }
    if let sdkPath = sysroot?.nilIfEmpty {
        commandLine.append(contentsOf: ["-isysroot", sdkPath.str])
    }
    commandLine.append(contentsOf: ["-x", language])
    commandLine.append("-c")
    commandLine.append(Path.null.str)

    return try await producer.discoveredCommandLineToolSpecInfo(delegate, nil, commandLine, { executionResult in
        let outputString = String(decoding: executionResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        var clangVersion: Version? = nil
        var llvmVersion: Version? = nil
        var isAppleClang = false

        for line in outputString.components(separatedBy: "\n") {
            if line.hasPrefix("#define ") {
                // Parse out the macro name and value.
                let macroAssignment = line.withoutPrefix("#define ")
                guard !macroAssignment.isEmpty else { continue }

                let (macroName, macroValue) = macroAssignment.split(" ")
                guard !macroValue.isEmpty else { continue }

                // If the #define is __clang_version__, then we try to extract the LLVM and clang versions.  The value of this macro will look something like one of the following (including the quote characters):
                // "8.1.0 (clang-802.1.38)"
                // "12.0.0 (clang-1200.0.22.5) [ptrauth objc isa mode: sign-and-strip]"
                if macroName == "__clang_version__" {
                    if let match: RegEx.MatchResult = clangVersionRe.firstMatch(in: macroValue) {
                        llvmVersion = match["llvm"].map { try? Version($0) } ?? nil
                        clangVersion = match["clang"].map { try? Version($0) } ?? nil
                    } else if let match = try? swiftOSSToolchainClangVersionRe.firstMatch(in: macroValue) {
                        llvmVersion = try? Version(String(match.llvm))
                    }
                }

                if macroName == "__apple_build_version__" {
                    isAppleClang = true
                }
            }
        }

        func getFeatures(at toolPath: Path) -> ToolFeatures<DiscoveredClangToolSpecInfo.FeatureFlag> {
            let featuresPath = toolPath.dirname.dirname.join("share").join("clang").join("features.json")
            do {
                return try ToolFeatures(path: featuresPath, fs: localFS)
            } catch {
                // Clang was missing its own 'features.json' for a while (see rdar://72387110). Use the presence of the Swift 'features.json' for the features that were supported when it was added.
                // Note that clang's is still missing on Windows: https://github.com/swiftlang/swift-installer-scripts/issues/337
                let swiftFeaturesPath = toolPath.dirname.dirname.join("share").join("swift").join("features.json")
                if localFS.exists(swiftFeaturesPath) {
                    return .init([ .allowPcmWithCompilerErrors, .vfsDirectoryRemap, .indexUnitOutputPath])
                }
                return .init([])
            }
        }

        let blocklistPaths = CompilerSpec.findToolchainBlocklists(producer, directoryOverride: blocklistsPathOverride)

        func getBlocklist<T: Codable>(type: T.Type, toolchainFilename: String, delegate: any TargetDiagnosticProducingDelegate) -> T? {
            return CompilerSpec.getBlocklist(
                type: type,
                toolchainFilename: toolchainFilename,
                blocklistPaths: blocklistPaths,
                fs: localFS,
                delegate: delegate
            )
        }

        return DiscoveredClangToolSpecInfo(
            toolPath: toolPath,
            clangVersion: clangVersion,
            llvmVersion: llvmVersion,
            isAppleClang: isAppleClang,
            clangCachingBlocklist: getBlocklist(type: ClangCachingBlockListInfo.self, toolchainFilename: "clang-caching.json", delegate: delegate),
            toolFeatures: getFeatures(at: toolPath)
        )
    })
}
