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

/// A unique identifier for a PIF object.  It doesn't have to be unique globally; just within the workspace.
public class IDEPIFGUID : CustomStringConvertible {

    /// Immutable string containing the string representation; right now, this is the only representation we carry.
    public let stringRepresentation: String

    /// Cached hash value, so it doesn't have to be rediscovered every time.  This is particularly useful since PIF GUIDs tend to be keys in sets and dictionaries a lot.
    private let hash: Int

    /// Initializes a GUID from the given string representation (which is usually, but not necessarily, the hexadecimal representation of a sequence of bytes).
    public init(stringRepresentation: String) {
        self.stringRepresentation = stringRepresentation
        self.hash = stringRepresentation.hashValue
    }

    /// Appends \p string to the receiver's string and returns a new GUID using the combined value.
    public func pifGuidByCombining(with string: String) -> IDEPIFGUID {
        return IDEPIFGUID(stringRepresentation: stringRepresentation + string)
    }

    public var description: String {
        return "\(type(of: self)):\(self):\(stringRepresentation)"
    }
}
