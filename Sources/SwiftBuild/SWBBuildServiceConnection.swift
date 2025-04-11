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
import SWBProtocol
import SWBUtil

public import Foundation

#if canImport(System)
import System
#else
import SystemPackage
#endif

typealias swb_build_service_connection_message_handler_t = @Sendable (UInt64, SWBDispatchData) -> Void

/// Represents and manages a connection to an Swift Build service subprocess.  Clients do not normally talk directly to the connection; instead, they almost always go through a SWBBuildService object, which provides higher-level operations.  The connection doesn’t know about the service-specific semantics, but instead provides general machinery for sending synchronous and asynchronous messages over one or more muxed communication “channels”, and for controlling the subprocess.
@_spi(Testing) public final class SWBBuildServiceConnection: @unchecked Sendable {
    /// Whether the connection is suspended.
    private let _isSuspended = LockedValue(true)

    /// Whether the connection has been closed.
    private let _isClosed = LockedValue(false)

    /// Our synchronization queue, on which dispatch I/O and other blocks are run.
    private let _queue = SWBQueue(label: "SWBBuildServiceConnection.queue", autoreleaseFrequency: .workItem)

    /// State flags synchronization queue.
    private let _stateQueue = SWBQueue(label: "SWBBuildServiceConnection.stateQueue", autoreleaseFrequency: .workItem)

    /// Dispatch I/O endpoint for writing to the pipe connected to the Swift Build process’ stdin.
    var _stdinWriter: SWBDispatchIO?

    /// Dispatch I/O endpoint for reading from the pipe connected to the Swift Build process’ stdout and stderr.
    var _stdoutReader: SWBDispatchIO?

    /// Any data that we’ve received from the subprocess but haven’t yet processed (i.e. it’s a partial message).
    private var _bufferedData = SWBDispatchData.empty

    private struct ChannelState: Sendable {
        /// Highest channel number that’s been assigned so far (zero if none).
        var nextChannelID = UInt64(0)

        /// Maps channel numbers of any open channels to the corresponding swb_build_service_connection_message_handler_t handlers.
        var channels = [UInt64: swb_build_service_connection_message_handler_t]()

        /// Track whether the channels have been cleared because the service has crashed.
        var channelsHaveBeenCleared = false
    }

    /// An "unfair lock" that protects the channels state.  Should be held only for very short periods of time.
    private let channelState = LockedValue<ChannelState>(.init())

    /// Absolute path to the dyld-loaded dylib binary that contains this class.
    fileprivate class var swiftbuildDylibPath: Path {
        return Library.locate(SWBBuildServiceConnection.self)
    }

    fileprivate enum State {
        case running
        case exited
        case crashed
    }

    /// Whether or not the underlying Swift Build service subprocess has terminated.
    public var hasTerminated: Bool {
        return connectionTransport.state != .running
    }

    /// Pipe for writing data to the stdin of the Swift Build service.
    private let stdinPipe: IOPipe

    /// Pipe for reading data from the stdout/stderr of the Swift Build service.
    private let stdoutPipe: IOPipe

    private let connectionTransport: any ConnectionTransport

    /// An opaque identifier representing the lifetime of this specific connection instance.
    let uuid = Foundation.UUID()

    /// Initializes a new Swift Build service connection by launching the service process and establishing a communication conduit to it.  The connection starts in suspended state, and must be resumed before any messages can be sent or received.  The connection must eventually be closed before being allowed to be deallocated.
    /// - parameter serviceBundleURL: Path to a specific service bundle URL to launch. If `nil`, the default lookup mechanism will be used.
    public init(connectionMode: SWBBuildServiceConnectionMode, variant: SWBBuildServiceVariant, serviceBundleURL: URL?) async throws {
        stdinPipe = try IOPipe()
        stdoutPipe = try IOPipe()

        var error = 0
        _stdinWriter = SWBDispatchIO.stream(fileDescriptor: DispatchFD(fileDescriptor: stdinPipe.writeEnd), queue: _queue) { err in
            // Cleanup handler, which is documented to be invoked with a non-zero error code only if the dispatch_io_t couldn't be created.
            if err != 0 {
                error = Int(err)
            }
        }
        assert(error == 0, "couldn’t create dispatch i/o stream for writing to subprocess stdin")
        _stdinWriter?.setLimit(lowWater: 0)
        _stdinWriter?.setLimit(highWater: Int.max)

        _stdoutReader = SWBDispatchIO.stream(fileDescriptor: DispatchFD(fileDescriptor: stdoutPipe.readEnd), queue: _queue) { err in
            // Cleanup handler, which is documented to be invoked with a non-zero error code only if the dispatch_io_t couldn't be created.
            if err != 0 {
                error = Int(err)
            }
        }
        assert(error == 0, "couldn’t create dispatch i/o stream for reading from subprocess stdout and stderr")
        _stdoutReader?.setLimit(lowWater: 0)
        _stdoutReader?.setLimit(highWater: Int.max)

        // Set up environment for the build service.
        // At this point we export selected user defaults to the environment which we want to make available to Swift Build. These include:
        //  - Xcode-defined user defaults which Swift Build is also interested in.
        //  - Swift Build user defaults which users want to specify on the Xcode side, for example as command-line options to xcodebuild.
        // Swift Build's UserDefaults class treats its environment as overrides to its own user defaults - see that class for details.
        for userDefault in xcodeUserDefaultsToExportToSwiftBuild {
            exportUserDefaultToEnvironment(userDefault)
        }

        self.connectionTransport = try connectionMode.createTransport(variant: variant, serviceBundleURL: serviceBundleURL, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)

        do {
            try self.connectionTransport.start { [weak self] error in
                guard let strongSelf = self else { return }

                strongSelf.suspend()
                strongSelf.sendCancellationMessages()

                guard let error else {
                    return
                }

                // If environment variable or user default are set, crash the IDE when the build service crashes.
                if ProcessInfo.processInfo.environment["SWIFTBUILD_ABORT_IDE_IF_SERVICE_ABORTED"] == "YES" || UserDefaults.standard.bool(forKey: "SwiftBuildAbortIDEIfServiceAborted") {
                    log("Shutting down build service due to fatal error: \(error)", isError: true)
                    abort()
                }
            }
        } catch {
            await self.close()
            throw error
        }
    }

    deinit {
        _isClosed.withLock { closed in
            if !closed {
                #if os(Windows)
                // FIXME: This is getting hit sometimes in the test suite
                print("connection wasn’t closed before being deallocated")
                #else
                assertionFailure("connection wasn’t closed before being deallocated")
                #endif
            }
        }
    }

    @_spi(Testing)
    public static func effectiveLaunchURL(for variant: SWBBuildServiceVariant, serviceBundleURL: URL?, environment: [String: String]) throws -> (URL, [String: String]) {
        asan: if variant.useASanMode {
            // Compute the path to the clang ASan dylib to use when launching the ASan variant of SWBBuildService.
            // The linker adds a non-portable rpath to the directory containing the ASan dylib based on the path to the Xcode used to link the binary.  We look in Bundle.main.bundlePath (SwiftBuild_asan) for .../Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/<vers>/lib/darwin so we can relaunch with the ASan library in the default toolchain of the Xcode we're part of.
            // There are some examples of this rpath breaking which we've had to fix, e.g.: rdar://57759442&75222176
            let asanDylib = SWBBuildServiceConnection.swiftbuildDylibPath.str.hasSuffix("_asan") ? SWBBuildServiceConnection.swiftbuildDylibPath.str : SWBBuildServiceConnection.swiftbuildDylibPath.str + "_asan"
            if !FileManager.default.isExecutableFile(atPath: asanDylib) {
                // We always look for the _asan variant of the build service executable since only it will have the rpaths we need to subsequently look up. However, if it's missing we should then just fall back to the normal variant.
                break asan
            }

            guard let binaryFile = FileHandle(forReadingAtPath: asanDylib),
                let macho = try? MachO(data: binaryFile),
                let rpaths = try? macho.slices()[0].rpaths() else {
                throw StubError.error("Could not open client library executable at \(asanDylib)")
            }

            let asanDylibPath: String? = {
                // Compute the path to the enclosing Xcode.app bundle, accounting for the different scenarios in which we might be called, in which our main bundle's executable path might be different.  Currently this logic supports:
                //  - From Xcode.app (the IDE).
                //  - From xcodebuild.
                //  - Environments in which DEVELOPER_DIR is set in the environment, such as our tests being run by the xctest agent.  This will be used instead of looking at the main bundle.
                // Note that we can't assume the Xcode bundle is named 'Xcode.app' - people name that bundle all sorts of things.
                let currentXcodeApp = getEnvironmentVariable("DEVELOPER_DIR").map({ Path($0).normalize().dirname.dirname.str }) ?? { () -> String in
                    let executablePath = Path(Bundle.main.executablePath ?? "")
                    switch executablePath {
                    case _ where executablePath.basename.hasPrefix("xcodebuild"):
                        // Remove 'Contents/Developer/usr/bin/xcodebuild*'.
                        return executablePath.dirname.dirname.dirname.dirname.dirname.str
                    default:
                        // Otherwise we assume we were called from Xcode.app and we return our main bundle's path.
                        return Bundle.main.bundlePath
                    }
                }()
                for rpath in rpaths {
                    // Now we look for the rpath the linker added.  We expect it to end in "lib/darwin".  Additionally we expect it to either contain "/Applications/Xcode.app/", or be a path into DEVELOPER_DIR (for unit testing, since the main bundle will be the test runner).
                    if rpath.hasSuffix("lib/darwin") {
                        var xcodeRelativeRpath: String? = nil
                        if rpath.starts(with: currentXcodeApp + "/") {
                            xcodeRelativeRpath = "\(rpath.dropFirst((currentXcodeApp + "/").count))"
                        }
                        else if rpath.contains("/Applications/Xcode.app/") {
                            if let endOfXcodeApp = rpath.range(of: "/Applications/Xcode.app/")?.upperBound {
                                xcodeRelativeRpath = String(rpath[endOfXcodeApp...])
                            }
                        }
                        if let xcodeRelativeRpath = xcodeRelativeRpath {
                            let path = currentXcodeApp.appending("/\(xcodeRelativeRpath)").appending("/libclang_rt.asan_osx_dynamic.dylib")
                            if FileManager.default.isReadableFile(atPath: path) {
                                return path
                            }
                        }
                    }
                }
                return nil
            }()

            // Only launch in asan mode if we were able to find the dylib, matching Xcode's behavior.
            if let asanDylib = asanDylibPath, let url = serviceExecutableURL(for: variant, serviceBundleURL: serviceBundleURL), url.lastPathComponent.hasSuffix("_asan") {
                return (url, environment.merging([
                    "DYLD_INSERT_LIBRARIES": asanDylib,

                    // If asan is enabled, inject the DYLD_IMAGE_SUFFIX environment variable so that the service loads up the _asan framework variants if they're present.
                    "DYLD_IMAGE_SUFFIX": "_asan"
                ], uniquingKeysWith: { _, new in new }))
            }
        }

        guard let url = serviceExecutableURL(for: .normal, serviceBundleURL: serviceBundleURL) else {
            throw StubError.error("cannot determine build service executable URL")
        }

        return (url, environment)
    }

    private func sendCancellationMessages() {
        // Capture the open channel map, and swap in an empty one while holding the lock.
        let channels = channelState.withLock { channelState in
            let channels = channelState.channels
            channelState.channels = [:]
            channelState.channelsHaveBeenCleared = true
            return channels
        }

        // Send a cancellation message to each handler that was open (we've already cleared out the map).
        if let data = connectionTransport.state.terminationReplyData {
            for (channel, handler) in channels {
                handler(channel, data)
            }
        }
    }

    /// Suspends the connection (but doesn’t terminate or even suspend the Swift Build service process).  After suspending the connection, no further messages will be dispatched until it is resumed again.  Does nothing if the connection is already suspended.
    public func suspend() {
        // If we are already suspended, do nothing.
        // Otherwise, mark the connection as suspended.
        if _isSuspended.exchange(true) {
            return
        }

        // Wait for any ongoing dispatch I/O to finish.
        _stateQueue.blocking_sync { _stdinWriter }?.barrier { }
        _stateQueue.blocking_sync { _stdoutReader }?.barrier { }
    }

    /// Resumes the connection.  Does nothing if the connection isn’t currently suspended.
    public func resume() {
        // If we aren’t suspended, do nothing.
        // Otherwise, mark the connection as no longer suspended.
        if !_isSuspended.exchange(false) {
            return
        }

        // Schedule the dispatch I/O operation to read data as it becomes available.
        _stateQueue.blocking_sync { _stdoutReader }?.read(offset: 0, length: Int.max, queue: _queue) { done, paramData, err in
            // FIXME: We need to deal properly with errors here.
            assert(err == 0 || err == EPIPE, "internal error: got \(err)")

            // Append the new data to any buffered data we have already.
            var data = self._bufferedData
            if let paramData {
                data.append(paramData)
            }

            // Process any complete messages (keeping track of how many bytes we’ve processed).
            // FIXME: For performance, avoid creating contiguous data here.
            var offset: Int = 0

            if !data.isEmpty {
                data.withUnsafeBytes { (pointer: UnsafePointer<UInt8>) -> Void in
                    // Keep going while we aren’t suspended and while have enough data for at least one more (possibly empty) message.
                    while !self._isSuspended.withLock({ $0 }) && offset + HeaderFrame.size <= data.count {
                        // Read the header, which consists of the channel number followed by the payload size.
                        let headerFrame = pointer.read(from: &offset) as HeaderFrame
                        let channel = headerFrame.channel
                        let msgSize = Int(headerFrame.messageSize)

                        // Look up the channel by its number.
                        let handler = self.channelState.withLock({ $0.channels[channel] })
                        if handler == nil {
                            // It’s an error if we didn’t find a channel here.
                            // FIXME: We need to handle this error in a better way.
                            assertionFailure("no handler for channel: \(channel)")
                        }

                        // If we don’t have all the data yet, we can go no further.
                        if offset + msgSize > data.count {
                            // Move the offset back to just before the header, so we’ll see it again next time around.
                            assert(offset >= HeaderFrame.size, "internal error: expected offset to be >= \(HeaderFrame.size) here, but it is \(offset)")
                            offset -= HeaderFrame.size
                            break
                        }

                        // Otherwise, look up the channel by its number.
                        handler?(channel, data.subdata(in: offset..<(offset + msgSize)))

                        // Move on to the next message.
                        offset += msgSize
                    }
                }
            }

            // Buffer any partial message until we get more data.
            self._bufferedData = data.subdata(in: offset..<data.count)
        }
    }

    /// Closes the connection, shuts down the Swift Build service, and releases any associated resources.  It is an error to allow the connection to be deallocated without being closed.
    public func close() async {
        // If we’re already closed, do nothing.
        if _isClosed.exchange(true) {
            return
        }

        // Otherwise, tell the subprocess to terminate. Do this on the zero channel so that we can guarantee the message has been enqueued by the time this method returns, but don't expect to receive a reply.
        send(Array("EXIT".utf8).withUnsafeBytes(SWBDispatchData.init(bytes:)), onChannel: 0)

        // Suspend ourself (this also waits for the queues to drain).
        suspend()

        await connectionTransport.close()

        // FIXME: We really should wait for any remaining I/O that hasn’t yet been sent by the subprocess.

        // Close down the send and receive queues.
        await _stateQueue.sync { [self] in
            _stdinWriter?.barrier { }
            _stdinWriter?.close()
            _stdinWriter = nil
            _stdoutReader?.barrier { }
            _stdoutReader?.close()
            _stdoutReader = nil
        }

        // We should be suspended now.
        if !_isSuspended.withLock({ $0 }) {
            assertionFailure("connection did not transition to suspended state properly")
        }
    }

    /// Terminates the Swift Build service process via SIGTERM if it is running out of process, otherwise does nothing if the service is running in-process.
    ///
    /// - note: This is intended for testing edge case scenarios and should not normally be called outside of tests. Instead, consider ``close()`` which cleanly shuts down the service.
    public func terminate() async {
        await connectionTransport.terminate()
    }
}

// Messages
extension SWBBuildServiceConnection {
    /// Opens a new message channel and returns its channel number (a positive integer).  The returned channel number can be used in ``send(_:onChannel:)`` calls to send messages to the SWBuildService.  The handler block will be invoked for each reply message received on the channel (until the channel is closed using the ``close(channel:)`` method).
    /*public*/ func openChannel(messageHandler block: @escaping swb_build_service_connection_message_handler_t) -> UInt64 {
        // Acquire the next unused channel number, and insert the block in the channel-to-handler map.
        return channelState.withLock { channelState in
            channelState.nextChannelID += 1
            let channel = channelState.nextChannelID
            assert(channel > 0, "internal error: channel count wrapped around to zero")
            assert(!channelState.channels.contains(channel), "internal error: channel \(channel) was already in use")
            channelState.channels[channel] = block

            // Return the channel number so that caller can pass it to the #sendData:onChannel: method.
            return channel
        }
    }

    /// Enqueues `data` to be sent on the specified channel, and returns immediately.  The channel must be one that has already been opened using the `openChannel(messageHandler:)` method, and it must not have been closed again.  Any replies will be sent to the block that was associated with the channel when it was opened.  It is valid for `data` to be empty, but not to be `nil`.
    func send(_ data: SWBDispatchData, onChannel channel: UInt64) {
        // Immediately reply with an error if the service has been terminated.
        // We only do this for "real" channels; the zero channel is used for special one-way messages.
        if channel > 0, let replyData = connectionTransport.state.terminationReplyData {
            // We may not have a handler, if it was cleared out as part of our own termination handler.
            if let handler = channelState.withLock({ $0.channels[channel] }) {
                handler(channel, replyData)
            }

            return
        }

        // Create the header, which consists of the channel number followed by the payload size.
        var headerData = withUnsafeBytes(of: channel.littleEndian) { SWBDispatchData(bytes: $0) }
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { headerData.append($0) }
        assert(headerData.count == 12) // UInt64 + UInt32
        headerData.append(data)

        // Schedule the dispatch I/O operation to write the header followed by the payload.
        _stateQueue.blocking_sync { _stdinWriter }?.write(offset: 0, data: headerData, queue: _queue) { done, data, err in
            // FIXME: We need to deal properly with errors here.
            assert(err == 0 || err == EPIPE, "internal error: got \(err)")
        }
    }

    /// Closes the specified channel.  The channel must be one that has already been opened using the `openChannel(messageHandler:)` method, and it must not already have been closed again.  Any messages received on the channel (including any that are waiting to be processed) after this call will result in an error.
    public func close(channel: UInt64) {
        // Check parameters.
        precondition(channel > 0, "channel number to close must be greater than 0")

        // Find and remove the block from the channel-to-handler map.
        channelState.withLock { channelState in
            // If the client crashes, it is possible we will receive a request to close a channel which has already been closed.
            assert(channelState.channelsHaveBeenCleared || channelState.channels.contains(channel), "internal error: channel \(channel) wasn't in use")
            channelState.channels.removeValue(forKey: channel)
        }
    }
}

// RPCs
extension SWBBuildServiceConnection {
    /// Enqueues `data` to be sent on a temporary new channel, and returns immediately.  The channel is used only for delivering the message and for waiting for the reply, and then it is closed again.  This can be used as a convenience for one-shot RPC messages where there is no conceptual notion of a channel that persists over time.
    func send(_ data: SWBDispatchData) async -> SWBDispatchData {
        return await withCheckedContinuation { continuation in
            // Immediately reply with an error if the service has been terminated
            if let replyData = connectionTransport.state.terminationReplyData {
                return continuation.resume(returning: replyData)
            }

            // Create a temporary channel on which to send the data.
            let channel = openChannel() { channel, reply in
                // Once we receive the reply, we close the channel before invoking the reply block.
                self.close(channel: channel)
                continuation.resume(returning: reply)
            }

            // Send the data on the channel.
            send(data, onChannel: channel)
        }
    }
}

extension SWBBuildServiceConnection {
    fileprivate struct BuildServiceLocation {
        var executable: URL
        var bundle: Bundle?
    }

    fileprivate static func buildServiceLocation(for variant: SWBBuildServiceVariant, overridingServiceBundleURL: URL?) -> BuildServiceLocation? {
        // Check if there is an explicit executable override in the environment. This guarantees use of the exact binary specified (does not look for an ASan variant suffix).
        if let environmentOverridingExecutablePath = getEnvironmentVariable("SWBBUILDSERVICE_PATH")?.nilIfEmpty ?? getEnvironmentVariable("XCBBUILDSERVICE_PATH")?.nilIfEmpty {
            let executableURL = URL(fileURLWithPath: environmentOverridingExecutablePath, isDirectory: false)

            let bundleURL: URL? =
                if case let candidateURL = executableURL.deletingLastPathComponent(), candidateURL.pathExtension == "bundle" {
                    candidateURL
                }
                else if case let candidateURL = executableURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), candidateURL.pathExtension == "bundle" {
                    candidateURL
                }
                else {
                    nil
                }

            let bundle: Bundle? =
                if let bundleURL {
                    Bundle(url: bundleURL)
                }
                else {
                    nil
                }

            return BuildServiceLocation(executable: executableURL, bundle: bundle)
        }

        let useASanMode = variant.useASanMode

        // Check if there is an explicit bundle override in the environment, or if there was one passed in.
        // This is the path to the service bundle rather than directly to the executable and so respects ASan-ness.
        if let buildServiceBundleURLOverride = getEnvironmentVariable("SWBBUILDSERVICE_BUNDLE_PATH")?.nilIfEmpty.map({ URL(fileURLWithPath: $0, isDirectory: true) }) ?? getEnvironmentVariable("XCBBUILDSERVICE_BUNDLE_PATH")?.nilIfEmpty.map({ URL(fileURLWithPath: $0, isDirectory: true) }) ?? overridingServiceBundleURL, let bundle = Bundle(url: buildServiceBundleURLOverride), let executableURL = bundle.executableURL {
            if useASanMode, let asanExecutableURL = executableURL.asanURLVariant {
                return BuildServiceLocation(executable: asanExecutableURL, bundle: bundle)
            }
            return BuildServiceLocation(executable: executableURL, bundle: bundle)
        }

        // Look for the service inside a PlugIns bundle.
        if let buildServiceBundleURL = Bundle(for: SWBBuildServiceConnection.self).builtInPlugInsURL?.appendingPathComponent("SWBBuildService.bundle"),
            let bundle = Bundle(url: buildServiceBundleURL),
            let executableURL = bundle.executableURL {
            if useASanMode, let asanExecutableURL = executableURL.asanURLVariant {
                return BuildServiceLocation(executable: asanExecutableURL, bundle: bundle)
            }
            return BuildServiceLocation(executable: executableURL, bundle: bundle)
        }

        guard let hostOperatingSystem = try? ProcessInfo.processInfo.hostOperatingSystem() else {
            return nil
        }

        let executableName = hostOperatingSystem.imageFormat.executableName(basename: "SWBBuildServiceBundle")

        // Look for the service next to the running image (Swift package builds)
        if let localURL = Bundle(for: SWBBuildServiceConnection.self).bundleURL.deletingLastPathComponent().appendingPathComponent(executableName) as URL?, let localURLPath = try? localURL.filePath, FileManager.default.isExecutableFile(atPath: localURLPath.str) {
            if useASanMode, let asanLocalURL = localURL.asanURLVariant {
                return BuildServiceLocation(executable: asanLocalURL)
            }
            return BuildServiceLocation(executable: localURL)
        }

        // Look for the service next to the running executable
        if let localURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(executableName), let localURLPath = try? localURL.filePath, FileManager.default.isExecutableFile(atPath: localURLPath.str) {
            if useASanMode, let asanLocalURL = localURL.asanURLVariant {
                return BuildServiceLocation(executable: asanLocalURL)
            }
            return BuildServiceLocation(executable: localURL)
        }

        return nil
    }

    /// Get the path of the service binary for the default variant.
    public static var serviceExecutableURL: URL? {
        return serviceExecutableURL(for: .default, serviceBundleURL: nil)
    }

    /// Get the path of the service binary for the specified variant.
    public static func serviceExecutableURL(for variant: SWBBuildServiceVariant, serviceBundleURL: URL?) -> URL? {
        return buildServiceLocation(for: variant, overridingServiceBundleURL: serviceBundleURL)?.executable
    }
}

extension URL {
    /// Helper property to retrieve the _asan variant of an executable, if it exists beside the original executable.
    var asanURLVariant: URL? {
        let asanURL = deletingLastPathComponent().appendingPathComponent(lastPathComponent + "_asan")
        do {
            if try FileManager.default.isExecutableFile(atPath: asanURL.filePath.str) {
                return asanURL
            }
        } catch {
            // wasn't a file URL
        }
        return nil
    }
}

/// Additional API for accessing diagnostic information about the connection.  Should not be used to make decisions about the normal operation of the connection (for example, the PID of the Swift Build subprocess should not be used for direct system calls on that process).
extension SWBBuildServiceConnection {
    /// The PID of the underlying process.
    ///
    /// Returns `nil` if there is no underlying subprocess, which is the case if the build service is being run in-process.
    var subprocessPID: pid_t? {
        connectionTransport.subprocessPID
    }
}

/// Method by which to launch the build service.
public enum SWBBuildServiceConnectionMode: Sendable {
    /// Launch the build service in-process, statically with the provided swiftBuildServiceEntryPoint function.
    case inProcessStatic(@Sendable (Int32, Int32, URL?, @Sendable @escaping ((any Error)?) -> Void) -> Void)

    /// Launch the build service in-process.
    case inProcess

    /// Launch the build service as a separate process.
    case outOfProcess

    /// Launch the build service in-process if the `XCBUILD_LAUNCH_IN_PROCESS` environment variable is set, otherwise launch the build service out-of-process. Embedded platforms support only the in-process mode.
    public static var `default`: Self {
        if (try? ProcessInfo.processInfo.hostOperatingSystem().isAppleEmbedded) == true {
            return .inProcess
        }
        return getEnvironmentVariable("SWIFTBUILD_LAUNCH_IN_PROCESS")?.boolValue == true || getEnvironmentVariable("XCBUILD_LAUNCH_IN_PROCESS")?.boolValue == true ? .inProcess : .outOfProcess
    }
}

/// The variant of the build service executable to launch.
public enum SWBBuildServiceVariant: Sendable {
    /// Request to launch the normal or address sanitizer enabled variant of the build service, depending on whether the running Swift Build client framework is address sanitizer enabled.
    case `default`

    /// Request to launch the normal variant of the build service.
    case normal

    /// Request to launch the address sanitizer enabled variant of the build service.
    case asan
}

extension SWBBuildServiceVariant {
    /// Whether we should try to launch the service process using the asan variant.
    var useASanMode: Bool {
        switch self {
        case .default:
            // Check if the binary containing this class ends with _asan, in which case, we interpret this as a signal that we're running in asan mode, and that we should
            // load the service bundle in asan mode as well.
            return SWBBuildServiceConnection.swiftbuildDylibPath.str.hasSuffix("_asan")
        case .normal:
            return false
        case .asan:
            return true
        }
    }
}

extension SWBBuildServiceConnection.State {
    var terminationReplyData: SWBDispatchData? {
        switch self {
        case .running:
            return nil
        case .exited:
            return .encodingIPCErrorStringUsingMsgPack("The Xcode build system has terminated due to an error. Build again to continue.")
        case .crashed:
            return .encodingIPCErrorStringUsingMsgPack("The Xcode build system has crashed. Build again to continue.")
        }
    }
}

fileprivate extension SWBDispatchData {
    static func encodingIPCErrorStringUsingMsgPack(_ string: String) -> Self {
        let serializer = MsgPackSerializer()
        IPCMessage(ErrorResponse(string)).serialize(to: serializer)
        return serializer.byteString.bytes.withUnsafeBytes { .init(bytes: $0) }
    }
}

extension SWBBuildServiceConnectionMode {
    fileprivate func createTransport(variant: SWBBuildServiceVariant, serviceBundleURL: URL?, stdinPipe: IOPipe, stdoutPipe: IOPipe) throws -> any ConnectionTransport {
        switch self {
        case let .inProcessStatic(startFunc):
            return try InProcessStaticConnection(serviceBundleURL: serviceBundleURL, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe, startFunc: startFunc)
        case .inProcess:
            return try InProcessConnection(variant: variant, serviceBundleURL: serviceBundleURL, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
        case .outOfProcess:
            #if os(macOS) || targetEnvironment(macCatalyst) || !canImport(Darwin)
            return try OutOfProcessConnection(variant: variant, serviceBundleURL: serviceBundleURL, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
            #else
            throw StubError.error("Out-of-process mode is unavailable; use in-process mode.")
            #endif
        }
    }
}

fileprivate protocol ConnectionTransport: AnyObject, Sendable {
    var state: SWBBuildServiceConnection.State { get }
    var subprocessPID: pid_t? { get }

    func start(terminationHandler: (@Sendable ((any Error)?) -> Void)?) throws
    func terminate() async
    func close() async
}

fileprivate final class InProcessStaticConnection: ConnectionTransport {
    private let stdinPipe: IOPipe
    private let stdoutPipe: IOPipe
    private let serviceBundleURL: URL?
    private let done = WaitCondition()
    private let _state: LockedValue<SWBBuildServiceConnection.State> = .init(.running)
    private let startFunc: @Sendable (Int32, Int32, URL?, @Sendable @escaping ((any Error)?) -> Void) -> Void

    init(serviceBundleURL: URL?, stdinPipe: IOPipe, stdoutPipe: IOPipe, startFunc: @Sendable @escaping (Int32, Int32, URL?, @Sendable @escaping ((any Error)?) -> Void) -> Void) throws {
        self.serviceBundleURL = serviceBundleURL
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.startFunc = startFunc
    }

    var state: SWBBuildServiceConnection.State {
        return _state.withLock { $0 }
    }

    var subprocessPID: pid_t? {
        return nil
    }

    func start(terminationHandler: (@Sendable ((any Error)?) -> Void)?) throws {
        var launched = false
        defer {
            // if there was a failure prior to calling the entry point, signal completion
            if !launched {
                done.signal()
            }
        }

        let inputFD = stdinPipe.readEnd.rawValue
        let outputFD = stdoutPipe.writeEnd.rawValue

        let buildServiceLocation = SWBBuildServiceConnection.buildServiceLocation(for: .normal, overridingServiceBundleURL: serviceBundleURL)
        let buildServicePlugInsDirectory: URL?
        if let buildServiceLocation, let buildServiceBundle = buildServiceLocation.bundle {
            buildServicePlugInsDirectory = buildServiceBundle.builtInPlugInsURL
        } else if let buildServiceLocation: SWBBuildServiceConnection.BuildServiceLocation {
            let path = SWBUtil.Path(buildServiceLocation.executable.path)
            buildServicePlugInsDirectory = URL(fileURLWithPath: path.dirname.str, isDirectory: true)
        } else {
            // If the build service executable is unbundled, then try to find the build service entry point in this executable.
            let path = Library.locate(SWBBuildServiceConnection.self)
            // If the build service executable is unbundled, assume that any plugins that may exist are next to our executable.
            buildServicePlugInsDirectory = URL(fileURLWithPath: path.dirname.str, isDirectory: true)
        }
        launched = true
        self.startFunc(Int32(inputFD), Int32(outputFD), buildServicePlugInsDirectory, { [done, terminationHandler] error in
            defer { done.signal() }

            #if !canImport(Darwin)
            // Workaround for a compiler crash presumably related to Objective-C bridging on non-Darwin platforms (rdar://130826719&136043295)
            terminationHandler?(error as! (any Error)?)
            #else
            terminationHandler?(error)
            #endif
        })
    }

    func terminate() async {
        _state.withLock { $0 = .crashed }
        await done.wait()
    }

    func close() async {
        _state.withLock { $0 = .exited }
        await done.wait()
    }
}

fileprivate final class InProcessConnection: ConnectionTransport {
    private let variant: SWBBuildServiceVariant
    private let serviceBundleURL: URL?
    private let stdinPipe: IOPipe
    private let stdoutPipe: IOPipe
    private let done = WaitCondition()
    private let _state: LockedValue<SWBBuildServiceConnection.State> = .init(.running)

    init(variant: SWBBuildServiceVariant, serviceBundleURL: URL?, stdinPipe: IOPipe, stdoutPipe: IOPipe) throws {
        self.variant = variant
        self.serviceBundleURL = serviceBundleURL
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
    }

    var state: SWBBuildServiceConnection.State {
        return _state.withLock { $0 }
    }

    var subprocessPID: pid_t? {
        return nil
    }

    func start(terminationHandler: (@Sendable ((any Error)?) -> Void)?) throws {
        var launched = false
        defer {
            // if there was a failure prior to calling the entry point, signal completion
            if !launched {
                done.signal()
            }
        }

        let buildServiceLocation = SWBBuildServiceConnection.buildServiceLocation(for: variant, overridingServiceBundleURL: serviceBundleURL)

        let handle: LibraryHandle
        let buildServicePlugInsDirectory: URL?
        if let buildServiceLocation, let buildServiceBundle = buildServiceLocation.bundle {
            guard let buildServiceFrameworkURL = buildServiceBundle.privateFrameworksURL?.appendingPathComponent("SWBBuildService.framework", isDirectory: true) else {
                throw StubError.error("cannot determine build service framework URL in build service bundle")
            }

            guard let buildServiceFrameworkBundle = Bundle(url: buildServiceFrameworkURL), let normalBuildServiceFrameworkExecutableURL = buildServiceFrameworkBundle.executableURL else {
                throw StubError.error("cannot determine build service framework executable URL")
            }

            let buildServiceFrameworkExecutableURL: URL
            if variant.useASanMode {
                buildServiceFrameworkExecutableURL = normalBuildServiceFrameworkExecutableURL.asanURLVariant ?? normalBuildServiceFrameworkExecutableURL
            }
            else {
                buildServiceFrameworkExecutableURL = normalBuildServiceFrameworkExecutableURL
            }

            let buildServiceFrameworkExecutablePath = try buildServiceFrameworkExecutableURL.filePath

            // Open the service executable and find the entry point...
            do {
                handle = try Library.open(buildServiceFrameworkExecutablePath)
            } catch {
                throw StubError.error("unable to open build service framework executable at '\(buildServiceFrameworkExecutablePath.str)': \(error)")
            }

            buildServicePlugInsDirectory = buildServiceBundle.builtInPlugInsURL
        } else if let buildServiceLocation {
            let path = SWBUtil.Path(buildServiceLocation.executable.path)
            handle = try Library.open(path)
            buildServicePlugInsDirectory = URL(fileURLWithPath: path.dirname.str, isDirectory: true)
        } else {
            // If the build service executable is unbundled, then try to find the build service entry point in this executable.
            let path = Library.locate(SWBBuildServiceConnection.self)
            handle = try Library.open(path)

            // If the build service executable is unbundled, assume that any plugins that may exist are next to our executable.
            buildServicePlugInsDirectory = URL(fileURLWithPath: path.dirname.str, isDirectory: true)
        }

        let entryPointName = "swiftbuildServiceEntryPoint"
        #if !canImport(Darwin)
        // Workaround for a compiler crash presumably related to Objective-C bridging on non-Darwin platforms (rdar://130826719&136043295)
        typealias swiftbuildServiceEntryPoint_t = @convention(c) (Int32, Int32, URL?, @Sendable @escaping (Any) -> Void) -> Void
        #else
        typealias swiftbuildServiceEntryPoint_t = @convention(c) (Int32, Int32, URL?, @Sendable @escaping ((any Error)?) -> Void) -> Void
        #endif
        guard let entryPointFunc: swiftbuildServiceEntryPoint_t = Library.lookup(handle, entryPointName) else {
            throw StubError.error("unable to find \(entryPointName) function in service executable")
        }

        let inputFD = stdinPipe.readEnd.rawValue
        let outputFD = stdoutPipe.writeEnd.rawValue

        // Launch the service, in process (on background queues).
        launched = true
        entryPointFunc(Int32(inputFD), Int32(outputFD), buildServicePlugInsDirectory, { [done, terminationHandler] error in
            defer { done.signal() }

            #if !canImport(Darwin)
            // Workaround for a compiler crash presumably related to Objective-C bridging on non-Darwin platforms (rdar://130826719&136043295)
            terminationHandler?(error as! (any Error)?)
            #else
            terminationHandler?(error)
            #endif
        })
    }

    func terminate() async {
        _state.withLock { $0 = .crashed }
        await done.wait()
    }

    func close() async {
        _state.withLock { $0 = .exited }
        await done.wait()
    }
}

#if os(macOS) || targetEnvironment(macCatalyst) || !canImport(Darwin)
fileprivate final class OutOfProcessConnection: ConnectionTransport {
    private let task: SWBUtil.Process
    private let done = WaitCondition()

    init(variant: SWBBuildServiceVariant, serviceBundleURL: URL?, stdinPipe: IOPipe, stdoutPipe: IOPipe) throws {
        /// Create and configure an NSTask for launching the Swift Build subprocess.
        task = Process()

        // Compute the launch path and environment.
        var updatedEnvironment = ProcessInfo.processInfo.environment
        // Add the contents of the SWBBuildServiceEnvironmentOverrides user default.
        updatedEnvironment = updatedEnvironment.addingContents(of: (UserDefaults.standard.dictionary(forKey: "SWBBuildServiceEnvironmentOverrides") as? [String: String]) ?? [:])
        // Remove inferior DYLD_LIBRARY_PATH paths into toolchains, or which contain a compiler library known to cause issues when mismatched. Swift Build does not need these when used by an inferior Xcode, and they can interfere with loading of correct clang and swift libraries.
        if let libraryPaths = updatedEnvironment["DYLD_LIBRARY_PATH"]?.components(separatedBy: ":") {
            updatedEnvironment["DYLD_LIBRARY_PATH"] = try libraryPaths.filter {
                var path = Path($0).normalize()
                let libExt = try ProcessInfo.processInfo.hostOperatingSystem().imageFormat.dynamicLibraryExtension
                for knownCompilerLibrary in ["libclang.\(libExt)", "lib_InternalSwiftScan.\(libExt)"] {
                    if localFS.exists(path.join(knownCompilerLibrary)) {
                        return false
                    }
                }
                while !path.isRoot && !path.isEmpty {
                    if path.fileExtension == "xctoolchain" {
                        return false
                    }
                    path = path.dirname
                }
                return true
            }.joined(separator: ":")
        }
        let (launchURL, environment) = try SWBBuildServiceConnection.effectiveLaunchURL(for: variant, serviceBundleURL: serviceBundleURL, environment: updatedEnvironment)

        #if os(macOS) || targetEnvironment(macCatalyst)
        let hostVersion = try Version(ProcessInfo.processInfo.operatingSystemVersion)
        if let buildVersion = try MachO(reader: BinaryReader(data: FileHandle(forReadingFrom: launchURL))).slices().flatMap({ try $0.buildVersions() }).filter({ $0.platform == .macOS }).only {
            if buildVersion.minOSVersion > hostVersion {
                throw StubError.error("Couldn't launch the build service process '\(try launchURL.filePath.str)' because it requires macOS \(buildVersion.minOSVersion.canonicalDeploymentTargetForm) or later (running macOS \(hostVersion.canonicalDeploymentTargetForm)).")
            }
        }
        #endif

        task.executableURL = launchURL
        task.currentDirectoryURL = launchURL.deletingLastPathComponent()
        task.environment = environment

        // Similar to the rationale for giving 'userInitiated' QoS for the 'SWBBuildService.ServiceHostConnection.receiveQueue' queue (see comments for that).
        // Start the service subprocess with the max QoS so it is setup to service 'userInitiated' requests if required.
        task.qualityOfService = .userInitiated

        task.standardInput = FileHandle(fileDescriptor: stdinPipe.readEnd.rawValue)
        task.standardOutput = FileHandle(fileDescriptor: stdoutPipe.writeEnd.rawValue)
    }

    var state: SWBBuildServiceConnection.State {
        if task.isRunning {
            return .running
        } else {
            switch task.terminationReason {
            case .exit:
                return .exited
            case .uncaughtSignal:
                return .crashed
            #if canImport(Foundation.NSTask) || !canImport(Darwin)
            @unknown default:
                preconditionFailure()
            #endif
            }
        }
    }

    var subprocessPID: pid_t? {
        return task.processIdentifier
    }

    func start(terminationHandler: (@Sendable ((any Error)?) -> Void)?) throws {
        // Install a termination handler that suspends us if we detect the termination of the subprocess.
        task.terminationHandler = { [self] task in
            defer { done.signal() }

            do {
                try terminationHandler?(RunProcessNonZeroExitError(task))
            } catch {
                terminationHandler?(error)
            }
        }

        do {
            // Launch the Swift Build subprocess.
            try task.run()
        } catch {
            // terminationHandler isn't going to be called if `run()` throws.
            done.signal()
            throw error
        }

        #if os(macOS)
        do {
            // If IBAutoAttach is enabled, send the message so Xcode will attach to the inferior.
            try Debugger.requestXcodeAutoAttachIfEnabled(task.processIdentifier)
        } catch {
            // Terminate the subprocess if start() is going to throw, so that close() will not hang
            task.terminate()
        }
        #endif
    }

    func terminate() async {
        assert(task.processIdentifier > 0)
        task.terminate()
        await done.wait()
        assert(!task.isRunning)
    }

    /// Wait for the subprocess to terminate.
    func close() async {
        assert(task.processIdentifier > 0)
        await done.wait()
        assert(!task.isRunning)
    }
}
#endif

extension UnsafePointer where Pointee == UInt8 {
    fileprivate func read<T: FixedWidthInteger>(from offset: inout Int) -> T {
        var rawValue: T = 0
        withUnsafeMutableBytes(of: &rawValue) { valuePtr in
            valuePtr.copyBytes(from: UnsafeRawBufferPointer(start: advanced(by: offset), count: MemoryLayout<T>.size))
        }
        offset += MemoryLayout<T>.size
        return T(littleEndian: rawValue)
    }

    fileprivate func read(from offset: inout Int) -> HeaderFrame {
        HeaderFrame(channel: read(from: &offset), messageSize: read(from: &offset))
    }
}

fileprivate struct HeaderFrame {
    let channel: UInt64
    let messageSize: UInt32

    static var size: Int {
        MemoryLayout<UInt64>.size + MemoryLayout<UInt32>.size
    }
}
