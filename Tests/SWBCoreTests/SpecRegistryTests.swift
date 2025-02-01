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

@Suite fileprivate struct SpecRegistryTests: CoreBasedTests {
    final class TestDataDelegate: SpecRegistryDelegate {
        private let _diagnosticsEngine = DiagnosticsEngine()

        var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            .init(_diagnosticsEngine)
        }

        var warnings: [(String, String)] {
            return _diagnosticsEngine.diagnostics.pathMessageTuples(.warning)
        }

        var errors: [(String, String)] {
            return _diagnosticsEngine.diagnostics.pathMessageTuples(.error)
        }
    }

    /// Helper function for scanning test spec inputs.
    ///
    /// - parameter inputs: A list of test inputs, in the form (name, testData). These inputs will be written to files in a temporary directory during scanning.
    /// - parameter perform: A block to run with the registry that results from scanning the inputs, as well as the list of warnings and errors. Each warning and error is a pair of the path basename and the diagnostic message.
    private func withRegistryForTestInputs(_ inputs: [(String, PropertyListItem)], sourceLocation: SourceLocation = #_sourceLocation, perform: (SpecRegistry, TestDataDelegate) async throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDirPath in
            for (name, data) in inputs {
                // Write the test data to the path.
                try await localFS.writePlist(tmpDirPath.join(name), data)
            }

            // Ensure spec types are loaded.
            let pluginManager = await PluginManager(skipLoadingPluginIdentifiers: [])
            await pluginManager.registerExtensionPoint(SpecificationsExtensionPoint())
            await pluginManager.register(BuiltinSpecsExtension(), type: SpecificationsExtensionPoint.self)

            let delegate = TestDataDelegate()
            let registry = await SpecRegistry(pluginManager, delegate, [(tmpDirPath, "")], loadBuiltinImplementations: false)

            try await perform(registry, delegate)
        }
    }

    @Test
    func subregistryNames() {
        #expect(ArchitectureSpec.subregistryName == "Architecture")
        #expect(PackageTypeSpec.subregistryName == "PackageType")
        #expect(ProductTypeSpec.subregistryName == "ProductType")
        #expect(PlatformSpec.subregistryName == "Platform")
    }

    @Test
    func specScanningErrors() async throws {
        try await withRegistryForTestInputs([("a.xcspec", "bad")]) { registry, delegate in
            #expect(registry.proxiesByDomain.count == 0)
            #expect(delegate.errors.count == 1)
            #expect(delegate.errors[0].0 == "a.xcspec")
            XCTAssertMatch(delegate.errors[0].1, .prefix("unexpected specification"))
        }
        // Check 'Identifier' errors.
        try await withRegistryForTestInputs(
            [("a.xcspec", ["a": "c"]),
             ("b.xcspec", ["Identifier": ["bad"]])]) { registry, delegate in
                 #expect(registry.proxiesByDomain.count == 0)
                 #expect(delegate.errors.count == 2)
                 #expect(delegate.errors[0].0 == "a.xcspec")
                 XCTAssertMatch(delegate.errors[0].1, .prefix("missing 'Identifier' field"))
                 #expect(delegate.errors[1].0 == "b.xcspec")
                 XCTAssertMatch(delegate.errors[1].1, .prefix("invalid 'Identifier' field"))
             }
        // Check 'Type' errors.
        try await withRegistryForTestInputs(
            [("a.xcspec", ["Identifier": "a"]),
             ("b.xcspec", ["Identifier": "b", "Type": ["bad"]]),
             ("c.xcspec", ["Identifier": "c", "Type": "notfound"])]) { registry, delegate in
                 #expect(registry.proxiesByDomain.count == 0)
                 #expect(delegate.errors.count == 3)
                 #expect(delegate.errors[0].0 == "a.xcspec")
                 XCTAssertMatch(delegate.errors[0].1, .prefix("missing 'Type' field"))
                 #expect(delegate.errors[1].0 == "b.xcspec")
                 XCTAssertMatch(delegate.errors[1].1, .prefix("invalid 'Type' field"))
                 #expect(delegate.errors[2].0 == "c.xcspec")
                 XCTAssertMatch(delegate.errors[2].1, .prefix("unknown spec 'Type'"))
             }
        // Check 'Class' errors.
        try await withRegistryForTestInputs(
            [("a.xcspec", ["Identifier": "a", "Type": "FileType", "Class": ["bad"]]),
             ("b.xcspec", ["Identifier": "b", "Type": "FileType", "Class": "notfound"])]) { registry, delegate in
                 #expect(registry.proxiesByDomain.count == 0)
                 #expect(delegate.errors.count == 2)
                 #expect(delegate.errors[0].0 == "a.xcspec")
                 XCTAssertMatch(delegate.errors[0].1, .prefix("invalid 'Class' field"))
                 #expect(delegate.errors[1].0 == "b.xcspec")
                 XCTAssertMatch(delegate.errors[1].1, .prefix("unknown spec 'Class'"))
             }
        // Check 'Domain' and 'BasedOn' errors.
        try await withRegistryForTestInputs([
            ("a.xcspec", ["Identifier": "a", "Type": "FileType", "Domain": ["bad"]]),
            ("b.xcspec", ["Identifier": "b", "Type": "FileType", "BasedOn": ["bad"]]),
            ("c.xcspec", ["Identifier": "c", "Type": "FileType", "BasedOn": "missing"])]) { registry, delegate in
                #expect(registry.proxiesByDomain.count == 1)
                #expect(registry.proxiesByDomain[""]?.proxiesByIdentifier["c"] == nil)
                #expect(delegate.errors.count == 3)
                #expect(delegate.errors[0].0 == "a.xcspec")
                XCTAssertMatch(delegate.errors[0].1, .prefix("invalid 'Domain' field"))
                #expect(delegate.errors[1].0 == "b.xcspec")
                XCTAssertMatch(delegate.errors[1].1, .prefix("invalid 'BasedOn' field"))
                #expect(delegate.errors[2].0 == "c.xcspec")
                XCTAssertMatch(delegate.errors[2].1, .prefix("missing base spec ':missing'"))

                // Check 'BasedOn' type compatibility.
                try await withRegistryForTestInputs([
                    ("a.xcspec", ["Identifier": "a", "Type": "FileType"]),
                    ("b.xcspec", ["Identifier": "b", "Type": "Architecture", "BasedOn": "a"])]) { registry, delegate in
                        #expect(delegate.errors.count == 1)
                        #expect(delegate.errors[0].0 == "b.xcspec")
                        XCTAssertMatch(delegate.errors[0].1, .prefix("incompatible base spec"))
                    }
            }
        // Check registration errors.
        try await withRegistryForTestInputs(
            [("a.xcspec", ["Identifier": "a", "Type": "FileType"]),
             ("b.xcspec", ["Identifier": "a", "Type": "FileType"])]) { registry, delegate in
                 #expect(registry.proxiesByDomain.count == 1)
                 #expect(delegate.errors.count == 1)

                 // We have to be prepared for either to be the duplicate, due to concurrent loading.
                 if let error = delegate.errors.first {
                     if error.0 == "a.xcspec" {
                         #expect(error.0 == "a.xcspec")
                         XCTAssertMatch(error.1, .prefix("spec ':a' already registered"))
                     } else {
                         #expect(error.0 == "b.xcspec")
                         XCTAssertMatch(error.1, .prefix("spec ':a' already registered"))
                     }
                 }
                 else {
                     Issue.record("Did not find an expected error that spec ':a' is already registered")
                 }
             }
    }

    @Test
    func specRegistryLoadingErrors() async throws {
        try await withRegistryForTestInputs(
            [("a.xcspec", ["Identifier": "a", "Type": "FileType"])]) { registry, delegate in
                #expect(registry.getSpec("a") != nil)
                #expect(registry.getSpec("a") === registry.getSpec("a"))
                #expect(delegate.warnings.count == 0)
                #expect(delegate.errors.count == 0)
            }
        // Check handling of errors in base specs.
        try await withRegistryForTestInputs(
            [("a.xcspec", ["Identifier": "a", "Type": "FileType", "BasedOn": "broken"]),
             ("broken.xcspec", ["Identifier": "broken", "Type": "FileType", "UTI": ["not-a-uti"]])]) { registry, delegate in
                 #expect(registry.getSpec("a") == nil)
                 #expect(delegate.warnings.count == 0)
                 #expect(delegate.errors.count == 2)
                 #expect(delegate.errors[0].0 == "a.xcspec")
                 #expect(delegate.errors[0].1 == "unable to load ':a' due to errors loading base spec")
                 #expect(delegate.errors[1].0 == "broken.xcspec")
                 XCTAssertMatch(delegate.errors[1].1, .prefix("unexpected item"))

                 // Check repeated loading attempts shouldn't generate new errors.
                 #expect(registry.getSpec("a") == nil)
                 #expect(delegate.errors.count == 2)
             }
        // Check that we don't fail on recursive base specs.
        try await withRegistryForTestInputs(
            [("a.xcspec", ["Identifier": "a", "Type": "FileType", "BasedOn": "a"]),
             ("b.xcspec", ["Identifier": "b", "Type": "FileType", "BasedOn": "b"])]) { registry, delegate in
                 #expect(registry.getSpec("a") == nil)
                 #expect(delegate.warnings.count == 0)
                 #expect(delegate.errors.count == 2)
                 XCTAssertMatch(delegate.errors[0].1, .prefix("encountered cyclic dependency"))
                 #expect(delegate.errors[1].1 == "unable to load ':a' due to errors loading base spec")
             }
    }


    @Test
    func specScanning() async throws {
        let core = try await getCore()
        // Validate that we loaded some of the known built-in specs.
        #expect(core.specRegistry.lookupProxy("com.apple.build-system.core") != nil)
        #expect(core.specRegistry.lookupProxy("sourcecode.c") != nil)

        // Validate that we load specs from legacy plugins (of which Clang is one example).
        guard let clangSpecProxy = core.specRegistry.lookupProxy("com.apple.compilers.llvm.clang.1_0") else {
            Issue.record("missing clang spec")
            return
        }

        // Validate we can load options and descriptions of real specs.
        guard let clangSpecBase = clangSpecProxy.load(core.specRegistry),
              let clangSpec = clangSpecBase as? PropertyDomainSpec else {
            Issue.record("unable to load clang spec")
            return
        }
        guard let enableCodeCoverageOption = clangSpec.flattenedBuildOptions["CLANG_X86_VECTOR_INSTRUCTIONS"] else {
            Issue.record("missing expected example option")
            return
        }
        #expect(enableCodeCoverageOption.localizedName == "Enable Additional Vector Extensions")
        XCTAssertMatch((enableCodeCoverageOption.localizedDescription ?? ""), .contains("Enables the use of extended vector instructions"))


        // Validate that we correctly extract the spec proxy domains.
        if let watchAppProxy = core.specRegistry.lookupProxy("com.apple.product-type.application.watchapp", domain: "iphoneos") {
            #expect(watchAppProxy.domain == "iphoneos")
        } else {
            Issue.record("no proxy for compiler 'com.apple.product-type.application.watchapp' in domain 'iphoneos'")
        }

        // Validate that we load specs based on known extensions (this spec comes from "Core Data.xcspec").
        if let xcdatamodelSpec = core.specRegistry.lookupProxy("wrapper.xcdatamodel") {
            #expect(xcdatamodelSpec.path.fileSuffix == ".xcspec")
        }
        else {
            Issue.record("no proxy for file type 'wrapper.xcdatamodel'")
        }

        // Validate that we load the specs from the platform
        let osxAppProduct = core.specRegistry.lookupProxy("com.apple.product-type.application", domain: "macosx")
        #expect(osxAppProduct != nil)
    }

    @Test
    func specLookup() async throws {
        #expect(try await getCore().specRegistry.lookupProxy("sourcecode.c", domain: "macosx") != nil)
    }

    @Test
    func specFindInSubregistry() async throws {
        let tools = try await getCore().specRegistry.findProxiesInSubregistry(CommandLineToolSpec.self)

        // Validate every item is of the appropriate type.
        for item in tools {
            #expect(item.type is CommandLineToolSpec.Type)
        }
    }

    @Test
    func noDuplicatedIdentifiersFindingProxiesIncludingInheritedDomains() async throws {
        let core = try await getCore()
        for (domain, proxies) in core.specRegistry.proxiesByDomain {
            // Query for all types (but only once per subregistry)
            var typesBySubregistryName = [String: any SpecType.Type]()
            for type in proxies.proxiesByIdentifier.values.compactMap({ $0.classType }) {
                typesBySubregistryName[type.subregistryName] = type
            }

            for type in typesBySubregistryName.values {
                let proxyIdentifiers = core.specRegistry.findProxiesInSubregistry(type, domain: domain, includeInherited: true).map{$0.identifier}.sorted()
                #expect(proxyIdentifiers == Set(proxyIdentifiers).sorted())
            }
        }
    }

    @Test
    func specParsing() async throws {
        let core = try await getCore()

        // Verify we can load a basic file type spec.
        let spec = core.specRegistry.getSpec("sourcecode.c.c")!
        #expect(spec.identifier == "sourcecode.c.c")

        // Validate we cache the loaded spec.
        #expect(spec === core.specRegistry.getSpec("sourcecode.c.c")!)

        // Validate that we loaded the super spec properly.
        let superSpec = core.specRegistry.getSpec("sourcecode.c")!
        #expect(spec.basedOnSpec === superSpec)
    }

    @Test
    func infoPlistKeyConfigurations() async throws {
        let checkInfoPlistKeyURLReachability = getEnvironmentVariable("CHECK_INFOPLIST_KEY_URL_REACHABILITY")?.boolValue == true
        let specRegistry = try await getCore().specRegistry

        let legacyKeyMappings = [
            "PRODUCT_NAME": "CFBundleName",
            "EXECUTABLE_NAME": "CFBundleExecutable",
            "CURRENT_PROJECT_VERSION": "CFBundleVersion",
            "PRODUCT_BUNDLE_IDENTIFIER": "CFBundleIdentifier",
            "MARKETING_VERSION": "CFBundleShortVersionString"
        ]

        let infoPlistKeyOptions = specRegistry.domains.flatMap { domain in
            return (specRegistry.findSpecs(BuildSettingsSpec.self, domain: domain, includeInherited: false)
                    + specRegistry.findSpecs(BuildSystemSpec.self, domain: domain, includeInherited: false)
                    + specRegistry.findSpecs(CommandLineToolSpec.self, domain: domain, includeInherited: false))
            .flatMap({ $0.flattenedBuildOptions.values })
        }.filter { $0.name.hasPrefix("INFOPLIST_KEY_") || legacyKeyMappings.contains($0.name) }

        // Check that the URLs of the keys are reachable. This is purposely not enabled by default and is primarily for debugging.
        let unreachableURLs: [(String, String)]
#if canImport(Darwin)
        if checkInfoPlistKeyURLReachability {
            unreachableURLs = try await withThrowingTaskGroup(of: (String, String).self) { group in
                for keyName in Set(infoPlistKeyOptions.map({ $0.name.hasPrefix("INFOPLIST_KEY_") ? String($0.name.dropFirst("INFOPLIST_KEY_".count)) : (legacyKeyMappings[$0.name] ?? $0.name) })).sorted() {
                    switch keyName {
                    case "UISupportedInterfaceOrientations_iPhone", "UISupportedInterfaceOrientations_iPad":
                        // These map to UISupportedInterfaceOrientations~iPhone and UISupportedInterfaceOrientations~iPad.
                        continue
                    case "UIApplicationSceneManifest_Generation", "UILaunchScreen_Generation":
                        // These map to UIApplicationSceneManifest and UILaunchScreen, which are dictionaries.
                        continue
                    case "MetalCaptureEnabled", "NSBluetoothWhileInUseUsageDescription", "NSFileProviderPresenceUsageDescription", "NSFocusStatusUsageDescription", "NSSystemExtensionUsageDescription", "NSVoIPUsageDescription", "OSBundleUsageDescription":
                        // rdar://91269820 (Missing documentation for some Info.plist keys which are directly supported by Xcode)
                        continue
                    default:
                        break
                    }

                    let url = "https://developer.apple.com/documentation/bundleresources/information_property_list/\(keyName.lowercased())"

                    group.addTask {
                        let (_, response) = try await URLSession.shared.data(from: #require(URL(string: url)))
                        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                            throw StubError.error("Network failure")
                        }

                        return (String(keyName), url)
                    }
                }

                return try await group.collect()
            }
        } else {
            unreachableURLs = []
        }
#else
        unreachableURLs = []
#endif

        for (keyName, url) in unreachableURLs {
            Issue.record("\(keyName) - \(url) is not reachable")
        }

        for option in infoPlistKeyOptions {
            let (keyName, keyURLPart): (String, String) = {
                guard option.name.hasPrefix("INFOPLIST_KEY_") else {
                    let keyName = legacyKeyMappings[option.name] ?? option.name
                    return (keyName, keyName)
                }
                let baseKeyName = option.name.dropFirst("INFOPLIST_KEY_".count)
                for suffix in ["_Generation", "_iPhone", "_iPad"] {
                    if baseKeyName.hasSuffix(suffix) {
                        let keyName = String(baseKeyName.dropLast(suffix.count))
                        return (["_iPhone", "_iPad"].contains(suffix) ? String(baseKeyName.replacingOccurrences(of: "_", with: "~")) : keyName, keyName)
                    }
                }
                return (String(baseKeyName), String(baseKeyName))
            }()
            let url = "https://developer.apple.com/documentation/bundleresources/information_property_list/\(keyURLPart.lowercased())"

            // FIXME: There are some duplicate definitions of these keys, with empty descriptions.
            if !option.name.hasPrefix("INFOPLIST_KEY_") && option.localizedDescription == nil {
                continue
            }

            let expectedCategory: String?
            switch option.name {
            case "EXECUTABLE_NAME":
                expectedCategory = nil
            case "PRODUCT_NAME", "PRODUCT_BUNDLE_IDENTIFIER":
                expectedCategory = "Packaging"
            case "CURRENT_PROJECT_VERSION", "MARKETING_VERSION":
                expectedCategory = "Versioning"
            default:
                expectedCategory = "Info.plist Values"
            }
            #expect(option.localizedCategoryName == expectedCategory)

            func generateSentence(keyName: String, url: String?) -> String {
                let infix: String
                if let url {
                    infix = "[\(keyName)](\(url))"
                } else {
                    infix = keyName
                }
                return "When `GENERATE_INFOPLIST_FILE` is enabled, sets the value of the \(infix) key in the `Info.plist` file to the value of this build setting."
            }

            let generateSentenceWithURL = generateSentence(keyName: keyName, url: url)
            let generateSentenceWithoutURL = generateSentence(keyName: keyName, url: nil)

            switch keyName {
            case "UIApplicationSceneManifest":
                #expect(option.localizedDescription == "When `GENERATE_INFOPLIST_FILE` is enabled, sets the value of the [\(keyName)](\(url)) key in the Info.plist file to an entry suitable for a multi-window application.")
            case "UILaunchScreen":
                #expect(option.localizedDescription == "When `GENERATE_INFOPLIST_FILE` is enabled, sets the value of the [\(keyName)](\(url)) key in the Info.plist file to an empty dictionary.")
            case _ where legacyKeyMappings.values.contains(keyName):
                XCTAssertMatch(option.localizedDescription, .suffix("\n\n\(generateSentenceWithURL)"))
            default:
                XCTAssertMatch(option.localizedDescription, .or(.equal(generateSentenceWithURL), .equal(generateSentenceWithoutURL)))
            }
        }
    }
}
