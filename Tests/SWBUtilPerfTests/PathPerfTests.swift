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

import Testing
import SWBTestSupport
import SWBUtil

@Suite(.performance)
fileprivate struct PathPerfTests: PerfTests {
    @Test
    func splitPerf_X100000() async {
        let path = Path("/hello/little/world")
        let N = 100000
        await measure {
            var lengths = 0
            for _ in 0 ..< N {
                let result = path.split()
                lengths = lengths &+ result.0.str.utf8.count &+ 1 &+ result.1.utf8.count
            }
            #expect(lengths == path.str.utf8.count &* N)
        }
    }

    @Test
    func dirnamePerf_X100000() async {
        let path = Path("/hello/little/world")
        let N = 100000
        await measure {
            var lengths = 0
            for _ in 0 ..< N {
                let result = path.dirname
                lengths = lengths &+ result.str.utf8.count
            }
            #expect(lengths == "/hello/little".utf8.count &* N)
        }
    }

    @Test
    func basenamePerf_X100000() async {
        let path = Path("/hello/little/world")
        let N = 100000
        await measure {
            var lengths = 0
            for _ in 0 ..< N {
                let result = path.basename
                lengths = lengths &+ result.utf8.count
            }
            #expect(lengths == "world".utf8.count &* N)
        }
    }

    @Test
    func basenameWithoutSuffixPerf_X100000() async {
        let path = Path("/hello/little/world.ext")
        let N = 100000
        await measure {
            var lengths = 0
            for _ in 0 ..< N {
                let result = path.basenameWithoutSuffix
                lengths = lengths &+ result.utf8.count
            }
            #expect(lengths == "world".utf8.count &* N)
        }
    }

    @Test
    func withoutSuffixPerf_X100000() async {
        let path = Path("/hello/little/world.ext")
        let N = 100000
        await measure {
            var lengths = 0
            for _ in 0 ..< N {
                let result = path.withoutSuffix
                lengths = lengths &+ result.utf8.count
            }
            #expect(lengths == "/hello/little/world".utf8.count &* N)
        }
    }

    @Test
    func fileSuffixPerf_X100000() async {
        let path = Path("/hello/little/world.ext")
        let N = 100000
        await measure {
            var lengths = 0
            for _ in 0 ..< N {
                let result = path.fileSuffix
                lengths = lengths &+ result.utf8.count
            }
            #expect(lengths == ".ext".utf8.count &* N)
        }
    }

    @Test
    func fileExtensionPerf_X100000() async {
        let path = Path("/hello/little/world.ext")
        let N = 100000
        await measure {
            var lengths = 0
            for _ in 0 ..< N {
                let result = path.fileExtension
                lengths = lengths &+ result.utf8.count
            }
            #expect(lengths == "ext".utf8.count &* N)
        }
    }

    @Test
    func normalizePerf_X100000() async {
        let path = Path("/hello/little/../tiny/world")
        let N = 100000
        await measure {
            var lengths = 0
            for _ in 0 ..< N {
                let result = path.normalize()
                lengths = lengths &+ result.str.utf8.count
            }
            #expect(lengths == "/hello/tiny/world".utf8.count &* N)
        }
    }

    @Test
    func joinPerf_X100000() async {
        let path = Path("/hello/little")
        let path2 = Path("world")
        let N = 100000
        await measure {
            var lengths = 0
            for _ in 0 ..< N {
                let result = path.join(path2)
                lengths = lengths &+ result.str.utf8.count
            }
            #expect(lengths == (path.str.utf8.count + 1 + path2.str.utf8.count) &* N)
        }
    }
}
