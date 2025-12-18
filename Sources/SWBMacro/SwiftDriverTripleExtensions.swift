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

import SwiftDriver

/// Compares two triples for equality after normalization, ignoring OS versions.
package func normalizedTriplesCompareDisregardingOSVersions(_ firstTripleString: String, _ secondTripleString: String) -> Bool {
    // Normalize both triples
    let firstTriple = Triple(firstTripleString, normalizing: true)
    let secondTriple = Triple(secondTripleString, normalizing: true)

    // Ignore OS versions in the comparison
    return firstTriple.arch == secondTriple.arch &&
    firstTriple.subArch == secondTriple.subArch &&
    firstTriple.vendor == secondTriple.vendor &&
    firstTriple.os == secondTriple.os &&
    firstTriple.environment == secondTriple.environment &&
    firstTriple.objectFormat == secondTriple.objectFormat
}
