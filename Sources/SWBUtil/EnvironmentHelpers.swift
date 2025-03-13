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

@TaskLocal fileprivate var processEnvironment = Environment.current

/// Binds the internal defaults to the specified `environment` for the duration of the synchronous `operation`.
/// - parameter clean: `true` to start with a clean environment, `false` to merge the input environment over the existing process environment.
/// - note: This is implemented via task-local values.
@_spi(Testing) public func withEnvironment<R>(_ environment: Environment, clean: Bool = false, operation: () throws -> R) rethrows -> R {
    try $processEnvironment.withValue(clean ? environment : processEnvironment.addingContents(of: environment), operation: operation)
}

/// Binds the internal defaults to the specified `environment` for the duration of the asynchronous `operation`.
/// - parameter clean: `true` to start with a clean environment, `false` to merge the input environment over the existing process environment.
/// - note: This is implemented via task-local values.
@_spi(Testing) public func withEnvironment<R>(_ environment: Environment, clean: Bool = false, operation: () async throws -> R) async rethrows -> R {
    try await $processEnvironment.withValue(clean ? environment : processEnvironment.addingContents(of: environment), operation: operation)
}

/// Gets the value of the named variable from the process' environment.
/// - parameter name: The name of the environment variable.
/// - returns: The value of the variable as a `String`, or `nil` if it is not defined in the environment.
public func getEnvironmentVariable(_ name: EnvironmentKey) -> String? {
    processEnvironment[name]
}
