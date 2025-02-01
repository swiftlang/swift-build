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

import SWBLibc
import Testing

// FIXME: Get a real random number generator.
private struct RandomNumberGenerator: Swift.RandomNumberGenerator {
    private var generator = SystemRandomNumberGenerator()

    /// Return a random number in the range 0 ... UInt64.max.
    mutating func next() -> UInt64 {
        return generator.next()
    }

    /// Return a random number in the range 0 ..< upperBound.
    mutating func uniform(lessThan upperBound: Int) -> Int {
        assert(upperBound < Int(UInt32.max), "FIXME: Unsupported")
        return Int(generator.next(upperBound: UInt32(upperBound)))
    }

    /// Return a random number over the range 0.0 ..< 1.0.
    mutating func probability() -> Double {
        var n = next()
        while true {
            n = next()
            if n != UInt64.max {
                return Double(next()) / Double(UInt64.max)
            }
        }
    }

    /// Select from among a set of weighted choices; the result is the index of the selection.
    mutating func select(from weights: [Int]) -> Int {
        // Pick a uniform N less than the sum.
        let sum = weights.reduce(0, +)
        var n = uniform(lessThan: sum)
        for (i,value) in weights.enumerated() {
            if n < value {
                return i
            }
            n -= value
        }
        fatalError("unreachable")
    }

    /// Split an input into N random pieces.
    mutating func split<T>(into n: Int, piecesOf input: [T]) -> [[T]] {
        // FIXME: This is not efficient.
        var results = (0 ..< n).map{ _ in [T]() }
        for item in input {
            results[uniform(lessThan: n)].append(item)
        }
        return results
    }
}

/// Generate a random test workspace.
package final class RandomWorkspaceBuilder {
    private var rng = RandomNumberGenerator()

    /// The total number of projects to generate.
    package var numProjects: Int = 1

    /// The total number of targets to generate, these will be random divided amongst the projects.
    package var numTargets: Int = 0

    /// The total number of files to generate, these will be randomly divided amongst the targets.
    package var numFiles: Int = 0

    package init() {
    }

    /// Generate a random workspace with the current parameters.
    package func generate() -> TestWorkspace {
        // Create all of the input files.
        let files = (0 ..< numFiles).map{ i -> TestFile in
            // FIXME: Pick a random file extension.
            let ext = "c"
            return TestFile("File-\(i).\(ext)")
        }

        // Create the targets, with files randomly divided.
        let targets = rng.split(into: numTargets, piecesOf: files).enumerated().map{ (entry) -> TestStandardTarget in
            let (i, files) = entry
            // FIXME: Pick type randomly.
            return TestStandardTarget("Target-\(i)", type: .staticLibrary, buildPhases: [
                    // FIXME: Pick phases randomly.
                    TestSourcesBuildPhase(files.map{ TestBuildFile($0.name) })
                ])
        }

        // FIXME: Create the random projects.
        assert(numProjects == 1, "FIXME: Unsupported")
        let project = TestProject("Project-0",
            groupTree: TestGroup("Sources", children: files),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)"]),
            ],
            targets: targets)

        return TestWorkspace("Random", sourceRoot: project.sourceRoot, projects: [project])
    }
}

@available(*, unavailable)
extension RandomWorkspaceBuilder: Sendable { }
