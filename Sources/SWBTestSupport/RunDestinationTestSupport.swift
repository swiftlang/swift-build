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

package import SWBCore
package import SWBProtocol
package import SWBUtil
import Foundation

/// This is a protocol to share the utilities in the below category between RunDestinationInfo in SWBProtocol.framework and SWBRunDestinationInfo in SwiftBuild.framework.
package protocol _RunDestinationInfo {
    init(platform: String, sdk: String, sdkVariant: String?, targetArchitecture: String, supportedArchitectures: [String], disableOnlyActiveArch: Bool)

    var platform: String { get }
    var sdk: String { get }
    var sdkVariant: String? { get }
}

extension _RunDestinationInfo {
    /// A generic run destination targeting macOS, using the public SDK.
    package static var anyMac: Self {
        return generic(sdk: "macosx", sdkVariant: "macos", supportedArchitectures: ["arm64", "arm64e", "x86_64", "x86_64h"])
    }

    /// A generic run destination targeting Mac Catalyst, using the public SDK.
    package static var anyMacCatalyst: Self {
        return generic(sdk: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName, supportedArchitectures: ["arm64", "arm64e", "x86_64", "x86_64h"])
    }

    /// A generic run destination targeting iOS, using the public SDK.
    package static var anyiOSDevice: Self {
        return generic(sdk: "iphoneos", supportedArchitectures: ["arm64", "arm64e", "armv7", "armv7s"])
    }

    /// A generic run destination targeting iOS Simulator, using the public SDK.
    package static var anyiOSSimulator: Self {
        return generic(sdk: "iphonesimulator", supportedArchitectures: ["arm64", "i386", "x86_64"])
    }

    /// A generic run destination targeting tvOS, using the public SDK.
    package static var anytvOSDevice: Self {
        return generic(sdk: "appletvos", supportedArchitectures: ["arm64", "arm64e"])
    }

    /// A generic run destination targeting tvOS Simulator, using the public SDK.
    package static var anytvOSSimulator: Self {
        return generic(sdk: "appletvsimulator", supportedArchitectures: ["arm64", "x86_64"])
    }

    /// A generic run destination targeting watchOS, using the public SDK.
    package static var anywatchOSDevice: Self {
        return generic(sdk: "watchos", supportedArchitectures: ["arm64_32", "armv7k"])
    }

    /// A generic run destination targeting watchOS Simulator, using the public SDK.
    package static var anywatchOSSimulator: Self {
        return generic(sdk: "watchsimulator", supportedArchitectures: ["arm64", "i386", "x86_64"])
    }

    /// A generic run destination targeting xrOS, using the public SDK.
    package static var anyxrOSDevice: Self {
        return generic(sdk: "xros", supportedArchitectures: ["arm64", "arm64e"])
    }

    /// A generic run destination targeting xrOS Simulator, using the public SDK.
    package static var anyxrOSSimulator: Self {
        return generic(sdk: "xrsimulator", supportedArchitectures: ["arm64", "x86_64"])
    }

    /// A generic run destination targeting DriverKit, using the public SDK.
    package static var anyDriverKit: Self {
        return generic(sdk: "driverkit", supportedArchitectures: ["arm64", "arm64e", "x86_64", "x86_64h"])
    }
}

extension _RunDestinationInfo {
    static func destination(operatingSystem: OperatingSystem) -> Self {
        switch operatingSystem {
        case .macOS:
            macOS
        case .iOS(let simulator):
            simulator ? iOSSimulator : iOS
        case .tvOS(let simulator):
            simulator ? tvOSSimulator : tvOS
        case .watchOS(let simulator):
            simulator ? watchOSSimulator : watchOS
        case .visionOS(let simulator):
            simulator ? xrOSSimulator : xrOS
        case .windows:
            windows
        case .linux:
            linux
        case .android:
            android
        case .unknown:
            preconditionFailure("Unknown platform")
        }
    }
}

extension _RunDestinationInfo {
    /// A run destination targeting the host platform.
    package static var host: Self {
        try! destination(operatingSystem: ProcessInfo.processInfo.hostOperatingSystem())
    }

    /// A run destination targeting macOS, using the public SDK.
    package static var macOS: Self {
        #if os(macOS)
        switch Architecture.host.stringValue {
        case "arm64":
            // FIXME: <rdar://78361860> Use results.runDestinationTargetArchitecture in our tests where appropriate so that this works
            fallthrough // return macOSAppleSilicon
        case "x86_64":
            return macOSIntel
        default:
            preconditionFailure("Unknown architecture \(Architecture.host.stringValue ?? "<nil>")")
        }
        #else
        return macOSIntel
        #endif
    }

    /// A run destination targeting macOS running on Intel, using the public SDK.
    package static var macOSIntel: Self {
        return .init(platform: "macosx", sdk: "macosx", sdkVariant: "macos", targetArchitecture: "x86_64", supportedArchitectures: ["x86_64h", "x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting macOS running on Intel (Haswell), using the public SDK.
    package static var macOSIntelHaswell: Self {
        return .init(platform: "macosx", sdk: "macosx", sdkVariant: "macos", targetArchitecture: "x86_64h", supportedArchitectures: ["x86_64h", "x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting macOS running on Apple Silicon, using the public SDK.
    package static var macOSAppleSilicon: Self {
        return .init(platform: "macosx", sdk: "macosx", sdkVariant: "macos", targetArchitecture: "arm64", supportedArchitectures: ["arm64", "x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting macOS (Mac Catalyst), using the public SDK.
    package static var macCatalyst: Self {
        #if os(macOS)
        switch Architecture.host.stringValue {
        case "arm64":
            // FIXME: <rdar://78361860> Use results.runDestinationTargetArchitecture in our tests where appropriate so that this works
            fallthrough // return macCatalystAppleSilicon
        case "x86_64":
            return macCatalystIntel
        default:
            preconditionFailure("Unknown architecture \(Architecture.host.stringValue ?? "<nil>")")
        }
        #else
        return macCatalystIntel
        #endif
    }

    /// A run destination targeting macOS (Mac Catalyst) running on Intel, using the public SDK.
    package static var macCatalystIntel: Self {
        return .init(platform: "macosx", sdk: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName, targetArchitecture: "x86_64", supportedArchitectures: ["x86_64h", "x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting macOS (Mac Catalyst) running on Intel (Haswell), using the public SDK.
    package static var macCatalystIntelHaswell: Self {
        return .init(platform: "macosx", sdk: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName, targetArchitecture: "x86_64h", supportedArchitectures: ["x86_64h", "x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting macOS (Mac Catalyst) running on Apple Silicon, using the public SDK.
    package static var macCatalystAppleSilicon: Self {
        return .init(platform: "macosx", sdk: "macosx", sdkVariant: MacCatalystInfo.sdkVariantName, targetArchitecture: "arm64", supportedArchitectures: ["arm64", "x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting iOS generic device, using the public SDK.
    package static var iOS: Self {
        return .init(platform: "iphoneos", sdk: "iphoneos", sdkVariant: "iphoneos", targetArchitecture: "arm64", supportedArchitectures: ["arm64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting iOS Simulator generic device, using the public SDK.
    package static var iOSSimulator: Self {
        return .init(platform: "iphonesimulator", sdk: "iphonesimulator", sdkVariant: "iphonesimulator", targetArchitecture: "x86_64", supportedArchitectures: ["x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting watchOS generic device, using the public SDK.
    package static var watchOS: Self {
        return .init(platform: "watchos", sdk: "watchos", sdkVariant: "watchos", targetArchitecture: "arm64_32", supportedArchitectures: ["arm64_32"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting watchOS Simulator generic device, using the public SDK.
    package static var watchOSSimulator: Self {
        return .init(platform: "watchsimulator", sdk: "watchsimulator", sdkVariant: "watchsimulator", targetArchitecture: "x86_64", supportedArchitectures: ["x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting tvOS generic device, using the public SDK.
    package static var tvOS: Self {
        return .init(platform: "appletvos", sdk: "appletvos", sdkVariant: "appletvos", targetArchitecture: "arm64", supportedArchitectures: ["arm64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting tvOS Simulator generic device, using the public SDK.
    package static var tvOSSimulator: Self {
        return .init(platform: "appletvsimulator", sdk: "appletvsimulator", sdkVariant: "appletvsimulator", targetArchitecture: "x86_64", supportedArchitectures: ["x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting xrOS generic device, using the public SDK.
    package static var xrOS: Self {
        return .init(platform: "xros", sdk: "xros", sdkVariant: "xros", targetArchitecture: "arm64", supportedArchitectures: ["arm64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting xrOS Simulator generic device, using the public SDK.
    package static var xrOSSimulator: Self {
        return .init(platform: "xrsimulator", sdk: "xrsimulator", sdkVariant: "xrsimulator", targetArchitecture: "x86_64", supportedArchitectures: ["x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting DriverKit, using the public SDK.
    package static var driverKit: Self {
        #if os(macOS)
        switch Architecture.host.stringValue {
        case "arm64":
            // FIXME: <rdar://78361860> Use results.runDestinationTargetArchitecture in our tests where appropriate so that this works
            fallthrough // return driverKitAppleSilicon
        case "x86_64":
            return driverKitIntel
        default:
            preconditionFailure("Unknown architecture \(Architecture.host.stringValue ?? "<nil>")")
        }
        #else
        return driverKitIntel
        #endif
    }

    /// A run destination targeting DriverKit for an Intel host, using the public SDK.
    package static var driverKitIntel: Self {
        return .init(platform: "driverkit", sdk: "driverkit", sdkVariant: "driverkit", targetArchitecture: "x86_64", supportedArchitectures: ["x86_64h", "x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting DriverKit for an Apple Silicon host, using the public SDK.
    package static var driverKitAppleSilicon: Self {
        return .init(platform: "driverkit", sdk: "driverkit", sdkVariant: "driverkit", targetArchitecture: "arm64", supportedArchitectures: ["arm64", "x86_64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting Windows generic device, using the public SDK.
    package static var windows: Self {
        guard let arch = Architecture.hostStringValue  else {
            preconditionFailure("Unknown architecture \(Architecture.host.stringValue ?? "<nil>")")
        }
        return .init(platform: "windows", sdk: "windows", sdkVariant: "windows", targetArchitecture: arch, supportedArchitectures: ["x86_64, aarch64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting Linux generic device, using the public SDK.
    package static var linux: Self {
        guard let arch = Architecture.hostStringValue  else {
            preconditionFailure("Unknown architecture \(Architecture.host.stringValue ?? "<nil>")")
        }
        return .init(platform: "linux", sdk: "linux", sdkVariant: "linux", targetArchitecture: arch, supportedArchitectures: ["x86_64", "aarch64"], disableOnlyActiveArch: false)
    }

    /// A run destination targeting Android generic device, using the public SDK.
    package static var android: Self {
        return .init(platform: "android", sdk: "android", sdkVariant: "android", targetArchitecture: "undefined_arch", supportedArchitectures: ["armv7", "aarch64", "riscv64", "i686", "x86_64"], disableOnlyActiveArch: true)
    }

    /// A run destination targeting QNX generic device, using the public SDK.
    package static var qnx: Self {
        return .init(platform: "qnx", sdk: "qnx", sdkVariant: "qnx", targetArchitecture: "undefined_arch", supportedArchitectures: ["aarch64", "x86_64"], disableOnlyActiveArch: true)
    }

    /// A run destination targeting WebAssembly/WASI generic device, using the public SDK.
    package static var wasm: Self {
        return .init(platform: "webassembly", sdk: "webassembly", sdkVariant: "webassembly", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: true)
    }
}

extension RunDestinationInfo {
    /// Returns the Mach-O platform corresponding to the run destination's target.
    ///
    /// - note: Returns `nil` for non-Mach-O platforms such as Linux.
    package func buildVersionPlatform(_ core: Core) -> BuildVersion.Platform? {
        guard let sdk = try? core.sdkRegistry.lookup(sdk, activeRunDestination: self) else { return nil }
        return sdk.targetBuildVersionPlatform(sdkVariant: sdkVariant.map { sdkVariant in sdk.variant(for: sdkVariant) } ?? sdk.defaultVariant)
    }

    package func imageFormat(_ core: Core) -> ImageFormat {
        switch platform {
        case "webassembly":
            fatalError("not implemented")
        case "windows":
            return .pe
        case _ where buildVersionPlatform(core) != nil:
            return .macho
        default:
            return .elf
        }
    }
}

extension _RunDestinationInfo {
    package var platformFilterString: String {
        switch platform {
        case "macosx" where sdkVariant == MacCatalystInfo.sdkVariantName:
            return "ios-macabi"
        case "macosx":
            return "macos"

        // We effectively treat the simulator build target the same as the corresponding device platform.
        // See initializer `PlatformFilter.init?(: MacroEvaluationScope)` for further information.
        case "iphoneos", "iphonesimulator":
            return "ios"
        case "appletvos", "appletvsimulator":
            return "tvos"
        case "watchsimulator":
            return "watchos"
        case "xros", "xrsimulator":
            return "xros"

        case "windows":
            return "windows-msvc"
        case "linux":
            return "linux-gnu"
        default:
            return platform // watchOS, DriverKit
        }
    }

    package var builtProductsDirSuffix: String {
        switch platform {
        case "macosx" where sdk == "macosx" && sdkVariant == MacCatalystInfo.sdkVariantName:
            return MacCatalystInfo.publicSDKBuiltProductsDirSuffix
        case "macosx":
            return ""
        default:
            return "-\(platform)"
        }
    }
}

extension _RunDestinationInfo {
    fileprivate static func generic(sdk: String, sdkVariant: String? = nil, supportedArchitectures: [String]) -> Self {
        return Self.init(platform: sdk, sdk: sdk, sdkVariant: sdkVariant ?? sdk, targetArchitecture: "undefined_arch", supportedArchitectures: supportedArchitectures, disableOnlyActiveArch: true)
    }
}

extension RunDestinationInfo: _RunDestinationInfo {
    package init(platform: String, sdk: String, sdkVariant: String?, targetArchitecture: String, supportedArchitectures: [String], disableOnlyActiveArch: Bool) {
        self.init(platform: platform, sdk: sdk, sdkVariant: sdkVariant, targetArchitecture: targetArchitecture, supportedArchitectures: OrderedSet(supportedArchitectures), disableOnlyActiveArch: disableOnlyActiveArch, hostTargetedPlatform: nil)
    }
}
