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
import Testing
import SWBUtil
import SWBTestSupport

@Suite fileprivate struct VersionTests {
    func checkEq(_ a: Version, _ b: Version) {
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    func checkNotEq(_ a: Version, _ b: Version) {
        #expect(a != b)
        #expect(a.hashValue != b.hashValue)
    }

    @Test
    func version3() throws {
        try checkEq(Version(1, 2, 3), Version("1.2.3"))
        try checkEq(Version(1, 2, 0), Version("1.2"))
        try checkEq(Version(1, 0, 0), Version("1"))

        #expect(throws: (any Error).self) {
            try Version("")
        }
        #expect(throws: (any Error).self) {
            try Version("a")
        }
        #expect(throws: (any Error).self) {
            try Version("1.2c.3")
        }
        #expect(throws: (any Error).self) {
            try Version("1. .3")
        }
        #expect(throws: (any Error).self) {
            try Version("1.2.-3")
        }
        #expect(throws: (any Error).self) {
            try Version("1.2.3.4", maximumNumberOfComponents: 3)
        }
        let _ = try Version("1.2.3", maximumNumberOfComponents: 3)

        #expect(Version(1, 0, 0) > Version(0, 0, 0))
        #expect(Version(1, 1, 0) > Version(1, 0, 0))
        #expect(Version(1, 1, 1) > Version(1, 1, 0))
        #expect(Version(11, 0, 0) > Version(2, 0, 0))

        #expect(Version(1, 0, 0) >= Version(0, 0, 0))
        #expect(Version(1, 1, 0) >= Version(1, 0, 0))
        #expect(Version(1, 1, 1) >= Version(1, 1, 0))
        #expect(Version(11, 0, 0) >= Version(2, 0, 0))

        #expect(!(Version(1, 0, 0) > Version(1, 0, 0)))
        #expect(Version(1, 0, 0) >= Version(1, 0, 0))

        #expect(Version(0, 0, 0) < Version(1, 0, 0))
        #expect(Version(1, 0, 0) < Version(1, 1, 0))
        #expect(Version(1, 1, 0) < Version(1, 1, 1))
        #expect(Version(2, 0, 0) < Version(11, 0, 0))

        #expect(Version(0, 0, 0) <= Version(1, 0, 0))
        #expect(Version(1, 0, 0) <= Version(1, 1, 0))
        #expect(Version(1, 1, 0) <= Version(1, 1, 1))
        #expect(Version(2, 0, 0) <= Version(11, 0, 0))

        #expect(!(Version(1, 0, 0) < Version(1, 0, 0)))
        #expect(Version(1, 0, 0) <= Version(1, 0, 0))
    }

    @Test
    func version4() throws {
        try checkEq(Version(1, 2, 3, 4), Version("1.2.3.4"))
        try checkEq(Version(1, 2, 3, 0), Version("1.2.3"))
        try checkEq(Version(1, 2, 0, 0), Version("1.2"))
        try checkEq(Version(1, 0, 0, 0), Version("1"))

        #expect(throws: (any Error).self) {
            try Version("")
        }
        #expect(throws: (any Error).self) {
            try Version("a")
        }
        #expect(throws: (any Error).self) {
            try Version("1.2c.3")
        }
        #expect(throws: (any Error).self) {
            try Version("1.2.-3")
        }
        #expect(throws: (any Error).self) {
            try Version("1.2.3.4.5", maximumNumberOfComponents: 4)
        }

        #expect(Version(1, 0, 0, 0) > Version(0, 0, 0, 0))
        #expect(Version(1, 1, 0, 0) > Version(1, 0, 0, 0))
        #expect(Version(1, 1, 1, 1) > Version(1, 1, 1, 0))
        #expect(Version(11, 0, 0, 0) > Version(2, 0, 0, 0))

        #expect(Version(1, 0, 0, 0) > Version(0, 0, 0, 0))
        #expect(Version(1, 1, 0, 0) > Version(1, 0, 0, 0))
        #expect(Version(1, 1, 1, 1) > Version(1, 1, 1, 0))
        #expect(Version(11, 0, 0, 0) > Version(2, 0, 0, 0))

        #expect(!(Version(1, 0, 0, 0) > Version(1, 0, 0, 0)))
        #expect(Version(1, 0, 0, 0) >= Version(1, 0, 0, 0))

        #expect(Version(0, 0, 0, 0) < Version(1, 0, 0, 0))
        #expect(Version(1, 0, 0, 0) < Version(1, 1, 0, 0))
        #expect(Version(1, 1, 0, 44) < Version(1, 1, 4, 0))
        #expect(Version(2, 0, 0, 0) < Version(11, 0, 0, 0))

        #expect(Version(0, 0, 0, 0) <= Version(1, 0, 0, 0))
        #expect(Version(1, 0, 0, 0) <= Version(1, 1, 0, 0))
        #expect(Version(1, 1, 0, 0) <= Version(1, 1, 1, 0))
        #expect(Version(2, 0, 0, 0) <= Version(11, 0, 0, 0))

        #expect(!(Version(1, 0, 0, 0) < Version(1, 0, 0, 0)))
        #expect(Version(1, 0, 0, 0) <= Version(1, 0, 0, 0))
    }

    @Test
    func hashValue() throws {
        #expect(Version(1).hashValue == Version(1, 0, 0).hashValue)
        #expect(try Version(2, 0, 1).hashValue == Version("2.0.1").hashValue)
        #expect(try Version(0, 1, 0).hashValue == Version("0.1.0.0").hashValue)
        #expect(try Version(12, 145, 878).hashValue == Version("12.145.878.0").hashValue)

        #expect(try Version(1, 0, 1).hashValue != Version("1.0.1.1").hashValue)
        #expect(try Version(0, 0, 1).hashValue != Version("0.0.1.1").hashValue)
        #expect(try Version(0, 1, 0, 1).hashValue != Version("1.0.1.0").hashValue)
        #expect(try Version(1, 0, 1, 1).hashValue != Version("1.1.1.0").hashValue)
        #expect(try Version(0, 12, 145, 878).hashValue != Version("12.145.878").hashValue)
    }

    @Test
    func description() throws {
        #expect(Version(1, 0, 1).description == "1.0.1")
        #expect(Version(1, 0, 0, 0).description == "1.0.0.0")
        #expect(Version(0).description == "0")
    }

    @Test
    func versionRange() throws {
        let versionSimple = Version(10, 0, 0)
        let versionComplex = Version(10, 4, 5)

        #expect(VersionRange(start: Version(1, 0, 0)).contains(versionSimple))
        #expect(!VersionRange(end: Version(1, 0, 0)).contains(versionSimple))
        #expect(!VersionRange(start: Version(11, 0, 0)).contains(versionSimple))
        #expect(VersionRange(end: Version(11, 0, 0)).contains(versionSimple))
        #expect(try VersionRange(start: Version(1, 0, 0), end: Version(11, 0, 0)).contains(versionSimple))
        #expect(try VersionRange(start: Version(10, 0, 0), end: Version(11, 0, 0)).contains(versionSimple))
        #expect(try VersionRange(start: Version(1, 0, 0), end: Version(10, 0, 0)).contains(versionSimple))

        #expect(VersionRange(start: versionComplex).contains(versionComplex))
        #expect(VersionRange(end: versionComplex).contains(versionComplex))
        #expect(try VersionRange(start: Version(10, 4, 5), end: Version(10, 4, 5)).contains(versionComplex))
        #expect(try VersionRange(start: Version(1, 0, 0), end: Version(10, 4, 5)).contains(versionComplex))
        #expect(try VersionRange(start: Version(10, 4, 5), end: Version(11, 0, 0)).contains(versionComplex))

        #expect(try !VersionRange(start: Version(1, 0, 0), end: Version(10, 0, 0)).contains(versionComplex))
        #expect(try !VersionRange(start: Version(11, 0, 0), end: Version(20, 0, 0)).contains(versionComplex))

        #expect(VersionRange().contains(versionComplex))

        #expect(throws: (any Error).self) {
            try VersionRange(start: Version(11, 0, 0), end: Version(1, 0, 0))
        }
    }

    @Test
    func zeroTrimmed() throws {
        let emptyVersion = Version().zeroTrimmed
        #expect(emptyVersion.description == "")

        let versionAllZeroes = Version(0, 0, 0, 0).zeroTrimmed
        #expect(versionAllZeroes.description == "0")

        let versionAllNonZeros = Version(1, 3, 4).zeroTrimmed
        #expect(versionAllNonZeros.description == "1.3.4")

        let versionTrailingZero = Version(1, 3, 4, 0, 0)
        #expect(versionTrailingZero.description == "1.3.4.0.0")

        let versionTrailingZeroTrimmed = versionTrailingZero.zeroTrimmed
        #expect(versionTrailingZeroTrimmed.description == "1.3.4")
    }

    @Test
    func zeroPadded() throws {
        let emptyVersion = Version()
        #expect(emptyVersion.zeroPadded(toMinimumNumberOfComponents: 0).description == "")
        #expect(emptyVersion.zeroPadded(toMinimumNumberOfComponents: 1).description == "0")
        #expect(emptyVersion.zeroPadded(toMinimumNumberOfComponents: 2).description == "0.0")
        #expect(emptyVersion.zeroPadded(toMinimumNumberOfComponents: 3).description == "0.0.0")

        let normalVersion = Version(1, 3, 4)
        #expect(normalVersion.zeroPadded(toMinimumNumberOfComponents: 2) == normalVersion)
        #expect(normalVersion.zeroPadded(toMinimumNumberOfComponents: 3) == normalVersion)
        #expect(normalVersion.zeroPadded(toMinimumNumberOfComponents: 4) == Version(1, 3, 4, 0))
        #expect(normalVersion.zeroPadded(toMinimumNumberOfComponents: 5) == Version(1, 3, 4, 0, 0))

        let versionTrailingZero = Version(1, 3, 4, 0, 0)
        #expect(versionTrailingZero.zeroPadded(toMinimumNumberOfComponents: 3) == versionTrailingZero)
        #expect(versionTrailingZero.zeroPadded(toMinimumNumberOfComponents: 4) == versionTrailingZero)
        #expect(versionTrailingZero.zeroPadded(toMinimumNumberOfComponents: 5) == versionTrailingZero)
        #expect(versionTrailingZero.zeroPadded(toMinimumNumberOfComponents: 6) == Version(1, 3, 4, 0, 0, 0))
    }

    @Test
    func subscripting() {
        let emptyVersion = Version()
        #expect(emptyVersion[0] == 0)
        #expect(emptyVersion[1] == 0)
        #expect(emptyVersion[2] == 0)
        #expect(emptyVersion[3] == 0)

        let normalVersion = Version(1, 3, 4)
        #expect(normalVersion[0] == 1)
        #expect(normalVersion[1] == 3)
        #expect(normalVersion[2] == 4)
        #expect(normalVersion[3] == 0)
    }

    @Test
    func signedComponents() throws {
        #expect(try Version(ignoringTrailingNegativeComponents: -1, -1) == Version())
        #expect(try Version(ignoringTrailingNegativeComponents: 1, 2, 3) == Version(1, 2, 3))
        #expect(try Version(ignoringTrailingNegativeComponents: 1, 2, 3, -1) == Version(1, 2, 3))
        #expect(try Version(ignoringTrailingNegativeComponents: 1, 2, 3, -1, -1) == Version(1, 2, 3))

        #expect(throws: (any Error).self) {
            try Version(ignoringTrailingNegativeComponents: 1, -1, 3)
        }
        #expect(throws: (any Error).self) {
            try Version(ignoringTrailingNegativeComponents: -1, 0)
        }
    }

    @Test
    func hashableConformance() {
        checkEq(Version(1), Version(1, 0, 0, 0, 0))
        checkEq(Version(1, 0, 0), Version(1, 0))
        checkEq(Version(1, 0, 1), Version(1, 0, 1))
        checkEq(Version(0, 0, 1), Version(0, 0, 1))

        checkNotEq(Version(1, 0, 0), Version(0, 0, 1))
        checkNotEq(Version(2, 1, 0), Version(2, 0, 1))
    }

    @Test
    func operatingSystemVersion() throws {
        #expect(try Version(OperatingSystemVersion(majorVersion: 10, minorVersion: 12, patchVersion: 3)) == Version(10, 12, 3))
        #expect(try Version(OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)) == Version(12, 0, 0))
        #expect(throws: (any Error).self) {
            try Version(OperatingSystemVersion(majorVersion: -1, minorVersion: 0, patchVersion: 0))
        }
        #expect(throws: (any Error).self) {
            try Version(OperatingSystemVersion(majorVersion: 10, minorVersion: -1, patchVersion: 0))
        }
    }

    @Test(.requireHostOS(.macOS)) // swift-foundation has "Unsupported until __PlistDictionaryDecoder is available", which seems to apply only to top-level dictionaries (but not arrays)
    func decodable() throws {
        func checkError(_ error: any Error) -> Bool {
            switch error {
            case let DecodingError.typeMismatch(_, context):
                return "Expected to decode a valid semver value instead of \'15a.wer\'." == context.debugDescription
            default:
                Issue.record("Unexpected error: \(error)")
                return false
            }
        }

        let decoder = PropertyListDecoder()
        #expect(try decoder.decode(Version.self, from: "15".data(using: .utf8)!) == Version("15"))
        #expect(try decoder.decode(Version.self, from: "15.2.1".data(using: .utf8)!) == Version("15.2.1"))

        #expect("Version should have thrown an error decoding.", performing: {
            try decoder.decode(Version.self, from: "15a.wer".data(using: .utf8)!)
        }, throws: { error in
            checkError(error)
        })
    }

    @Test
    func fuzzyVersion() throws {
        let fuzzy = try FuzzyVersion("1100.*.2.1")

        #expect(fuzzy.description == "1100.*.2.1")

        #expect(fuzzy == Version(1100, 0, 2, 1))
        #expect(fuzzy == Version(1100, 2, 2, 1))

        #expect(!(fuzzy == Version(1100, 0, 2, 0)))
        #expect(!(fuzzy == Version(1100, 0, 0, 1)))

        #expect(fuzzy <= Version(1100, 0, 2, 1))
        #expect(fuzzy <= Version(1100, 2, 2, 1))
        #expect(fuzzy <= Version(1100, 0, 3))
        #expect(fuzzy <= Version(1100, 2, 3))

        #expect(!(fuzzy <= Version(1100)))

        #expect(fuzzy > Version(1100, 0, 0, 1))
        #expect(fuzzy > Version(1100, 2, 2, 0))

        #expect(Version(1100, 0, 0, 1) <= fuzzy)
        #expect(Version(1100, 2, 2, 0) <= fuzzy)
    }

    @Test
    func fuzzyVersionRange() throws {
        let range = try VersionRange(start: FuzzyVersion("1100.*.2.1"))

        #expect(range.contains(Version(1100, 0, 2, 1)))
        #expect(range.contains(Version(1100, 2, 2, 1)))
        #expect(range.contains(Version(1100, 0, 3)))
        #expect(range.contains(Version(1100, 2, 3)))

        #expect(!range.contains(Version(1100)))

        #expect(!range.contains(Version(1100, 0, 0, 1)))
        #expect(!range.contains(Version(1100, 2, 2, 0)))

        #expect(!range.contains(Version(1100, 0, 0, 1)))
        #expect(!range.contains(Version(1100, 2, 2, 0)))
    }

    @Test(.requireHostOS(.macOS))
    func kernelVersion() throws {
        let userSpaceVersion = try Version(ProcessInfo.processInfo.operatingSystemVersion)
        let kernelVersion = ProcessInfo.processInfo.operatingSystemKernelVersion
        if try ProcessInfo.processInfo.hostOperatingSystem().isSimulator {
            // on simulators, kernelVersion will be the macOS product version, not the iOS product version
            #expect(userSpaceVersion == kernelVersion)
        }

        #expect(ProcessInfo.processInfo.isOperatingSystemKernelAtLeast(Version(10, 14, 0)))

        #expect(!ProcessInfo.processInfo.isOperatingSystemKernelAtLeast(Version(99, 0, 0)))
    }
}
