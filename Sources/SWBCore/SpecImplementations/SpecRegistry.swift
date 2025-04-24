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

import SWBLibc
public import SWBUtil
public import SWBMacro
import Foundation
import Synchronization

/// Delegate protocol used by the registry to report diagnostics.
@_spi(Testing) public protocol SpecRegistryDelegate: DiagnosticProducingDelegate {}

/// Errors thrown when loading a spec of a specific type fails.
public enum SpecLoadingError: Error {
    /// No spec with `identifier` exists in `domain`.
    case notFound(identifier: String, domain: String)
    /// A spec with `identifier` was found in `domain`, but was not of the type `expectedType`.
    case wrongType(identifier: String, domain: String, expectedType: Spec.Type, actualType: Spec.Type)
}

extension SpecLoadingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .notFound(identifier, domain):
            return "Couldn't load spec with identifier '\(identifier)'" + (!domain.isEmpty ? " in domain '\(domain)'" : "")
        case let .wrongType(identifier, domain, expectedType, actualType):
            return "Loaded spec with identifier '\(identifier)'" + (!domain.isEmpty ? " in domain '\(domain)'" : "") + ", but was not of the expected type '\(expectedType)' (was '\(actualType)')"
        }
    }
}

/// Protocol adopted by all spec *types* (subclasses of Spec).
public protocol SpecType: AnyObject {
    /// The name of the specification type.
    static var typeName: String { get }

    /// The name of the spec subregistry to associate with this type.
    static var subregistryName: String { get }

    /// The default class type to instantiate as, if not overridden.
    ///
    /// By default, this will be the SpecType itself, however this can be used to force specs which do not override 'Class' to be instantiated as a separate type (which would generally be a subclass of the actual SpecType). This is useful when specs without a custom 'Class' support a different set of keys than those that do.
    static var defaultClassType: (any SpecType.Type)? { get }

    /// Load the spec for the given proxy.
    static func parseSpec(_ delegate: any SpecParserDelegate, _ proxy: SpecProxy, _ basedOnSpec: Spec?) -> Spec
}

/// Protocol adopted by all internal spec implementations.
public protocol SpecImplementationType: SpecType, IdentifiedSpecType {
    /// The identifier of the spec.
    static var identifier: String { get }

    /// Construction the specification implementation.
    static func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec
}

/// Protocol adopted by all spec implementations with an identifier.
public protocol IdentifiedSpecType {
    /// The identifier of the spec.
    static var identifier: String { get }
}

/// "Classic" spec implementations whose specifications use a "Class" key.
public protocol SpecClassType: SpecType {
    /// The name of the specification class this type provides.
    static var className: String { get }
}

/// "Modern" spec implementations whose specifications do not use a "Class" key.
public protocol SpecIdentifierType: SpecType, IdentifiedSpecType {
    /// The identifier of the spec.
    static var identifier: String { get }
}

public final class SpecProxy {
    @_spi(Testing) public typealias SpecData = [String: PropertyListItem]

    /// The identifier of the spec.
    @_spi(Testing) public let identifier: String

    /// The domain the spec is registered in.
    //
    // FIXME: Eventually, it would be nice to have domains be fully registered and not string based.
    @_spi(Testing) public let domain: String

    /// The path the spec was loaded from.
    @_spi(Testing) public let path: Path

    /// The type of the spec.
    @_spi(Testing) public let type: any SpecType.Type

    /// The specific subclass instance to use, if defined.
    @_spi(Testing) public let classType: (any SpecType.Type)?

    /// The base spec specifier, if defined.
    @_spi(Testing) public let basedOn: String?

    /// The base spec proxy, if defined.
    ///
    /// This is initialized after loading is complete to ensure that we can resolve all references.
    @_spi(Testing) public var basedOnProxy: SpecProxy?

    /// The spec data.
    let data: SpecData

    /// The spec localization data, if available.
    let localizedStrings: [String: String]?

    /// The loaded spec.
    enum LoadedSpecKind {
        case notLoaded
        case error(diagnostics: [Diagnostic])
        case loading
        case loaded(spec: Spec)
    }
    private var loadedSpec = LoadedSpecKind.notLoaded

    /// The display string to use when printing this proxy.
    @_spi(Testing) public var specifierString: String {
        return "'\(domain):\(identifier)'"
    }

    @_spi(Testing) public init(identifier: String, domain: String, path: Path, type: any SpecType.Type, classType: (any SpecType.Type)?, basedOn: String?, data: SpecData, localizedStrings: [String: String]?) {
        self.identifier = identifier
        self.domain = domain
        self.path = path
        self.type = type
        self.classType = classType
        self.basedOn = basedOn
        self.basedOnProxy = nil
        self.data = data
        self.localizedStrings = localizedStrings
    }

    /// Force resolution of the basedOn reference.  Returns false if the basedOn reference could not be resolved.  But returns true if the spec does not have a basedOn reference specifier to resolve.
    func resolveBasedOnReference(_ registry: SpecRegistry) -> Bool {
        // Extract the basedOn specifier, if present.  If not present, then return true.
        guard let specifier = self.basedOn else { return true }

        // Extract the identifier and domain. If present, the domain is prefixed followed by ':' and the identifier, otherwise the entire string should be the identifier.
        let (lhs, rhs) = specifier.split(":")
        let (identifier, domain) = rhs.isEmpty ? (lhs, self.domain) : (rhs, lhs == "default" ? "" : lhs)

        // Look up the base proxy.
        guard let baseProxy = registry.lookupProxy(identifier, domain: domain) else {
            registry.error(path, "missing base spec '\(domain):\(identifier)' for spec '\(self.domain):\(self.identifier)'")
            return false
        }

        // Validate that the base proxy is of a compatible type.
        if baseProxy.type != self.type {
            registry.error(path, "incompatible base spec '\(domain):\(identifier)' for spec '\(self.domain):\(self.identifier)', type: '\(baseProxy.type)' (expected: '\(self.type)')")
            return false
        }

        // Validate that the base proxy itself can be resolved, recursively.
        // Make sure to check for self to handle potential cycles.
        if self !== baseProxy && !baseProxy.resolveBasedOnReference(registry) {
            return false
        }

        // Assign the basedOn proxy.
        basedOnProxy = baseProxy
        return true
    }

    /// Get the resolve spec type to use for this proxy.
    var resolvedType: any SpecType.Type {
        return self.classType ?? self.basedOnProxy?.resolvedType ?? self.type.defaultClassType ?? self.type
    }

    /// Load the spec from an internal implementation.
    func load(implementation spec: Spec) {
        guard case .notLoaded = loadedSpec else { fatalError("unexpected concrete implementation") }
        loadedSpec = .loaded(spec: spec)
    }

    /// Load the spec for this proxy.
    ///
    /// This will load the specification, if possible, and return the result.
    ///
    /// If there was an error while loading the diagnostics will be reported through the spec and nil will be returned.
    @_spi(Testing) public func load(_ registry: SpecRegistry) -> Spec? {
        // Return the loaded result, if we have already computed it.
        switch loadedSpec {
        case .loaded(let spec):
            return spec

        case .error:
            return nil

        case .loading:
            let loadingErrorDiagnostic = Diagnostic(behavior: .error, location: .path(self.path), data: DiagnosticData("encountered cyclic dependency while loading \(specifierString)"))
            loadedSpec = .error(diagnostics: [loadingErrorDiagnostic])
            registry.emit(loadingErrorDiagnostic)
            return nil

        case .notLoaded:
            break
        }

        // Otherwise, load the spec.
        loadedSpec = .loading

        // If we have a base spec, load it.
        var basedOnSpec: Spec? = nil
        if let basedOnProxy = self.basedOnProxy {
            basedOnSpec = basedOnProxy.load(registry)
            if basedOnSpec == nil {
                let loadingErrorDiagnostic = Diagnostic(behavior: .error, location: .path(self.path), data: DiagnosticData("unable to load \(specifierString) due to errors loading base spec"), childDiagnostics: {
                    if case let .error(diagnostics) = basedOnProxy.loadedSpec {
                        return diagnostics
                    } else {
                        return []
                    }
                }())
                loadedSpec = .error(diagnostics: [loadingErrorDiagnostic])
                registry.emit(loadingErrorDiagnostic)
                return nil
            }
        }

        final class Delegate : SpecParserDelegate {
            let specRegistry: SpecRegistry
            let proxy: SpecProxy
            var internalMacroNamespace: MacroNamespace {
                return specRegistry.internalMacroNamespace
            }
            private let _diagnosticsEngine = DiagnosticsEngine()

            init(_ registry: SpecRegistry, _ proxy: SpecProxy) {
                self.specRegistry = registry
                self.proxy = proxy
                self._diagnosticsEngine.addHandler { [weak self] diag in
                    self?.handleDiagnostic(diag)
                }
            }

            var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
                return .init(_diagnosticsEngine)
            }

            func handleDiagnostic(_ diag: Diagnostic) {
                // Forward the diagnostic with more information attached.
                specRegistry.delegate.emit(Diagnostic(behavior: diag.behavior, location: .path(proxy.path), data: DiagnosticData("\(diag.data.description) (while parsing '\(proxy.identifier)')")))
            }

            func groupingStrategy(name: String, specIdentifier: String) -> (any InputFileGroupingStrategy)? {
                specRegistry.inputFileGroupingStrategyFactories[name]?.makeStrategy(specIdentifier: specIdentifier)
            }

            var hasErrors: Bool {
                _diagnosticsEngine.hasErrors
            }

            var diagnostics: [Diagnostic] {
                _diagnosticsEngine.diagnostics
            }
        }

        // Parse the spec data.
        let delegate = Delegate(registry, self)
        let result = resolvedType.parseSpec(delegate, self, basedOnSpec)

        // If there were errors, discard the spec.
        if delegate.hasErrors {
            loadedSpec = .error(diagnostics: delegate.diagnostics.filter { $0.behavior == .error })
            return nil
        }

        // Otherwise, cache the loaded result.
        loadedSpec = .loaded(spec: result)
        return result
    }

    /// Look up the spec data associated with the given key.
    ///
    /// This will search the proxy data for a definition of the key, or search
    /// in the base spec if not present.
    func lookupDataForKey(_ key: String, inherited: Bool = true) -> PropertyListItem? {
        if let result = data[key] {
            return result
        }
        if inherited {
            return basedOnProxy?.lookupDataForKey(key)
        }
        return nil
    }

    /// Look up the localized string for a given key-mangling.
    func lookupLocalizedString(_ key: String) -> String? {
        return localizedStrings?[key] ?? basedOnProxy?.lookupLocalizedString(key)
    }
}

extension SpecProxy: CustomStringConvertible {
    public var description: String {
        return "<\(Swift.type(of: self)): \"\(domain):\(identifier)\">"
    }
}

// Private ordering of SpecProxy objects.
private func <(lhs: SpecProxy, rhs: SpecProxy) -> Bool {
    // Every (identifier, domain) pair should be unique, so this should define a total ordering.
    return (lhs.identifier < rhs.identifier) || (lhs.identifier == rhs.identifier && lhs.domain < rhs.domain)
}

/// Domain specific spec registry.
@_spi(Testing) public final class SpecDomainRegistry {
    /// The domain the registry is for.
    let domain: String

    /// The map of spec proxies by identifier.
    @_spi(Testing) public fileprivate(set) var proxiesByIdentifier: [String: SpecProxy] = [:]

    init(_ domain: String) {
        self.domain = domain
    }
}

/// The SpecRegistry owns the set of registered specifications segregated by domain.
public final class SpecRegistry {
    /// The static map of registered spec types.
    private let specTypes: [String: any SpecType.Type]

    /// The static map of registered "classic" spec classes, those with "Class" in their spec.
    private let specClassesByClassName: [String: any SpecType.Type]

    /// The static map of registered "modern" spec classes, those without "Class" in their spec.
    private let specClassesByIdentifier: [String: any SpecType.Type]

    /// The static map of registered spec implementations.
    private let specImplementations: [String: any SpecImplementationType.Type]

    @_spi(Testing) public let inputFileGroupingStrategyFactories: [String: any InputFileGroupingStrategyFactory]

    /// The parser delegate.
    fileprivate let delegate: any SpecRegistryDelegate

    /// A lock for access to the registry delegate.
    private let delegateLock = SWBMutex(())

    /// The map of domain-specific registries.
    @_spi(Testing) public private(set) var proxiesByDomain: [String: SpecDomainRegistry] = [:]

    /// The map of which domains include other ones, in the order they should be searched.
    let domainInclusions: [String: [String]]

    /// Dictionary to support the special case of specs which have `basedOn` domain inversion, where a spec in a more general domain sometimes is based on specs in a more specific domain.
    /// FIXME: Cleaning this up is tracked by <rdar://problem/22361888> Swift Build: Change handling of "domain-inversion" for base specs
    let domainRemaps: [String: [String]]

    /// The namespace used to register internal macros (ones defined by specs).
    ///
    /// This namespace is global across all specs, but builds on top of the builtin macro namespace.
    public let internalMacroNamespace = MacroNamespace(parent: BuiltinMacros.namespace, debugDescription: "internal")

    /// Whether the registry has been frozen (mutations are no longer possible). The process will crash if something attempts to mutate it after it has been frozen.
    private var isFrozen = false

    /// Create a SpecRegistry from all of the specs in the given search paths.
    ///
    /// - parameter delegate: The delegate used to report diagnostics about spec loading.
    /// - parameter searchPaths: The list of (path, defaultDomain) tuples to search for specs. The path may be either a directory (which will be scanned for specs), or the path directly to an ".xcspec" which will be registered. In both cases, the defaultDomain specifies which domain to register the found specs in if the spec itself does not specify the domain.
    /// - parameter domainIncludes: The mapping of which domains include other ones.
    @_spi(Testing) public init(_ pluginManager: PluginManager, _ delegate: any SpecRegistryDelegate, _ searchPaths: [(Path, String)], _ domainInclusions: [String: [String]] = [:], _ domainRemaps: [String: [String]] = [:], loadBuiltinImplementations: Bool = true) async {
        self.delegate = delegate
        self.domainInclusions = domainInclusions
        self.domainRemaps = domainRemaps

        do {
            // Register specification types
            self.specTypes = await Dictionary(grouping: SpecificationsExtensionPoint.specificationTypes(pluginManager: pluginManager)) { $0.typeName }.compactMapValues { key, types in
                guard let type = types.only else {
                    preconditionFailure("attempt to register duplicate spec types for type name '\(key)': \(types)")
                }
                return type
            }

            // Register "modern" specification classes, ones without "Class" in their specification
            var specClassesByIdentifier = await Dictionary(grouping: SpecificationsExtensionPoint.specificationClasses(pluginManager: pluginManager)) { $0.identifier }.compactMapValues { key, types in
                guard let type = types.only else {
                    preconditionFailure("attempt to register duplicate spec class for identifier '\(key)': \(types)")
                }
                return type
            }

            // This spec is special in that it's both an abstract and concrete spec, so register the abstract identifier as well.
            // This allows subclasses like the preprocessor, assembler, and module verifier specs to load it as the right class.
            if let type = specClassesByIdentifier[ClangCompilerSpec.identifier] {
                specClassesByIdentifier["com.apple.compilers.llvm.clang.1_0"] = type
            }

            self.specClassesByIdentifier = specClassesByIdentifier

            // Register "classic" specification classes, ones with "Class" in their specification
            self.specClassesByClassName = await Dictionary(grouping: SpecificationsExtensionPoint.specificationClassesClassic(pluginManager: pluginManager)) { $0.className }.compactMapValues { key, types in
                guard let type = types.only else {
                    preconditionFailure("attempt to register duplicate classic spec class for class name '\(key)': \(types)")
                }
                return type
            }

            // Register specific specification implementations
            // These define internal implementations of the specs, which will automatically be added to any registry
            self.specImplementations = await Dictionary(grouping: SpecificationsExtensionPoint.specificationImplementations(pluginManager: pluginManager)) { $0.identifier }.compactMapValues { key, types in
                guard let type = types.only else {
                    preconditionFailure("attempt to register duplicate spec implementation for identifier '\(key)': \(types)")
                }
                return type
            }
        }

        self.inputFileGroupingStrategyFactories = await pluginManager.extensions(of: InputFileGroupingStrategyExtensionPoint.self).reduce([:], { $0.merging($1.groupingStrategies(), uniquingKeysWith: { _, _ in
            preconditionFailure("attempt to register duplicate input file grouping strategy")
        }) })

        // Register all the specs concurrently.
        //
        // NOTE: This must be done with care, in order to easily allow the work to be concurrent we only use one top-level async queue and simply wait for it with a barrier. That only is safe as long as *all* of the work is enqueued up front.
        //
        // FIXME: We could use producer and consumer queues more efficiently/safely/cleanly here.
        let registrationLock = SWBMutex(())
        let queue = SWBQueue(label: #function + "-discovery", qos: UserDefaults.undeterminedQoS, attributes: .concurrent, autoreleaseFrequency: .workItem)
        let group = SWBDispatchGroup()
        for (path, defaultDomain) in searchPaths {
            // We support direct listing of individual 'xcspec' files in the search list.
            // Ignore dotfiles, as installing roots on filesystems which don't support extended attributes (such as NFS) may create AppleDouble files.
            if !path.basename.hasPrefix(".") && path.fileSuffix == ".xcspec" {
                registerSpec(path, on: queue, group: group, domain: defaultDomain) { proxy in
                    registrationLock.withLock {
                        self.registerProxy(proxy)
                    }
                }
            } else {
                registerSpecsInDirectory(path, on: queue, group: group, domain: defaultDomain) { proxy in
                    registrationLock.withLock {
                        self.registerProxy(proxy)
                    }
                }
            }
        }

        // Wait for all registration to complete.
        await group.wait(queue: queue)

        // Resolve all of the based on references.
        //
        // FIXME: It is unfortunate we have to do a duplicate traversal for this, but it is much more annoying to need to resolve these lazily.
        for domain in proxiesByDomain.values {
            var proxyIdentsToRemove = Set<String>()
            for (identifier, proxy) in domain.proxiesByIdentifier {
                if !proxy.resolveBasedOnReference(self) {
                    // If we couldn't resolve the based-on reference, then we discard the spec altogether.  This is so we don't produce further downstream errors for a spec which we already know is broken for this reason.
                    proxyIdentsToRemove.insert(identifier)
                }
            }
            for identifier in proxyIdentsToRemove {
                domain.proxiesByIdentifier.removeValue(forKey: identifier)
            }
        }

        // Finally, instantiate any internal implementations.
        if loadBuiltinImplementations {
            for (identifier, type) in specImplementations {
                // Create a proxy to represent the spec.
                let proxy = SpecProxy(identifier: identifier, domain: "", path: Path(""), type: type, classType: type, basedOn: nil, data: [:], localizedStrings: [:])

                // Instantiate the spec.
                proxy.load(implementation: type.construct(registry: self, proxy: proxy))

                self.registerProxy(proxy)
            }
        }
    }

    func warning(_ path: Path, _ message: String) {
        delegateLock.withLock {
            self.delegate.warning(path, message)
        }
    }

    func error(_ path: Path, _ message: String) {
        delegateLock.withLock {
            self.delegate.error(path, message)
        }
    }

    func emit(_ diagnostic: Diagnostic) {
        delegateLock.withLock {
            self.delegate.emit(diagnostic)
        }
    }

    /// Mark the registry as immutable.
    public func freeze() {
        isFrozen = true
    }

    /// Asynchronously register all specs in the given directory.
    private func registerSpecsInDirectory(_ path: Path, on queue: SWBQueue, group: SWBDispatchGroup, domain: String = "", completion: @escaping (SpecProxy) -> Void) {
        // NOTE: Xcode has logic to do a recursive visitation in some cases, but we don't ever actually use this to load real specifications so it is not implemented here.
        precondition(!isFrozen, "tried to register specifications in directory '\(path.str)' after the registry was frozen")

        for item in (try? localFS.listdir(path)) ?? [] {
            queue.async(group: group) {
                let itemPath = path.join(item)

                // Check if this is a specification we should load.
                let ext = itemPath.fileSuffix

                // Check if it is an .xcspec.
                // Ignore dotfiles, as installing roots on filesystems which don't support extended attributes (such as NFS) may create AppleDouble files.
                if !itemPath.basename.hasPrefix(".") && ext == ".xcspec" {
                    self.registerSpec(itemPath, on: queue, group: group, domain: domain, completion: completion)
                    return
                }

                // FIXME: We should potentially warn about anything else here.
            }
        }
    }

    /// Asynchronously register the specs at the given path.
    private func registerSpec(_ path: Path, on queue: SWBQueue, group: SWBDispatchGroup, domain: String, completion: @escaping (SpecProxy) -> Void) {
        precondition(!isFrozen, "tried to register specification at path '\(path.str)' after the registry was frozen")

        // Load the spec data.
        do {
            let data = try PropertyList.fromPath(path, fs: localFS)

            // Load each specification record that was present. There may be either one top-level entry, or multiple entries in an array.
            switch data {
            case .plArray(let items):
                for item in items {
                    queue.async(group: group) {
                        self.registerSpec(path, data: item, domain: domain, completion: completion)
                    }
                }
            default:
                queue.async(group: group) {
                    self.registerSpec(path, data: data, domain: domain, completion: completion)
                }
            }
        } catch _ {
            error(path, "unable to load spec data")
        }
    }

    private func resolveSpecType(_ path: Path, _ items: [String: PropertyListItem]) -> (any SpecType.Type)? {
        // Check that we have a Type field.
        guard let typeItem = items["Type"] else {
            error(path, "missing 'Type' field")
            return nil
        }
        guard case .plString(let typeName) = typeItem else {
            error(path, "invalid 'Type' field")
            return nil
        }

        // Look up the spec type.
        guard let type = specTypes[typeName] else {
            error(path, "unknown spec 'Type': '\(typeName)'")
            return nil
        }

        return type
    }

    private func resolveSpecClass(_ path: Path, _ identifier: String, _ items: [String: PropertyListItem]) -> (success: Bool, (any SpecType.Type)?) {
        // Check if we have a old Class field.
        guard let classItem = items["Class"] else {
            // Look up newer specs by identifier.
            if let classType = specClassesByIdentifier[identifier] {
                return (success: true, classType)
            }

            return (success: true, nil)
        }

        guard case .plString(let className) = classItem else {
            error(path, "invalid 'Class' field")
            return (success:false, nil)
        }

        // Look up the spec class.
        guard let classType = specClassesByClassName[className] else {
            error(path, "unknown spec 'Class': '\(className)'")
            return (success:false, nil)
        }

        return (success: true, classType)
    }

    /// Register the given spec *data* from *path*.
    ///
    /// - parameter path: The path the spec data was loaded from.
    /// - parameter data: The spec data.
    /// - parameter domain: The domain the spec should be registered in.
    private func registerSpec(_ path: Path, data: PropertyListItem, domain: String, completion: (SpecProxy) -> Void) {
        precondition(!isFrozen, "tried to register specification from data at path '\(path.str)' after the registry was frozen")
        var domain = domain

        // The spec data should always be a dictionary.
        guard case .plDict(var items) = data else {
            error(path, "unexpected specification data in \(path.str)")
            return;
        }

        // Get the identifier.
        guard let identifierItem = items["Identifier"] else {
            error(path, "missing 'Identifier' field")
            return
        }
        guard case .plString(let identifier) = identifierItem else {
            error(path, "invalid 'Identifier' field")
            return
        }

        // HACK: Force the class for the app extension product type. We do it in this way because we want to preserve the inheritance hierarchy (ApplicationExtensionProductType *is* a BundleProductType), so we can't use registerSpecOverrideClass. Going forward, we should set PBXApplicationExtensionProductType in the actual spec, but doing so would require changing the legacy build system, so this may be a light weight compromise for now. We also can't do a conformance check here, and wouldn't want to anyways, because we don't want to override a (potentially derived) class of PBXApplicationExtensionProductType.
        if identifier == "com.apple.product-type.app-extension" || identifier == "com.apple.product-type.extensionkit-extension" {
            items["Class"] = .plString("PBXApplicationExtensionProductType")
        }

        // Validate the spec type information.
        guard let type = resolveSpecType(path, items) else { return }

        // Get the spec domain, if specified.
        if let domainItem = items["Domain"] ?? items["_Domain"] {
            guard case .plString(let value) = domainItem else {
                error(path, "invalid 'Domain' field")
                return
            }
            domain = value
        }

        // Get the spec class, if present.
        guard case (let success, let classType) = resolveSpecClass(path, identifier, items), success == true else { return }

        // Get the base spec name, if present.
        var basedOn: String?
        if let basedOnItem = items["BasedOn"] {
            guard case .plString(let value) = basedOnItem else {
                error(path, "invalid 'BasedOn' field")
                return
            }
            basedOn = value
        }

        // Load the localized strings, if available.
        //
        // We currently hard code a local search, assuming the xcspec file is adjacent to the `strings` file or the containing `lproj`.
        func loadLocalizedStrings(_ path: Path) -> [String: String]? {
            if let data = try? PropertyList.fromPath(path, fs: localFS) {
                // If we found a property list, it should be a map of strings.
                guard case .plDict(let items) = data else {
                    error(path, "unexpected `.strings` file content")
                    return nil
                }

                var strings = [String: String]()
                for (key, value) in items {
                    guard case .plString(let valueString) = value else {
                        error(path, "unexpected value for key '\(key)' in `.strings` file")
                        continue
                    }
                    // Normalize windows CR/LF
                    strings[key] = valueString.replacingOccurrences(of: "\r", with: "")
                }
                return strings
            }
            return nil
        }
        func findLocalizedStrings() -> [String: String]? {
            // Construct the search paths: if the spec has a name then search that first, then the identifier.
            var searchPaths = [Path]()
            let parent = path.dirname
            if case .plString(let name)? = items["Name"] {
                searchPaths.append(parent.join(name + ".strings"))
                searchPaths.append(parent.join("en.lproj").join(name + ".strings"))
                searchPaths.append(parent.join("English.lproj").join(name + ".strings"))
            }
            searchPaths.append(parent.join(identifier + ".strings"))
            searchPaths.append(parent.join("en.lproj").join(identifier + ".strings"))
            searchPaths.append(parent.join("English.lproj").join(identifier + ".strings"))

            for path in searchPaths {
                if let result = loadLocalizedStrings(path) {
                    return result
                }
            }
            return nil
        }
        let localizedStrings: [String: String]? = findLocalizedStrings()

        // Swift doesn't support static function locals: <rdar://problem/17662275> Support function-local "static" (i.e. global) data
        struct Static {
            // FIXME: Cleaning this up is tracked by <rdar://problem/22361888> Swift Build: Change handling of "domain-inversion" for base specs
            //
            /// Dictionary to support the special case of specs which have `basedOn` domain inversion, where a spec in a more general domain sometimes is based on specs in a more specific domain.
            ///
            /// This is a dictionary mapping spec domain-identifier pairs to a list of domains they should be considered to be part of, even though we don't have a copy of that spec explicitly declared in this domain.  In a sense we are cloning that spec into all of the listed domains.
            ///
            /// In general, a new spec should be added to this list if the spec it is based on has been added to a more specific domain. For example, a spec in the global domain has been copied into a platform domain, but there are still sub-specs of it defined in the global domain but not in the platform domain; those sub-specs should be declared below to also be in the platform domain.
            ///
            /// We can support this cleanly by adding support for "Domain" to be plural, and match these semantics. This is in practice a more efficient way to handle this problem then making the rest of spec machinery be prepared for needing to clone a proxy into a subdomain. Also because this table is confusing to maintain because tracking down which xcspecs are declared in which domains is cumbersome as - especially for embedded platforms - they are defined in multiple `.xcspec` files, and the domains are declared in the platform plug-in's `.plugindata` file.
            static let domainRemapsTable = [
                // ":foo" is a spec with the identifier 'foo' which is in the global domain ''.
                // We also map these specs into the global domain because not doing so would take them out of that domain (i.e., the arrays below are not additive to the domain the spec is declared in).
                ":com.apple.build-system.external": ["", "macosx", "embedded", "embedded-shared", "embedded-simulator"],

                "darwin:com.apple.product-type.application": ["macosx", "embedded", "embedded-shared", "embedded-simulator", "iphoneos-shared", "watchos-shared"],
                "darwin:com.apple.product-type.application.watchapp2-container": ["macosx", "embedded", "embedded-shared", "embedded-simulator", "iphoneos-shared", "iphoneos", "iphonesimulator", "watchos-shared", "watchos", "watchsimulator"],
                "darwin:com.apple.product-type.application.messages": ["macosx", "embedded", "embedded-shared", "embedded-simulator", "iphoneos-shared", "iphoneos", "iphonesimulator", "watchos-shared", "watchos", "watchsimulator"],
                "darwin:com.apple.product-type.application.on-demand-install-capable": ["macosx", "embedded", "embedded-shared", "embedded-simulator", "iphoneos-shared", "iphoneos", "iphonesimulator", "watchos-shared", "watchos", "watchsimulator"],

                "appletvos-shared:com.apple.product-type.application.cpsdkapp": ["appletvos", "appletvsimulator"],
                "appletvos-shared:com.apple.product-type.tv-app-extension": ["appletvos", "appletvsimulator"],
                "appletvos-shared:com.apple.product-type.tv-broadcast-extension": ["appletvos", "appletvsimulator"],

                "watchos-shared:com.apple.product-type.application.watchapp2": ["watchos", "watchsimulator"],
                "watchos-shared:com.apple.product-type.app-extension.base": ["watchos", "watchsimulator"],
                "watchos-shared:com.apple.product-type.watchkit2-extension": ["watchos", "watchsimulator"],
                "watchos-shared:com.apple.product-type.clockface-extension": ["watchos", "watchsimulator"],
                "watchos-shared:com.apple.product-type.app-extension.intents-service": ["watchos", "watchsimulator"],
            ]
        }

        /// Check `domainRemaps` loaded via XCSpecDomainRemapExtension first, then `Static.domainRemapsTable` if not found
        if let domains = domainRemaps["\(domain):\(identifier)"] ?? Static.domainRemapsTable["\(domain):\(identifier)"] {
            for domain in domains {
                completion(SpecProxy(identifier: identifier, domain: domain, path: path, type: type, classType: classType, basedOn: basedOn, data: items, localizedStrings: localizedStrings))
            }
            return
        }

        // Create the spec proxy.
        completion(SpecProxy(identifier: identifier, domain: domain, path: path, type: type, classType: classType, basedOn: basedOn, data: items, localizedStrings: localizedStrings))
    }

    private func registerProxy(_ proxy: SpecProxy) {
        precondition(!isFrozen, "tried to register specification proxy '\(proxy.identifier)' after the registry was frozen")
        // Get the domain specific registry.
        let domainRegistry = getRegistryForDomain(proxy.domain)

        // It is an error to register the same spec multiple times.
        if let duplicateProxy = domainRegistry.proxiesByIdentifier[proxy.identifier] {
            error(proxy.path, "spec \(proxy.specifierString) already registered from \(duplicateProxy.path.str)")
            return
        }

        // Register the proxy.
        domainRegistry.proxiesByIdentifier[proxy.identifier] = proxy
    }

    /// Get or create the registry for a particular domain.
    private func getRegistryForDomain(_ domain: String) -> SpecDomainRegistry {
        // Return the registry if it already exists.
        if let registry = proxiesByDomain[domain] {
            return registry
        }

        // Otherwise, create it and add it to the map.
        // If the registry has already been frozen, then this will crash.  All domains need to be registered at core initialization time.
        precondition(!isFrozen, "tried to look up specification domain '\(domain)' which was not registered during Swift Build core initialization")
        let registry = SpecDomainRegistry(domain)
        proxiesByDomain[domain] = registry
        return registry
    }

    /// Get the complete, ordered list of domains to search when performing lookups into a specific domain.
    private func getDomainSearchListForDomain(_ domain: String) -> [String] {
        func visit(_ domain: String, _ result: inout [String]) {
            // If we have already visited this domain, we are done.
            if result.contains(domain) { return }

            // Otherwise, append it to the list and recurse over included domains.
            result.append(domain)
            if let includedDomains = self.domainInclusions[domain] {
                for domain in includedDomains {
                    visit(domain, &result)
                }
            }
        }

        // Treat the default domain as a special case.
        if domain == "" { return [""] }

        // We expect the result to be short, so an array is appropriate despite O(N) behavior.
        var result = Array<String>()
        visit(domain, &result)

        // Add the default domain.
        visit("", &result)

        return result
    }

    /// The list of registered domains.
    @_spi(Testing) public var domains: [String] {
        return [String](proxiesByDomain.keys)
    }

    /// Look up the proxy for a given identifier and domain.
    @_spi(Testing) public func lookupProxy(_ identifier: String, domain: String = "") -> SpecProxy? {
        for domain in getDomainSearchListForDomain(domain) {
            if let result = getRegistryForDomain(domain).proxiesByIdentifier[identifier] {
                return result
            }
        }
        return nil
    }

    /// Find all proxies in the same subregistry as the given type.
    //
    // FIXME: I think this can probably be eliminated in favor of just returning all specifications of the particular type. Xcode used a multi-level registry for (domain, registry) which avoids the need for this search, but in practice it is expensive regardless so any client that needs this information should be caching it anyway. Verify this isn't an issue for us once things have settled, and then eliminate the subregistry stuff if possible.
    @_spi(Testing) public func findProxiesInSubregistry(_ type: any SpecType.Type, domain: String = "", includeInherited: Bool = true) -> [SpecProxy] {
        if isFrozen {
            let key = ProxyCacheKey(type: Ref(type), domain: domain, includeInherited: includeInherited)
            return proxyCache.getOrInsert(key) {
                return _findProxiesInSubregistry(type, domain: domain, includeInherited: includeInherited)
            }
        } else {
            return _findProxiesInSubregistry(type, domain: domain, includeInherited: includeInherited)
        }
    }

    func _findProxiesInSubregistry(_ type: any SpecType.Type, domain: String = "", includeInherited: Bool = true) -> [SpecProxy] {
        // Search for all proxies which use the same subregistry as the given type.
        let subregistryName = type.subregistryName

        var result = [String: SpecProxy]()
        let domainSearchList = includeInherited ? getDomainSearchListForDomain(domain) : [domain]
        for domain in domainSearchList {
            for proxy in getRegistryForDomain(domain).proxiesByIdentifier.values {
                // If a more specific spec has overridden this identifier, we shouldn't return it again.
                guard !includeInherited || !result.contains(proxy.identifier) else { continue }

                if proxy.type.subregistryName == subregistryName {
                    result[proxy.identifier] = proxy
                }
            }
        }

        // Sort the result to ensure determinacy.
        return result.values.sorted(by: <)
    }

    /// The cache key used for proxy lookup.
    private struct ProxyCacheKey: Equatable, Hashable {
        let type: Ref<any SpecType.Type>
        let domain: String
        let includeInherited: Bool
    }

    /// The cache used for proxy lookup.
    private var proxyCache = Cache<ProxyCacheKey, [SpecProxy]>()

    /// Get all specs in the registry of the given spec type `T` in the given `domain`.
    public func findSpecs<T: Spec>(_ type: T.Type, domain: String = "", includeInherited: Bool = true) -> [T] where T : SpecType {
        var result = Array<T>()
        for proxy in findProxiesInSubregistry(T.self, domain: domain, includeInherited: includeInherited) {
            if let spec = proxy.load(self) {
                // The subregistries aren't always type safe (for example, compilers do not have their own subregistry). So we do a dynamic cast here.
                if let typedSpec = spec as? T {
                    result.append(typedSpec)
                }
            }
        }
        return result
    }

    /// Get the loaded spec for a given identifier and domain.
    public func getSpec(_ identifier: String, domain: String = "") -> Spec? {
        return lookupProxy(identifier, domain: domain)?.load(self)
    }

    /// Get the loaded spec of a specific type for a given identifier and domain.  If no such spec exists or if it is not of the expected type, an error will be thrown.
    public func getSpec<T: Spec>(_ identifier: String, domain: String = "") throws -> T {
        guard let spec = getSpec(identifier, domain: domain) else {
            throw SpecLoadingError.notFound(identifier: identifier, domain: domain)
        }
        guard let typedSpec = spec as? T else {
            throw SpecLoadingError.wrongType(identifier: identifier, domain: domain, expectedType: T.self, actualType: type(of: spec))
        }
        return typedSpec
    }

    /// Get the loaded spec of a specific type for a given identifier and domain.  If no such spec exists or if it is not of the expected type, an error will be thrown.
    ///
    /// This is a convenience overload for identified spec types which removes the need to manually pass in the identifier.
    public func getSpec<T: Spec & IdentifiedSpecType>(domain: String = "") throws -> T {
        return try getSpec(T.identifier, domain: domain)
    }

    /// Validate that there are no cases where a spec depends on one in a subdomain.  This is only used by `SpecLoadingTests.testSpecDomainInversion()`.
    @discardableResult @_spi(Testing) public func validateSpecDomainInversion(reportError: ((String) -> (Void))? = nil) -> Bool {
        // See the hacks in registerSpec(), and rdar://problem/22361888.

        let reportError = reportError ?? { error in
            print(error)
        }

        // Find places where a proxy illegally depends on a spec overridden in a subdomain.
        //
        // Essentially, if spec in a generic domain (foo:default) is based on an unspecified specification (bar), which is in a more specific domain 'device', then the semantics we want are that a search for 'foo:device' will return 'foo:device basedOn bar:device'. These are unfortunate semantics to implement dynamically (we want each proxy to resolve to one spec), so instead we clone any proxies that might need to satisfy this.

        // Get the set of domains and proxy identifiers.
        var domains = Set<String>()
        var identifiers = Set<String>()
        for domain in proxiesByDomain.values {
            for proxy in domain.proxiesByIdentifier.values {
                domains.insert(proxy.domain)
                identifiers.insert(proxy.identifier)
            }
        }

        // Now do a search for all specs where a dynamic lookup of the 'basedOn' spec is in a more refined domain.
        var hadErrors = false
        for identifier in identifiers {
            for domain in domains {
                // Look up the proxy.
                guard let proxy = lookupProxy(identifier, domain: domain) else { continue }

                // If the proxy has no basedOn reference, it is fine.
                guard let basedOn = proxy.basedOn else { continue }

                // If the proxy's basedOn reference has a domain specifier, we require it to resolve to a fixed proxy.
                let (_,rhs) = basedOn.split(":")
                if !rhs.isEmpty {
                    continue
                }

                // Otherwise, look up the basedOn reference using the current domain.
                guard let basedOnSpec = lookupProxy(basedOn, domain: domain) else {
                    reportError("error: missing spec: \(proxy.specifierString) based on: '\(basedOn)'")
                    hadErrors = true
                    continue
                }

                // Validate that the basedOnSpec is not in a more specific domain.
                if proxy.domain != basedOnSpec.domain && !self.getDomainSearchListForDomain(proxy.domain).contains(basedOnSpec.domain) {
                    reportError("error: spec: when searching the domain '\(domain)', \(proxy.specifierString) is based on: '\(basedOn)' which resolves to \(basedOnSpec.specifierString) which is not in an included domain")
                    hadErrors = true
                }
            }
        }

        return hadErrors
    }
}

// TODO: <rdar://problem/40394949> Add a series of constants or enum for known file type identifiers
extension SpecRegistry {
    public static var headerFileTypeIdentifiers: [String] {
        return ["sourcecode.c.h", "sourcecode.cpp.h"]
    }

    public static var metalFileTypeIdentifier: String {
        return "sourcecode.metal"
    }

    public static var modulemapFileTypeIdentifier: String {
        return "sourcecode.module-map"
    }

    public static var xibFileTypeIdentifier: String {
        return "file.xib"
    }

    public static var storyboardFileTypeIdentifier: String {
        return "file.storyboard"
    }

    public static var interfaceBuilderDocumentFileTypeIdentifiers: [String] {
        return [xibFileTypeIdentifier, storyboardFileTypeIdentifier]
    }
}

// TODO: <rdar://problem/40394951> Think about how to better handle files based on "file type traits" rather than concrete file type identifiers
extension SpecRegistry {
    public var headerFileTypes: [FileTypeSpec] {
        return SpecRegistry.headerFileTypeIdentifiers.map { getSpec($0) as! FileTypeSpec }
    }

    public var metalFileType: FileTypeSpec {
        return getSpec(SpecRegistry.metalFileTypeIdentifier) as! FileTypeSpec
    }

    public var modulemapFileType: FileTypeSpec {
        return getSpec(SpecRegistry.modulemapFileTypeIdentifier) as! FileTypeSpec
    }
}

/// Convenience methods for looking up file types.
extension SpecRegistry {
    /// Looks up and returns the FileType (if any) that has the identifier `ident`.
    public func lookupFileType(identifier ident: String, domain: String) -> FileTypeSpec? {
        assert(ident != "")
        return getSpec(ident, domain: domain) as? FileTypeSpec
    }

    /// Looks up and returns the FileType (if any) that has the language dialect `dialect`.
    public func lookupFileType(languageDialect dialect: GCCCompatibleLanguageDialect, domain: String) -> FileTypeSpec? {
        guard let sourceFileNameSuffix = dialect.sourceFileNameSuffix else {
            return nil
        }
        return lookupFileType(fileName: sourceFileNameSuffix, domain: domain)
    }

    /// Looks up and returns the FileType (if any) that best matches `fileName`.  Looking up by file name should usually only be used if no other means of determining the type is available.
    public func lookupFileType(fileName: String, domain: String) -> FileTypeSpec? {
        // FIXME: Need efficient implementation.
        let ext = Path(fileName).fileExtension
        for fileType in findSpecs(FileTypeSpec.self, domain: domain) {
            if fileType.extensions.contains(ext) {
                return fileType
            }
        }

        return nil
    }

    /// Looks up and returns the FileType (if any) for a `Reference`.
    public func lookupFileType(reference ref: Reference, domain: String) -> FileTypeSpec? {
        switch ref {
        case let fileRef as FileReference:
            // We get look up a file reference's identifier directly.
            return lookupFileType(identifier: fileRef.fileTypeIdentifier, domain: domain)

        case let productRef as ProductReference:
            // For a product reference, we look up its producing target's PackageTypeSpec, and return the file type the package type defines.
            if let standardTargetRef = productRef.target as? StandardTarget,
                   let productType = getSpec(standardTargetRef.productTypeIdentifier, domain: domain) as? ProductTypeSpec,
                   let packageType = getSpec(productType.defaultPackageTypeIdentifier, domain: domain) as? PackageTypeSpec,
                   let fileTypeIdent = packageType.productReferenceFileTypeIdentifier {
                return lookupFileType(identifier: fileTypeIdent, domain: domain)
            }
            return nil

        case let versionGroup as VersionGroup:
            // For a version group, if it has children then we return the file type of its first child.  If it has no children, then we return nil.
            if let firstChild = versionGroup.children.first {
                return lookupFileType(reference: firstChild, domain: domain)
            }
            return nil

        default:
            // Other reference types don't have a file type.
            return nil
        }
    }
}

/// Protocol for objects that provide access to a specification registry.
public protocol SpecRegistryProvider {
    var specRegistry: SpecRegistry { get }
}

/// Protocol for objects that support looking up specifications.
///
/// This is primarily a convenience protocol to reduce boilerplate code, as its extension provides implementations of many common lookup methods which compute the lookup domain, and clients can access these methods directly rather than going to the spec registry.
///
/// - remark: If `platform` becomes optional in the future, this protocol can significantly reduce the number of changes needed to accommodate that.
public protocol SpecLookupContext: SpecRegistryProvider {
    var platform: Platform? { get }
}

/// Methods to look up specs in the context of the receiver's specRegistry and platform.
extension SpecLookupContext {
    /// The specification domain this context uses for looking up specs and file types.
    public var domain: String {
        return platform?.name ?? ""
    }

    /// Get the loaded spec for a given identifier and domain.
    public func getSpec(_ identifier: String) -> Spec? {
        specRegistry.getSpec(identifier, domain: domain)
    }

    /// Get all specs in the registry of the given spec type `T` in the given `domain`.
    func findSpecs<T: Spec>(_ type: T.Type, includeInherited: Bool = true) -> [T] where T : SpecType {
        return specRegistry.findSpecs(type, domain: domain, includeInherited: includeInherited)
    }

    /// Get the loaded spec of a specific type for a given identifier and domain.  If no such spec exists or if it is not of the expected type, an error will be thrown.
    public func getSpec<T: Spec>(_ identifier: String) throws -> T {
        return try specRegistry.getSpec(identifier, domain: domain)
    }

    /// Get the loaded spec of a specific type for a given identifier and domain.  If no such spec exists or if it is not of the expected type, an error will be thrown.
    ///
    /// This is a convenience overload for identified spec types which removes the need to manually pass in the identifier.
    public func getSpec<T: Spec & IdentifiedSpecType>(domain: String = "") throws -> T {
        return try getSpec(T.identifier)
    }

    /// Looks up and returns the FileType (if any) that has the identifier `ident`.
    public func lookupFileType(identifier ident: String) -> FileTypeSpec? {
        return specRegistry.lookupFileType(identifier: ident, domain: domain)
    }

    /// Looks up and returns the FileType (if any) that has the language dialect `dialect`.
    public func lookupFileType(languageDialect dialect: GCCCompatibleLanguageDialect) -> FileTypeSpec? {
        return specRegistry.lookupFileType(languageDialect: dialect, domain: domain)
    }

    /// Looks up and returns the FileType (if any) that best matches `fileName`.  Looking up by file name should usually only be used if no other means of determining the type is available.
    public func lookupFileType(fileName: String) -> FileTypeSpec? {
        return specRegistry.lookupFileType(fileName: fileName, domain: domain)
    }

    /// Looks up and returns the FileType (if any) for a `Reference`.
    public func lookupFileType(reference ref: Reference) -> FileTypeSpec? {
        return specRegistry.lookupFileType(reference: ref, domain: domain)
    }
}

/// Lightweight struct for clients which need a `SpecLookupContext`-conforming entity but don't have one readily available.
public struct SpecLookupCtxt: SpecLookupContext {
    public let specRegistry: SpecRegistry
    public let platform: Platform?

    public init(specRegistry: SpecRegistry, platform: Platform?) {
        self.specRegistry = specRegistry
        self.platform = platform
    }
}
