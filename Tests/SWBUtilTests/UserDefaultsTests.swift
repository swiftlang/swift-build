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
@_spi(Testing) import SWBUtil
import Testing

/// Test methods in `UserDefaults` used to interpret the value of individual defaults.
///
/// The `UserDefaults` instance has process lifetime user defaults are set in the environment of the test plan to be used as defaults (which is how Xcode passes them to Swift Build).
@Suite fileprivate struct UserDefaultsTests {
    /// Test that a boolean set in the environment as a string is properly interpreted.
    @Test
    func boolCheck() throws {
        let keyName = "SWBUtilTests_UserDefaultsTests_StringBool"
        UserDefaults.withEnvironment([keyName: "YES"]) {
            #expect(UserDefaults.bool(forKey: keyName))
        }
    }

    /// Test that an environment variable set as a string is interpreted as a string.
    @Test
    func string() throws {
        let keyName = "SWBUtilTests_UserDefaultsTests_Path"
        UserDefaults.withEnvironment([keyName: "/tmp/directory"]) {
            #expect(UserDefaults.string(forKey: keyName) == "/tmp/directory")
        }
    }

    /// Test that an environment variable set as a string is interpreted as a string array.
    @Test
    func stringAsStringArray() throws {
        let keyName = "SWBUtilTests_UserDefaultsTests_Path"
        UserDefaults.withEnvironment([keyName: "/tmp/directory"]) {
            #expect(UserDefaults.stringArray(forKey: keyName) == ["/tmp/directory"])
        }
    }

    // There is presently no way to pass user defaults via the environment as arrays (c.f. UserDefaults.internalDefaults), so we can't test that UserDefaults.stringArray() returns the expected value if the set value is an array.
}
