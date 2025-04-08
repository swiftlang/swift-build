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
import Testing
import SWBTestSupport
import SWBUtil
@_spi(Testing) import SWBCore
import SWBMacro

@Suite fileprivate struct PlatformRegistryTests {
    final class TestDataDelegate: PlatformRegistryDelegate {
        final class MockSpecRegistryDelegate : SpecRegistryDelegate {
            let diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine>

            init(_ diagnosticsEngine: DiagnosticsEngine) {
                self.diagnosticsEngine = .init(diagnosticsEngine)
            }
        }

        let specRegistry: SpecRegistry
        let _diagnosticsEngine = DiagnosticsEngine()
        let pluginManager: PluginManager

        init(pluginManager: PluginManager) async {
            self.specRegistry = await SpecRegistry(PluginManager(skipLoadingPluginIdentifiers: []), MockSpecRegistryDelegate(_diagnosticsEngine), [])
            self.pluginManager = pluginManager
        }

        var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            .init(_diagnosticsEngine)
        }

        var warnings: [String] {
            return _diagnosticsEngine.diagnostics.filter { $0.behavior == .warning }.map { $0.formatLocalizedDescription(.debugWithoutBehavior) }
        }

        var errors: [String] {
            return _diagnosticsEngine.diagnostics.filter { $0.behavior == .error }.map { $0.formatLocalizedDescription(.debugWithoutBehavior) }
        }

        var developerPath: Core.DeveloperPath {
            .fallback(Path.temporaryDirectory)
        }
    }

    /// Helper function for scanning test inputs.
    ///
    /// - parameter inputs: A list of test inputs, in the form (name, testData). These inputs will be written to files in a temporary directory for testing.
    /// - parameter perform: A block to run with the registry that results from scanning the inputs, as well as the list of warnings and errors. Each warning and error is a pair of the path basename and the diagnostic message.
    private func withRegistryForTestInputs(_ inputs: [(String, PropertyListItem?)], perform: (PlatformRegistry, TestDataDelegate) async throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            for (name,dataOpt) in inputs {
                let itemPath = tmpDirPath.join(name).join("Info.plist")
                try localFS.createDirectory(itemPath.dirname, recursive: true)

                // Write the test data to the path, if present.
                if let data = dataOpt {
                    try await localFS.writePlist(itemPath, data)
                }
            }

            let delegate = await TestDataDelegate(pluginManager: PluginManager(skipLoadingPluginIdentifiers: []))
            let registry = await PlatformRegistry(delegate: delegate, searchPaths: [tmpDirPath], hostOperatingSystem: try ProcessInfo.processInfo.hostOperatingSystem(), fs: localFS)
            try await perform(registry, delegate)
        }
    }
    private func withRegistryForTestInputs(_ inputs: [(String, [String: PropertyListItem]?)], perform: (PlatformRegistry, TestDataDelegate) throws -> Void) async throws {
        try await withRegistryForTestInputs(inputs.map{ ($0, $1.flatMap{ .plDict($0) }) }, perform: perform)
    }

    @Test
    func loadingErrors() async throws {
        try await withRegistryForTestInputs([
            ("unused", nil),
            ("a.platform", nil),
            ("b.platform", []),
            ("c.platform", ["Type": "Platform", "Name": "c", "Identifier": "c", "Version": "1.0", "Description": "c", "FamilyName": "c", "FamilyIdentifier": "c", "DefaultProperties": ["CODE_SIGNING_REQUIRED": true]]),
        ]) { registry, delegate in
            #expect(Set(registry.platformsByIdentifier.keys) == Set(["c"]))
            registry.loadExtendedInfo(MacroNamespace())

            XCTAssertMatch(delegate.errors, [
                .contains("b.platform: unexpected platform data"),
            ])

            XCTAssertMatch(delegate.warnings, [
                .equal("unexpected macro parsing failure loading platform c: inconsistentMacroDefinition(name: \"CODE_SIGNING_REQUIRED\", type: SWBMacro.MacroType.userDefined, value: true)"),
            ])

            // We no longer warn about platforms which are missing their Info.plist - we just silently don't load them, which avoids spamming the user console in some common scenarios.
            XCTAssertMatch(delegate.warnings, [])
            //        XCTAssertEqual(warnings[0].0, "a.platform")
            //        XCTAssertMatch(warnings[0].1, .prefix("missing 'Info.plist'"))
        }

        try await withRegistryForTestInputs([
            ("c.platform", ["Type": "Other"]),
            ("d.platform", ["Type": "Platform"]),
            ("e.platform", ["Type": "Platform", "Name": ["Bad"]]),
            ("f.platform", ["Type": "Platform", "Name": "f"]),
            ("g.platform", ["Type": "Platform", "Name": "g", "Identifier": ["Bad"]]),
            ("h.platform", ["Type": "Platform", "Name": "h", "Identifier": "h"]),
            ("i.platform", ["Type": "Platform", "Name": "i", "Identifier": "i", "Version": ["Bad"]]),
            ("j.platform", ["Type": "Platform", "Name": "j", "Identifier": "j", "Version": "1.0"]),
            ("k.platform", ["Type": "Platform", "Name": "k", "Identifier": "k", "Version": "1.0", "Description": ["Bad"]]),
            ("l.platform", ["Type": "Platform", "Name": "l", "Identifier": "k", "Version": "1.0", "Description": "ok"]),
            ("m.platform", ["Type": "Platform", "Name": "m", "Identifier": "k", "Version": "1.0", "Description": "ok", "FamilyName": ["bad"]]),

            ("ok.platform", ["Type": "Platform", "Name": "okName", "Description": "ok", "FamilyName": "okFamily", "FamilyIdentifier": "ok", "Identifier": "ok", "Version": "1.0", "DefaultProperties": ["NAME": "VALUE"]]),
            ("ok2.platform", ["Type": "Platform", "Name": "ok", "Description": "ok", "FamilyName": "okFamily", "FamilyIdentifier": "ok", "Identifier": "ok", "Version": "1.0"]),
            ("ok2.platform", ["Type": "Platform", "Name": "ok", "Description": "ok", "FamilyName": "okFamily", "FamilyIdentifier": "ok", "Identifier": "ok", "Version": "1.0"]),
        ]) { registry, delegate in
            #expect(Set(registry.platformsByIdentifier.keys) == Set(["ok"]))

            let jPlatform = try #require(registry.lookup(identifier: "ok"))
            #expect(registry.lookup(name: "okName") === jPlatform)
            #expect(registry.lookup(identifier: "ok2") == nil)
            #expect(jPlatform.name == "okName")
            #expect(jPlatform.defaultSettings["NAME"] == .plString("VALUE"))

            XCTAssertMatch(delegate.errors, [
                .contains("c.platform: invalid 'Type' field"),
                .contains("d.platform: missing 'Name' field"),
                .contains("e.platform: invalid 'Name' field"),
                .contains("f.platform: missing 'Identifier' field"),
                .contains("g.platform: invalid 'Identifier' field"),
                .contains("h.platform: missing 'Description' field"), // missing the 'Version' field is allowed.
                .contains("i.platform: invalid 'Version' field"),
                .contains("j.platform: missing 'Description' field"),
                .contains("k.platform: invalid 'Description' field"),
                .contains("l.platform: missing 'FamilyName' field"),
                .contains("m.platform: invalid 'FamilyName' field"),
                .contains("ok2.platform: platform 'ok' already registered"),
            ])
            #expect(delegate.warnings == [])
        }
    }
}
