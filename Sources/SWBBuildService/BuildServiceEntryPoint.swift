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

public import class Foundation.Bundle
public import struct Foundation.URL

import SWBBuildSystem
import SWBServiceCore
import SWBUtil
import SWBLibc
import SWBCore
import SWBTaskConstruction
import SWBTaskExecution

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if USE_STATIC_PLUGIN_INITIALIZATION
private import SWBAndroidPlatform
private import SWBApplePlatform
private import SWBGenericUnixPlatform
private import SWBQNXPlatform
private import SWBUniversalPlatform
private import SWBWebAssemblyPlatform
private import SWBWindowsPlatform
#endif

private struct Options {
    /// Whether the caller should exit after parsing options.  This is set to `true` when the `--help` option is parsed.
    var exit = false

    init(commandLine: [String]) throws {
        func warning(_ message: String) {
            log("warning: option parsing failure: \(message)")
        }
        func error(_ message: String) throws {
            throw StubError.error("error: option parsing failure: \(message)")
        }

        // Parse the arguments.
        var generator = commandLine.makeIterator()
        // Skip the executable.
        _ = generator.next() ?? "<<missing program name>>"
        while let arg = generator.next() {
            switch arg {
            case "--help":
                print((OutputByteStream()
                        <<< "Swift Build Build Service\n"
                        <<< "\n"
                        <<< "  Read the source for help.").bytes.asString)
                exit = true

            default:
                warning("unknown argument: \(arg)")
            }
        }
    }
}

extension BuildService {
    /// Starts the build service. This should be invoked _only_ from the SWBBuildService executable as its direct entry point.
    package static func main() async -> Never {
        let arguments = CommandLine.arguments
        do {
            try await Service.main { inputFD, outputFD in
                // Launch the Swift Build service.
                try await BuildService.run(inputFD: inputFD, outputFD: outputFD, connectionMode: .outOfProcess, pluginsDirectory: Bundle.main.builtInPlugInsURL, arguments: arguments, pluginLoadingFinished: {
                    // Already using DYLD_IMAGE_SUFFIX, clear it to avoid propagating ASan to children.
                    // This must happen after plugin loading.
                    if let suffix = getEnvironmentVariable("DYLD_IMAGE_SUFFIX"), suffix == "_asan" {
                        try POSIX.unsetenv("DYLD_IMAGE_SUFFIX")
                    }
                })
            }
            exit(EXIT_SUCCESS)
        } catch {
            log("\(error)", isError: true)
            exit(EXIT_FAILURE)
        }
    }

    /// Common entry point to the build service for in-process and out-of-process connections.
    ///
    /// Called directly from the exported C entry point `swiftbuildServiceEntryPoint` for in-process connections, or from `BuildService.main()` (after some basic file descriptor setup) for out-of-process connections.
    fileprivate static func run(inputFD: FileDescriptor, outputFD: FileDescriptor, connectionMode: ServiceHostConnectionMode, pluginsDirectory: URL?, arguments: [String], pluginLoadingFinished: () throws -> Void) async throws {
        let pluginManager = await { @PluginExtensionSystemActor in
            // Create the plugin manager and load plugins.
            let pluginManager = PluginManager(skipLoadingPluginIdentifiers: [])

            // Register plugin extension points.
            pluginManager.registerExtensionPoint(ServiceExtensionPoint())
            pluginManager.registerExtensionPoint(SettingsBuilderExtensionPoint())
            pluginManager.registerExtensionPoint(BuildOperationExtensionPoint())
            pluginManager.registerExtensionPoint(SpecificationsExtensionPoint())
            pluginManager.registerExtensionPoint(SDKRegistryExtensionPoint())
            pluginManager.registerExtensionPoint(PlatformInfoExtensionPoint())
            pluginManager.registerExtensionPoint(ToolchainRegistryExtensionPoint())
            pluginManager.registerExtensionPoint(EnvironmentExtensionPoint())
            pluginManager.registerExtensionPoint(InputFileGroupingStrategyExtensionPoint())
            pluginManager.registerExtensionPoint(TaskProducerExtensionPoint())
            pluginManager.registerExtensionPoint(DeveloperDirectoryExtensionPoint())
            pluginManager.registerExtensionPoint(DiagnosticToolingExtensionPoint())
            pluginManager.registerExtensionPoint(SDKVariantInfoExtensionPoint())
            pluginManager.registerExtensionPoint(FeatureAvailabilityExtensionPoint())
            pluginManager.registerExtensionPoint(TaskActionExtensionPoint())

            // Register the core set of service message handlers directly since they don't live in a plugin
            pluginManager.register(ServiceSessionMessageHandlers(), type: ServiceExtensionPoint.self)
            pluginManager.register(ServicePIFMessageHandlers(), type: ServiceExtensionPoint.self)
            pluginManager.register(WorkspaceModelMessageHandlers(), type: ServiceExtensionPoint.self)
            pluginManager.register(ActiveBuildBasicMessageHandlers(), type: ServiceExtensionPoint.self)
            pluginManager.register(ServiceMessageHandlers(), type: ServiceExtensionPoint.self)

            pluginManager.register(BuiltinSpecsExtension(), type: SpecificationsExtensionPoint.self)

            pluginManager.register(BuiltinTaskActionsExtension(), type: TaskActionExtensionPoint.self)

            #if USE_STATIC_PLUGIN_INITIALIZATION
            // Statically initialize the plugins.
            SWBAndroidPlatform.initializePlugin(pluginManager)
            SWBApplePlatform.initializePlugin(pluginManager)
            SWBGenericUnixPlatform.initializePlugin(pluginManager)
            SWBQNXPlatform.initializePlugin(pluginManager)
            SWBUniversalPlatform.initializePlugin(pluginManager)
            SWBWebAssemblyPlatform.initializePlugin(pluginManager)
            SWBWindowsPlatform.initializePlugin(pluginManager)
            #else
            // Otherwise, load the normal plugins.
            if let pluginsDirectory {
                let pluginsPath = try pluginsDirectory.filePath
                pluginManager.load(at: pluginsPath)
                for subpath in (try? localFS.listdir(pluginsPath).sorted().map({ pluginsPath.join($0) })) ?? [] {
                    if localFS.isDirectory(subpath) {
                        pluginManager.load(at: subpath)
                    }
                }
            }
            #endif

            return pluginManager
        }()

        try pluginLoadingFinished()

        for diagnosticToolingPlugin in await pluginManager.extensions(of: DiagnosticToolingExtensionPoint.self) {
            diagnosticToolingPlugin.initialize()
        }

        // Parse command line options.
        let options = try Options(commandLine: arguments)

        if options.exit {
            return
        }

        // Create the single service object.
        let service = await SWBBuildService.BuildService(inputFD: inputFD, outputFD: outputFD, connectionMode: connectionMode, pluginManager: pluginManager)

        // Start handling requests.
        service.resume()
        try await service.run()
    }
}

/// Starts the build service in-process.
///
/// This is exported as a C function for clients who wish to spawn the build service in-process, and which is used by the SwiftBuild client framework.
@_cdecl("swiftbuildServiceEntryPoint")
public func swiftbuildServiceEntryPoint(inputFD: Int32, outputFD: Int32, pluginsDirectory: URL?, completion: @Sendable @escaping ((any Error)?) -> Void) {
    _Concurrency.Task<Void, Never>.detached {
        let error: (any Error)?
        do {
            try await BuildService.run(inputFD: FileDescriptor(rawValue: inputFD), outputFD: FileDescriptor(rawValue: outputFD), connectionMode: .inProcess, pluginsDirectory: pluginsDirectory, arguments: [buildServiceExecutableName()], pluginLoadingFinished: {})
            error = nil
        } catch let e {
            error = e
        }
        completion(error)
    }
}
