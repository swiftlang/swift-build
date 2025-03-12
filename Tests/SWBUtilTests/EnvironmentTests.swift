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

import SWBUtil
import Foundation
import Testing

@Suite fileprivate struct EnvironmentTests {
    let isCaseInsensitive: Bool

    init() throws {
        isCaseInsensitive = try ProcessInfo.processInfo.hostOperatingSystem() == .windows
    }

    @Test func empty() {
        let environment = Environment()
        #expect(environment.isEmpty)
    }

    @Test func `subscript`() {
        var environment = Environment()
        let key = EnvironmentKey("TestKey")
        environment[key] = "TestValue"
        #expect(environment[key] == "TestValue")
    }

    @Test func initDictionaryFromSelf() {
        let dictionary = [
            "TestKey": "TestValue",
            "testKey": "TestValue2",
        ]
        let environment = Environment(dictionary)

        if isCaseInsensitive {
            #expect(environment["TestKey"] == "TestValue2") // uppercase sorts before lowercase, so the second value overwrites the first
            #expect(environment.count == 1)
        } else {
            #expect(environment["TestKey"] == "TestValue")
            #expect(environment.count == 2)
        }
    }

    @Test func initSelfFromDictionary() {
        let dictionary = ["TestKey": "TestValue"]
        let environment = Environment(dictionary)
        #expect(environment["TestKey"] == "TestValue")
    }

    func path(_ components: String...) -> String {
        components.joined(separator: String(Path.pathEnvironmentSeparator))
    }

    @Test func prependPath() {
        var environment = Environment()
        let key = EnvironmentKey(UUID().uuidString)
        #expect(environment[key] == nil)

        environment.prependPath(key: key, value: "/bin")
        #expect(environment[key] == path("/bin"))

        environment.prependPath(key: key, value: "/usr/bin")
        #expect(environment[key] == path("/usr/bin", "/bin"))

        environment.prependPath(key: key, value: "/usr/local/bin")
        #expect(environment[key] == path("/usr/local/bin", "/usr/bin", "/bin"))

        environment.prependPath(key: key, value: "")
        #expect(environment[key] == path("/usr/local/bin", "/usr/bin", "/bin"))
    }

    @Test func appendPath() {
        var environment = Environment()
        let key = EnvironmentKey(UUID().uuidString)
        #expect(environment[key] == nil)

        environment.appendPath(key: key, value: "/bin")
        #expect(environment[key] == path("/bin"))

        environment.appendPath(key: key, value: "/usr/bin")
        #expect(environment[key] == path("/bin", "/usr/bin"))

        environment.appendPath(key: key, value: "/usr/local/bin")
        #expect(environment[key] == path("/bin", "/usr/bin", "/usr/local/bin"))

        environment.appendPath(key: key, value: "")
        #expect(environment[key] == path("/bin", "/usr/bin", "/usr/local/bin"))
    }

    @Test func collection() {
        let environment: Environment = ["TestKey": "TestValue"]
        #expect(environment.count == 1)
        #expect(environment.first?.key == EnvironmentKey("TestKey"))
        #expect(environment.first?.value == "TestValue")
    }

    @Test func description() {
        var environment = Environment()
        environment[EnvironmentKey("TestKey")] = "TestValue"
        #expect(environment.description == #"["TestKey=TestValue"]"#)
    }

    @Test func encodable() throws {
        var environment = Environment()
        environment["TestKey"] = "TestValue"
        let data = try JSONEncoder().encode(environment)
        let jsonString = String(decoding: data, as: UTF8.self)
        #expect(jsonString == #"{"TestKey":"TestValue"}"#)
    }

    @Test func equatable() {
        let environment0: Environment = ["TestKey": "TestValue"]
        let environment1: Environment = ["TestKey": "TestValue"]
        #expect(environment0 == environment1)

        if isCaseInsensitive {
            // Test case insensitivity on windows
            let environment2: Environment = ["testKey": "TestValue"]
            #expect(environment0 == environment2)
        }
    }

    @Test func expressibleByDictionaryLiteral() {
        let environment: Environment = ["TestKey": "TestValue"]
        #expect(environment["TestKey"] == "TestValue")
    }

    @Test func decodable() throws {
        let jsonString = #"{"TestKey":"TestValue"}"#
        let data = Data(jsonString.utf8)
        let environment = try JSONDecoder().decode(Environment.self, from: data)
        #expect(environment[EnvironmentKey("TestKey")] == "TestValue")
    }
}
