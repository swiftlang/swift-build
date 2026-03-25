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

import Testing
import SWBUtil
import SwiftBuild
import SWBBuildService
import SWBTestSupport

@Suite(.skipHostOS(.windows))
fileprivate struct BuildServiceTests: CoreBasedTests {
    @Test func createXCFramework() async throws {
        do {
            let (result, message) = try await withBuildService { await $0.createXCFramework([], currentWorkingDirectory: Path.root.str, developerPath: nil) }
            #expect(!result)
            #expect(message == "error: at least one framework or library must be specified.\n")
        }

        do {
            let (result, message) = try await withBuildService { await $0.createXCFramework(["createXCFramework"], currentWorkingDirectory: Path.root.str, developerPath: nil) }
            #expect(!result)
            #expect(message == "error: at least one framework or library must be specified.\n")
        }

        do {
            let (result, message) = try await withBuildService { await $0.createXCFramework(["createXCFramework", "-help"], currentWorkingDirectory: Path.root.str, developerPath: nil) }
            #expect(result)
            #expect(message.starts(with: "OVERVIEW: Utility for packaging multiple build configurations of a given library or framework into a single xcframework."))
        }
    }

    @Test func macCatalystSupportsProductTypes() async throws {
        #expect(try await withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "com.apple.product-type.application") })
        #expect(try await withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "com.apple.product-type.framework") })
        #expect(try await !withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "com.apple.product-type.application.on-demand-install-capable") })

        // False on non-existent product types
        #expect(try await !withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "doesnotexist") })

        // Error on spec identifiers which aren't product types
        await #expect(throws: (any Error).self) {
            try await withBuildService { try await $0.productTypeSupportsMacCatalyst(developerPath: nil, productTypeIdentifier: "com.apple.package-type.wrapper") }
        }
    }

    @Test(arguments: [
        // Apple platforms
        .init(triple: "arm64-apple-macos15.0", platformName: "macosx", sdkVariant: nil, deploymentTargetSettingName: "MACOSX_DEPLOYMENT_TARGET", deploymentTarget: "15.0"),
        .init(triple: "arm64-apple-ios18.0", platformName: "iphoneos", sdkVariant: nil, deploymentTargetSettingName: "IPHONEOS_DEPLOYMENT_TARGET", deploymentTarget: "18.0"),
        .init(triple: "arm64-apple-ios18.0-simulator", platformName: "iphonesimulator", sdkVariant: nil, deploymentTargetSettingName: "IPHONEOS_DEPLOYMENT_TARGET", deploymentTarget: "18.0"),
        .init(triple: "arm64-apple-ios17.0-macabi", platformName: "macosx", sdkVariant: "iosmac", deploymentTargetSettingName: "IPHONEOS_DEPLOYMENT_TARGET", deploymentTarget: "17.0"),
        .init(triple: "arm64-apple-tvos18.0", platformName: "appletvos", sdkVariant: nil, deploymentTargetSettingName: "TVOS_DEPLOYMENT_TARGET", deploymentTarget: "18.0"),
        .init(triple: "arm64-apple-tvos18.0-simulator", platformName: "appletvsimulator", sdkVariant: nil, deploymentTargetSettingName: "TVOS_DEPLOYMENT_TARGET", deploymentTarget: "18.0"),
        .init(triple: "arm64-apple-watchos11.0", platformName: "watchos", sdkVariant: nil, deploymentTargetSettingName: "WATCHOS_DEPLOYMENT_TARGET", deploymentTarget: "11.0"),
        .init(triple: "arm64-apple-watchos11.0-simulator", platformName: "watchsimulator", sdkVariant: nil, deploymentTargetSettingName: "WATCHOS_DEPLOYMENT_TARGET", deploymentTarget: "11.0"),
        .init(triple: "arm64-apple-xros2.0", platformName: "xros", sdkVariant: nil, deploymentTargetSettingName: "XROS_DEPLOYMENT_TARGET", deploymentTarget: "2.0"),
        .init(triple: "arm64-apple-xros2.0-simulator", platformName: "xrsimulator", sdkVariant: nil, deploymentTargetSettingName: "XROS_DEPLOYMENT_TARGET", deploymentTarget: "2.0"),
        .init(triple: "arm64-apple-driverkit24.0", platformName: "driverkit", sdkVariant: nil, deploymentTargetSettingName: "DRIVERKIT_DEPLOYMENT_TARGET", deploymentTarget: "24.0"),

        // Linux
        .init(triple: "aarch64-unknown-linux-gnu", platformName: "linux", sdkVariant: nil, deploymentTargetSettingName: nil, deploymentTarget: nil),
        .init(triple: "x86_64-unknown-linux-musl", platformName: "linux", sdkVariant: nil, deploymentTargetSettingName: nil, deploymentTarget: nil),

        // Android
        .init(triple: "aarch64-unknown-linux-android24", platformName: "android", sdkVariant: nil, deploymentTargetSettingName: "ANDROID_DEPLOYMENT_TARGET", deploymentTarget: "24"),
        .init(triple: "armv7-unknown-linux-androideabi24", platformName: "android", sdkVariant: nil, deploymentTargetSettingName: "ANDROID_DEPLOYMENT_TARGET", deploymentTarget: "24"),

        // FreeBSD
        .init(triple: "x86_64-unknown-freebsd14", platformName: "freebsd", sdkVariant: nil, deploymentTargetSettingName: "FREEBSD_DEPLOYMENT_TARGET", deploymentTarget: "14"),

        // OpenBSD
        .init(triple: "x86_64-unknown-openbsd7.8", platformName: "openbsd", sdkVariant: nil, deploymentTargetSettingName: "OPENBSD_DEPLOYMENT_TARGET", deploymentTarget: "7.8"),

        // QNX
        .init(triple: "aarch64-unknown-nto-qnx", platformName: "qnx", sdkVariant: nil, deploymentTargetSettingName: nil, deploymentTarget: nil),

        // Windows
        .init(triple: "x86_64-unknown-windows-msvc", platformName: "windows", sdkVariant: nil, deploymentTargetSettingName: nil, deploymentTarget: nil),

        // WebAssembly
        .init(triple: "wasm32-unknown-wasi", platformName: "webassembly", sdkVariant: nil, deploymentTargetSettingName: nil, deploymentTarget: nil),
    ] as [BuildTargetInfoExpectation])
    func buildTargetInfo(_ expectation: BuildTargetInfoExpectation) async throws {
        let info = try await withBuildSession { try await $0.buildTargetInfo(triple: expectation.triple) }
        #expect(info == SWBBuildTargetInfo(sdkName: expectation.platformName, platformName: expectation.platformName, sdkVariant: expectation.sdkVariant, deploymentTargetSettingName: expectation.deploymentTargetSettingName, deploymentTarget: expectation.deploymentTarget))
    }

    @Test func buildTargetInfoUnrecognizedTriple() async throws {
        await #expect(throws: (any Error).self) {
            try await withBuildSession { try await $0.buildTargetInfo(triple: "unknown-unknown-unknown") }
        }
    }
}

fileprivate struct BuildTargetInfoExpectation: Sendable, CustomTestStringConvertible {
    let triple: String
    let platformName: String
    let sdkVariant: String?
    let deploymentTargetSettingName: String?
    let deploymentTarget: String?

    var testDescription: String { triple }
}

extension CoreBasedTests {
    func withBuildService<T>(_ block: (SWBBuildService) async throws -> T) async throws -> T {
        try await withAsyncDeferrable { deferrable in
            let service = try await SWBBuildService()
            await deferrable.addBlock {
                await service.close()
            }
            return try await block(service)
        }
    }

    func withBuildSession<T>(_ block: (SWBBuildServiceSession) async throws -> T) async throws -> T {
        try await withAsyncDeferrable { deferrable in
            let service = try await SWBBuildService()
            await deferrable.addBlock {
                await service.close()
            }
            let (result, _) = await service.createSession(name: "Test", cachePath: nil, inferiorProductsPath: nil, environment: nil)
            let session = try result.get()
            await deferrable.addBlock {
                try? await session.close()
            }
            return try await block(session)
        }
    }
}
