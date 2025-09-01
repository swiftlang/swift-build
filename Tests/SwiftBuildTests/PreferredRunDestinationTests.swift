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
import SwiftBuild
import SwiftBuildTestSupport
import SWBTestSupport
@_spi(Testing) import SWBUtil

@Suite
fileprivate struct PreferredRunDestinationTests {
    @Test(.requireSDKs(.macOS), .temporaryDirectory, .asyncDeferrable)
    func platformExists() async throws {
        let testSession = try await TestSWBSession(temporaryDirectory: TemporaryDirectoryTrait.temporaryDirectory)
        try await AsyncDeferrableTrait.defer {
            try await testSession.close()
        }
        let runDestination = try await testSession.session.preferredRunDestination(forPlatform: "macosx")
        #expect(runDestination.sdk == "macosx")
    }

    @Test(.temporaryDirectory, .asyncDeferrable)
    func unknownPlatform() async throws {
        let testSession = try await TestSWBSession(temporaryDirectory: TemporaryDirectoryTrait.temporaryDirectory)
        try await AsyncDeferrableTrait.defer {
            try await testSession.close()
        }
        await #expect(throws: (any Error).self) {
            try await testSession.session.preferredRunDestination(forPlatform: "unknown_platform")
        }
    }
}

struct TemporaryDirectoryTrait: TestTrait {
    @TaskLocal private static var _temporaryDirectory: NamedTemporaryDirectory?

    static var temporaryDirectory: NamedTemporaryDirectory {
        get throws {
            guard let _temporaryDirectory else {
                throw StubError.error("Accessing temporary directory in test that doesn't specify .temporaryDirectory trait")
            }
            return _temporaryDirectory
        }
    }

    package init() {}

    struct TestScopeProvider: TestScoping {
        func provideScope(
            for test: Test,
            testCase: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            try await withTemporaryDirectory { temporaryDirectory in
                try await $_temporaryDirectory.withValue(temporaryDirectory) {
                    try await function()
                }
            }
        }
    }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> TestScopeProvider? {
        guard testCase != nil else {
            // We only need to set up a new temporary directory for the execution of a parameterized version of the test.
            return nil
        }
        return TestScopeProvider()
    }
}

extension Trait where Self == TemporaryDirectoryTrait {
    static var temporaryDirectory: TemporaryDirectoryTrait {
        return TemporaryDirectoryTrait()
    }
}

struct AsyncDeferrableTrait: TestTrait {
    @TaskLocal private static var _deferrable: Deferrable?

    static var deferrable: Deferrable {
        get throws {
            guard let _deferrable else {
                throw StubError.error("Accessing temporary directory in test that doesn't specify .asyncDeferrable trait")
            }
            return _deferrable
        }
    }

    static func `defer`(sourceLocation: SourceLocation = #_sourceLocation, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await deferrable.addBlock {
            await #expect(throws: Never.self, sourceLocation: sourceLocation) {
                try await body()
            }
        }
    }

    package init() {}

    struct TestScopeProvider: TestScoping {
        func provideScope(
            for test: Test,
            testCase: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            try await withAsyncDeferrable { deferrable in
                try await $_deferrable.withValue(deferrable) {
                    try await function()
                }
            }
        }
    }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> TestScopeProvider? {
        guard testCase != nil else {
            // We only need to set up a deferrable for the execution of a parameterized version of the test.
            return nil
        }
        return TestScopeProvider()
    }
}

extension Trait where Self == AsyncDeferrableTrait {
    static var asyncDeferrable: AsyncDeferrableTrait {
        return AsyncDeferrableTrait()
    }
}
