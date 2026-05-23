//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing
@_spi(Testing) import SWBTaskExecution

@Suite
struct MakefileDependencyParserTests {

    @Test
    func singleLineDependencies() {
        let contents = "/path/to/output.o : /path/to/input.swift /path/to/Module.swiftmodule\n"
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result == ["/path/to/input.swift", "/path/to/Module.swiftmodule"])
    }

    @Test
    func continuationLines() {
        let contents = """
            /path/to/output.o : \\
              /path/to/input1.swift \\
              /path/to/input2.swift \\
              /path/to/Module.swiftmodule
            """
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result == ["/path/to/input1.swift", "/path/to/input2.swift", "/path/to/Module.swiftmodule"])
    }

    @Test
    func escapedSpacesInPaths() {
        let contents = "/path/to/output.o : /path/to/My\\ Project/input.swift /other/path.swift\n"
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result == ["/path/to/My Project/input.swift", "/other/path.swift"])
    }

    @Test
    func continuationLinesWithEscapedSpaces() {
        let contents = """
            /path/to/output.o : \\
              /Users/me/My\\ Project/file1.swift \\
              /Users/me/My\\ Project/file2.swift \\
              /path/to/Module.swiftmodule
            """
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result == [
            "/Users/me/My Project/file1.swift",
            "/Users/me/My Project/file2.swift",
            "/path/to/Module.swiftmodule"
        ])
    }

    @Test
    func emptyDependencies() {
        let contents = "/path/to/output.o :\n"
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result.isEmpty)
    }

    @Test
    func noColonReturnsEmpty() {
        let contents = "no colon here\n"
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result.isEmpty)
    }

    @Test
    func manyDependenciesWithContinuations() {
        let contents = """
            /build/MyModule-emit-module.d : \\
              /src/File1.swift \\
              /src/File2.swift \\
              /src/File3.swift \\
              /sdk/usr/lib/swift/Swift.swiftmodule/arm64-apple-ios.swiftinterface \\
              /sdk/usr/lib/swift/Foundation.swiftmodule/arm64-apple-ios.swiftinterface \\
              /build/OtherModule.swiftmodule
            """
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result.count == 6)
        #expect(result.contains("/src/File1.swift"))
        #expect(result.contains("/src/File2.swift"))
        #expect(result.contains("/src/File3.swift"))
        #expect(result.contains("/sdk/usr/lib/swift/Swift.swiftmodule/arm64-apple-ios.swiftinterface"))
        #expect(result.contains("/sdk/usr/lib/swift/Foundation.swiftmodule/arm64-apple-ios.swiftinterface"))
        #expect(result.contains("/build/OtherModule.swiftmodule"))
    }

    @Test
    func escapedHash() {
        let contents = "/path/to/output.o : /path/to/file\\#1.swift /other.swift\n"
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result == ["/path/to/file#1.swift", "/other.swift"])
    }

    @Test
    func tabSeparated() {
        let contents = "/path/to/output.o :\t/path/a.swift\t/path/b.swift\n"
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result == ["/path/a.swift", "/path/b.swift"])
    }

    @Test
    func multipleRulesOnlyParsesFirst() {
        let contents = """
            /path/to/Foo.swiftmodule : /path/to/Source.swift /path/to/Swift.swiftinterface
            /path/to/Foo.swiftdoc : /path/to/Source.swift
            /path/to/Foo-Swift.h : /path/to/Source.swift
            """
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result == ["/path/to/Source.swift", "/path/to/Swift.swiftinterface"])
    }

    @Test
    func multipleRulesWithContinuationInFirst() {
        let contents = "/path/Foo.swiftmodule : \\\n  /src/A.swift \\\n  /src/B.swift\n/path/Foo.swiftdoc : /src/A.swift /src/B.swift\n"
        let result = SwiftDriverJobSchedulingTaskAction.parseMakefileDependencies(contents)
        #expect(result == ["/src/A.swift", "/src/B.swift"])
    }
}
