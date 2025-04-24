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

package import SWBUtil
import Foundation

/// Helpers for creating frameworks and libraries for use in unit tests.
extension InstalledXcode {

    /// Additional arguments to pass when linking.
    package enum LinkerOption: Sendable {
        case embedInfoPlist(Path)
        case makeMergeable
        case noAdhocCodeSign

        package var args: [String] {
            switch self {
            case let .embedInfoPlist(path):
                return ["-sectcreate", "__TEXT", "__info_plist", path.str]
            case .makeMergeable:
                return ["-Xlinker", "-make_mergeable"]
            case .noAdhocCodeSign:
                return ["-Xlinker", "-no_adhoc_codesign"]
            }
        }
    }

    /// Create the path for our swiftmodule directory structure.
    private func createSwiftModuleDir(at path: Path, name: String, fs: any FSProxy) throws -> Path {
        let swiftModuleDir = path.join("\(name).swiftmodule")
        try fs.createDirectory(swiftModuleDir, recursive: true)
        return swiftModuleDir
    }

    /// Writes out a basic swift file with doc comments.
    private func createSampleSwiftCode(at path: Path, _ sourceContents: String?, fs: any FSProxy) throws -> Path {
        let sourcePath = path.join("source.swift")
        let sourceContents = sourceContents ?? "/// just a simple func\npublic func favorite() -> Int { return 0 }\n"
        try fs.write(sourcePath, contents: ByteString(encodingAsUTF8: sourceContents))
        return sourcePath
    }

    /// Compiles a given swift file producing all of the outputs needed for testing.
    private func compileSwiftFile(name: String, platform: BuildVersion.Platform, infoLookup: any PlatformInfoLookup, platformVariant: BuildVersion.Platform?, arch: String, sourcePath: Path, buildDir: Path, swiftModuleDir: Path, buildLibraryForDistribution: Bool, static: Bool, linkerOptions: [InstalledXcode.LinkerOption] = [], workingDirectory: Path, fs: any FSProxy, object: Bool, needSigned: Bool) async throws -> Path {
        let target = platform.targetTriple(arch, infoLookup: infoLookup)
        let targetVariant = platformVariant?.targetTriple(arch, infoLookup: infoLookup)
        let archDir = buildDir.join(arch)
        try fs.createDirectory(archDir, recursive: true)
        let objectPath = archDir.join("source.o")
        let machoPath = archDir.join(name)

        // Generate the swiftinterface file, last in wins is fine for this.
        let distributionArgs: [String]
        let targetVariantArgs = targetVariant.map { ["-target-variant", $0] } ?? []
        let linkerArgs = linkerOptions.map({ $0.args }).reduce([], +)
        if buildLibraryForDistribution {
            distributionArgs = ["-enable-library-evolution"]
            _ = try await xcrun(["-sdk", platform.sdkName, "swiftc", "-target", target] + targetVariantArgs + distributionArgs as [String] + ["-emit-module-interface", "-emit-module-interface-path", swiftModuleDir.join("\(name).swiftinterface").str, "-c",  sourcePath.str], workingDirectory: workingDirectory.str)
        } else {
            distributionArgs = []
        }

        // Generate the macho file.
        let machoArgs = [["-sdk", platform.sdkName, "swiftc", "-target", target], targetVariantArgs, distributionArgs, ["-emit-module", "-emit-module-path", swiftModuleDir.join("\(arch).swiftmodule").str, "-module-name", name, "-c", sourcePath.str]].reduce([], +)
        _ = try await xcrun(machoArgs, workingDirectory: workingDirectory.str)

        // Generate the swiftmodule file.
        let swiftmoduleArgs = [["-sdk", platform.sdkName, "swiftc", "-target", target], targetVariantArgs, distributionArgs, ["-module-name", name, "-o", objectPath.str, "-c", sourcePath.str]].reduce([], +)
        _ = try await xcrun(swiftmoduleArgs, workingDirectory: workingDirectory.str)

        if `static` {
            return objectPath
        } else if object {
            let linkArgs = [["-sdk", platform.sdkName, "clang", "-r", "-target", target], targetVariantArgs, linkerArgs, ["-L" + swiftRuntimeLibraryDirectoryPath(name: platform.sdkName), "-L/usr/lib/swift", "-o", machoPath.str, objectPath.str]].reduce([], +)
            _ = try await xcrun(linkArgs, workingDirectory: workingDirectory.str)
            return machoPath
        } else {
            let linkArgs = [["-sdk", platform.sdkName, "clang", "-dynamiclib", "-target", target], targetVariantArgs, linkerArgs, ["-L" + swiftRuntimeLibraryDirectoryPath(name: platform.sdkName), "-L/usr/lib/swift", "-o", machoPath.str, objectPath.str]].reduce([], +)
            _ = try await xcrun(linkArgs, workingDirectory: workingDirectory.str)
            if needSigned {
                _ = try await runProcessWithDeveloperDirectory(["/usr/bin/codesign", "-s", "-", machoPath.str])
            }
            return machoPath
        }
    }

    /// Compiles and creates a framework for the given parameters named `<baseName>.framework` or `static<baseName>.framework`, where `baseName` defaults to `sample`.
    package func compileFramework(path basePath: Path, baseName: String = "sample", platform: BuildVersion.Platform, infoLookup: any PlatformInfoLookup, platformVariant: BuildVersion.Platform? = nil, archs: [String], alwaysLipo: Bool = true, sourceContents: String? = nil, headerContents: String? = nil, useSwift: Bool = false, buildLibraryForDistribution: Bool = true, static: Bool = false, linkerOptions: [InstalledXcode.LinkerOption] = [], fs: any FSProxy = localFS, object: Bool = false, needInfoPlist: Bool = false, needSigned: Bool = false) async throws -> Path {
        let buildDir = basePath.join("build")
        let srcDir = basePath.join("src")
        let name = `static` ? "static\(baseName)" : baseName

        let frameworkDir = buildDir.join("\(name).framework")

        try fs.createDirectory(srcDir, recursive: true)
        try fs.createDirectory(buildDir, recursive: true)
        try fs.createDirectory(frameworkDir, recursive: true)

        let isDeepBundle = platform == .macOS

        if isDeepBundle {
            try fs.createDirectory(frameworkDir.join("Versions"))
            try fs.createDirectory(frameworkDir.join("Versions/A"))
            try fs.symlink(frameworkDir.join("Versions/Current"), target: Path("A"))
        }

        func bundleSubItem(name: String) throws -> Path {
            if isDeepBundle {
                if !fs.exists(frameworkDir.join(name)) {
                    try fs.symlink(frameworkDir.join(name), target: Path("Versions/Current/\(name)"))
                }
                return frameworkDir.join("Versions/A/\(name)")
            }
            return frameworkDir.join(name)
        }

        var machos = [Path]()
        // create an Info.plist to sign stripped stub binaries of static/object linkage file types
        if needInfoPlist {
            let resDirPath = try bundleSubItem(name: "Resources")
            let plist = PropertyListItem.plDict(["CFBundleIdentifier": .plString("com.apple.foo")])
            try fs.createDirectory(resDirPath, recursive: true)
            try fs.write(resDirPath.join("Info.plist"), contents: ByteString(try plist.asBytes(.xml)))
        }

        if useSwift {
            let sourcePath = try createSampleSwiftCode(at: srcDir, sourceContents, fs: fs)

            // Create the path for our swiftmodule structure within a framework.
            let modulesDir = try bundleSubItem(name: "Modules")
            let swiftModuleDir = try createSwiftModuleDir(at: modulesDir, name: name, fs: fs)

            // A fake module map is fine..
            try fs.write(modulesDir.join("module.modulemap"), contents: "just some fake data")

            // compile for each arch
            for arch in archs {
                let macho = try await compileSwiftFile(name: name, platform: platform, infoLookup: infoLookup, platformVariant: platformVariant, arch: arch, sourcePath: sourcePath, buildDir: buildDir, swiftModuleDir: swiftModuleDir, buildLibraryForDistribution: buildLibraryForDistribution, static: `static`, linkerOptions: linkerOptions, workingDirectory: basePath, fs: fs, object: object, needSigned: needSigned)
                machos.append(macho)
            }
        }
        else {
            let sourcePath = srcDir.join("source.c")
            let sourceContents = sourceContents ?? "int favorite() { return 0; }\n"
            try fs.write(sourcePath, contents: ByteString(encodingAsUTF8: sourceContents))

            let headersDir = try bundleSubItem(name: "Headers")
            try fs.createDirectory(headersDir, recursive: true)
            let headerContents = headerContents ?? "int favorite();\n"
            try fs.write(headersDir.join("source.h"), contents: ByteString(encodingAsUTF8: headerContents))

            // compile for each arch
            for arch in archs {
                let target = platform.targetTriple(arch, infoLookup: infoLookup)
                let targetVariant = platformVariant?.targetTriple(arch, infoLookup: infoLookup)
                let archDir = buildDir.join(arch)
                try fs.createDirectory(archDir, recursive: true)
                let objectPath = archDir.join("source.o")
                let machoPath = archDir.join(name)

                let targetVariantArgs = targetVariant.map { ["-target-variant", $0] } ?? []
                let linkerArgs = linkerOptions.map({ $0.args }).reduce([], +)
                _ = try await xcrun(["-sdk", platform.sdkName, "clang", "-target", target] + targetVariantArgs + ["-o", objectPath.str, "-c", sourcePath.str])
                if `static` {
                    machos.append(objectPath)
                } else if object {
                    _ = try await xcrun(["-sdk", platform.sdkName, "clang", "-r", "-target", target] + targetVariantArgs + linkerArgs + ["-o", machoPath.str, objectPath.str])
                    machos.append(machoPath)
                } else {
                    _ = try await xcrun(["-sdk", platform.sdkName, "clang", "-dynamiclib", "-target", target] + targetVariantArgs + linkerArgs + ["-o", machoPath.str, objectPath.str])
                    if needSigned {
                        _ = try await runProcessWithDeveloperDirectory(["/usr/bin/codesign", "-s", "-", machoPath.str])
                    }
                    machos.append(machoPath)
                }
            }
        }

        // Compute the path to the binary.
        let binaryPath = try bundleSubItem(name: name)

        if let only = machos.only, !alwaysLipo {
            try fs.copy(only, to: binaryPath)
        } else if `static` {
            _ = try await libtool(machos, into: binaryPath, usingSDK: platform.sdkName)
        } else {
            _ = try await lipo(machos, into: binaryPath, usingSDK: platform.sdkName)
        }

        return frameworkDir
    }

    @discardableResult package func compileExecutable(path basePath: Path, baseName: String = "sample", platform: BuildVersion.Platform, infoLookup: any PlatformInfoLookup, archs: [String], alwaysLipo: Bool = true, hideARM64: Bool = false, linkerOptions: [InstalledXcode.LinkerOption] = [], fs: any FSProxy = localFS) async throws -> Path {
        let buildDir = basePath.join("build")
        let srcDir = basePath.join("src")

        try fs.createDirectory(srcDir, recursive: true)
        try fs.createDirectory(buildDir, recursive: true)

        var machos = [String]()

        let sourcePath = srcDir.join("source.c")
        try fs.write(sourcePath, contents: "int main() { return 0; }\n")

        // compile for each arch
        for arch in archs {
            let target = platform.targetTriple(arch, infoLookup: infoLookup)
            let archDir = buildDir.join(arch)
            try fs.createDirectory(archDir, recursive: true)
            let objectPath = archDir.join("source.o")
            let machoPath = archDir.join("sample")

            let linkerArgs = linkerOptions.map({ $0.args }).reduce([], +)

            // don't pass target variant because only dylibs and bundles can be zippered (not executables)
            _ = try await xcrun(["-sdk", platform.sdkName, "clang", "-target", target] + ["-o", objectPath.str, "-c", sourcePath.str])
            _ = try await xcrun(["-sdk", platform.sdkName, "clang", "-target", target] + linkerArgs + ["-o", machoPath.str, objectPath.str])
            machos.append(machoPath.str)
        }

        if let only = machos.only, !alwaysLipo {
            return Path(only)
        }

        let machoPath = basePath.join(baseName)
        _ = try await xcrun(["-sdk", platform.sdkName, "lipo"]
                        .appending(contentsOf: hideARM64 ? ["-hideARM64"] : [])
                        .appending(contentsOf: ["-create"] + machos)
                        .appending(contentsOf: ["-output", machoPath.str]))

        return machoPath
    }

    /// Compiles and creates a dynamic library for the given parameters named `lib<baseName>.dylib`, where `baseName` defaults to `sample`.
    package func compileDynamicLibrary(path basePath: Path, baseName: String = "sample", platform: BuildVersion.Platform, infoLookup: any PlatformInfoLookup, platformVariant: BuildVersion.Platform? = nil, archs: [String], alwaysLipo: Bool = true, sourceContents: String? = nil, headerContents: String? = nil, useSwift: Bool = false, buildLibraryForDistribution: Bool = true, linkerOptions: [InstalledXcode.LinkerOption] = [], fs: any FSProxy = localFS) async throws -> Path {
        let buildDir = basePath.join("build")
        let srcDir = basePath.join("src")
        let machoPath = buildDir.join("lib\(baseName).dylib")

        try fs.createDirectory(srcDir, recursive: true)
        try fs.createDirectory(buildDir, recursive: true)

        var machos = [String]()

        if useSwift {
            let sourcePath = try createSampleSwiftCode(at: srcDir, sourceContents, fs: fs)

            // Create the path for our swiftmodule structure for the dynamic library.
            let headersDir = buildDir.join("include")
            let swiftModuleDir = try createSwiftModuleDir(at: headersDir, name: baseName, fs: fs)

            // compile for each arch
            for arch in archs {
                let macho = try await compileSwiftFile(name: baseName, platform: platform, infoLookup: infoLookup, platformVariant: platformVariant, arch: arch, sourcePath: sourcePath, buildDir: buildDir, swiftModuleDir: swiftModuleDir, buildLibraryForDistribution: buildLibraryForDistribution, static: false, linkerOptions: linkerOptions, workingDirectory: basePath, fs: fs, object: false, needSigned: false)
                machos.append(macho.str)
            }
        }
        else {
            let sourcePath = srcDir.join("source.c")
            let sourceContents = sourceContents ?? "int favorite() { return 0; }\n"
            try fs.write(sourcePath, contents: ByteString(encodingAsUTF8: sourceContents))

            let headersDir = buildDir.join("include")
            try fs.createDirectory(headersDir, recursive: true)
            let headerContents = headerContents ?? "int favorite();\n"
            try fs.write(headersDir.join("source.h"), contents: ByteString(encodingAsUTF8: headerContents))

            // compile for each arch
            for arch in archs {
                let target = platform.targetTriple(arch, infoLookup: infoLookup)
                let targetVariant = platformVariant?.targetTriple(arch, infoLookup: infoLookup)
                let archDir = buildDir.join(arch)
                try fs.createDirectory(archDir, recursive: true)
                let objectPath = archDir.join("source.o")
                let machoPath = archDir.join("sample")

                let targetVariantArgs = targetVariant.map { ["-target-variant", $0] } ?? []
                let linkerArgs = linkerOptions.map({ $0.args }).reduce([], +)
                _ = try await xcrun(["-sdk", platform.sdkName, "clang", "-target", target] + targetVariantArgs + ["-o", objectPath.str, "-c", sourcePath.str])
                _ = try await xcrun(["-sdk", platform.sdkName, "clang", "-dynamiclib", "-target", target] + targetVariantArgs + linkerArgs + ["-o", machoPath.str, objectPath.str])
                machos.append(machoPath.str)
            }
        }

        if let only = machos.only, !alwaysLipo {
            return Path(only)
        }

        _ = try await xcrun(["-sdk", platform.sdkName, "lipo", "-create"] + machos + ["-output", machoPath.str])

        return machoPath
    }

    // FIXME: re-enable when this is fixed and fix it for target-triples: <rdar://problem/47898659> MachO utilities cannot introspect static libraries
    //
    /// Compiles and creates a dynamic library for the given parameters named `lib<baseName>.a`, where `baseName` defaults to `sample`.
    package func compileStaticLibrary(path basePath: Path, baseName: String = "sample", platform: BuildVersion.Platform, infoLookup: any PlatformInfoLookup, platformVariant: BuildVersion.Platform? = nil, archs: [String], alwaysLipo: Bool = true, useSwift: Bool = false, omitBuildVersion: Bool = false, fs: any FSProxy = localFS) async throws -> Path {
        let buildDir = basePath.join("build")
        let srcDir = basePath.join("src")

        try fs.createDirectory(srcDir, recursive: true)
        try fs.createDirectory(buildDir, recursive: true)

        let sourcePath1 = srcDir.join("source1.c")
        let sourcePath2 = srcDir.join("source2.c")
        let archivePath = buildDir.join("lib\(baseName).a")

        try fs.write(sourcePath1, contents: "int favorite1() { return 0; }\n")
        try fs.write(sourcePath2, contents: "int favorite2() { return 0; }\n")

        var machos = [Path]()

        if useSwift {
            fatalError("generated Swift static libraries is not currently supported")
        }
        else {
            // Write out a basic header.
            let headersDir = buildDir.join("include")
            try fs.createDirectory(headersDir, recursive: true)
            try fs.write(headersDir.join("source.h"), contents: "int favorite1();\nint favorite2();\n")

            // compile for each arch
            for arch in archs {
                let target = platform.targetTriple(arch, infoLookup: infoLookup)
                let targetVariant = platformVariant?.targetTriple(arch, infoLookup: infoLookup)
                let archDir = buildDir.join(arch)
                try fs.createDirectory(archDir, recursive: true)
                let objectPath1 = archDir.join("source1.o")
                let objectPath2 = archDir.join("source2.o")

                let targetVariantArgs = targetVariant.map { ["-target-variant", $0] } ?? []
                _ = try await xcrun(["-sdk", platform.sdkName, "clang", "-target", target] + targetVariantArgs + ["-o", objectPath1.str, "-c", sourcePath1.str])
                _ = try await xcrun(["-sdk", platform.sdkName, "clang", "-target", target] + targetVariantArgs + ["-o", objectPath2.str, "-c", sourcePath2.str])
                machos.append(objectPath1)
                machos.append(objectPath2)
            }
        }

        if omitBuildVersion {
            for macho in machos {
                try await removeBuildVersion(binary: macho, platform: platform)
            }
        }

        if let only = machos.only, !alwaysLipo {
            return only
        }

        _ = try await xcrun(["-sdk", platform.sdkName, "libtool", "-static", "-o", archivePath.str] + machos.map { $0.str })

        return archivePath
    }

    package func libtool(_ inputs: [Path], into outputPath: Path, usingSDK sdk: String? = nil) async throws -> Path {
        let sdkArgs = sdk.map { ["-sdk", $0] } ?? []
        _ = try await xcrun(sdkArgs + ["libtool", "-static", "-o", outputPath.str] + inputs.map { $0.str })
        return outputPath
    }

    package func lipo(_ inputs: [Path], into outputPath: Path, usingSDK sdk: String? = nil) async throws -> Path {
        let sdkArgs = sdk.map { ["-sdk", $0] } ?? []

        // this is silly... broken up like this help Swift's type checker...
        let mappedInputs: [String] = inputs.map { $0.str } + ["-output", outputPath.str]
        _ = try await xcrun(sdkArgs + ["lipo", "-create"] + mappedInputs)
        return outputPath
    }

    package func removeBuildVersion(binary: Path, platform: BuildVersion.Platform) async throws {
        _ = try await xcrun(["vtool", "-remove-build-version", platform.rawValue.description, "-output", binary.str, binary.str])
    }
}

extension InstalledXcode {
    fileprivate func swiftRuntimeLibraryDirectoryPath(name: String) -> String {
        return "\(developerDirPath.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/\(name)"
    }
}

/// Convenience methods for marshaling platform information for library generation tasks in the `XCTestCase` extension above.
extension BuildVersion.Platform {
    package var sdkName: String {
        switch self {
        case .macOS, .macCatalyst:
            return "macosx"
        case .iOS:
            return "iphoneos"
        case .tvOS:
            return "appletvos"
        case .watchOS:
            return "watchos"
        case .xrOS:
            return "xros"
        case .iOSSimulator:
            return "iphonesimulator"
        case .tvOSSimulator:
            return "appletvsimulator"
        case .watchOSSimulator:
            return "watchsimulator"
        case .xrOSSimulator:
            return "xrsimulator"
        case .driverKit:
            return "driverkit"
        default:
            fatalError("sdkName not supported in test for this platform (\(self))")
        }
    }

    fileprivate func targetTriple(_ arch: String, infoLookup: any PlatformInfoLookup) -> String {
        switch self {
        case .macOS:
            return targetTripleString(arch: arch, deploymentTarget: Version(10, 15), infoLookup: infoLookup)
        case .macCatalyst:
            return targetTripleString(arch: arch, deploymentTarget: Version(13, 1), infoLookup: infoLookup)
        case .iOS, .iOSSimulator:
            // NOTE: legacy 32-bit architectures require building with a deployment target < iOS 11
            return targetTripleString(arch: arch, deploymentTarget: arch.contains("64") ? Version(13) : Version(10), infoLookup: infoLookup)
        case .tvOS, .tvOSSimulator:
            return targetTripleString(arch: arch, deploymentTarget: Version(13), infoLookup: infoLookup)
        case .watchOS, .watchOSSimulator:
            return targetTripleString(arch: arch, deploymentTarget: Version(6), infoLookup: infoLookup)
        case .xrOS, .xrOSSimulator:
            return targetTripleString(arch: arch, deploymentTarget: Version(1), infoLookup: infoLookup)
        case .driverKit:
            return targetTripleString(arch: arch, deploymentTarget: Version(19), infoLookup: infoLookup)
        default:
            fatalError("targetTriple not supported in test for this platform (\(self))")
        }
    }
}
