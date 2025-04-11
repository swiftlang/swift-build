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
import Testing
import SWBTestSupport
import SWBUtil
import SWBCore

@Suite(.skipHostOS(.windows, "path tests need a big overhaul for Windows"))
fileprivate struct PathTests {
    @Test
    func constructors() {
        #expect(Path("/") == Path(ByteString("/")))
        #expect(Path("/") == Path(Substring("/")))
    }

    @Test
    func split() {
        #expect(Path("").split() == (Path(""), String("")))

        // Path with no slashes.
        #expect(Path("test").split() == (Path(""), String("test")))

        // Root path.
        #expect(Path("/").split() == (Path("/"), String("")))

        // Common case.
        #expect(Path("/path/to/thing").split() == (Path("/path/to"), String("thing")))

        // Test split() derived operations.
        #expect(Path("/tmp/foo").basename == "foo")
        #expect(Path("/tmp/foo").dirname == Path("/tmp"))
    }

    @Test
    func dirname() {
        #expect(Path("").dirname == Path(""))
        #expect(Path("foo").dirname == Path(""))
        #expect(Path("/").dirname == Path("/"))
        #expect(Path("/..").dirname == Path("/"))
        #expect(Path("/../.").dirname == Path("/.."))
    }

    @Test
    func join() {
        #expect(Path("").join("tmp").str == "tmp")
        #expect(Path("/private").join("tmp").str == "/private/tmp")
        #expect(Path("/private/").join("tmp").str == "/private/tmp")
        #expect(Path("/private/").join("/tmp").str == "/tmp")
    }

    @Test
    func joinPreservingRoot() {
        #expect(Path("").join("/tmp", preserveRoot: true).str == "/tmp")
        #expect(Path("/tmp").join("/b", preserveRoot: true).str == "/tmp/b")
        #expect(Path("/tmp/").join("/b", preserveRoot: true).str == "/tmp/b")
        #expect(Path("/tmp/").join("//b", preserveRoot: true).str == "/tmp/b")
        #expect(Path("/tmp/").join("b", preserveRoot: true).str == "/tmp/b")
    }

    @Test
    func normalizingJoin() {
        #expect(Path("").join("", normalize: true).str == "")

        #expect(Path("").join("/", normalize: true).str == "/")
        #expect(Path("/").join("", normalize: true).str == "/")
        #expect(Path("/").join("/", normalize: true).str == "/")

        #expect(Path("").join(".", normalize: true).str == ".")
        #expect(Path(".").join("", normalize: true).str == ".")
        #expect(Path(".").join(".", normalize: true).str == ".")

        #expect(Path("").join("..", normalize: true).str == "..")
        #expect(Path("..").join("", normalize: true).str == "..")
        #expect(Path("..").join("..", normalize: true).str == "../..")

        #expect(Path("/").join(".", normalize: true).str == "/")
        #expect(Path("/").join("..", normalize: true).str == "/")
        #expect(Path("/").join("../..", normalize: true).str == "/")

        #expect(Path("..").join(".", normalize: true).str == "..")
        #expect(Path(".").join("..", normalize: true).str == "./..")
        #expect(Path("..").join("../..", normalize: true).str == "../../..")

        #expect(Path("a").join(".", normalize: true).str == "a")
        #expect(Path("a").join("..", normalize: true).str == "")
        #expect(Path("a").join("../..", normalize: true).str == "..")
        #expect(Path("a/b").join("..", normalize: true).str == "a")
        #expect(Path("a/b").join("../", normalize: true).str == "a")
        #expect(Path("a/b").join("../..", normalize: true).str == "")
        #expect(Path("a/b").join("../../", normalize: true).str == "")

        #expect(Path("/private").join("a/b/../c", normalize: true).str == "/private/a/c")

        #expect(Path("/private").join("/a/b/../c", normalize: true).str == "/a/c")
        #expect(Path("/private").join("/a/b/../c", preserveRoot: true, normalize: true).str == "/private/a/c")
    }

    @Test
    func splitext() {
        #expect(Path("a").splitext() == ("a", ""))
        #expect(Path("a.").splitext() == ("a", "."))
        #expect(Path("a.b").splitext() == ("a", ".b"))
        #expect(Path("/a.b/c").splitext() == ("/a.b/c", ""))
    }

    @Test
    func extensionOps() {
        #expect(Path("/a/b/c.ext").withoutSuffix == "/a/b/c")
        #expect(Path("/a/b/c.ext").basenameWithoutSuffix == "c")
        #expect(Path("/a/b/c.ext").fileSuffix == ".ext")
        #expect(Path("/a/b/c.ext").fileExtension == "ext")
        #expect(Path("/a/b/c.ext.ext").basenameWithoutSuffix == "c.ext")
        #expect(Path("c.ext.ext").basenameWithoutSuffix == "c.ext")
        #expect(Path("/a/b/c.ext/d").withoutSuffix == "/a/b/c.ext/d")
        #expect(Path("/a/b/c.ext/d").basenameWithoutSuffix == "d")
        #expect(Path("/a/b/c.ext/d").fileSuffix == "")
        #expect(Path("/a/b/c.ext/d").fileExtension == "")
        #expect(Path("/a/b/c.ext.ext/d").basenameWithoutSuffix == "d")
        #expect(Path("c.ext.ext/d").basenameWithoutSuffix == "d")
    }

    @Test
    func misc() {
        #expect(!Path("").isAbsolute)
        #expect(!Path("tmp").isAbsolute)
        #expect(Path("/").isAbsolute)
        #expect(Path("/tmp").isAbsolute)
    }

    @Test
    func regionVariantName() {
        #expect(Path("").regionVariantName == nil)
        #expect(Path("/").regionVariantName == nil)
        #expect(Path("/tmp/foo.c").regionVariantName == nil)
        #expect(Path("/tmp/en.lproj").regionVariantName == nil)
        #expect(Path("/tmp/en.lproj/foo.c").regionVariantName == "en")
        #expect(Path("/tmp/en.lproj/subdir/foo.c").regionVariantName == nil)
        #expect(Path("/tmp/.lproj/foo.c").regionVariantName == "")
    }

    @Test
    func regionVariantPathComponent() {
        #expect(Path("").regionVariantPathComponent == "")
        #expect(Path("/").regionVariantPathComponent == "")
        #expect(Path("/tmp/foo.c").regionVariantPathComponent == "")
        #expect(Path("/tmp/en.lproj").regionVariantPathComponent == "")
        #expect(Path("/tmp/en.lproj/foo.c").regionVariantPathComponent == "en.lproj/")
        #expect(Path("/tmp/en.lproj/subdir/foo.c").regionVariantPathComponent == "")
        #expect(Path("/tmp/.lproj/foo.c").regionVariantPathComponent == ".lproj/")
    }

    @Test
    func normalize() {
        #expect(Path("").normalize() == Path(""))
        #expect(Path(".").normalize() == Path("."))
        #expect(Path("/a/b/./../c").normalize() == Path("/a/c"))
        #expect(Path(".././c").normalize() == Path("../c"))
        #expect(Path("/.././c").normalize() == Path("/c"))
        #expect(Path("/../../a").normalize() == Path("/a"))
        #expect(Path("../../a").normalize() == Path("../../a"))
        #expect(Path("../.././c/b/../a").normalize() == Path("../../c/a"))
        #expect(Path("///a/b/../c/").normalize() == Path("/a/c"))
        #expect(Path("/a/b../../c").normalize() == Path("/a/c"))

        // Test not removing ..'s from relative paths.
        #expect(Path("a/../b").normalize(removeDotDotFromRelativePath: false) == Path("a/../b"))
        #expect(Path("/a/../b").normalize(removeDotDotFromRelativePath: false) == Path("/b"))
    }

    @Test
    func withoutTrailingSlash() {
        #expect(Path("/a/").withoutTrailingSlash() == Path("/a"))
        #expect(Path("/a").withoutTrailingSlash() == Path("/a"))
        #expect(Path("/").withoutTrailingSlash() == Path("/"))
    }

    @Test
    func ancestors() {
        #expect(!Path("").isAncestor(of: Path("")))
        #expect(!Path("foo").isAncestor(of: Path("foo")))
        #expect(!Path("foo").isAncestor(of: Path("foo/bar")))
        #expect(!Path("/").isAncestor(of: Path("foo")))
        // A path is not an ancestor of itself
        #expect(!Path("/foo").isAncestor(of: Path("/foo")))
        #expect(!Path("/foo").isAncestor(of: Path("/foo/")))
        #expect(!Path("/").isAncestor(of: Path("/")))
        // Proper ancestors
        #expect(Path("/").isAncestor(of: Path("/foo")))
        #expect(Path("/foo").isAncestor(of: Path("/foo/bar")))

        // isAncestorOrEqual(of:)
        // Relative paths should always fail
        #expect(!Path("").isAncestorOrEqual(of: Path("")))
        #expect(!Path("foo").isAncestorOrEqual(of: Path("foo")))
        #expect(!Path("foo").isAncestorOrEqual(of: Path("foo/bar")))
        #expect(!Path("/").isAncestorOrEqual(of: Path("foo")))
        // A path is an ancestor-or-equal of itself
        #expect(Path("/foo").isAncestorOrEqual(of: Path("/foo")))
        #expect(Path("/foo").isAncestorOrEqual(of: Path("/foo/")))
        #expect(Path("/").isAncestorOrEqual(of: Path("/")))
        // Proper ancestors
        #expect(Path("/").isAncestorOrEqual(of: Path("/foo")))
        #expect(Path("/foo").isAncestorOrEqual(of: Path("/foo/bar")))

        // Array<Path>.ancestors
        #expect([Path("/path/to/input/one"), Path("/path/to/input/two"), Path("/path/to/input/two/subfolder")].ancestors ==
                Set([Path("/"), Path("/path"), Path("/path/to"), Path("/path/to/input"), Path("/path/to/input/two")]))
        #expect([Path("/")].ancestors == [])
        #expect([Path("/path"), Path("/secondPath")].ancestors == [Path("/")])
        let emptyList: [Path] = []
        #expect(emptyList.ancestors == [])
    }

    @Test
    func relativeSubpaths() {
        #expect(Path("").relativeSubpath(from: Path("")) == nil)
        #expect(Path("foo").relativeSubpath(from: Path("foo")) == nil)
        #expect(Path("foo").relativeSubpath(from: Path("foo/bar")) == nil)
        #expect(Path("/").relativeSubpath(from: Path("foo")) == nil)
        #expect(Path("foo").relativeSubpath(from: Path("/")) == nil)

        // Paths which are unrelated should return nil.
        #expect(Path("/foo").relativeSubpath(from: Path("/bar")) == nil)
        #expect(Path("/foo").relativeSubpath(from: Path("/bar/baz")) == nil)

        // Equal paths should return the empty string.
        #expect(Path("/").relativeSubpath(from: Path("/")) == "")
        #expect(Path("/foo").relativeSubpath(from: Path("/foo")) == "")

        #expect(Path("/foo").relativeSubpath(from: Path("/")) == "foo")
        #expect(Path("/foo/bar").relativeSubpath(from: Path("/")) == "foo/bar")
        #expect(Path("/foo/bar").relativeSubpath(from: Path("/foo")) == "bar")
    }

    @Test
    func resolveSymlink() throws {
        try withTemporaryDirectory { tmpDir in
            // Test a simple resolution.
            let foo = tmpDir.join("foo")
            let link = foo.join("link")
            let bar = tmpDir.join("bar")
            try localFS.createDirectory(foo)
            try localFS.createDirectory(bar)
            try localFS.symlink(link, target: bar)
            #expect(try link.resolveSymlink(fs: localFS).basename == "bar")
            // NOTE: We also realpath `bar` here in case the temporary directory path has symlinks (common on macOS).
            #expect(try link.resolveSymlink(fs: localFS) == bar.resolveSymlink(fs: localFS))

            // Test resolving chained symlinks. This is the model inside macOS .framework bundles.
            let fwk = tmpDir.join("Framework.fwk")
            let binaryLink = fwk.join("Framework")
            let versions = fwk.join("Versions")
            let a = versions.join("A")
            let currentLink = versions.join("Current")
            let binary = a.join("Framework")
            try localFS.createDirectory(fwk)
            try localFS.createDirectory(versions)
            try localFS.createDirectory(a)
            try localFS.symlink(currentLink, target: Path("A"))
            try localFS.symlink(binaryLink, target: Path("Versions/Current/Framework"))
            try localFS.write(binary, contents: "Binary")
            #expect(try currentLink.resolveSymlink(fs: localFS) == a)
            #expect(try binaryLink.resolveSymlink(fs: localFS) == binary)
            // NOTE: We also realpath `bar` here in case the temporary directory path has symlinks (common on macOS).
            #expect(try currentLink.resolveSymlink(fs: localFS) == a.resolveSymlink(fs: localFS))
            #expect(try binaryLink.resolveSymlink(fs: localFS) == binary.resolveSymlink(fs: localFS))
        }
    }

    @Test
    func endsWithPath() {
        #expect(Path("").ends(with: ""))
        #expect(Path("/tmp").ends(with: ""))
        #expect(!Path("").ends(with: "quux"))
        #expect(Path("/").ends(with: "/"))
        #expect(!Path("/a/").ends(with: "/b"))
        #expect(Path("/").ends(with: ""))

        // More interesting cases.
        #expect(Path("foo/bar/baz").ends(with: "baz"))
        #expect(Path("/foo/bar/baz").ends(with: "baz"))
        #expect(!Path("foo/bar/baz").ends(with: "/baz"))
        #expect(!Path("/foo/bar/baz").ends(with: "/baz"))
        #expect(Path("foo/bar/baz").ends(with: "bar/baz"))
        #expect(!Path("foo/bar/baz").ends(with: "/bar/baz"))
        #expect(!Path("foo/bar/baz").ends(with: "/baz"))            // A relative path can't end with an absolute path
        #expect(Path("foo/bar/baz").ends(with: "foo/bar/baz"))
        #expect(!Path("foo/bar/baz").ends(with: "/foo/bar/baz"))
        #expect(!Path("foo/bar/baz").ends(with: "foo/bar"))
        #expect(!Path("foo/bar/baz").ends(with: "quux"))
        #expect(Path("foo/bar/baz").ends(with: "baz/"))             // The trailing slash is removed
        #expect(!Path("foo/bar/baz").ends(with: "bar/"))
    }

    @Test
    func matchesFilenamePattern() {
        #expect(!Path("").isInFilenamePatternList(["", "*", "foo", "/foo"]))
        #expect(!Path("/foo").isInFilenamePatternList([]))
        #expect(!Path("/foo").matchesFilenamePattern(""))
        #expect(!Path("").matchesFilenamePattern("*"))

        // Test absolute path matches.
        #expect(Path("/").matchesFilenamePattern("/"))
        #expect(Path("/").matchesFilenamePattern("/*"))
        #expect(!Path("/").matchesFilenamePattern("/*/"))
        #expect(Path("/foo").matchesFilenamePattern("/*"))
        #expect(Path("/foo").matchesFilenamePattern("/foo"))
        #expect(Path("/foo").matchesFilenamePattern("/foo*"))
        #expect(Path("/foobar").matchesFilenamePattern("/foo*"))
        #expect(!Path("/foo").matchesFilenamePattern("/foo*/"))
        #expect(!Path("/foo").matchesFilenamePattern("/foo/bar"))
        #expect(Path("/foo/bar").matchesFilenamePattern("/*/bar"))
        #expect(Path("/foo/bar").matchesFilenamePattern("/foo/*"))
        #expect(Path("/foo/$/bar").matchesFilenamePattern("*/$/*"))
        #expect(!Path("/foo/$/bar").matchesFilenamePattern("*/$/*/*"))
        #expect(Path("foo").matchesFilenamePattern("*"))
        #expect(Path("foo").matchesFilenamePattern("foo"))
        #expect(Path("foo").matchesFilenamePattern("f*"))
        #expect(!Path("foo").matchesFilenamePattern("foobar"))

        // Test partial path matches.
        #expect(Path("/foo/bar").matchesFilenamePattern("*"))
        #expect(Path("/foo/bar").matchesFilenamePattern("bar"))
        #expect(Path("/foo/bar").matchesFilenamePattern("*/bar"))
        #expect(Path("/foo/bar").matchesFilenamePattern("foo/*"))
        #expect(!Path("/foo/bar").matchesFilenamePattern("foo/*/*/*"))
        #expect(Path("/foo/bar").matchesFilenamePattern("*/*"))
        #expect(!Path("/foo/bar").matchesFilenamePattern("foo"))
        #expect(!Path("/foo/bar").matchesFilenamePattern("a*"))
        #expect(Path("/foo/bar").matchesFilenamePattern("b*"))
        #expect(Path("/foo/bar").matchesFilenamePattern("[a-zA-Z]*"))
        #expect(!Path("/foo/bar").matchesFilenamePattern("[0-9]*"))
        #expect(!Path("/foo/bar").matchesFilenamePattern("[0-9]*/*/*/*/*"))
        #expect(!Path("aa////aa/").matchesFilenamePattern("a"))

        // Test array matches.
        #expect(Path("/foo").isInFilenamePatternList(["bar", "*"]))
        #expect(Path("/foo").isInFilenamePatternList(["bar", "/foo"]))
        #expect(Path("/foo").isInFilenamePatternList(["bar", "foo"]))
        #expect(!Path("/foo").isInFilenamePatternList(["bar", "foo/"]))
    }

    @Test
    func appendingFileNameSuffix() throws {
        #expect(Path("File.swift").appendingFileNameSuffix("-copy") == Path("File-copy.swift"))
        #expect(Path("/tmp/File.swift").appendingFileNameSuffix("-copy") == Path("/tmp/File-copy.swift"))
        #expect(Path("File.swift").appendingFileNameSuffix("") == Path("File.swift"))
        #expect(Path("File").appendingFileNameSuffix("") == Path("File"))
        #expect(Path("File").appendingFileNameSuffix("-suffix") == Path("File-suffix"))
        #expect(Path("").appendingFileNameSuffix("Suffix") == Path("Suffix"))
        #expect(Path("/tmp/$/File.jpg").appendingFileNameSuffix("-suffix") == Path("/tmp/$/File-suffix.jpg"))
        #expect(Path("/tmp/$/File\nname.jpg").appendingFileNameSuffix("-suffix") == Path("/tmp/$/File\nname-suffix.jpg"))
    }

    @Test
    func frameworkPath() {
        #expect(Path("/Applications/Xcode.app").frameworkPath == nil)
        #expect(Path("/someframework").frameworkPath == nil)
        #expect(Path("/path/to/foo.framework").frameworkPath == Path("/path/to/foo.framework"))
        #expect(Path("/path/to/foo.framework/Versions/A").frameworkPath == Path("/path/to/foo.framework"))
        #expect(Path("/path/to/foo.framework/Versions/Current").frameworkPath == Path("/path/to/foo.framework"))
        #expect(Path("/path/to/foo.framework/foo").frameworkPath == nil)
        #expect(Path("/path/to/foo.framework/foo").frameworkPath == nil)
        #expect(Path("/path/to/foo.framework/Versions/A/foo").frameworkPath == nil)
        #expect(Path("/path/to/foo.framework/Versions").frameworkPath == nil)
    }
}
@Suite()
fileprivate struct PathTestsPlatformSpecific {
    @Test(.skipHostOS(.windows))
    func conformantPathsPOSIX() {
        let conformantRoots = ["/", "/\r\n/"]
        conformantRoots.forEach { root in
            #expect(Path(root).isConformant)
            #expect(Path(root).join("foo/bar.txt").isConformant)
            #expect(Path(root).join("foo/bar with spaces.txt").isConformant)
            #expect(Path(root).join("foo\\slashy\\slash/bar.txt").isConformant)
            #expect(!Path(root).join("/foo/bar\u{0}/barnull.txt").isConformant)
        }
        // Relative paths
        #expect(Path("foo/bar.txt").isConformant)
        #expect(!Path("foo/bar\u{0}/barnull.txt").isConformant)
    }
    @Test(.requireHostOS(.windows))
    func conformantPathsWindows() {
        let reservedCharacterString = "<>:|*?" + String((00...31).map({Character(UnicodeScalar($0))}))
        var conformantRoots = ["C:\\", "Z:\\", "\\\\server\\", "\\\\?\\Volume{123456789}\\"]
        // Windows path separators
        conformantRoots.forEach { root in
            #expect(Path(root).join("foo\\bar").isConformant)
            #expect(Path(root).join("foo\\bar with spaces.txt").isConformant)
            #expect(!Path(root).join("foo\(reservedCharacterString)\\bar.txt").isConformant)
        }
        // Relative paths
        #expect(Path("foo\\bar.txt").isConformant)
        #expect(!Path("foo\(reservedCharacterString)\\bar.txt").isConformant)

        //Posix path separators
        conformantRoots = ["C:/", "Z:/", "//server/", "//?/Volume{123456789}/"]
        conformantRoots.forEach { root in
            #expect(Path(root).join("foo/bar.txt").isConformant)
            #expect(!Path(root).join("foo\(reservedCharacterString)/bar.txt").isConformant)
        }
        //Mixed path separators
        conformantRoots.forEach { root in
            #expect(Path(root).join("foo\\bar.txt").isConformant)
            #expect(!Path(root).join("foo\(reservedCharacterString)\\bar.txt").isConformant)
        }
        let nonConformantRoots = ["C:\t\\", "//\t\n\r", "\\\\server\t\\"]
        nonConformantRoots.forEach { root in
            #expect(!Path(root).join("foo\\bar.txt").isConformant)
        }
    }
}
