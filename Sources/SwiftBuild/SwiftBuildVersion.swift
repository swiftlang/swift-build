//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SWBUtil

import Foundation

public func SwiftBuildGetVersion() throws -> String {
    final class C { }
    return try ((Bundle(for: C.self).infoDictionary?["CFBundleVersion"] as? String).map { try Version($0) } ?? Version()).description
}
