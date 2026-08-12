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

@Suite(.skipHostOS(.windows, "testing unix path style"))
fileprivate struct PrefixMapperTests {
    private func mapper(_ mappings: (String, String)...) -> PrefixMapper {
        PrefixMapper(mappings: mappings.map { .init(from: Path($0.0), to: Path($0.1)) }).sorted()
    }

    @Test
    func empty() {
        let mapper = PrefixMapper()
        #expect(mapper.isEmpty)
        #expect(mapper.map(Path("/src/main.swift")) == Path("/src/main.swift"))
    }

    @Test
    func mapsPrefixAndSuffix() {
        let mapper = mapper(("/Users/me/proj", "/^src"))
        #expect(mapper.map(Path("/Users/me/proj/Sources/main.swift")) == Path("/^src/Sources/main.swift"))
    }

    @Test
    func mapsExactMatch() {
        let mapper = mapper(("/Users/me/proj", "/^src"))
        #expect(mapper.map(Path("/Users/me/proj")) == Path("/^src"))
    }

    @Test
    func leavesUnrelatedPathsAlone() {
        let mapper = mapper(("/Users/me/proj", "/^src"))
        #expect(mapper.map(Path("/Users/me/other/main.swift")) == Path("/Users/me/other/main.swift"))
    }

    /// `llvm::PrefixMapper` only matches on whole path components, so a mapping for `/tmp` must not
    /// rewrite `/tmp-other`.
    @Test
    func matchesWholeComponentsOnly() {
        let mapper = mapper(("/tmp", "/^tmp"))
        #expect(mapper.map(Path("/tmp-other/main.swift")) == Path("/tmp-other/main.swift"))
        #expect(mapper.map(Path("/tmp/main.swift")) == Path("/^tmp/main.swift"))
    }

    /// Sorting has to prefer the more specific prefix, matching `llvm::PrefixMapper::sort`, regardless
    /// of the order the mappings were added in.
    @Test
    func prefersMoreSpecificPrefix() {
        for mappings in [[("/tmp", "/^tmp"), ("/tmp/inner", "/^inner")], [("/tmp/inner", "/^inner"), ("/tmp", "/^tmp")]] {
            let mapper = PrefixMapper(mappings: mappings.map { .init(from: Path($0.0), to: Path($0.1)) }).sorted()
            #expect(mapper.map(Path("/tmp/inner/main.swift")) == Path("/^inner/main.swift"))
            #expect(mapper.map(Path("/tmp/outer/main.swift")) == Path("/^tmp/outer/main.swift"))
        }
    }

    @Test
    func inverted() {
        let mapper = mapper(("/Users/me/proj", "/^src"), ("/Users/me/build", "/^derived")).inverted()
        #expect(mapper.map(Path("/^src/main.swift")) == Path("/Users/me/proj/main.swift"))
        #expect(mapper.map(Path("/^derived/Objects/main.o")) == Path("/Users/me/build/Objects/main.o"))
        #expect(mapper.map(Path("/^unmapped/x")) == Path("/^unmapped/x"))
    }

    /// Inverting has to re-sort, because the ordering that was right for the forward direction says
    /// nothing about the ordering the inverse needs.
    @Test
    func invertedPrefersMoreSpecificPrefix() {
        let mapper = mapper(("/a", "/^x"), ("/b", "/^x/inner")).inverted()
        #expect(mapper.map(Path("/^x/inner/main.swift")) == Path("/b/main.swift"))
        #expect(mapper.map(Path("/^x/other/main.swift")) == Path("/a/other/main.swift"))
    }
}
