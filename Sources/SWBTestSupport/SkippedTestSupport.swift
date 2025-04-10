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

import class Foundation.FileManager
import class Foundation.ProcessInfo

package import SWBUtil
package import SWBCore
package import SWBProtocol
package import Testing
private import SWBLLBuild

package struct KnownSDK: ExpressibleByStringLiteral, Comparable, Sendable {
    package let sdkName: String

    package init(stringLiteral sdkName: String) {
        self.sdkName = sdkName
    }

    package static func < (lhs: KnownSDK, rhs: KnownSDK) -> Bool {
        lhs.sdkName < rhs.sdkName
    }
}

extension KnownSDK {
    package static var host: Self {
        switch Result(catching: { try ProcessInfo.processInfo.hostOperatingSystem() }) {
        case .success(.macOS):
            return macOS
        case .success(.iOS):
            return iOS
        case .success(.tvOS):
            return tvOS
        case .success(.watchOS):
            return watchOS
        case .success(.visionOS):
            return xrOS
        case .success(.windows):
            return windows
        case .success(.linux):
            return linux
        case .success(.android):
            return android
        case .success(.unknown), .failure:
            preconditionFailure("Unknown host platform")
        }
    }
}

extension KnownSDK {
    package static let macOS: Self = "macosx"
    package static let iOS: Self = "iphoneos"
    package static let tvOS: Self = "appletvos"
    package static let watchOS: Self = "watchos"
    package static let xrOS: Self = "xros"
    package static let driverKit: Self = "driverkit"
}

extension KnownSDK {
    package static let windows: Self = "windows"
    package static let linux: Self = "linux"
    package static let android: Self = "android"
    package static let qnx: Self = "qnx"
    package static let wasi: Self = "wasi"
}

package final class ConditionTraitContext: CoreBasedTests, Sendable {
    package static let shared = ConditionTraitContext()

    private enum LibclangState {
        case uninitialized
        case initialized(Libclang)
        case failed
    }

    private let _libclang = AsyncLockedValue<LibclangState>(.uninitialized)

    private init() {
    }

    package var libclang: Libclang? {
        get async throws {
            try await _libclang.withLock {
                switch $0 {
                case .uninitialized:
                    if let libclang = try await Libclang(path: libClangPath.str) {
                        $0 = .initialized(libclang)
                        libclang.leak()
                        return libclang
                    } else {
                        $0 = .failed
                        return nil
                    }
                case let .initialized(libclang):
                    return libclang
                case .failed:
                    return nil
                }
            }
        }
    }
}

extension Trait where Self == Testing.ConditionTrait {
    /// Skips a test case that requires one or more SDKs if they are not all available.
    package static func requireSDKs(_ knownSDKs: KnownSDK..., comment: Comment? = nil) -> Self {
        enabled(comment != nil ? "required SDKs are not installed: \(comment?.description ?? "")" : "required SDKs are not installed.", {
            let sdkRegistry = try await ConditionTraitContext.shared.getCore().sdkRegistry
            let missingSDKs = await knownSDKs.asyncFilter { knownSDK in
                sdkRegistry.lookup(knownSDK.sdkName) == nil && sdkRegistry.allSDKs.count(where: { $0.aliases.contains(knownSDK.sdkName) }) == 0
            }.sorted()
            return missingSDKs.isEmpty
        })
    }

    /// Constructs a condition trait that causes a test to be disabled if not running on the specified host OS.
    /// - parameter when: An additional constraint to apply such that the host OS requirement is only applied if this parameter is _also_ true. Defaults to true.
    package static func requireHostOS(_ os: OperatingSystem..., when condition: Bool = true) -> Self {
        enabled("This test requires a \(os) host OS.", { os.contains(try ProcessInfo.processInfo.hostOperatingSystem()) && condition })
    }

    /// Constructs a condition trait that causes a test to be disabled if running on the specified host OS.
    package static func skipHostOS(_ os: OperatingSystem, _ comment: Comment? = nil) -> Self {
        disabled(comment ?? "This test cannot run on a \(os) host OS.", { try ProcessInfo.processInfo.hostOperatingSystem() == os })
    }

    /// Constructs a condition trait that causes a test to be disabled if process spawning is unavailable (for example, on Apple embedded platforms).
    package static var requireProcessSpawning: Self {
        disabled("Process spawning is unavailable.", { try ProcessInfo.processInfo.hostOperatingSystem().isAppleEmbedded || ProcessInfo.processInfo.isMacCatalystApp })
    }

    /// Constructs a condition trait that causes a test to be disabled if the developer directory is pointing at an Xcode developer directory.
    package static var skipXcodeToolchain: Self {
        disabled("This test is incompatible with Xcode toolchains.", {
            try await ConditionTraitContext.shared.getCore().developerPath.path.str.contains(".app/Contents/Developer")
        })
    }

    /// Constructs a condition trait that causes a test to be disabled if the Foundation process spawning implementation is not using `posix_spawn_file_actions_addchdir`.
    package static var requireThreadSafeWorkingDirectory: Self {
        disabled("Thread-safe process working directory support is unavailable.", {
            switch try ProcessInfo.processInfo.hostOperatingSystem() {
            case .linux:
                // Amazon Linux 2 has glibc 2.26, and glibc 2.29 is needed for posix_spawn_file_actions_addchdir_np support
                FileManager.default.contents(atPath: "/etc/system-release").map { String(decoding: $0, as: UTF8.self) == "Amazon Linux release 2 (Karoo)\n" } ?? false
            default:
                false
            }
        })
    }

    /// Constructs a condition trait that causes a test to be disabled if the specified llbuild API version requirement is not met.
    package static func requireLLBuild(apiVersion version: Int32) -> Self {
        let llbuildVersion = llb_get_api_version()
        return disabled("llbuild version \(llbuildVersion) is too old (\(version) or later required)", { llbuildVersion < version })
    }

    package static var skipSwiftPackage: Self {
        #if SWIFT_PACKAGE
        return disabled("Test is not supported when building Swift Build as a package")
        #else
        return enabled(if: true)
        #endif
    }

    package static func requireClangFeatures(_ requiredFeatures: DiscoveredClangToolSpecInfo.FeatureFlag...) -> Self {
        enabled("Clang compiler does not support features: \(requiredFeatures)") {
            let features = try await ConditionTraitContext.shared.clangFeatures
            return requiredFeatures.allSatisfy { features.has($0) }
        }
    }

    package static func requireSwiftFeatures(_ requiredFeatures: DiscoveredSwiftCompilerToolSpecInfo.FeatureFlag...) -> Self {
        enabled("Swift compiler does not support features: \(requiredFeatures)") {
            let features = try await ConditionTraitContext.shared.swiftFeatures
            return requiredFeatures.allSatisfy { features.has($0) }
        }
    }

    package static func requireSDKImports() -> Self {
        enabled("Linker does not support SDK imports") {
            return try await ConditionTraitContext.shared.supportsSDKImports
        }
    }

    package static func requireLocalFileSystem(_ sdks: RunDestinationInfo...) -> Self {
        disabled("macOS SDK is on a remote filesystem") {
            let core = try await ConditionTraitContext.shared.getCore()
            return sdks.allSatisfy { localFS.isOnPotentiallyRemoteFileSystem(core.loadSDK($0).path) }
        }
    }

    package static func requireSystemPackages(apt: String..., yum: String..., sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        enabled("required system packages are not installed") {
            func checkInstalled(hostOS: OperatingSystem, packageManagerPath: Path, args: [String], packages: [String], regex: Regex<(Substring, name: Substring)>) async throws -> Bool {
                if try ProcessInfo.processInfo.hostOperatingSystem() == hostOS && localFS.exists(packageManagerPath) {
                    var installedPackages: Set<String> = []
                    for line in try await runProcess([packageManagerPath.str] + args + packages).split(separator: "\n") {
                        if let packageName = try regex.firstMatch(in: line)?.output.name {
                            installedPackages.insert(String(packageName))
                        }
                    }

                    let uninstalledPackages = Set(packages).subtracting(installedPackages)
                    if !uninstalledPackages.isEmpty {
                        Issue.record("system packages are missing. Install via `\(packageManagerPath.basenameWithoutSuffix) install \(uninstalledPackages.sorted().joined(separator: " "))`", sourceLocation: sourceLocation)
                        return false
                    }
                }

                return true
            }

            let apt = try await checkInstalled(hostOS: .linux, packageManagerPath: Path("/usr/bin/apt"), args: ["list", "--installed", "apt"], packages: apt, regex: #/(?<name>.+)\//#)

            // spelled `--installed` in newer versions of yum, but Amazon Linux 2 is on older versions
            let yum = try await checkInstalled(hostOS: .linux, packageManagerPath: Path("/usr/bin/yum"), args: ["list", "installed", "yum"], packages: yum, regex: #/(?<name>.+)\./#)

            return apt && yum
        }
    }

    package static func skipIfEnvironment(key: EnvironmentKey, value: String) -> Self {
        disabled("environment sets '\(key)' to '\(value)'") {
            getEnvironmentVariable(key) == value
        }
    }

    package static func skipIfEnvironmentVariableSet(key: EnvironmentKey) -> Self {
        disabled("environment sets '\(key)'") {
            getEnvironmentVariable(key) != nil
        }
    }
}

// MARK: Condition traits for Xcode and SDK version requirements
extension Trait where Self == Testing.ConditionTrait {
    /// Constructs a condition trait that causes a test to be disabled if running against the exact given version of Xcode.
    package static func skipXcodeBuildVersion(_ version: String, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        skipXcodeBuildVersions(in: try {
            let v: ProductBuildVersion = try ProductBuildVersion(version)
            return v...v
        }(), sourceLocation: sourceLocation)
    }

    /// Constructs a condition trait that causes a test to be disabled if running against the exact given version of Xcode.
    package static func skipXcodeBuildVersion(_ version: ProductBuildVersion, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        skipXcodeBuildVersions(in: version...version, sourceLocation: sourceLocation)
    }

    /// Constructs a condition trait that causes a test to be disabled if running against a version of Xcode within the given range.
    package static func skipXcodeBuildVersions<R: RangeExpression>(in range: @Sendable @autoclosure @escaping () throws -> R, sourceLocation: SourceLocation = #_sourceLocation) -> Self where R.Bound == ProductBuildVersion {
        disabled("Xcode version is not suitable", sourceLocation: sourceLocation, {
            return try await range().contains(InstalledXcode.currentlySelected().productBuildVersion())
        })
    }

    /// Constructs a condition trait that causes a test to be disabled if not running against at least the given version of Xcode.
    package static func requireMinimumXcodeBuildVersion(_ version: String, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        requireXcodeBuildVersions(in: try ProductBuildVersion(version)..., sourceLocation: sourceLocation)
    }

    package static func requireXcode16(sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        enabled("Xcode version is not suitable", sourceLocation: sourceLocation, {
            guard let installedVersion =  try? await InstalledXcode.currentlySelected().productBuildVersion() else {
                return true
            }
            return installedVersion > (try ProductBuildVersion("16A242d"))
        })
    }

    /// Constructs a condition trait that causes a test to be disabled if not running against at least the given version of Xcode.
    package static func requireMinimumXcodeBuildVersion(_ version: ProductBuildVersion, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        requireXcodeBuildVersions(in: version..., sourceLocation: sourceLocation)
    }

    /// Constructs a condition trait that causes a test to be disabled if not running against a version of Xcode within the given range.
    package static func requireXcodeBuildVersions<R: RangeExpression>(in range: @Sendable @autoclosure @escaping () throws -> R, sourceLocation: SourceLocation = #_sourceLocation) -> Self where R.Bound == ProductBuildVersion {
        enabled("Xcode version is not suitable", sourceLocation: sourceLocation, {
            return try await range().contains(InstalledXcode.currentlySelected().productBuildVersion())
        })
    }

    /// Constructs a condition trait that causes a test to be disabled if not running against a version of Xcode including at least the given version of a particular SDK.
    package static func requireMinimumSDKBuildVersion(sdkName: String, requiredVersion: String, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        requireMinimumSDKBuildVersion(sdkName: sdkName, requiredVersion: try ProductBuildVersion(requiredVersion), sourceLocation: sourceLocation)
    }

    /// Constructs a condition trait that causes a test to be disabled if not running against a version of Xcode including at least the given version of a particular SDK.
    package static func requireMinimumSDKBuildVersion(sdkName: String, requiredVersion: @Sendable @autoclosure @escaping () throws -> ProductBuildVersion, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        disabled("SDK build version is too old", sourceLocation: sourceLocation, {
            let sdkVersion = try await InstalledXcode.currentlySelected().productBuildVersion(sdkCanonicalName: sdkName)
            return try sdkVersion < requiredVersion()
        })
    }

    /// Constructs a condition trait that causes a test to be disabled if not running against a version of Xcode including the SDK which is equal to or newer than at least one of the given versions within the same release.
    package static func requireMinimumSDKBuildVersion(sdkName: String, requiredVersions: [String], sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        requireMinimumSDKBuildVersion(sdkName: sdkName, requiredVersions: try requiredVersions.map { try ProductBuildVersion($0) }, sourceLocation: sourceLocation)
    }

    /// Constructs a condition trait that causes a test to be disabled if not running against a version of Xcode including the SDK which is equal to or newer than at least one of the given versions within the same release.
    package static func requireMinimumSDKBuildVersion(sdkName: String, requiredVersions: @Sendable @autoclosure @escaping () throws -> [ProductBuildVersion], sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        disabled("SDK build version is too old", sourceLocation: sourceLocation, {
            let sdkVersion = try await InstalledXcode.currentlySelected().productBuildVersion(sdkCanonicalName: sdkName)

            // For each required version, check to see if it is from the same release as the SDK version.  If it is, then we will check against it.
            for requiredVersion in try requiredVersions() {
                if sdkVersion.major == requiredVersion.major, sdkVersion.train == requiredVersion.train {
                    return sdkVersion < requiredVersion
                }
            }

            // If the SDK version is not from the same release as any of required versions, then we assume we don't need to skip.  This is to handle the common case where we've moved on to newer releases and don't want to be forced to clean up these skips as soon as we do so.  It assumes we won't start running the test against older releases of the SDK.
            // We could do something more sophisticated here to handle versions outside of the specific releases we were passed, but this meets our needs for now.
            return false
        })
    }
}

extension Trait where Self == Testing.ConditionTrait {
    package static var skipDeveloperDirectoryWithEqualSign: Self {
        disabled {
            try await ConditionTraitContext.shared.getCore().developerPath.path.str.contains("=")
        }
    }

    package static var requireStructuredDiagnostics: Self {
        enabled("clang is too old to support structured scanner diagnostics") {
            try #require(try await ConditionTraitContext.shared.libclang).supportsStructuredDiagnostics
        }
    }

    package static var requireDependencyScanner: Self {
        disabled {
            let libclang = try #require(try await ConditionTraitContext.shared.libclang)

            do {
                let _ = try libclang.createScanner()
            } catch DependencyScanner.Error.featureUnsupported {
                // libclang at `libClangPath.str` does not have up-to-date dependency scanner (rdar://68233820)
                return true
            }

            return false
        }
    }

    package static var requireDependencyScannerWorkingDirectoryOptimization: Self {
        enabled {
            let libclang = try #require(try await ConditionTraitContext.shared.libclang)
            return libclang.supportsCurrentWorkingDirectoryOptimization
        }
    }

    package static var requireCompilationCaching: Self {
        enabled("compilation caching is not supported") {
            try await ConditionTraitContext.shared.supportsCompilationCaching
        }
    }

    package static var requireDependencyScannerPlusCaching: Self {
        disabled {
            let libclang = try #require(try await ConditionTraitContext.shared.libclang)

            return try withTemporaryDirectory { tmpDirPath in
                do {
                    let casOpts = try ClangCASOptions(libclang).setOnDiskPath(tmpDirPath.str)
                    let casDBs = try ClangCASDatabases(options: casOpts)
                    let _ = try libclang.createScanner(casDBs: casDBs)
                } catch DependencyScanner.Error.featureUnsupported {
                    // libclang at `libClangPath.str` does not have up-to-date dependency scanner (rdar://68233820)
                    return true
                } catch ClangCASDatabases.Error.featureUnsupported {
                    // libclang at `libClangPath.str` does not have up-to-date caching support (rdar://102786106)
                    return true
                }

                return false
            }
        }
    }

    package static var requireCASPlugin: Self {
        enabled("libclang does not support CAS plugins") { try await casOptions().canUseCASPlugin }
    }

    package static var requireCASUpToDate: Self {
        enabled("libclang does not support CAS up-to-date checks") { try await casOptions().canCheckCASUpToDate }
    }

    package static var requireLocalizedStringExtraction: Self {
        enabled("swift-driver does not support localized string extraction") {
            LibSwiftDriver.supportsDriverFlag(spelled: "-emit-localized-strings")
        }
    }
}

package func casOptions() async throws -> (canUseCASPlugin: Bool, canUseCASPruning: Bool, canCheckCASUpToDate: Bool) {
    let libclang = try #require(try await ConditionTraitContext.shared.libclang)
    let core = try await ConditionTraitContext.shared.getCore()
    let canUseCASPlugin = libclang.supportsCASPlugin && localFS.exists(core.developerPath.path.join("usr/lib/libToolchainCASPlugin.dylib"))
    let canUseCASPruning = libclang.supportsCASPruning
    let canCheckCASUpToDate = libclang.supportsCASUpToDateChecks
    return (canUseCASPlugin, canUseCASPruning, canCheckCASUpToDate)
}

extension Libclang {
    var supportsCASPlugin: Bool {
        do {
            let casOpts = try ClangCASOptions(self)
            casOpts.setPluginPath("/tmp")
            return true
        } catch ClangCASDatabases.Error.featureUnsupported {
            return false
        } catch {
            Issue.record("unexpected error: \(error)")
            return false
        }
    }
}

fileprivate enum XcodeVersionInfoProvider {
    case coreBasedTests(any CoreBasedTests)
    case installedXcode(InstalledXcode)
    case noXcode

    func xcodeProductBuildVersion() async throws -> ProductBuildVersion {
        switch self {
        case let .coreBasedTests(testCase):
            return try await testCase.getCore().xcodeProductBuildVersion
        case let .installedXcode(xcode):
            return try xcode.productBuildVersion()
        case .noXcode:
            return try ProductBuildVersion("99T999") // same fallback version that Core uses
        }
    }

    func sdkProductBuildVersion(canonicalName sdkName: String) async throws -> ProductBuildVersion {
        switch self {
        case let .coreBasedTests(testCase):
            guard let sdk = try await testCase.getCore().sdkRegistry.lookup(nameOrPath: sdkName, basePath: .root) else {
                throw StubError.error("couldn't lookup \(sdkName) SDK")
            }

            guard let sdkBuildVersion = try sdk.productBuildVersion.map({ try ProductBuildVersion($0) }) else {
                throw StubError.error("couldn't determine build version of \(sdkName) SDK")
            }

            return sdkBuildVersion
        case let .installedXcode(xcode):
            return try await xcode.productBuildVersion(sdkCanonicalName: sdkName)
        case .noXcode:
            throw StubError.error("couldn't determine build version of \(sdkName) SDK")
        }
    }

    func hasSDK(canonicalName sdkName: String) async -> Bool {
        switch self {
        case let .coreBasedTests(testCase):
            return await (try? testCase.getCore().sdkRegistry.lookup(sdkName)) != nil
        case let .installedXcode(xcode):
            return await xcode.hasSDK(sdkCanonicalName: sdkName)
        case .noXcode:
            return sdkName == KnownSDK.host.sdkName
        }
    }
}
