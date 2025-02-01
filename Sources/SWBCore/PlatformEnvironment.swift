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

extension UserInfo {
    public func addingPlatformDefaults(from env: [String: String]) async throws -> Self {
        var userInfo = self
        for (key, value) in env {
            userInfo.buildSystemEnvironment.setValueIfNeeded(value, forKey: key)
            userInfo.processEnvironment.setValueIfNeeded(value, forKey: key)
        }
        return userInfo
    }
}

fileprivate extension Dictionary where Key == String, Value == String {
    mutating func setValueIfNeeded(_ value: String, forKey key: String) {
        if !contains(key) {
            self[key] = value
        }
    }
}
