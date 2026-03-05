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

import SWBProtocol

public enum SWBSourceLanguage: Hashable, Sendable {
    case c
    case cpp
    case metal
    case objectiveC
    case objectiveCpp
    case swift

    init?(_ language: SourceLanguage?) {
        guard let language else {
            return nil
        }
        self.init(language)
    }

    init(_ language: SourceLanguage) {
        switch language {
        case .c: self = .c
        case .cpp: self = .cpp
        case .metal: self = .metal
        case .objectiveC: self = .objectiveC
        case .objectiveCpp: self = .objectiveCpp
        case .swift: self = .swift
        }
    }
}
