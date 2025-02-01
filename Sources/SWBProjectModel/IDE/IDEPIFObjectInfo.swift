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

/// A wrapper describing a PIF object via its signature and the means to generate it.  We use this API so that clients which *must* generate the PIF in order to be able to create the signature can provide the signature and PIF together, without requiring this.
public class IDEPIFObjectInfo {
    public typealias PIFGeneratingClosure = (any IDEPIFSerializer) -> [String: Any]
    /// The signature of the PIF (a sort of digest that indicates whether the PIF needs to be regenerated).
    public internal(set) var signature: String

    /// A block to construct PIF and return the PIF data for the object.  Clients are expected to cache this result if necessary.
    public internal(set) var generatePIF: PIFGeneratingClosure

    /// Initializes the IDEPIFObjectInfo with a \p signature (a sort of digest that indicates whether the PIF needs to be regenerated) and a PIF generation \p block that will be invoked if it does.  The generator block might not be invoked if the signature is the same as in a previous invocation.
    public init(signature: String,
                generatePIF: @escaping PIFGeneratingClosure) {
        self.signature = signature
        self.generatePIF = generatePIF
    }
}
