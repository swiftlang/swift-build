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

/// Protocol description any type which can be represented in the PIF.
public protocol IDEPIFGenerating {

    /// The PIF global ID for the receiver, which will be unique within the top-level object of the PIF.
    var PIFGUID: IDEPIFGUID? { get }

    /// Returns the PIF representation - dictionary, string, integer, boolean - for the receiver, or nil if the receiver does not have a meaningful PIF representation. If nil is returned, that effectively means the receiver will be skipped in PIF generation.
    func pifRepresentation(serializer: any IDEPIFSerializer) -> Any?

}
