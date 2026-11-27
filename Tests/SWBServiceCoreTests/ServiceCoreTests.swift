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
import SWBServiceCore
import SWBUtil
import Synchronization

#if canImport(System)
import System
#else
import SystemPackage
#endif

@Suite fileprivate struct ServiceCoreTests {
    @Test func basics() {
    }

    /// A service which counts how many times its shutdown work runs.
    private final class CountingService: Service, @unchecked Sendable {
        let shutdownCount = SWBMutex(0)

        override func performShutdown(_ error: (any Error)?) {
            shutdownCount.withLock { $0 += 1 }
            super.performShutdown(error)
        }
    }

    /// Shutdown can be requested concurrently from the connection's receive and send pumps (e.g. when the client exits); the shutdown work must only run once.
    @Test func shutdownRunsOnce() async throws {
        let fd = try FileDescriptor.open("/dev/null", .readWrite)
        let pluginManager = await MutablePluginManager(pluginLoadingFilter: { _ in true })
        let service = await CountingService(inputFD: fd, outputFD: fd, connectionMode: .inProcess, pluginManager: pluginManager)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    service.shutdown(nil)
                }
            }
        }

        service.shutdown(nil)
        #expect(service.shutdownCount.withLock { $0 } == 1)

        // The service's `run()` must complete now that shutdown was requested.
        try await service.run()
    }
}
