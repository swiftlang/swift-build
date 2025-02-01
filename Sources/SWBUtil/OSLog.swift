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

import func Foundation.NSLog

#if canImport(os)
public import os

/// A wrapper around the OSLog.
public final class OSLog: Sendable {

    /// Payload of a log message.
    public struct Payload: Sendable {
        public let message: String
        public let file: String
        public let line: UInt
        public let function: String

        init(message: String, file: String, line: UInt, function: String) {
            self.message = message
            self.file = file
            self.line = line
            self.function = function
        }
    }

    /// The default OSLog instance.
    static let `default` = OSLog()

    /// The underlying log reference. If nil, the default log will be used.
    let log: os.OSLog?

    /// The formatter for the log messages.
    let formatter: any OSLogMessageFormatter

    /// Queue to dispatch the log on.
    private let queue = SWBQueue(label: "\(OSLog.self).queue", autoreleaseFrequency: .workItem)

    /// Create an instance of OSLog.
    public init(_ log: os.OSLog? = nil, formatter: any OSLogMessageFormatter = DefaultOSLogMessageFormatter()) {
        self.log = log
        self.formatter = formatter
    }

    deinit {
        queue.blocking_sync{}
    }

    /// Log a message.
    public func log(_ message: @Sendable @escaping @autoclosure () -> String, file: String = #file, function: String = #function, line: UInt = #line) {
        queue.async { [log, formatter] in
            // Construct and format the payload.
            let payload = Payload(message: message(), file: file, line: line, function: function)
            let formattedMessage = formatter.format(payload)

            os_log("%@", log: log ?? .default, formattedMessage)
        }
    }
}

extension OSLog {
    /// Log a message using the default OSLog instance.
    public static func log(_ message: @Sendable @escaping @autoclosure () -> String, file: String = #file, function: String = #function, line: UInt = #line) {
        OSLog.default.log(message(), file: file, function: function, line: line)
    }
}

/// A formatter for OSLog messages.
public protocol OSLogMessageFormatter: Sendable {
    func format(_ payload: OSLog.Payload) -> String
}

/// The default formatter that displays the entire payload.
public struct DefaultOSLogMessageFormatter: OSLogMessageFormatter, Sendable {

    public init(){}

    public func format(_ payload: OSLog.Payload) -> String {
        return "\(payload.file):\(payload.line):\(payload.function) \(payload.message)"
    }
}
#endif
