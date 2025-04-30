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

package import Foundation
import SWBUtil
package import SWBCore

#if os(macOS)
import OSLog
#endif

extension ExecutableTask {
    /// Whether or not this task is being executed within a sandbox which restricts filesystem access to declared inputs and outputs.
    ///
    /// - note: Currently this will be true for any task whose executable is `sandbox-exec`, not only tasks which were created using _Swift Builds_ sandboxing mechanism and therefore whose diagnostics contain the message sentinel that we look for. However, this shouldn't really matter in practice at this time as if this property is true for a task not sandboxed _by Swift Build_, we'll simply not extract any diagnostics for it. The only way to get into this situation is to create such tasks in the PIF, which end-users can't do.
    package var isSandboxed: Bool {
        return commandLine.first?.asByteString == ByteString(encodingAsUTF8: "/usr/bin/sandbox-exec")
    }

    /// This must be called from threads which aren't Swift async worker threads. This func uses OSLog which kicks off async work and waits for it on a semaphore, causing deadlocks when invoked from Swift Concurrency worker threads.
    @available(*, noasync)
    package func extractSandboxViolationMessages_ASYNC_UNSAFE(startTime: Date) -> [String] {
        var res: [String] = []
        #if os(macOS)
        withUnsafeCurrentTask { task in
            if task != nil {
                preconditionFailure("This function should not be invoked from the Swift Concurrency thread pool as it may lead to deadlock via thread starvation.")
            }
        }

        if let store = try? OSLogStore.local() {
            let query = String("((processID == 0 AND senderImagePath CONTAINS[c] \"/Sandbox\") OR (process == \"sandboxd\" AND subsystem == \"com.apple.sandbox.reporting\")) AND (eventMessage CONTAINS[c] %@)")
            let endTime = Date()
            let duration = -DateInterval(start: startTime, end: endTime).duration

            let position = store.position(timeIntervalSinceEnd: duration)

            let sentinel = identifier.sandboxProfileSentinel

            if let entries = try? store.getEntries(with: [], at: position, matching: NSPredicate(format: query, sentinel)) {
                for entry in entries {
                    if entry is (any OSLogEntryWithPayload) {
                        let fullViolation = entry.composedMessage
                        if let strippedViolation = fullViolation.components(separatedBy: "\n").first {
                            // strip the guid from the emitted diagnostic
                            res.append(strippedViolation)
                        } else {
                            // this should never happen
                            res.append("Failed to parse sandbox violation: \(fullViolation)")
                        }
                    }

                    if let entryWithPayload = entry as? (any OSLogEntryWithPayload),
                        entryWithPayload.components.count == 5,
                        entryWithPayload.components[3].argumentCategory == .string,
                        let violationMessage = entryWithPayload.components[3].argumentStringValue {
                        res.append(violationMessage)
                    }
                }
            }
        }
        #else
        res.append("Cannot obtain list of violations on non-macOS platforms")
        #endif
        return res
    }
}
