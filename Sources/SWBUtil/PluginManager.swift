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

@globalActor public actor PluginExtensionSystemActor: GlobalActor {
    public static let shared = PluginExtensionSystemActor()
}

/// A generic area of extensibility.
///
/// Plugins hook into specific extension points to add additional behavior; the extension points themselves are defined by clients.
@PluginExtensionSystemActor public protocol ExtensionPoint: Sendable {
    /// The protocol describing the API required of extensions.
    associatedtype ExtensionProtocol: Sendable

    /// The name of the extension point.
    static var name: String { get }
}

/// A very basic Swift plugin manager.
///
/// This manager works by using a *very* minimal API between the service and the plugins, only the PluginManager itself is passed to the plugins (as an opaque pointer). All actual plugging then can happen using real Swift APIs between the plugin manager and the plugins.
///
/// This mechanism is *NOT* intended to be used to build plugins which have a stable API -- all plugins must be built with exactly the Swift Build the are intended to plug in to. The only thing this allows is for dynamically loaded the plugin in order to manage distributing parts independently.
@PluginExtensionSystemActor public final class PluginManager: Sendable {
    private struct Plugin: CommonPlugin {
        /// The identifier of the plugin.
        @_spi(Testing) public let identifier: String

        /// The path to the plugin. If the plugin is a bundle, this is the path to the bundle directory. Otherwise, it's the path to the plugin library.
        public let path: Path
    }

    /// The set of all plugins we've successfully loaded (CFBundleIdentifier for bundles if they have one, filenames otherwise), mapping to the paths to those plugins (for debugging convenience).
    ///
    /// This is primarily used to avoid loading the same plugin twice.
    private var loadedPlugins = [String: Path]()

    /// Diagnostics produced during plugin loading.
    public private(set) var loadingDiagnostics: [Diagnostic] = []

    /// The set of registered extension points.
    private var extensionPoints: [String: any ExtensionPoint] = [:]

    private var extensions: [Ref<any ExtensionPoint>: [Any]] = [:]

    private let skipLoadingPluginIdentifiers: Set<String>

    /// Create the plugin manager.
    ///
    /// Clients are expected to register all of the available extension points, then load the plugins.
    public init(skipLoadingPluginIdentifiers: Set<String>) {
        self.skipLoadingPluginIdentifiers = skipLoadingPluginIdentifiers
    }

    public var pluginsByIdentifier: [String: any CommonPlugin] {
        Dictionary(uniqueKeysWithValues: loadedPlugins.map { ($0.key, Plugin(identifier: $0.key, path: $0.value)) })
    }

    /// Load the plugin at the given path. This is meant for unit tests where a specific plugin is being tested.
    public func loadPlugin(at path: Path) {
        // If we found a bundle, load it and look for a registration function.
        let name = path.basename

        let pluginPath: Path
        let executablePath: Path
        let pluginIdentifier: String
        switch path.fileSuffix {
        case ".bundle":
            pluginPath = path
            let shallow = !localFS.exists(path.join("Contents"))
            let executableBasePath = shallow
                ? path.join(Path(name).basenameWithoutSuffix)
                : path.join("Contents").join("MacOS").join(Path(name).basenameWithoutSuffix)
            executablePath = {
                if let suffix = getEnvironmentVariable("DYLD_IMAGE_SUFFIX")?.nilIfEmpty {
                    let candidate = executableBasePath.appendingFileNameSuffix(suffix)
                    if localFS.exists(candidate) {
                        return candidate
                    }
                }
                return executableBasePath
            }()
            let infoPlistPath = shallow
                ? path.join("Info.plist")
                : path.join("Contents").join("Info.plist")
            if let plist = try? PropertyList.fromPath(infoPlistPath, fs: localFS), let cfBundleIdentifier = plist.dictValue?["CFBundleIdentifier"]?.stringValue {
                pluginIdentifier = cfBundleIdentifier
            }
            else {
                pluginIdentifier = path.basename
            }
        default:
            return
        }

        // If we've already loaded a plugin with this identifier, don't load it again.
        if let existingPluginPath = loadedPlugins[pluginIdentifier] {
            loadingDiagnostics.append(Diagnostic(behavior: .warning, location: .unknown, data: DiagnosticData("Duplicate plugin with identifier '\(pluginIdentifier)' at path: \(pluginPath.str) (already loaded from path \(existingPluginPath.str))")))
            return
        }

        guard !skipLoadingPluginIdentifiers.contains(pluginIdentifier) else {
            return
        }

        let handle: LibraryHandle
        do {
            handle = try Library.open(executablePath)
        } catch {
            loadingDiagnostics.append(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Unable to load plugin: \(pluginPath.str): \(error)")))
            return
        }

        typealias PluginInitializationFunc = @PluginExtensionSystemActor @convention(c) (UnsafeRawPointer) -> Void
        guard let f: PluginInitializationFunc = Library.lookup(handle, "initializePlugin") else {
            loadingDiagnostics.append(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Missing plugin entry point: \(executablePath.str)")))
            return
        }

        // Ask the plugin to register itself.
        f(Unmanaged.passUnretained(self).toOpaque())

        // Remember that we loaded this plugin.
        loadedPlugins[pluginIdentifier] = pluginPath
    }

    /// Load plugins present at the given path.
    public func load(at path: Path) {
        for name in (try? localFS.listdir(path).sorted()) ?? [] {
            self.loadPlugin(at: path.join(name))
        }
    }

    /// Register a new extension point.
    ///
    /// This is intended to be used by clients before any plugin loading happens.
    ///
    /// This is *NOT* thread safe.
    public func registerExtensionPoint<T: ExtensionPoint>(_ extensionPoint: T) {
        extensionPoints[T.self.name] = extensionPoint
    }

    /// Register a new extension for a particular extension point.
    public func register<T: ExtensionPoint>(_ instance: T.ExtensionProtocol, type: T.Type) {
        // Get the extension point.
        guard let extensionPoint = extensionPoints[T.self.name] else {
            fatalError("unknown extension point: \(T.self.name)")
        }

        _register(extensionPoint as! T, instance)
    }

    /// Register a new extension for a particular extension point if the extension point exists. This is only meant for plugin-hosted extension points used in unit tests.
    public func conditionallyRegister<T: ExtensionPoint>(_ instance: T.ExtensionProtocol, type: T.Type) {
        // Get the extension point and return if we can't find it
        guard let extensionPoint = extensionPoints[T.self.name] else {
            return
        }

        _register(extensionPoint as! T, instance)
    }

    private func _register<T: ExtensionPoint>(_ extensionPoint: T, _ instance: T.ExtensionProtocol) {
        extensions[Ref(extensionPoint), default: []].append(instance)
    }

    public func extensions<T: ExtensionPoint>(of extensionPoint: T.Type) -> [T.ExtensionProtocol] {
        extensions.flatMap { key, value in
            if type(of: key.instance) == extensionPoint {
                return value as! [T.ExtensionProtocol]
            }
            return []
        }
    }
}
