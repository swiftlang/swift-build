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
import SWBMacro
@_spi(Testing) import SWBCore

@Suite fileprivate struct SpecLoadingTests: CoreBasedTests {
    var specDataCaches = Registry<Spec, any SpecDataCache>()

    class TestDataDelegate : SpecParserDelegate {
        class MockSpecRegistryDelegate : SpecRegistryDelegate {
            private let _diagnosticsEngine: DiagnosticsEngine

            init(_ diagnosticsEngine: DiagnosticsEngine) {
                self._diagnosticsEngine = diagnosticsEngine
            }

            var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
                .init(_diagnosticsEngine)
            }
        }

        let specRegistry: SpecRegistry

        var internalMacroNamespace: MacroNamespace

        private let _diagnosticsEngine = DiagnosticsEngine()

        var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            .init(_diagnosticsEngine)
        }

        func groupingStrategy(name: String, specIdentifier: String) -> (any SWBCore.InputFileGroupingStrategy)? {
            specRegistry.inputFileGroupingStrategyFactories[name]?.makeStrategy(specIdentifier: specIdentifier)
        }

        var warnings: [String] {
            return _diagnosticsEngine.diagnostics.compactMap {
                if case .warning = $0.behavior {
                    return $0.data.description
                }
                return nil
            }
        }

        var errors: [String] {
            return _diagnosticsEngine.diagnostics.compactMap {
                if case .error = $0.behavior {
                    return $0.data.description
                }
                return nil
            }
        }

        init(namespace: MacroNamespace? = nil) async {
            self.internalMacroNamespace = namespace ?? MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: "spec loading tests")
            specRegistry = await SpecRegistry(PluginManager(skipLoadingPluginIdentifiers: []), MockSpecRegistryDelegate(_diagnosticsEngine), [])
        }
    }

    private func parseTestSpec<T : SpecType>(_ type: T.Type, _ specData: [String: PropertyListItem], _ baseSpec: Spec? = nil, namespace: MacroNamespace? = nil) async throws -> (T, [String], [String]) {
        let core = try await getCore()
        // Create a mock proxy for the data.
        var identifier = "test"
        if let value = specData["Identifier"] {
            if case .plString(let ident) = value {
                identifier = ident
            }
        }
        let proxy = SpecProxy(identifier: identifier, domain: "", path: Path("test.xcspec"), type: type, classType: nil, basedOn: baseSpec.map { "'\($0.proxyDomain):\($0.proxyIdentifier)'" }, data: specData, localizedStrings: nil)
        if let baseSpec {
            proxy.basedOnProxy = core.specRegistry.lookupProxy(baseSpec.proxyIdentifier, domain: baseSpec.proxyDomain)
        }

        let delegate = await TestDataDelegate(namespace: namespace)
        let specResult = type.parseSpec(delegate, proxy, baseSpec)
        guard let result = specResult as? T else {
            throw StubError.error("unexpected spec type (expected \(T.self), got \(Swift.type(of: specResult))")
        }
        return (result, delegate.warnings, delegate.errors)
    }

    @Test
    func specLoading() async throws {
        let core = try await getCore()

        // Verify we can load a basic file type spec.
        let spec = core.specRegistry.getSpec("sourcecode.c.c")!

        // Validate we cache the loaded spec.
        #expect(spec === core.specRegistry.getSpec("sourcecode.c.c")!)

        // Validate that we loaded the super spec properly.
        let superSpec = core.specRegistry.getSpec("sourcecode.c")!
        #expect(spec.basedOnSpec === superSpec)

        // Validate that we loaded specs from IDE plugins.
        #expect(core.specRegistry.getSpec("com.apple.product-type.bundle", domain: "embedded") != nil)

        // Validate use of default proxy as fallback for based on references.
        let staticFramework = core.specRegistry.getSpec("com.apple.product-type.framework.static", domain: "macosx")!
        let staticFrameworkProxy = core.specRegistry.lookupProxy(staticFramework.proxyIdentifier, domain: staticFramework.proxyDomain)
        #expect(staticFrameworkProxy?.basedOn == "com.apple.product-type.framework")
        #expect(staticFramework.basedOnSpec! === core.specRegistry.getSpec("com.apple.product-type.framework", domain: "macosx")!)

        // Validate that we respect domain composition.
        let buildSystemSpec = core.specRegistry.lookupProxy("com.apple.build-system.core", domain: "iphoneos")
        #expect(buildSystemSpec != nil)
        #expect(buildSystemSpec?.domain == "embedded-shared")
    }

    @Test(.requireHostOS(.macOS))
    func archSpecLoading() async throws {
        let core = try await getCore()
        // Validate that we can load an arch spec properly.
        let standardArchs = try core.specRegistry.getSpec("Standard", domain: "macosx") as ArchitectureSpec
        #expect(standardArchs.archSetting?.name == "ARCHS_STANDARD")
        #expect(standardArchs.realArchs?.stringRep == "arm64 x86_64")
    }

    @Test
    func productTypeSpecLoading() async throws {
        var (spec, _, errors) = try await parseTestSpec(ProductTypeSpec.self, ["DefaultBuildProperties": [:], "PackageTypes": []])
        #expect(errors.count == 1)
        #expect(errors[0] == "at least one entry for 'PackageTypes' must be defined")

        (spec, _, errors) = try await parseTestSpec(ProductTypeSpec.self, ["DefaultBuildProperties": [:], "PackageTypes": ["com.apple.package-type.mach-o-executable"]])
        #expect(spec.defaultPackageTypeIdentifier == "com.apple.package-type.mach-o-executable")
        #expect(errors.count == 0)
    }

    func testProductTypeSpecLoadingClassAssociations(domain: String) async throws {
        let core = try await getCore()
        for spec in core.specRegistry.findSpecs(ProductTypeSpec.self, domain: domain) {
            func check<T>(identifier: String, is: T.Type, sourceLocation: SourceLocation = #_sourceLocation) {
                #expect(throws: Never.self) {
                    try core.specRegistry.getSpec(identifier, domain: domain) as ProductTypeSpec
                }
                if spec.conformsTo(identifier: identifier) {
                    #expect(spec is T, "\(spec) is not an instance of \(T.self)", sourceLocation: sourceLocation)
                }
            }

            check(identifier: "com.apple.product-type.bundle", is: BundleProductTypeSpec.self)
            check(identifier: "com.apple.product-type.application", is: ApplicationProductTypeSpec.self)
            check(identifier: "com.apple.product-type.app-extension", is: ApplicationExtensionProductTypeSpec.self)
            check(identifier: "com.apple.product-type.extensionkit-extension", is: ApplicationExtensionProductTypeSpec.self)
            check(identifier: "com.apple.product-type.framework", is: FrameworkProductTypeSpec.self)
            check(identifier: "com.apple.product-type.framework.static", is: StaticFrameworkProductTypeSpec.self)
            check(identifier: "com.apple.product-type.bundle.unit-test", is: XCTestBundleProductTypeSpec.self)
            check(identifier: "com.apple.product-type.objfile", is: StandaloneExecutableProductTypeSpec.self)
            check(identifier: "com.apple.product-type.library.dynamic", is: DynamicLibraryProductTypeSpec.self)
            check(identifier: "com.apple.product-type.library.static", is: StaticLibraryProductTypeSpec.self)
            check(identifier: "com.apple.product-type.kernel-extension", is: KernelExtensionProductTypeSpec.self)
            check(identifier: "com.apple.product-type.tool", is: ToolProductTypeSpec.self)
        }
    }

    @Test(.requireSDKs(.macOS))
    func productTypeSpecLoadingClassAssociations_macOS() async throws {
        try await testProductTypeSpecLoadingClassAssociations(domain: "macosx")
    }

    @Test(.requireSDKs(.iOS))
    func productTypeSpecLoadingClassAssociations_iOS() async throws {
        try await testProductTypeSpecLoadingClassAssociations(domain: "iphoneos")
    }

    @Test(.requireSDKs(.tvOS))
    func productTypeSpecLoadingClassAssociations_tvOS() async throws {
        try await testProductTypeSpecLoadingClassAssociations(domain: "appletvos")
    }

    @Test(.requireSDKs(.watchOS))
    func productTypeSpecLoadingClassAssociations_watchOS() async throws {
        try await testProductTypeSpecLoadingClassAssociations(domain: "watchos")
    }

    @Test(.requireSDKs(.xrOS))
    func productTypeSpecLoadingClassAssociations_visionOS() async throws {
        try await testProductTypeSpecLoadingClassAssociations(domain: "xros")
    }

    @Test
    func packageTypeSpecLoading() async throws {
        let (spec, _, errors) = try await parseTestSpec(PackageTypeSpec.self, [
            "Identifier": "com.apple.package-type.wrapper.framework",
            "DefaultBuildSettings": [:],
            "ProductReference": ["Name": "$(WRAPPER_NAME)", "FileType": "wrapper.framework", "IsLaunchable": "NO"]
        ])
        #expect(spec.identifier == "com.apple.package-type.wrapper.framework")
        #expect(spec.productReferenceFileTypeIdentifier == "wrapper.framework")
        #expect(errors.count == 0)
    }

    @Test
    func productTypeSpecLoadingWithBasedOnSettings() async throws {
        let testNamespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: "product-type-spec-loading-tests")
        let foo = try testNamespace.declareStringListMacro("FOO")
        let bar = try testNamespace.declareStringMacro("BAR")

        let (rootspec, rw, re) = try await parseTestSpec(ProductTypeSpec.self, [
            "DefaultBuildProperties": [
                "FOO" : "$(inherited) no",
                "BAR" : "i386"
            ],
            "PackageTypes": ["com.apple.product-type.bundle.ui-testing"]], namespace: testNamespace)
        #expect(rootspec.defaultPackageTypeIdentifier == "com.apple.product-type.bundle.ui-testing")
        #expect(re == [])
        #expect(rw == [])
        #expect(rootspec.buildSettings.valueAssignments.count == 2)

        let (spec, warnings, errors) = try await parseTestSpec(ProductTypeSpec.self, [
            "DefaultBuildProperties": [
                "FOO" : "$(inherited) yes"
            ],
            "PackageTypes": ["com.apple.product-type.bundle.ui-testing"]], rootspec, namespace: testNamespace)
        #expect(spec.defaultPackageTypeIdentifier == "com.apple.product-type.bundle.ui-testing")
        #expect(errors == [])
        #expect(warnings == [])
        #expect(spec.buildSettings.valueAssignments.count == 2)

        let scope = MacroEvaluationScope(table: spec.buildSettings)
        #expect(scope.evaluate(foo) == ["yes"])
        #expect(scope.evaluate(bar) == "i386")
    }

    @Test
    func productTypeSpecLoadingWithErrorForMissingDeprecationReason() async throws {
        let (spec, warnings, errors) = try await parseTestSpec(ProductTypeSpec.self, [
            "DeprecationLevel" : "error",
            "DefaultBuildProperties": [:],
            "PackageTypes": ["com.apple.product-type.bundle.ui-testing"]])
        #expect(spec.deprecationInfo == nil)
        #expect(warnings.count == 0)
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("expected 'DeprecationReason' if key 'DeprecationLevel' is used."))
    }

    @Test
    func productTypeSpecLoadingWithErrorForInvalidDeprecationReason() async throws {
        let (spec, warnings, errors) = try await parseTestSpec(ProductTypeSpec.self, [
            "DeprecationReason" : "no longer supported",
            "DeprecationLevel" : "err",
            "DefaultBuildProperties": [:],
            "PackageTypes": ["com.apple.product-type.bundle.ui-testing"]])
        #expect(spec.deprecationInfo == nil)
        #expect(warnings.count == 0)
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid 'DeprecationLevel' value of 'err'"))
    }

    @Test
    func productTypeSpecLoadingWithDeprecatedAsErrorValues() async throws {
        let (spec, warnings, errors) = try await parseTestSpec(ProductTypeSpec.self, [
            "DeprecationReason" : "no longer supported",
            "DeprecationLevel" : "ErrOR",
            "DefaultBuildProperties": [:],
            "PackageTypes": ["com.apple.product-type.bundle.ui-testing"]])
        #expect(spec.deprecationInfo != nil)
        #expect(spec.deprecationInfo?.level == .error)
        #expect(spec.deprecationInfo?.reason == "no longer supported")
        #expect(warnings.count == 0)
        #expect(errors.count == 0)
    }

    @Test
    func productTypeSpecLoadingWithDeprecatedAsWarningValues() async throws {
        let (spec, warnings, errors) = try await parseTestSpec(ProductTypeSpec.self, [
            "DeprecationReason" : "no longer supported",
            "DeprecationLevel" : "warNing",
            "DefaultBuildProperties": [:],
            "PackageTypes": ["com.apple.product-type.bundle.ui-testing"]])
        #expect(spec.deprecationInfo != nil)
        #expect(spec.deprecationInfo?.level == .warning)
        #expect(spec.deprecationInfo?.reason == "no longer supported")
        #expect(warnings.count == 0)
        #expect(errors.count == 0)
    }

    @Test
    func propertyDomainSpecPropertiesParsing() async throws {
        var (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": "Foo"])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("expected build option array"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": ["Foo"]])
        #expect(errors.count >= 1)
        XCTAssertMatch(errors[0], .prefix("expected build option definition dictionary"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ ["Name": ["bad"]] ]])
        #expect(errors.count == 2)
        XCTAssertMatch(errors[0], .prefix("expected string value for build option key 'Name'"))
        XCTAssertMatch(errors[1], .prefix("missing build option key 'Name'"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ ["Foo": "Bar"] ]])
        #expect(errors.count == 2)
        XCTAssertMatch(errors[0], .prefix("unknown build option key 'Foo'"))
        XCTAssertMatch(errors[1], .prefix("missing build option key 'Name'"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ ["Name": "Foo", "Type": ["bad"] as PropertyListItem]]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid build option key 'Type'"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ ["Name": "Foo", "Type": "Missing"] ]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("unknown build option type 'Missing'"))
    }

    // These helpers are just to help Swift's type inference out, which otherwise blows up pretty badly on our big object literals.
    func OptionData(_ name: String, _ type: String, _ data: [String: PropertyListItem]) -> [String: PropertyListItem] {
        var result: [String: PropertyListItem] = [:]
        result["Name"] = .plString(name)
        result["Type"] = .plString(type)
        for (key,value) in data {
            result[key] = value
        }
        return result
    }

    @Test
    func propertyDomainSpecPropertiesValuesParsing() async throws {
        var (_, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "Enumeration", [:]) ]])
        #expect(warnings.count == 1)
        #expect(errors.count == 0)
        XCTAssertMatch(warnings[0], .prefix("missing required build option key 'Values'"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "String", ["Values": []]) ]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid build option key 'Values' used with type 'String'"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "Enumeration", ["Values": [], "AllowedValues": []]),
                                                                                  OptionData("Foo1", "Enumeration", ["Values": "bad"])],
                                                                  "Options": []])
        #expect(errors.count == 3)
        XCTAssertMatch(errors[0], .prefix("cannot define both 'Properties' and 'Options'"))
        XCTAssertMatch(errors[1], .prefix("cannot specify both 'AllowedValues' and 'Values'"))
        XCTAssertMatch(errors[2], .prefix("invalid build option key 'Values'"))
    }

    @Test
    func propertyDomainSpecPropertiesCommandLineKeysParsing() async throws {
        var (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "String", ["CommandLineArgs": [], "CommandLineFlag": "foo", "CommandLinePrefixFlag": "foo"]) ]])
        #expect(errors.count == 2)
        // FIXME: This order is technically non-deterministic, need a fuzzy comparison.
        XCTAssertMatch(errors[0], .prefix("invalid build option key"))
        XCTAssertMatch(errors[0], .contains("cannot combine with"))
        XCTAssertMatch(errors[1], .prefix("invalid build option key"))
        XCTAssertMatch(errors[1], .contains("cannot combine with"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "String", ["CommandLineFlag": "foo", "CommandLinePrefixFlag": "foo"]) ]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid build option key"))
        XCTAssertMatch(errors[0], .contains("cannot combine with"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "String", ["CommandLineArgs": PropertyListItem.plData(Array("bad".utf8))]) ]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("expected string, array, or dict value for build option key 'CommandLineArgs'"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "String", ["CommandLineFlag": ["bad"]]) ]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("expected string value for build option key 'CommandLineFlag'"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "String", ["CommandLinePrefixFlag": ["bad"]]) ]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("expected string value for build option key 'CommandLinePrefixFlag'"))
    }

    @Test
    func propertyDomainSpecPropertiesCommandLineKeysListTypeParsing() async throws {
        var (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "StringList", ["Values": []]) ]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid build option key 'Values' used with type 'StringList'"))

        // Check list arguments.
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Foo", "StringList", ["CommandLineArgs": "foo"]),
            OptionData("Foo2", "StringList", ["CommandLineArgs": ["foo2"]]),
            OptionData("Foo3", "StringList", ["CommandLineArgs": ""]),
            OptionData("Foo4", "StringList", ["CommandLineArgs": [["bad"]]]) ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 1)
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("expected string in 'CommandLineArgs' for option 'Foo4'"))
        #expect(spec.buildOptions.count == 4)
        #expect(spec.buildOptions[0].name == "Foo")
        guard case .args(let fooArg)? = spec.buildOptions[0].otherValueDefn?.commandLineTemplate, fooArg.stringRep == "foo"  else { fatalError("unexpected template") }
        #expect(spec.buildOptions[1].name == "Foo2")
        guard case .args(let foo2Args)? = spec.buildOptions[1].otherValueDefn?.commandLineTemplate, foo2Args.stringRep == "foo2" else { fatalError("unexpected template") }
        #expect(spec.buildOptions[2].name == "Foo3")
        guard case .empty? = spec.buildOptions[2].otherValueDefn?.commandLineTemplate else { fatalError() }

        // Check flag arguments.
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Foo", "StringList", ["CommandLineFlag": ""]),
            OptionData("Foo2", "StringList", ["CommandLineFlag": "foo2flag"]),
            OptionData("Bar", "StringList", ["CommandLinePrefixFlag": ""]),
            OptionData("Bar2", "StringList", ["CommandLinePrefixFlag": "bar2flag"]),]])
        #expect(warnings.count == 0)
        #expect(errors.count == 0)
        #expect(spec.buildOptions.count == 4)
        #expect(spec.buildOptions[0].name == "Foo")
        guard case .literal? = spec.buildOptions[0].otherValueDefn?.commandLineTemplate else { fatalError("unexpected template") }
        #expect(spec.buildOptions[1].name == "Foo2")
        guard case .flag(let foo2expr)? = spec.buildOptions[1].otherValueDefn?.commandLineTemplate, foo2expr.stringRep == "foo2flag" else { fatalError("unexpected template") }
        #expect(spec.buildOptions[2].name == "Bar")
        guard case .literal? = spec.buildOptions[2].otherValueDefn?.commandLineTemplate else { fatalError("unexpected template") }
        #expect(spec.buildOptions[3].name == "Bar2")
        guard case  .prefixFlag(let bar2expr)? = spec.buildOptions[3].otherValueDefn?.commandLineTemplate, bar2expr.stringRep == "bar2flag" else { fatalError("unexpected template") }
    }

    @Test
    func propertyDomainSpecPropertiesCommandLineKeysScalarTypeValuesParsing() async throws {
        let z = OptionData("Opt", "Enumeration", ["Values": [
            [ "Foo1": "Bar"],
            [ "Value": "Foo2", "Foo1": "Bar" ],
            [ "Value": "Foo2" ],
            [ "Value": "Foo3", "DisplayName": "X", "Outputs": "X" ] as PropertyListItem,
            [ "Value": "Foo4", "CommandLine": ["bad"]] as PropertyListItem,
            [ "Value": "Foo5", "CommandLine": "good thing", "CommandLineFlag": "bad" ] as PropertyListItem,
            "Foo5",
            PropertyListItem.plData(Array("bad".utf8)),
        ]])
        var (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ z ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 8)
        XCTAssertMatch(errors[0], .prefix("unknown build option value key 'Foo1' for value '<UNKNOWN>' in option 'Opt'"))
        XCTAssertMatch(errors[1], .prefix("missing build option value key 'Value' in option 'Opt'"))
        XCTAssertMatch(errors[2], .prefix("unknown build option value key 'Foo1' for value 'Foo2' in option 'Opt'"))
        XCTAssertMatch(errors[3], .prefix("duplicate value definition 'Foo2' for option 'Opt'"))
        XCTAssertMatch(errors[4], .prefix("expected string value for build option value key 'CommandLine'"))
        XCTAssertMatch(errors[5], .prefix("invalid build option value key"))
        XCTAssertMatch(errors[5], .contains("cannot combine with"))
        XCTAssertMatch(errors[6], .prefix("duplicate value definition 'Foo5' for option 'Opt'"))
        XCTAssertMatch(errors[7], .prefix("invalid value definition data"))

        // Check the option values.
        #expect(spec.buildOptions.count == 1)
        #expect(spec.buildOptions[0].valueDefns != nil)
        var values = spec.buildOptions[0].valueDefns!
        #expect(values.keys.sorted(by: <) == ["Foo2", "Foo3", "Foo4", "Foo5"])
        #expect(values["Foo2"]!.commandLineTemplate == nil)
        #expect(values["Foo3"]!.commandLineTemplate == nil)
        #expect(values["Foo4"]!.commandLineTemplate == nil)
        // The state of Foo5 is undefined due to the error reported above.

        // Check CommandLineArgs.
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Opt", "Enumeration", [
            "Values": [
                [ "Value": "Foo1", "CommandLineArgs": "bad" ] as PropertyListItem,
                [ "Value": "Foo2", "CommandLineArgs": ["thing1 thing2", "thing3", ["bad"]] as PropertyListItem] as PropertyListItem,
            ] as PropertyListItem]) ] as PropertyListItem])
        #expect(warnings.count == 0)
        #expect(errors.count == 2)
        XCTAssertMatch(errors[0], .prefix("expected array value for build option value key 'CommandLineArgs'"))
        XCTAssertMatch(errors[1], .prefix("expected string in 'CommandLineArgs' for value 'Foo2'"))

        // Check the option values.
        #expect(spec.buildOptions.count == 1)
        #expect(spec.buildOptions[0].valueDefns != nil)
        values = spec.buildOptions[0].valueDefns!
        #expect(values.keys.sorted(by: <) == ["Foo1", "Foo2"])
        guard case .args(let foo2items)? = values["Foo2"]!.commandLineTemplate, foo2items.stringRep == "thing1\\ thing2 thing3" else { fatalError() }

        // Check CommandLineFlag.
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Opt", "Enumeration", [
            "Values": [
                [ "Value": ["Bad"]],
                [ "Value": "Foo1", "CommandLineFlag": ["bad"]] as PropertyListItem,
                [ "Value": "Foo2", "CommandLineFlag": "good" ] as PropertyListItem,
            ]]) ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 3)
        XCTAssertMatch(errors[0], .prefix("invalid build option value key 'Value'"))
        XCTAssertMatch(errors[1], .prefix("missing build option value key 'Value' in option 'Opt'"))
        XCTAssertMatch(errors[2], .prefix("expected string value for build option value key 'CommandLineFlag'"))

        // Check the option values.
        #expect(spec.buildOptions.count == 1)
        #expect(spec.buildOptions[0].valueDefns != nil)
        values = spec.buildOptions[0].valueDefns!
        #expect(values.keys.sorted(by: <) == ["Foo1", "Foo2"])
        guard case .flag(let foo2expr)? = values["Foo2"]!.commandLineTemplate, foo2expr.stringRep == "good" else { fatalError() }

        // Check Boolean specific checks.
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Opt", "Boolean", ["Values": [
            [ "Value": "Hello" ], [ "Value": "NO" ], [ "Value": "YES" ] ]]) ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("unexpected 'Hello' value definition"))
    }

    @Test
    func propertyDomainSpecPropertiesCommandLineKeysScalarTypeCommandLineArgsParsing() async throws {
        var (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Opt0", "String", ["CommandLineArgs": []]),
            OptionData("Opt1", "String", ["CommandLineArgs": ""]),
            OptionData("Opt2", "String", ["CommandLineFlag": ""]),
            OptionData("Opt3", "String", ["CommandLinePrefixFlag": ""]),
            OptionData("Opt4", "String", [:]),
        ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 0)

        // Check the option values.
        #expect(spec.buildOptions.count == 5)
        #expect(spec.buildOptions[0].name == "Opt0")
        guard case .empty? = spec.buildOptions[0].otherValueDefn?.commandLineTemplate else { fatalError() }
        #expect(spec.buildOptions[1].name == "Opt1")
        guard case .empty? = spec.buildOptions[1].otherValueDefn?.commandLineTemplate else { fatalError() }
        #expect(spec.buildOptions[2].name == "Opt2")
        guard case .literal? = spec.buildOptions[2].otherValueDefn?.commandLineTemplate else { fatalError() }
        #expect(spec.buildOptions[3].name == "Opt3")
        guard case .literal? = spec.buildOptions[3].otherValueDefn?.commandLineTemplate else { fatalError() }
        #expect(spec.buildOptions[4].name == "Opt4")
        #expect(spec.buildOptions[4].otherValueDefn == nil)

        // This is split just for compile time reasons. :(
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Opt4", "String", ["CommandLineArgs": ["foo"]]),
            OptionData("Opt5", "String", ["CommandLineArgs": "foo"]),
            OptionData("Opt6", "String", ["CommandLineFlag": "foo"]),
            OptionData("Opt7", "String", ["CommandLinePrefixFlag": "foo"]),
        ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 0)
        #expect(spec.buildOptions.count == 4)
        #expect(spec.buildOptions[0].name == "Opt4")
        guard case .args(let opt4args)? = spec.buildOptions[0].emptyValueDefn?.commandLineTemplate, opt4args.stringRep == "foo" else { fatalError() }
        guard case .args(let opt4args2)? = spec.buildOptions[0].otherValueDefn?.commandLineTemplate, opt4args2.stringRep == "foo" else { fatalError() }
        #expect(spec.buildOptions[1].name == "Opt5")
        guard case .args(let opt5args)? = spec.buildOptions[1].emptyValueDefn?.commandLineTemplate, opt5args.stringRep == "foo" else { fatalError() }
        guard case .args(let opt5args2)? = spec.buildOptions[1].otherValueDefn?.commandLineTemplate, opt5args2.stringRep == "foo" else { fatalError() }
        #expect(spec.buildOptions[2].name == "Opt6")
        guard case .flag(let opt2expr)? = spec.buildOptions[2].otherValueDefn?.commandLineTemplate, opt2expr.stringRep == "foo" else { fatalError() }
        #expect(spec.buildOptions[3].name == "Opt7")
        guard case  .prefixFlag(let opt3expr)? = spec.buildOptions[3].otherValueDefn?.commandLineTemplate, opt3expr.stringRep == "foo" else { fatalError() }

        // Check string dict args handling.
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Opt0", "String", ["CommandLineArgs": [
                "": "",
                "foo0": "",
                "foo1": [] as PropertyListItem,
                "foo2": "hello little",
                "foo3": ["hello little", ["bad"], "world"] as PropertyListItem,
                "foo4": ["bad": "bad"],
                "<<otherwise>>": "otherwise" ] as PropertyListItem]),
        ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 2)
        XCTAssertMatch(errors[0], .prefix("expected string for 'foo3' in 'CommandLineArgs'"))
        XCTAssertMatch(errors[1], .prefix("invalid build option value for 'foo4'"))
        #expect(spec.buildOptions.count == 1)
        guard case .empty? = spec.buildOptions[0].emptyValueDefn?.commandLineTemplate else { fatalError() }
        guard case .args(let otherArgs)? = spec.buildOptions[0].otherValueDefn?.commandLineTemplate, otherArgs.stringRep == "otherwise" else { fatalError() }
        #expect(spec.buildOptions[0].valueDefns != nil)
        var values = spec.buildOptions[0].valueDefns!
        #expect(values.keys.sorted(by: <) == ["foo0", "foo1", "foo2", "foo3"])
        guard case .args(let foo2args)? = values["foo2"]?.commandLineTemplate, foo2args.stringRep == "hello little" else { fatalError() }
        guard case .args(let foo3args)? = values["foo3"]?.commandLineTemplate, foo3args.stringRep == "hello\\ little world" else { fatalError() }

        // Check boolean dict args handling.
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Opt0", "Boolean", ["CommandLineArgs": [
                "NO": "thisisno",
                "YES": "thisisyes" ]])
        ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 0)
        #expect(spec.buildOptions.count == 1)
        guard case .args(let noArgs)? = spec.buildOptions[0].emptyValueDefn?.commandLineTemplate, noArgs.stringRep == "thisisno" else { fatalError() }
        guard case .args(let yesArgs)? = spec.buildOptions[0].otherValueDefn?.commandLineTemplate, yesArgs.stringRep == "thisisyes" else { fatalError() }

        // Check dict value merging.
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Opt0", "Enumeration", ["Values": [
                ["Value": "Value0"],
                ["Value": "Value1", "CommandLineFlag": "OK"],
                ["Value": "Value2"],
                ["Value": "Empty", "CommandLineFlag": ""]
            ], "CommandLineArgs": ["Value0": "", "Value1": "BAD", "Value2": "INHERITED", "Value3": "INHERITED2"]]),
        ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid key 'Value1' in 'CommandLineArgs', a command line template was already defined"))
        values = spec.buildOptions[0].valueDefns!
        #expect(values.keys.sorted(by: <) == ["Empty", "Value0", "Value1", "Value2", "Value3"])
        guard case .empty? = values["Value0"]!.commandLineTemplate else { fatalError() }
        guard case .flag(let value1expr)? = values["Value1"]?.commandLineTemplate, value1expr.stringRep == "OK" else { fatalError() }
        guard case .args(let value2expr)? = values["Value2"]?.commandLineTemplate, value2expr.stringRep == "INHERITED" else { fatalError() }
        guard case .args(let value3expr)? = values["Value3"]?.commandLineTemplate, value3expr.stringRep == "INHERITED2" else { fatalError() }
        guard case .empty? = values["Empty"]!.commandLineTemplate else { fatalError() }

        // Check array value merging.
        (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Opt0", "Enumeration", ["Values": [
                ["Value": "Value0"],
                ["Value": "Value4", "CommandLineFlag": "OK"],
                ["Value": "Empty", "CommandLineFlag": ""]
            ], "CommandLineArgs": ["INHERITED"]]),
        ]])
        #expect(warnings.count == 0)
        #expect(errors.count == 0)
        values = spec.buildOptions[0].valueDefns!
        #expect(values.keys.sorted(by: <) == ["Empty", "Value0", "Value4"])
        guard case .args(let value0expr)? = values["Value0"]?.commandLineTemplate, value0expr.stringRep == "INHERITED" else { fatalError() }
        guard case .flag(let value4expr)? = values["Value4"]?.commandLineTemplate, value4expr.stringRep == "OK" else { fatalError() }
        guard case .empty? = values["Empty"]!.commandLineTemplate else { fatalError() }
    }

    @Test
    func propertyDomainSpecPropertiesCommandConditionParsing() async throws {
        var (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "String", ["Condition": "$(Bar) == bar"]) ]])
        #expect(errors.count == 0)

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "String", ["Condition": ["$(Bar) == bar"]]) ]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("expected string value for build option key \'Condition\'"))

        (_, _, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [ OptionData("Foo", "String", ["Condition": "$(Bar == bar"]) ]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("unable to parse value for build option key \'Condition\'"))
    }

    @Test
    func propertyDomainSpecPropertiesAdditionalLinkerArgsParsing() async throws {
        do {
            let (_, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
                OptionData("Opt0", "String", ["AdditionalLinkerArgs": []]),
            ]])
            #expect(warnings == [])
            XCTAssertMatch(errors, [.prefix("expected dictionary value for build option key 'AdditionalLinkerArgs'")])
        }

        do {
            let (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
                OptionData("Opt0", "Enumeration", ["Values": [], "AdditionalLinkerArgs": ["SomeKey": "Value"]]),
            ]])
            #expect(warnings == [])
            XCTAssertMatch(errors, [])
            #expect(spec.buildOptions.count == 1)

            let opt = spec.buildOptions[0]
            #expect(opt.valueDefns?.count == 1)
            let (key, value) = opt.valueDefns!.first!
            #expect(key == "SomeKey")
            #expect(value.commandLineTemplate == nil)
            #expect(value.additionalLinkerArgs?.stringRep == "Value")
        }

        do {
            let (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
                OptionData("Opt0", "Boolean", ["AdditionalLinkerArgs": [
                    "NO": "NOValue",
                    "YES": ["YESValue"],
                    "BAD": "BADValue"]]),
            ]])
            #expect(warnings == [])
            XCTAssertMatch(errors, [.prefix("unexpected 'BAD' linker args")])
            #expect(spec.buildOptions.count == 1)

            let opt = spec.buildOptions[0]
            #expect(opt.valueDefns == nil)

            #expect(opt.emptyValueDefn != nil)
            let noValue = opt.emptyValueDefn!
            #expect(noValue.commandLineTemplate == nil)
            #expect(noValue.additionalLinkerArgs?.stringRep == "NOValue")

            #expect(opt.otherValueDefn != nil)
            let yesValue = opt.otherValueDefn!
            #expect(yesValue.commandLineTemplate == nil)
            #expect(yesValue.additionalLinkerArgs?.stringRep == "YESValue")
        }

        do {
            let (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
                OptionData("Opt0", "String", [
                    "CommandLineArgs": [
                        "": ["xxx"],
                        "defined": ["xxx"],
                        "undefined": ["xxx"],
                        "<<otherwise>>": ["xxx"]],
                    "AdditionalLinkerArgs": [
                        "": "EmptyValue",
                        "defined": ["DefinedValue"],
                        "<<otherwise>>": ["OtherValue"]]]),
            ]])
            #expect(warnings == [])
            #expect(errors == [])
            #expect(spec.buildOptions.count == 1)

            let opt = spec.buildOptions[0]
            if let valueDefns = opt.valueDefns {
                #expect(valueDefns.count == 2)
                #expect(valueDefns["defined"]?.additionalLinkerArgs?.stringRep == "DefinedValue")
                #expect(valueDefns["undefined"]?.additionalLinkerArgs?.stringRep == "OtherValue")
            }
            else {
                Issue.record("opt.valueDefns is unexpectedly nil")
            }

            #expect(opt.emptyValueDefn != nil)
            let noValue = opt.emptyValueDefn!
            #expect(noValue.commandLineTemplate != nil)
            #expect(noValue.additionalLinkerArgs?.stringRep == "EmptyValue")

            #expect(opt.otherValueDefn != nil)
            let yesValue = opt.otherValueDefn!
            #expect(yesValue.commandLineTemplate != nil)
            #expect(yesValue.additionalLinkerArgs?.stringRep == "OtherValue")
        }

        // Test an edge case where there is only an empty and an otherwise definition.
        do {
            let (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
                OptionData("Opt0", "String", [
                    "CommandLineArgs": [
                        "": ["xxx"],
                        "<<otherwise>>": ["xxx"]],
                    "AdditionalLinkerArgs": [
                        "": "EmptyValue",
                        "<<otherwise>>": ["OtherValue"]]]),
            ]])
            #expect(warnings == [])
            #expect(errors == [])
            #expect(spec.buildOptions.count == 1)

            let opt = spec.buildOptions[0]
            #expect(opt.valueDefns == nil)

            #expect(opt.emptyValueDefn != nil)
            let noValue = opt.emptyValueDefn!
            #expect(noValue.commandLineTemplate != nil)
            #expect(noValue.additionalLinkerArgs?.stringRep == "EmptyValue")

            #expect(opt.otherValueDefn != nil)
            let yesValue = opt.otherValueDefn!
            #expect(yesValue.commandLineTemplate != nil)
            #expect(yesValue.additionalLinkerArgs?.stringRep == "OtherValue")
        }
    }

    @Test
    func propertyDomainSpecMacroBinding() async throws {
        let (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Foo", "Boolean", [:]),
            OptionData("Foo2", "String", [:]),
            OptionData("Foo3", "StringList", [:]),
            OptionData("Foo3", "String", [:])]])
        #expect(warnings.count == 0)
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("unable to declare macro for option 'Foo3'"))

        #expect(spec.buildOptions.count == 4)
        #expect(spec.buildOptions[0].name == "Foo")
        #expect(spec.buildOptions[0].macro.name == "Foo")
        #expect(spec.buildOptions[0].macro.type == .boolean)

        #expect(spec.buildOptions[1].name == "Foo2")
        #expect(spec.buildOptions[1].macro.name == "Foo2")
        #expect(spec.buildOptions[1].macro.type == .string)

        #expect(spec.buildOptions[2].name == "Foo3")
        #expect(spec.buildOptions[2].macro.name == "Foo3")
        #expect(spec.buildOptions[2].macro.type == .stringList)
    }

    @Test
    func propertyDomainSpecMacroDefaultValues() async throws {
        let (spec, warnings, errors) = try await parseTestSpec(BuildSystemSpec.self, ["Properties": [
            OptionData("Foo", "Boolean", ["DefaultValue": "NO"]),
            OptionData("Foo2", "String", ["DefaultValue": ["bad"]])]])
        #expect(warnings.count == 0)
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("expected string value for build option key 'DefaultValue' for option 'Foo2'"))

        #expect(spec.buildOptions.count == 2)
        #expect(spec.buildOptions[0].name == "Foo")
        #expect(spec.buildOptions[0].defaultValue?.stringRep == "NO")

        #expect(spec.buildOptions[1].name == "Foo2")
        #expect(spec.buildOptions[1].defaultValue == nil)
    }

    @Test
    func buildSettingWithBasedOnSpec() async throws {
        let (rootspec, rw, re) = try await parseTestSpec(BuildSettingsSpec.self, ["Properties": [
            OptionData("FOO", "String", ["DefaultValue": "$(inherited) no"]),
            OptionData("BAR", "String", ["DefaultValue": "i386"])]])
        #expect(rootspec.buildOptions.count == 2)
        #expect(rw.count == 0)
        #expect(re.count == 0)

        let (spec, warnings, errors) = try await parseTestSpec(BuildSettingsSpec.self, ["Properties": [
            OptionData("FOO", "String", ["DefaultValue": "$(inherited) yes"])]], rootspec)
        #expect(spec.buildOptions.count == 1)
        #expect(warnings.count == 0)
        #expect(errors.count == 0)

        let buildOptions = spec.flattenedBuildOptions
        #expect(buildOptions.count == 2)

        #expect(buildOptions["FOO"] != nil)
        #expect(buildOptions["FOO"]?.defaultValue?.stringRep == "$(inherited) yes")

        #expect(buildOptions["BAR"] != nil)
        #expect(buildOptions["BAR"]?.defaultValue?.stringRep == "i386")
    }

    @Test
    func buildPropertiesWithConditionsAndBasedOnSpec() async throws {
        let (rootspec, rw, re) = try await parseTestSpec(PackageTypeSpec.self, [
            "DefaultBuildSettings": [
                "OTHER_CFLAGS": "$(inherited) base_flags",
                "OTHER_CFLAGS[sdk=iphoneos]": "$(inherited) base_iphoneos",
                "OTHER_LDFLAGS": "base"
            ]])
        #expect(rootspec.buildSettings.valueAssignments.count == 3)
        #expect(rw.count == 0)
        #expect(re.count == 0)

        let (spec, warnings, errors) = try await parseTestSpec(PackageTypeSpec.self, [
            "DefaultBuildSettings": [
                "OTHER_CFLAGS": "$(inherited) super_flags",
                "OTHER_CFLAGS[sdk=iphoneos]": "$(inherited) super_iphoneos"]], rootspec)
        #expect(spec.buildSettings.valueAssignments.count == 3)
        #expect(warnings.count == 0)
        #expect(errors.count == 0)

        let scope = MacroEvaluationScope(table: spec.buildSettings)
        #expect(scope.evaluate(BuiltinMacros.OTHER_CFLAGS) == ["super_flags"])
        #expect(scope.evaluate(BuiltinMacros.OTHER_LDFLAGS) == ["base"])

        let conditionedScope = MacroEvaluationScope(table: spec.buildSettings, conditionParameterValues: [spec.buildSettings.namespace.lookupConditionParameter("sdk")!: ["iphoneos"]])
        #expect(conditionedScope.evaluate(BuiltinMacros.OTHER_CFLAGS) == ["super_flags", "super_iphoneos"])
        #expect(conditionedScope.evaluate(BuiltinMacros.OTHER_LDFLAGS) == ["base"])
    }

    /// Validate that we can load a known command line spec properly.
    @Test
    func commandLineSpecLoading() async throws {
        let infoPlistUtilSpec = try await getCore().specRegistry.getSpec("com.apple.tools.info-plist-utility") as CommandLineToolSpec
        #expect(infoPlistUtilSpec.execDescription!.stringRep.hasPrefix("Process"))

        // Check diagnostics using synthetic data.
        do {
            let (spec, warnings, errors) = try await parseTestSpec(GenericCommandLineToolSpec.self,
                                                             [
                                                                "Name": "Mock",
                                                                "RuleName": "Mock [output] [input]",
                                                                "Type": "Compiler",
                                                                "CommandLine": ["foo"],
                                                                "Outputs": ["$(((bogus", "$(OutputPath)"]
                                                             ])
            #expect(warnings == [])
            XCTAssertMatch(errors, [.prefix("macro parsing error in 'Outputs'")])

            #expect(spec.outputs != nil)
        }
    }

    /// Test characteristics of loading compiler specs.
    @Test
    func compilerSpecLoading() async throws {
        // Test the allowed values for 'Architectures': Unset, set to an array of strings, and set specifically to the string "$(VALID_ARCHS)".
        var (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "", "RuleName": ""])
        #expect(errors.isEmpty, "Parsing compiler spec resulted in errors: \(errors)")

        (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "", "RuleName": "", "Architectures": ["arm64", "arm64e"]])
        #expect(errors.isEmpty, "Parsing compiler spec resulted in errors: \(errors)")

        (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "", "RuleName": "", "Architectures": "$(VALID_ARCHS)"])
        #expect(errors.isEmpty, "Parsing compiler spec resulted in errors: \(errors)")

        // Check that unsupported values result in errors.
        (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "", "RuleName": "", "Architectures": "arm64e"])            // Other string values not supported.
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("unexpected item: \"arm64e\" while parsing key Architectures"))
    }

    @Test
    func environmentVariableConsistentOrdering() async throws {
        let core = try await getCore()
        let migSpec: CompilerSpec = try core.specRegistry.getSpec("com.apple.compilers.mig") as CompilerSpec
        #expect(migSpec.environmentVariables?.map({ $0.0 }) == ["DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS"])
    }

    /// Test that loading concrete compiler specs in our Xcode install work as expected.
    @Test
    func concreteCompilerSpecLoading() async throws {
        let core = try await getCore()

        // Validate that we can load a compiler spec properly.
        let clangCompilerSpec: CompilerSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0.compiler") as ClangCompilerSpec

        // Validate that non-custom implementations get the custom subclass.
        #expect(core.specRegistry.getSpec("com.apple.build-tasks.copy-png-file")! is GenericCompilerSpec)

        // Validate that we properly fetch the Class field from the base spec.
        let analyzerSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0.analyzer") as CompilerSpec
        #expect(analyzerSpec is ClangCompilerSpec)
        let analyzerSpecIPhone = try #require(core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0.analyzer", domain: "iphoneos"))
        #expect(analyzerSpecIPhone is ClangCompilerSpec)

        // Validate that we parse other properties from the base spec.
        let clangSpec = try core.specRegistry.getSpec("com.apple.compilers.llvm.clang.1_0") as CompilerSpec
        #expect(clangSpec.execDescription == clangCompilerSpec.execDescription)

        // Validate overridden class loading.
        let codesignSpec = core.specRegistry.getSpec("com.apple.build-tools.codesign")
        #expect(codesignSpec is CodesignToolSpec)

        // Validate loading of supported language versions
        let swiftCompilerSpec = try core.specRegistry.getSpec() as SwiftCompilerSpec
        #expect(swiftCompilerSpec.supportedLanguageVersions == [ Version(4,0), Version(4,2), Version(5,0), Version(6, 0)])
    }

    @Test
    func compilerSpecCommandLineParsing() async throws {
        for arg in ["exec-path", "input", "inputs", "options", "output", "special-args"] {
            let (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": .plString("[\(arg)] [\(arg)]"), "RuleName": ""])
            #expect(errors.count == 1)
            XCTAssertMatch(errors[0], .prefix("duplicate 'CommandLine' template arg: '[\(arg)]'"))
        }

        var (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "[input] [inputs]", "RuleName": ""])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid 'CommandLine' template"))
        (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "[inputs] [input]", "RuleName": ""])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid 'CommandLine' template"))

        (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "[bogus]", "RuleName": ""])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid 'CommandLine' template placeholder"))

        (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "cc [options] -fsyntax-only", "RuleName": ""])
        #expect(errors.count == 0)

        // Don't report duplicate errors from base specs.
        let (baseSpec, _, baseErrors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "[input] [input]", "RuleName": ""])
        #expect(baseErrors.count == 1)
        XCTAssertMatch(baseErrors[0], .prefix("duplicate 'CommandLine' template arg"))
        let (derivedSpec, _, derivedErrors) = try await parseTestSpec(GenericCompilerSpec.self, ["Unused": ""], baseSpec)
        #expect(derivedErrors.count == 0)
        #expect(derivedSpec.commandLineTemplate != nil)
    }

    @Test
    func compilerSpecRuleNameParsing() async throws {
        for arg in ["input", "output"] {
            let (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "", "RuleName": .plString("[\(arg)] [\(arg)]")])
            #expect(errors.count == 1)
            XCTAssertMatch(errors[0], .prefix("duplicate 'RuleName' template arg: '[\(arg)]'"))
        }

        var (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "", "RuleName": "[bogus]"])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid 'RuleName' template placeholder"))

        (_, _, errors) = try await parseTestSpec(GenericCompilerSpec.self, ["CommandLine": "", "RuleName": "Compile [output] [input]"])
        #expect(errors.count == 0)
    }

    @Test
    func compilerSpecEnvironmentVariablesParsing() async throws {
        var (_, _, errors) = try await parseTestSpec(CommandLineToolSpec.self, ["EnvironmentVariables": ""])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid value for 'EnvironmentVariables' key (expected dictionary)"))

        (_, _, errors) = try await parseTestSpec(CommandLineToolSpec.self, ["EnvironmentVariables": ["bad": ["bad"]]])
        #expect(errors.count == 1)
        XCTAssertMatch(errors[0], .prefix("invalid value for 'bad' key in 'EnvironmentVariables' (expected string)"))

        (_, _, errors) = try await parseTestSpec(CommandLineToolSpec.self, ["EnvironmentVariables": ["OK": "GOOD"]])
        #expect(errors.count == 0)
    }

    /// Validate that we can load a linker spec properly.
    @Test
    func linkerSpecLoading() async throws {
        try #require(try await (getCore().specRegistry.getSpec() as LdLinkerSpec).execDescription?.stringRep.hasPrefix("Link") == true)
    }

    /// Validate there are no cases of domain inversion.
    @Test
    func specDomainInversion() async throws {
        try await getCore().specRegistry.validateSpecDomainInversion(reportError: { error in
            Issue.record(Comment(rawValue: error))
        })
    }
}
