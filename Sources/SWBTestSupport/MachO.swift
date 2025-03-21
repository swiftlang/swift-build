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

extension MachO.Slice {
    package func targetTripleStrings(infoLookup: any PlatformInfoLookup) throws -> [String] {
        #if canImport(Darwin)
        return try buildVersions().map { $0.targetTripleString(arch: self.arch, infoLookup: infoLookup) }
        #else
        throw BinaryReaderError.parseError("Mach-O parsing not supported on this platform")
        #endif
    }
}

extension BuildVersion {
    /// Creates an LLVM target triple string for the build version info, given the architecture, and using the `minos` value as the version part of the OS field.
    package func targetTripleString(arch: String, infoLookup: any PlatformInfoLookup) -> String {
        return platform.targetTripleString(arch: arch, deploymentTarget: minOSVersion, infoLookup: infoLookup)
    }
}

extension BuildVersion.Platform {
    /// The vendor of the platform, suitable for use as the OS field of an LLVM target triple.
    package func vendor(infoLookup: any PlatformInfoLookup) -> String {
        switch self {
        case .macOS, .iOS, .iOSSimulator, .macCatalyst, .tvOS, .tvOSSimulator, .watchOS, .watchOSSimulator, .xrOS, .xrOSSimulator, .driverKit:
            return "apple"
        default:
            return infoLookup.lookupPlatformInfo(platform: self)?.llvmTargetTripleVendor ?? "unknown"
        }
    }

    /// The name of the platform, suitable for use as the OS field of an LLVM target triple.
    package func name(infoLookup: any PlatformInfoLookup) -> String {
        switch self {
        case .macOS:
            return "macos"
        case .iOS, .iOSSimulator, .macCatalyst:
            return "ios"
        case .tvOS, .tvOSSimulator:
            return "tvos"
        case .watchOS, .watchOSSimulator:
            return "watchos"
        case .xrOS, .xrOSSimulator:
            return "xros"
        case .driverKit:
            return "driverkit"
        default:
            guard let llvmTargetTripleSys = infoLookup.lookupPlatformInfo(platform: self)?.llvmTargetTripleSys else {
                  fatalError("external Mach-O based platform \(self) must provide a llvmTargetTripleSys value")
            }
            return llvmTargetTripleSys
        }
    }

    /// The variant of the platform, suitable for use as the environment field of an LLVM target triple.
    ///
    /// - returns: `nil` if the platform has no associated environment value.
    package func environment(infoLookup: any PlatformInfoLookup) -> String? {
        switch self {
        case .macCatalyst:
            return "macabi"
        case .iOSSimulator, .tvOSSimulator, .watchOSSimulator, .xrOSSimulator:
            return "simulator"
        default:
            guard let environment = infoLookup.lookupPlatformInfo(platform: self)?.llvmTargetTripleEnvironment, !environment.isEmpty else {
                return nil
            }
            if environment == "macabi" {
                // Only ".macCatalyst" should return this (e.g. macOS technically specifies its environment as "macabi" but we don't report that)
                return nil
            }
            return environment
        }
    }

    /// Creates an LLVM target triple string for the platform, given the architecture and deployment target, and the platform info lookup
    package func targetTripleString(arch: String, deploymentTarget: Version?, infoLookup: any PlatformInfoLookup) -> String {
        return [arch, vendor(infoLookup: infoLookup), name(infoLookup: infoLookup) + (deploymentTarget?.canonicalDeploymentTargetForm.description ?? ""), environment(infoLookup: infoLookup)].compactMap { $0 }.joined(separator: "-")
    }
}
