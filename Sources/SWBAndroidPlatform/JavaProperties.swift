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
internal import SWBUtil

/// A simple representation of a Java properties file.
///
/// See `java.util.Properties` for a description of the file format. This parser is a simplified version that doesn't handle line continuations, etc., because our use case is narrow.
struct JavaProperties {
    private let properties: [String: String]

    init(data: Data) throws {
        properties = Dictionary(
            uniqueKeysWithValues: String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isNewline }).map(String.init).map {
                let (key, value) = $0.split("=")
                return (key.trimmingCharacters(in: .whitespaces), value.trimmingCharacters(in: .whitespaces))
            }
        )
    }

    subscript(_ propertyName: String) -> String? {
        properties[propertyName]
    }
}
