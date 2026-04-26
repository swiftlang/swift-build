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
@_spi(Testing) import SWBUtil

@Suite fileprivate struct PluginManagerTests {
    protocol TestExtensionProtocol: Sendable {}

    struct TestExtensionPoint: ExtensionPoint {
        typealias ExtensionProtocol = any TestExtensionProtocol
        static let name = "TestExtensionPoint"
    }

    struct ExtA: TestExtensionProtocol {}
    struct ExtB: TestExtensionProtocol {}
    struct ExtC: TestExtensionProtocol {}
    struct ExtD: TestExtensionProtocol {}
    struct ExtE: TestExtensionProtocol {}
    struct ExtF: TestExtensionProtocol {}
    struct ExtG: TestExtensionProtocol {}
    struct ExtH: TestExtensionProtocol {}

    @Test
    @PluginExtensionSystemActor
    func extensionsHaveStableOrdering() async {
        let allExtensions: [any TestExtensionProtocol] = [
            ExtA(), ExtB(), ExtC(), ExtD(),
            ExtE(), ExtF(), ExtG(), ExtH(),
        ]

        var firstResult: [String]?

        for _ in 0..<10 {
            let manager = MutablePluginManager(pluginLoadingFilter: { _ in true })
            manager.registerExtensionPoint(TestExtensionPoint())

            var shuffled = allExtensions
            shuffled.shuffle()

            for ext in shuffled {
                manager.register(ext, type: TestExtensionPoint.self)
            }

            let result = manager.extensions(of: TestExtensionPoint.self)
            let descriptions = result.map { String(reflecting: type(of: $0)) }

            if let firstResult {
                #expect(descriptions == firstResult)
            } else {
                firstResult = descriptions
            }
        }
    }

    @Test
    @PluginExtensionSystemActor
    func extensionsHaveStableOrderingAfterFreezing() async {
        let allExtensions: [any TestExtensionProtocol] = [
            ExtA(), ExtB(), ExtC(), ExtD(),
            ExtE(), ExtF(), ExtG(), ExtH(),
        ]

        var firstResult: [String]?

        for _ in 0..<10 {
            let manager = MutablePluginManager(pluginLoadingFilter: { _ in true })
            manager.registerExtensionPoint(TestExtensionPoint())

            var shuffled = allExtensions
            shuffled.shuffle()

            for ext in shuffled {
                manager.register(ext, type: TestExtensionPoint.self)
            }

            do {
                let manager = manager.finalize()

                let result = manager.extensions(of: TestExtensionPoint.self)
                let descriptions = result.map { String(reflecting: type(of: $0)) }

                if let firstResult {
                    #expect(descriptions == firstResult)
                } else {
                    firstResult = descriptions
                }
            }
        }
    }
}
