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

public import struct Foundation.Date
public import func Foundation.NSLog
public import class Foundation.ProcessInfo
public import class Foundation.RunLoop
public import class Foundation.Thread

import SWBLibc

/// Get the name of the build service executable
public func buildServiceExecutableName() -> String {
#if SWBBUILDSERVICE_USE_DEBUG_EXECUTABLE_SUFFIX
    return "SWBBuildServiceDebug"
#else
    return "SWBBuildService"
#endif
}

public func log(_ message: String, isError: Bool = false) {
    #if canImport(os)
    if isError {
        return OSLog.log(message)
    }
    #endif
    NSLog(message)
}

/// Get the path to the user cache directory.
public func userCacheDir() -> Path {
    #if canImport(Darwin)
    struct Static {
        static let value = { () -> Path in
            let len = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)

            let tmp = UnsafeMutableBufferPointer(start: UnsafeMutablePointer<Int8>.allocate(capacity: len), count:len)
            defer {
                tmp.deallocate()
            }
            guard confstr(_CS_DARWIN_USER_CACHE_DIR, tmp.baseAddress, len) == len else { fatalError("unexpected confstr failure()") }

            return Path(String(cString: tmp.baseAddress!))
        }()
    }
    return Static.value
    #else
    return .temporaryDirectory
    #endif
}

public func parseUmbrellaHeaderName(_ string: String) -> String? {
    struct Static {
        static let regex = try! RegEx(pattern: "umbrella *header *\"(.*)\"")
    }
    return Static.regex.matchGroups(in: string).first?[0]
}

#if os(Android)
public typealias FILEPointer = OpaquePointer
#else
public typealias FILEPointer = UnsafeMutablePointer<FILE>
#endif

/// Adapts a FILE to a TextOutputStream. Does not own or automatically close the file.
public struct FILETextOutputStream: TextOutputStream {
    let stream: FILEPointer

    public init(_ stream: FILEPointer) {
        self.stream = stream
    }

    public func write(_ string: String) {
        fputs(string, stream)
    }

    public static var stdout: Self {
        .init(SWBLibc.stdout)
    }

    public static var stderr: Self {
        .init(SWBLibc.stderr)
    }
}

@available(*, unavailable)
extension FILETextOutputStream: Sendable { }

#if canImport(Darwin)
public import func Foundation.autoreleasepool
#endif

public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    #if canImport(Darwin)
    return try Foundation.autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

#if !canImport(Darwin)
public let NSEC_PER_SEC: UInt64 = 1000000000
public let NSEC_PER_MSEC: UInt64 = 1000000
public let USEC_PER_SEC: UInt64 = 1000000
public let NSEC_PER_USEC: UInt64 = 1000
#endif

extension Date: Serializable {
    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serialize(timeIntervalSinceReferenceDate)
    }

    public init(from deserializer: any Deserializer) throws {
        try self.init(timeIntervalSinceReferenceDate: deserializer.deserialize())
    }
}

extension IndexingIterator {
    /// Consumes and returns the next `count` elements from the iterator.
    ///
    /// - parameter transform: A closure used to transform the element before adding it to the returned array. Because this provides access to the iterator, executing the closure may consume additional elements and consequently may consume more elements than indicated by `count`. By default, the element is returned unchanged.
    /// - returns: An array containing the consumed elements. The length of the array is guaranteed to be equal to `count`, and any `nil` elements in the array indicate that the end of iteration was reached.
    @discardableResult public mutating func next(count: Int, transform: (inout Self, Element?) -> (Element?) = { _, e in e }) -> [Element?] {
        return (0..<count).map { _ in transform(&self, next()) }
    }
}
