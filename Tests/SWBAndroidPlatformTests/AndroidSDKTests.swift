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
@_spi(Testing) import SWBAndroidPlatform
import SWBTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct AndroidSDKTests {
    @Test func findInstallations() async throws {
        let host = try ProcessInfo.processInfo.hostOperatingSystem()
        let installations = try await AndroidSDK.findInstallations(host: host, fs: localFS)
        // It's OK if `installations` is an empty set, the host system might have no Android SDK/NDK installed
        for installation in installations {
            #expect(installation.host == host)
            #expect(installation.latestNDK == installation.ndks.last)
        }
    }

    @Test func abis_r22() async throws {
        try await withNDKVersion(version: Version("22.1.7171670")) { host, fs, ndkVersionPath in
            let error = #expect(throws: StubError.self) {
                try AndroidSDK.NDK.findInstallations(host: host, sdkPath: ndkVersionPath.dirname.dirname, fs: fs)
            }
            #expect(error?.description == "Android NDK version at path '\(ndkVersionPath.str)' is not supported (r23 or later required)")
        }
    }

    @Test func abis_r26_3() async throws {
        try await withNDKVersion(version: Version("26.3.11579264")) { host, fs, ndkVersionPath in
            try await fs.writeFileContents(ndkVersionPath.join("meta").join("abis.json")) { contents in
                contents <<<
                """
                {
                    "armeabi-v7a": {
                        "bitness": 32,
                        "default": true,
                        "deprecated": false,
                        "proc": "armv7-a",
                        "arch": "arm",
                        "triple": "arm-linux-androideabi",
                        "llvm_triple": "armv7-none-linux-androideabi"
                    },
                    "arm64-v8a": {
                        "bitness": 64,
                        "default": true,
                        "deprecated": false,
                        "proc": "aarch64",
                        "arch": "arm64",
                        "triple": "aarch64-linux-android",
                        "llvm_triple": "aarch64-none-linux-android"
                    },
                    "x86": {
                        "bitness": 32,
                        "default": true,
                        "deprecated": false,
                        "proc": "i686",
                        "arch": "x86",
                        "triple": "i686-linux-android",
                        "llvm_triple": "i686-none-linux-android"
                    },
                    "x86_64": {
                        "bitness": 64,
                        "default": true,
                        "deprecated": false,
                        "proc": "x86_64",
                        "arch": "x86_64",
                        "triple": "x86_64-linux-android",
                        "llvm_triple": "x86_64-none-linux-android"
                    }
                }
                """
            }

            try await fs.writeFileContents(ndkVersionPath.join("meta").join("platforms.json")) { contents in
                contents <<<
                """
                {
                    "min": 21,
                    "max": 34,
                    "aliases": {
                        "20": 19,
                        "25": 24,
                        "J": 16,
                        "J-MR1": 17,
                        "J-MR2": 18,
                        "K": 19,
                        "L": 21,
                        "L-MR1": 22,
                        "M": 23,
                        "N": 24,
                        "N-MR1": 24,
                        "O": 26,
                        "O-MR1": 27,
                        "P": 28,
                        "Q": 29,
                        "R": 30,
                        "S": 31,
                        "Sv2": 32,
                        "Tiramisu": 33,
                        "UpsideDownCake": 34
                    }
                }
                """
            }

            let installations = try AndroidSDK.NDK.findInstallations(host: host, sdkPath: ndkVersionPath.dirname.dirname, fs: fs)
            let installation = try #require(installations.only)
            #expect(installation.host == host)
            #expect(installation.path == ndkVersionPath)
            #expect(try installation.version == Version("26.3.11579264"))
            #expect(installation.deploymentTargetRange.min == 21)
            #expect(installation.deploymentTargetRange.max == 34)

            #expect(installation.abis.count == 4)

            let armv7 = try #require(installation.abis["armeabi-v7a"])
            #expect(armv7.bitness == .bits32)
            #expect(armv7.default == true)
            #expect(armv7.deprecated == false)
            #expect(armv7.proc == "armv7-a")
            #expect(armv7.arch == "arm")
            #expect(armv7.triple == "arm-linux-androideabi")
            #expect(armv7.llvm_triple.arch == "armv7")
            #expect(armv7.llvm_triple.vendor == "none")
            #expect(armv7.llvm_triple.system == "linux")
            #expect(armv7.llvm_triple.environment == "androideabi")
            #expect(armv7.min_os_version == 21)

            let arm64 = try #require(installation.abis["arm64-v8a"])
            #expect(arm64.bitness == .bits64)
            #expect(arm64.default == true)
            #expect(arm64.deprecated == false)
            #expect(arm64.proc == "aarch64")
            #expect(arm64.arch == "arm64")
            #expect(arm64.triple == "aarch64-linux-android")
            #expect(arm64.llvm_triple.arch == "aarch64")
            #expect(arm64.llvm_triple.vendor == "none")
            #expect(arm64.llvm_triple.system == "linux")
            #expect(arm64.llvm_triple.environment == "android")
            #expect(arm64.min_os_version == 21)

            let x86 = try #require(installation.abis["x86"])
            #expect(x86.bitness == .bits32)
            #expect(x86.default == true)
            #expect(x86.deprecated == false)
            #expect(x86.proc == "i686")
            #expect(x86.arch == "x86")
            #expect(x86.triple == "i686-linux-android")
            #expect(x86.llvm_triple.arch == "i686")
            #expect(x86.llvm_triple.vendor == "none")
            #expect(x86.llvm_triple.system == "linux")
            #expect(x86.llvm_triple.environment == "android")
            #expect(x86.min_os_version == 21)

            let x86_64 = try #require(installation.abis["x86_64"])
            #expect(x86_64.bitness == .bits64)
            #expect(x86_64.default == true)
            #expect(x86_64.deprecated == false)
            #expect(x86_64.proc == "x86_64")
            #expect(x86_64.arch == "x86_64")
            #expect(x86_64.triple == "x86_64-linux-android")
            #expect(x86_64.llvm_triple.arch == "x86_64")
            #expect(x86_64.llvm_triple.vendor == "none")
            #expect(x86_64.llvm_triple.system == "linux")
            #expect(x86_64.llvm_triple.environment == "android")
            #expect(x86_64.min_os_version == 21)
        }
    }

    @Test func abis_r27() async throws {
        try await withNDKVersion(version: Version("27.0.11718014")) { host, fs, ndkVersionPath in
            try await fs.writeFileContents(ndkVersionPath.join("meta").join("abis.json")) { contents in
                contents <<<
                """
                {
                    "armeabi-v7a": {
                        "bitness": 32,
                        "default": true,
                        "deprecated": false,
                        "proc": "armv7-a",
                        "arch": "arm",
                        "triple": "arm-linux-androideabi",
                        "llvm_triple": "armv7-none-linux-androideabi",
                        "min_os_version": 21
                    },
                    "arm64-v8a": {
                        "bitness": 64,
                        "default": true,
                        "deprecated": false,
                        "proc": "aarch64",
                        "arch": "arm64",
                        "triple": "aarch64-linux-android",
                        "llvm_triple": "aarch64-none-linux-android",
                        "min_os_version": 21
                    },
                    "riscv64": {
                        "bitness": 64,
                        "default": false,
                        "deprecated": false,
                        "proc": "riscv64",
                        "arch": "riscv64",
                        "triple": "riscv64-linux-android",
                        "llvm_triple": "riscv64-none-linux-android",
                        "min_os_version": 35
                    },
                    "x86": {
                        "bitness": 32,
                        "default": true,
                        "deprecated": false,
                        "proc": "i686",
                        "arch": "x86",
                        "triple": "i686-linux-android",
                        "llvm_triple": "i686-none-linux-android",
                        "min_os_version": 21
                    },
                    "x86_64": {
                        "bitness": 64,
                        "default": true,
                        "deprecated": false,
                        "proc": "x86_64",
                        "arch": "x86_64",
                        "triple": "x86_64-linux-android",
                        "llvm_triple": "x86_64-none-linux-android",
                        "min_os_version": 21
                    }
                }
                """
            }

            try await fs.writeFileContents(ndkVersionPath.join("meta").join("platforms.json")) { contents in
                contents <<<
                """
                {
                    "min": 21,
                    "max": 35,
                    "aliases": {
                        "20": 19,
                        "25": 24,
                        "J": 16,
                        "J-MR1": 17,
                        "J-MR2": 18,
                        "K": 19,
                        "L": 21,
                        "L-MR1": 22,
                        "M": 23,
                        "N": 24,
                        "N-MR1": 24,
                        "O": 26,
                        "O-MR1": 27,
                        "P": 28,
                        "Q": 29,
                        "R": 30,
                        "S": 31,
                        "Sv2": 32,
                        "Tiramisu": 33,
                        "UpsideDownCake": 34,
                        "VanillaIceCream": 35
                    }
                }
                """
            }

            let installations = try AndroidSDK.NDK.findInstallations(host: host, sdkPath: ndkVersionPath.dirname.dirname, fs: fs)
            let installation = try #require(installations.only)
            #expect(installation.host == host)
            #expect(installation.path == ndkVersionPath)
            #expect(try installation.version == Version("27.0.11718014"))
            #expect(installation.deploymentTargetRange.min == 21)
            #expect(installation.deploymentTargetRange.max == 35)

            #expect(installation.abis.count == 5)

            let armv7 = try #require(installation.abis["armeabi-v7a"])
            #expect(armv7.bitness == .bits32)
            #expect(armv7.default == true)
            #expect(armv7.deprecated == false)
            #expect(armv7.proc == "armv7-a")
            #expect(armv7.arch == "arm")
            #expect(armv7.triple == "arm-linux-androideabi")
            #expect(armv7.llvm_triple.arch == "armv7")
            #expect(armv7.llvm_triple.vendor == "none")
            #expect(armv7.llvm_triple.system == "linux")
            #expect(armv7.llvm_triple.environment == "androideabi")
            #expect(armv7.min_os_version == 21)

            let arm64 = try #require(installation.abis["arm64-v8a"])
            #expect(arm64.bitness == .bits64)
            #expect(arm64.default == true)
            #expect(arm64.deprecated == false)
            #expect(arm64.proc == "aarch64")
            #expect(arm64.arch == "arm64")
            #expect(arm64.triple == "aarch64-linux-android")
            #expect(arm64.llvm_triple.arch == "aarch64")
            #expect(arm64.llvm_triple.vendor == "none")
            #expect(arm64.llvm_triple.system == "linux")
            #expect(arm64.llvm_triple.environment == "android")
            #expect(arm64.min_os_version == 21)

            let riscv64 = try #require(installation.abis["riscv64"])
            #expect(riscv64.bitness == .bits64)
            #expect(riscv64.default == false)
            #expect(riscv64.deprecated == false)
            #expect(riscv64.proc == "riscv64")
            #expect(riscv64.arch == "riscv64")
            #expect(riscv64.triple == "riscv64-linux-android")
            #expect(riscv64.llvm_triple.arch == "riscv64")
            #expect(riscv64.llvm_triple.vendor == "none")
            #expect(riscv64.llvm_triple.system == "linux")
            #expect(riscv64.llvm_triple.environment == "android")
            #expect(riscv64.min_os_version == 35)

            let x86 = try #require(installation.abis["x86"])
            #expect(x86.bitness == .bits32)
            #expect(x86.default == true)
            #expect(x86.deprecated == false)
            #expect(x86.proc == "i686")
            #expect(x86.arch == "x86")
            #expect(x86.triple == "i686-linux-android")
            #expect(x86.llvm_triple.arch == "i686")
            #expect(x86.llvm_triple.vendor == "none")
            #expect(x86.llvm_triple.system == "linux")
            #expect(x86.llvm_triple.environment == "android")
            #expect(x86.min_os_version == 21)

            let x86_64 = try #require(installation.abis["x86_64"])
            #expect(x86_64.bitness == .bits64)
            #expect(x86_64.default == true)
            #expect(x86_64.deprecated == false)
            #expect(x86_64.proc == "x86_64")
            #expect(x86_64.arch == "x86_64")
            #expect(x86_64.triple == "x86_64-linux-android")
            #expect(x86_64.llvm_triple.arch == "x86_64")
            #expect(x86_64.llvm_triple.vendor == "none")
            #expect(x86_64.llvm_triple.system == "linux")
            #expect(x86_64.llvm_triple.environment == "android")
            #expect(x86_64.min_os_version == 21)
        }
    }

    private func withNDKVersion(version: Version, _ block: (OperatingSystem, any FSProxy, Path) async throws -> ()) async throws {
        let fs = PseudoFS()
        let ndkPath = Path.root.join("ndk")
        let ndkVersionPath = ndkPath.join(version.description)
        try fs.createDirectory(ndkPath, recursive: true)
        try fs.createDirectory(ndkVersionPath.join("meta"), recursive: true)
        let host = try ProcessInfo.processInfo.hostOperatingSystem()
        try await block(host, fs, ndkVersionPath)
    }
}
