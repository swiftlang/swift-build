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

public import Foundation

/// Implements a comparable N-component version number (A.B...N), which can be initialized from a string form, and used in a `Range` or `ClosedRange`.
public struct Version: CustomStringConvertible, Sendable {
    public typealias Component = UInt
    public typealias RawValue = [Component]

    /// The raw components that make up the version.
    public let rawValue: RawValue

    /// Initialize a `Version` from the given `rawValue`. This is a convenience form as there are no failable constructs for `Version`.
    public init(_ rawValue: RawValue) {
        self.rawValue = rawValue
    }

    /// Initializes an empty `Version`
    public init() {
        self.init([])
    }

    /// Initializes a `Version` type given the various components, in order.
    public init(_ components: Component...) {
        self.init(components)
    }

    public init(ignoringTrailingNegativeComponents: Int...) throws {
        // Remove any trailing "-1" components,
        // which indicates a missing component in a fixed-length array
        var components = ignoringTrailingNegativeComponents
        while let last = components.last, last < 0 {
            components.removeLast()
        }

        // Check if there are any positive components FOLLOWED by negative ones
        if let negativeComponent = components.first(where: { $0 < 0 }) {
            throw StubError.error("Could not parse component; value \(negativeComponent) is out of range at this position")
        }

        // All remaining components are positive Ints,
        // which mean they fit in the range of a UInt
        self.init(components.map { UInt($0) })
    }

    /// Used to initialize a `Version` that can only have a limited set of components.
    public init(_ s: String, maximumNumberOfComponents: Int? = nil) throws {
        let components: [Component] = try s.split(separator: ".").map { c in
            guard let r = Component(c) else { throw StubError.error("Could not parse version component from: '\(c)'") }
            return r
        }

        if components.count <= 0 { throw StubError.error("There are no components to parse: '\(s)'") }
        if let max = maximumNumberOfComponents {
            if components.count > max { throw StubError.error("There are too many components: '\(s)', maximumNumberOfComponents: \(max)") }
            self.init(Version.normalized(components, max))
        }
        else {
            self.init(components)
        }
    }

    public subscript(n: UInt) -> Component {
        return n < rawValue.count ? rawValue[Int(n)] : 0
    }

    /// Returns the same Version with trailing ".0"s removed.
    public var zeroTrimmed: Version {
        let components = self.rawValue
        guard !components.isEmpty else { return self }
        var index = 0
        if let rindex = components.reversed().firstIndex(where: { $0 != 0 }) {
            index = components.index(before: rindex.base)
        }
        return Version(Array(components[0...index]))
    }

    /// Returns the same Version with trailing ".0"s added until the version contains at least `count` number of components.
    /// - Parameter count: The minimum number of components in the resulting Version.
    public func zeroPadded(toMinimumNumberOfComponents count: Int) -> Version {
        guard self.rawValue.count < count else { return self }
        return Version(Version.normalized(self.rawValue, count))
    }

    /// Returns the Version normalized to the given number of values.  This will zero-pad if the number is larger than the existing number of values, and truncate if given a number smaller.
    public func normalized(toNumberOfComponents count: Int) -> Version {
        return Version(Version.normalized(self.rawValue, count))
    }

    /// Returns a string representation of the receiver.
    /// This does NOT normalize, so a version number with trailing zero components will have those retained in the output.
    public var description: String {
        return rawValue.map { String($0) }.joined(separator: ".")
    }

    // Produces a `Component` set with the given number of values.
    private static func normalized(_ components: [Component], _ n: Int) -> [Component] {
        var c: [Component] = []
        for i in 0..<n {
            c.append(i < components.count ? components[i] : 0)
        }
        return c
    }
}

public extension Version {
    /// Returns the version in the canonical form used for displaying an OS version deployment target.
    ///
    /// The canonical form is the version with any trailing zeros removed, but padded to at least two version components.
    var canonicalDeploymentTargetForm: Version {
        return zeroTrimmed.zeroPadded(toMinimumNumberOfComponents: 2)
    }
}

extension Version: Hashable {

    public func hash(into hasher: inout Hasher) {
        // The values of 1.0 and 1.0.0 should be considered equivalent, so we need to build up a hash value such that insignificant values can be ignored.
        for c in rawValue.reversed().drop(while: { $0 == 0 }) {
            hasher.combine(c)
        }
    }
}

extension Version: Comparable {
    // Produces a tuple of integer representations of the value normalized to the two different `Version`. This allows the comparison of "1.0" to "1.2.3" in an easier way.
    private static func comparableValue(lhs: Version, rhs: Version) -> ([Component], [Component]) {
        // The two component sizes need to have the same length to be compared properly.

        if lhs.rawValue.count == rhs.rawValue.count {
            return (lhs.rawValue, rhs.rawValue)
        }
        else {
            let n = max(lhs.rawValue.count, rhs.rawValue.count)
            return (Version.normalized(lhs.rawValue, n), normalized(rhs.rawValue, n))
        }
    }

    public static func ==(lhs: Version, rhs: Version) -> Bool {
        let (l, r) = Version.comparableValue(lhs: lhs, rhs: rhs)
        return l == r
    }

    public static func <(lhs: Version, rhs: Version) -> Bool {
        let (l, r) = Version.comparableValue(lhs: lhs, rhs: rhs)
        return l.lexicographicallyPrecedes(r)
    }

    public static func <=(lhs: Version, rhs: Version) -> Bool {
        let (l, r) = Version.comparableValue(lhs: lhs, rhs: rhs)
        return l.lexicographicallyPrecedes(r) || l == r
    }

    public static func >(lhs: Version, rhs: Version) -> Bool {
        let (l, r) = Version.comparableValue(lhs: lhs, rhs: rhs)
        return r.lexicographicallyPrecedes(l)
    }

    public static func >=(lhs: Version, rhs: Version) -> Bool {
        let (l, r) = Version.comparableValue(lhs: lhs, rhs: rhs)
        return r.lexicographicallyPrecedes(l) || l == r
    }
}

/// A closed range of `Version` structs.  Unlike using a `ClosedRange` of versions, this struct supports omitting the lower or upper bound.
public struct VersionRange: Sendable {
    public let fuzzyVersion: FuzzyVersion?
    public let start: Version?
    public let end: Version?

    public init() {
        self.start = nil
        self.end = nil
        self.fuzzyVersion = nil
    }

    public init(start fuzzyVersion: FuzzyVersion) {
        self.start = nil
        self.end = nil
        self.fuzzyVersion = fuzzyVersion
    }

    public init(start: Version) {
        self.start = start
        self.end = nil
        self.fuzzyVersion = nil
    }

    public init(end: Version) {
        self.start = nil
        self.end = end
        self.fuzzyVersion = nil
    }

    public init(start: Version, end: Version) throws {
        // If both start and end are defined, then start must be <= end.
        guard start <= end else { throw StubError.error("version range start must be less than or equal to end, but \(start) greater than \(end) ") }

        self.start = start
        self.end = end
        self.fuzzyVersion = nil
    }

    /// Returns true if `version` falls within the range's `start` and `end` properties (inclusive).
    public func contains(_ version: Version) -> Bool {
        if let fuzzyVersion {
            return fuzzyVersion <= version
        }

        switch (start, end) {
        case (nil, nil):
            return true
        case (.some(let start), nil):
            return start <= version
        case (nil, .some(let end)):
            return version <= end
        case (.some(let start), .some(let end)):
            return start <= version && version <= end
        }
    }
}

public import struct Foundation.OperatingSystemVersion

extension Version {
    public init(_ operatingSystemVersion: OperatingSystemVersion) throws {
        try self.init(ignoringTrailingNegativeComponents: operatingSystemVersion.majorVersion, operatingSystemVersion.minorVersion, operatingSystemVersion.patchVersion)
    }
}

extension Version: Decodable {
    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s: String = try container.decode(String.self)
        self.rawValue = try s.split(separator: ".").map {
            guard let n = UInt($0) else {
                throw Swift.DecodingError.typeMismatch(String.self, DecodingError.Context.init(codingPath: decoder.codingPath, debugDescription: "Expected to decode a valid semver value instead of '\(s)'."))
            }
            return n
        }
    }
}

extension Version: Encodable {
    public func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.map { String($0) }.joined(separator: "."))
    }
}

/// Represents an Apple-style product build version number.
public struct ProductBuildVersion: Hashable, CustomStringConvertible, Sendable {
    public let major: UInt
    public let train: Character
    public let build: UInt
    public let buildSuffix: String

    public init(major: UInt, train: Character, build: UInt, buildSuffix: String = "") {
        self.major = major
        self.train = train
        self.build = build
        self.buildSuffix = buildSuffix
    }

    /// Parses a product build version from its string form, for example, "10A148a" or "10A150".
    public init(_ string: String) throws {
        let error = StubError.error("Unable to parse product build version '\(string)' because the input was in an invalid format.")
        guard let match = try #/(?<major>\d+)(?<minor>\w)(?<build>\d+)(?<suffix>\w*)/#.wholeMatch(in: string) else {
            // We are unable to parse the value.
            throw error
        }
        self.major = UInt(match.output.major)!
        self.train = Character(String(match.output.minor))
        self.build = UInt(match.output.build)!
        self.buildSuffix = String(match.output.suffix)

        // It's a "parse" error to not roundtrip to the same input.
        // This means that a build number like "010A0148A" (leading zeros)
        // is not considered valid.
        if string != description {
            throw error
        }
    }

    public var description: String {
        return "\(major)\(train)\(build)\(buildSuffix)"
    }
}

extension ProductBuildVersion: Comparable {
    public static func < (lhs: ProductBuildVersion, rhs: ProductBuildVersion) -> Bool {
        guard lhs.major == rhs.major else {
            return lhs.major < rhs.major
        }

        guard lhs.train == rhs.train else {
            // This provides a better experience for uses such as:
            //   XCTSkipUnlessXcodeBuildVersion(ProductBuildVersion(major: 11, train: "A", build: 376))
            // e.g. when running with 11E13, this check should pass.
            return lhs.train < rhs.train
        }

        guard lhs.build == rhs.build else {
            return lhs.build < rhs.build
        }

        return lhs.buildSuffix < rhs.buildSuffix
    }
}

extension ProductBuildVersion: Codable {
    public func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }
}

public struct FuzzyVersion: Hashable, CustomStringConvertible, Sendable {
    public typealias Component = UInt
    public typealias RawValue = [Component]

    /// The raw components that make up the version.
    public let rawValue: RawValue

    private let fuzzyComponents: [Bool]

    /// Used to initialize a version which may have one or more "wildcard" components which are ignored for comparison purposes.
    public init(_ s: String) throws {
        let components: [(Component, Bool)] = try s.split(separator: ".").map { c in
            if c == "*" {
                return (0, true)
            }
            guard let r = Component(c) else { throw StubError.error("Could not parse version component from: '\(c)'") }
            return (r, false)
        }

        if components.count <= 0 { throw StubError.error("There are no components to parse: '\(s)'") }
        self.rawValue = components.map { $0.0 }
        self.fuzzyComponents = components.map { $0.1 }
    }

    /// Returns a string representation of the receiver.
    /// This does NOT normalize, so a version number with trailing zero components will have those retained in the output.
    public var description: String {
        return rawValue.enumerated().map { i, v in fuzzyComponents[i] ? "*" : String(v) }.joined(separator: ".")
    }

    public static func ==(fuzzy: FuzzyVersion, normal: Version) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return f == n
    }

    public static func ==(normal: Version, fuzzy: FuzzyVersion) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return n == f
    }

    public static func <(fuzzy: FuzzyVersion, normal: Version) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return f.lexicographicallyPrecedes(n)
    }

    public static func <(normal: Version, fuzzy: FuzzyVersion) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return n.lexicographicallyPrecedes(f)
    }

    public static func <=(fuzzy: FuzzyVersion, normal: Version) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return f.lexicographicallyPrecedes(n) || f == n
    }

    public static func <=(normal: Version, fuzzy: FuzzyVersion) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return n.lexicographicallyPrecedes(f) || n == f
    }

    public static func >(fuzzy: FuzzyVersion, normal: Version) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return n.lexicographicallyPrecedes(f)
    }

    public static func >(normal: Version, fuzzy: FuzzyVersion) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return f.lexicographicallyPrecedes(n)
    }

    public static func >=(fuzzy: FuzzyVersion, normal: Version) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return n.lexicographicallyPrecedes(f) || f == n
    }

    public static func >=(normal: Version, fuzzy: FuzzyVersion) -> Bool {
        let (f, n) = comparableValue(fuzzy: fuzzy, normal: normal)
        return f.lexicographicallyPrecedes(n) || n == f
    }

    private static func comparableValue(fuzzy: FuzzyVersion, normal: Version) -> (fuzzy: [Component], normal: [Component]) {
        let n = max(fuzzy.rawValue.count, normal.rawValue.count)
        var fcomp = [Component]()
        var ncomp = [Component]()
        for i in 0..<n {
            let isFuzzy = i < fuzzy.fuzzyComponents.count ? fuzzy.fuzzyComponents[i] : false
            if !isFuzzy {
                fcomp.append(i < fuzzy.rawValue.count ? fuzzy.rawValue[i] : 0)
                ncomp.append(i < normal.rawValue.count ? normal.rawValue[i] : 0)
            }
        }
        return (fcomp, ncomp)
    }
}

public import class Foundation.ProcessInfo
import SWBLibc

extension ProcessInfo {
    /// The version of the operating system kernel on which the process is running.
    ///
    /// This is distinct from `operatingSystemVersion` in that this property will return the kernel version, which may be different than the user-space operating system version. This can be the case in `chroot`-ed environments, for example where the user-space OS version may be 10.15, while the kernel version is 10.14.
    ///
    /// - note: This is still in terms of *product* version, for example "10.15", NOT a Darwin version like "19.0.0" as returned by `uname -r`.
    public var operatingSystemKernelVersion: Version {
        #if canImport(Darwin)
        let kern_osproductversion = "kern.osproductversion"
        var len: Int = 0
        if sysctlbyname(kern_osproductversion, nil, &len, nil, 0) == 0 {
            var p = [CChar](repeating: 0, count: len)
            if sysctlbyname(kern_osproductversion, &p, &len, nil, 0) == 0 {
                do {
                    return try Version(String(cString: p))
                } catch {
                }
            }
        }
        #endif
        return Version()
    }

    /// Returns a Boolean value indicating whether the version of the operating system kernel on which the process is executing is the same or later than the given version.
    ///
    /// This method accounts for major, minor, and update versions of the operating system kernel.
    ///
    /// See `operatingSystemKernelVersion` for why this is distinct from `isOperatingSystemAtLeast`.
    ///
    /// - parameter version: The operating system kernel version to test against.
    /// - returns: `true` if the operating system kernel on which the process is executing is the same or later than the given version; otherwise `false`.
    /// - note: This is still in terms of *product* version, for example "10.15", NOT a Darwin version like "19.0.0" as returned by `uname -r`.
    public func isOperatingSystemKernelAtLeast(_ version: Version) -> Bool {
        return operatingSystemKernelVersion >= version
    }

    /// Returns the build number of the running operating system.
    public func productBuildVersion() throws -> ProductBuildVersion {
        return try systemVersion().productBuildVersion
    }

    var simulatorRoot: String? {
        environment["SIMULATOR_ROOT"]?.nilIfEmpty
    }

    var systemVersionPlistURL: URL {
        URL(fileURLWithPath: "\(simulatorRoot ?? "")/System/Library/CoreServices/SystemVersion.plist")
    }

    func systemVersion() throws -> SystemVersion {
        #if !canImport(Darwin)
        return SystemVersion(
            productName: ProcessInfo.processInfo.operatingSystemVersionString,
            productBuildVersion: .init(major: 1, train: "A", build: 1)
        )
        #else
        let url = systemVersionPlistURL
        let filePath = try url.filePath
        guard FileManager.default.isReadableFile(atPath: filePath.str) else {
            throw StubError.error("No system version plist at \(filePath.str)")
        }
        let version: SystemVersion
        do {
            version = try PropertyListDecoder().decode(SystemVersion.self, from: Data(contentsOf: url))
        } catch {
            throw StubError.error("Failed to decode contents of '\(filePath.str)': \(error.localizedDescription)")
        }
        return version
        #endif
    }
}

struct SystemVersion: Codable {
    let productName: String
    let productBuildVersion: ProductBuildVersion
    enum CodingKeys: String, CodingKey {
        case productName = "ProductName"
        case productBuildVersion = "ProductBuildVersion"
    }
}
