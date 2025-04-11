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
import SWBBuildSystem
import SWBCore
import SWBLibc
public import SWBProtocol
public import SWBServiceCore
import SWBUtil

typealias Cache = SWBUtil.Cache

enum ServiceError: Swift.Error {
    case unableToInitializeCore(errors: [String])
}

public struct MsgHandlingError: Swift.Error {
    public let message: String

    init(_ message: String) {
        self.message = message
    }
}

private struct CoreCacheKey: Equatable, Hashable {
    /// The path of the developer directory.
    let developerPath: SWBProtocol.DeveloperPath?

    /// The inferior build products path, if defined.
    let inferiorProducts: Path?

    /// A set of override environment variables to pass
    let environment: [String: String]
}

/// This is the central class which manages a service instance communicating with a unique client.
///
/// This class is designed to be thread safe: clients can send messages from any thread and they will be sent in FIFO order. Note that individual messages are currently always processed in FIFO order non-concurrently. Messages which require non-trivial amounts of time to service should always be split to use an asynchronous reply.
open class BuildService: Service, @unchecked Sendable {
    /// The map of registered sessions.
    var sessionMap = Dictionary<String, Session>()

    private var lastBuildOperationID = LockedValue<Int>(0)

    /// The shared build manager.
    let buildManager = BuildManager()

    /// The cache of core objects.
    ///
    /// We make this a heavy cache in debug mode, so that it can be explicitly cleared (via `clearAllCaches`), which helps considerably with memory leak debugging.
#if DEBUG
    private let sharedCoreCache = HeavyCache<CoreCacheKey, (Core?, [Diagnostic])>()
#else
    private let sharedCoreCache = Cache<CoreCacheKey, (Core?, [Diagnostic])>()
#endif

    /// Async lock to guard access to `sharedCoreCache`, since its `getOrInsert` method can't be given an async closure.
    private var sharedCoreCacheLock = ActorLock()

    public func nextBuildOperationID() -> Int {
        return lastBuildOperationID.withLock { value in
            let lastID = value
            value += 1
            return lastID
        }
    }

    /// Override shutdown to clear out any active sessions.
    override open func shutdown(_ error: (any Error)?) {
        // We always explicitly remove all sessions at shutdown, before invoking the leak checking logic.
        sessionMap.removeAll()

        super.shutdown(error)
    }

    /// The most recent modification time of all binaries in SWBBuildService.bundle and its embedded frameworks.
    private static func buildServiceModTime() throws -> Date {
        // Find all the binaries that we want to get mod times for.
        // It's highly likely (as Swift Build is currently arranged) that all of these files will have the same mod time, since they all get copied into SwiftBuild.framework at once.  But this approach is more robust for some likely alternate configurations.  It still expects that the running images of all the items came from inside SWBBuildService.bundle, though.
        let fs = SWBUtil.localFS
        var binariesToCheck = [Path]()
        // Check our own bundle's executable.
        if let executablePath = try Bundle.main.executableURL?.filePath {
            if fs.exists(executablePath) {
                binariesToCheck.append(executablePath)
            }
        }
        // Check all the binaries of frameworks in the Frameworks folder.
        // Note that this does not recurse into the frameworks for other items nested inside them.  We also presently don't check the PlugIns folder.
        if let frameworksPath = try Bundle.main.privateFrameworksURL?.filePath {
            do {
                for subpath in try fs.listdir(frameworksPath) {
                    let frameworkPath = frameworksPath.join(subpath)
                    // Load a bundle at this path.  This means we'll skip things which aren't bundles, such as the Swift standard libraries.
                    if let bundle = Bundle(path: frameworkPath.str) {
                        if let unresolvedExecutablePath = try bundle.executableURL?.filePath {
                            let executablePath = try fs.realpath(unresolvedExecutablePath)
                            if fs.exists(executablePath) {
                                binariesToCheck.append(executablePath)
                            }
                        }
                    }
                }
            }
            catch {
                // Couldn't get the contents of the frameworks directory - not sure whether this should be an error or if there are development workflows we want to support where it might be missing.
            }
        }

        guard binariesToCheck.count > 0 else {
            throw StubError.error("Couldn't get timestamp of SWBBuildService.bundle contents: No binaries to stat could be found.")
        }

        // Now go through all the binaries we gathered and get their mod times, keeping the most recent one.
        var latestModDate: Date? = nil
        for binaryPath in binariesToCheck {
            do {
                let modDate = try fs.getFileInfo(binaryPath).modificationDate
                if latestModDate.map({ latestModDate in modDate > latestModDate }) ?? true {
                    latestModDate = modDate
                }
            }
            catch let error as NSError {
                throw StubError.error("Couldn't get timestamp of SWBBuildService.bundle contents: \(error.localizedDescription)")
            }
            catch {
                throw StubError.error("Couldn't get timestamp of SWBBuildService.bundle contents: \(error)")
            }
        }

        guard let latestModDate else {
            throw StubError.error("Couldn't get timestamp of SWBBuildService.bundle contents: Unknown error (mod time is nil)")
        }

        return latestModDate
    }

    /// Convenience overload which throws if the Core had initialization errors.
    func sharedCore(developerPath: SWBProtocol.DeveloperPath?, inferiorProducts: Path? = nil, environment: [String: String] = [:]) async throws -> Core {
        let (c, diagnostics) = await sharedCore(developerPath: developerPath, inferiorProducts: inferiorProducts, environment: environment)
        guard let core = c else {
            throw ServiceError.unableToInitializeCore(errors: diagnostics.map { $0.formatLocalizedDescription(.debug) })
        }
        return core
    }

    /// Get a shared core instance.
    ///
    /// We use an explicit cache so that we can minimize the number of cores we load while still keeping a flexible public interface that doesn't require all clients to provide all possible required parameters for core initialization (which is useful for testing and debug purposes).
    func sharedCore(developerPath: SWBProtocol.DeveloperPath?, resourceSearchPaths: [Path] = [], inferiorProducts: Path? = nil, environment: [String: String] = [:]) async -> (Core?, [Diagnostic]) {
        let key = CoreCacheKey(developerPath: developerPath, inferiorProducts: inferiorProducts, environment: environment)
        return await sharedCoreCacheLock.withLock {
            if let existing = sharedCoreCache[key] {
                return existing
            }

            let buildServiceModTime: Date
            do {
                buildServiceModTime = try Self.buildServiceModTime()
            } catch {
                return (nil, [.init(behavior: .error, location: .unknown, data: .init("\(error)"))])
            }

            final class Delegate: CoreDelegate {
                private let _diagnosticsEngine = DiagnosticsEngine()

                var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
                    .init(_diagnosticsEngine)
                }

                var diagnostics: [Diagnostic] {
                    _diagnosticsEngine.diagnostics
                }

                var hasErrors: Bool {
                    _diagnosticsEngine.hasErrors
                }

                func freeze() {
                    _diagnosticsEngine.freeze()
                }
            }
            let delegate = Delegate()
            let coreDeveloperPath: Core.DeveloperPath?
            switch developerPath {
            case .xcode(let path):
                coreDeveloperPath = .xcode(path)
            case .swiftToolchain(let path):
                let xcodeDeveloperPath = try? await Xcode.getActiveDeveloperDirectoryPath()
                coreDeveloperPath = .swiftToolchain(path, xcodeDeveloperPath: xcodeDeveloperPath)
            case nil:
                coreDeveloperPath = nil
            }
            let (core, diagnostics) = await (Core.getInitializedCore(delegate, pluginManager: pluginManager, developerPath: coreDeveloperPath, resourceSearchPaths: resourceSearchPaths, inferiorProductsPath: inferiorProducts, environment: environment, buildServiceModTime: buildServiceModTime, connectionMode: connectionMode), delegate.diagnostics)
            delegate.freeze()
            sharedCoreCache[key] = (core, diagnostics)
            return (core, diagnostics)
        }
    }

    open func createBuildOperation(request: Request, message: CreateBuildRequest) throws -> any ActiveBuildOperation {
        // Create an active build instance.
        let build = try ActiveBuild(request: request, message: message)

        // Register it with the session, and return the handle to the client.
        try build.registerWithSession()

        return build
    }
}
