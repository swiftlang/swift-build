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

@Suite fileprivate struct BuildServiceTests: CoreBasedTests {
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
}
