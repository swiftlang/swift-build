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
import Foundation

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

private extension String.UTF8View {
    func lastIndex(of element: Element) -> Index? {
        var idx = self.endIndex
        while idx != self.startIndex {
            idx = self.index(before: idx)
            if self[idx] == element {
                return idx
            }
        }
        return nil
    }
}

/// The Path is a value type wrapper for a string which is used to identify the path on the file system.
///
/// This struct adds support for common path manipulation operations.
public struct Path: Serializable, Sendable {
    private var useLegacyImplementation: Bool {
        #if os(Windows)
        return false
        #else
        return true
        #endif
    }

    private var _impl: FilePath {
        // When switching to the new implementation, this will become an ivar
        precondition(!useLegacyImplementation)
        return FilePath(str)
    }

    private init(_ impl: FilePath) {
        // When switching to the new implementation, this store the instance directly
        _str = impl.string
        precondition(!useLegacyImplementation)
    }

    private let _str: String

    /// The path's file system representation as a string.
    public var str: String {
        if useLegacyImplementation {
            return _str
        }
        return FilePath(_str).string
    }

    /// The system path separator.
    #if os(Windows)
    public static let pathSeparator = Character("\\")
    public static let pathSeparatorUTF8 = UInt8(ascii: "\\")
    public static let pathSeparatorsUTF8 = Set([UInt8(ascii: "\\"), UInt8(ascii: "/")])
    public static let pathEnvironmentSeparator = Character(";")
    public static let pathSeparators = Set("\\/")
    #else
    public static let pathSeparator = Character("/")
    public static let pathSeparatorUTF8 = UInt8(ascii: "/")
    public static let pathSeparatorsUTF8 = Set([UInt8(ascii: "/")])
    public static let pathEnvironmentSeparator = Character(":")
    public static let pathSeparators = Set([Character("/")])
    #endif

    /// The system path separator, as a string.
    public static let pathSeparatorString = String(pathSeparator)

    //Reserved path characters
    //See https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file#naming-conventions
    #if os(Windows)
       static let reservedPathCharacters = CharacterSet(charactersIn: "\\<>:|*?\u{000000}\"").union(CharacterSet(charactersIn: "\u{000001}"..."\u{00001F}"))
       static let reservedRootPathCharacters = CharacterSet(charactersIn: "<>\"|*\u{000000}").union(CharacterSet(charactersIn: "\u{000001}"..."\u{00001F}"))
    #else
        static let reservedPathCharacters = CharacterSet(charactersIn: "/\u{000000}")
        static let reservedRootPathCharacters = CharacterSet(charactersIn: "\u{000000}")
    #endif

    /// Returns the null device path; `/dev/null` on Unix-like platforms, or `NUL` on Windows.
    public static var null: Path {
        #if os(Windows)
        Path("NUL")
        #else
        Path("/dev/null")
        #endif
    }

    public init(_ str: String) {
        self._str = str
    }

    public init(_ str: Substring) {
        self._str = String(str)
    }

    /// Create a path from a byte string.
    // FIXME: This needs to be failable, since a ByteString is not necessarily a valid String
    public init(_ bytes: ByteString) {
        // FIXME: This should move to being the actual internal representation.
        self._str = bytes.asString
    }

    public init(platformString: UnsafePointer<CInterop.PlatformChar>) {
        self.init(FilePath(platformString: platformString).string)
    }

    public func withPlatformString<Result>(_ body: (UnsafePointer<CInterop.PlatformChar>) throws -> Result) rethrows -> Result {
        if useLegacyImplementation {
            return try FilePath(str).withPlatformString(body)
        }

        return try _impl.withPlatformString(body)
    }

    /// Returns the current working directory path, which is guaranteed to be absolute.
    public static var currentDirectory: Path {
        let fp = (FileManager.default.currentDirectoryPath.nilIfEmpty.map(Path.init) ?? .root).withTrailingSlashIfRoot
        precondition(fp.isAbsolute, "path '\(fp.str)' is not absolute")
        return fp
    }

    public static var homeDirectory: Path {
        var rawPath = NSHomeDirectory()
        // NSHomeDirectory produces a NSPathStore2, which is not a contiguous
        // UTF-8 layout. Most of Path's operations rely on efficient iteration
        // of String, and we can dodge the -characterAtIndex: slow path by
        // performing this conversion early.
        rawPath.makeContiguousUTF8()
        #if os(Windows)
        if rawPath.hasPrefix("/") {
            rawPath.removeFirst()
        }
        #endif
        let fp = Path(rawPath)
        precondition(fp.isAbsolute, "path '\(fp.str)' is not absolute")
        return fp
    }

    public static var temporaryDirectory: Path {
        // Only this API for retrieving the temporary directory seems to respect the TMPDIR override
        try! Path(FileManager.default.temporaryDirectory.filePath.str)
    }

    /// If the path is a root, force the path to end with slash, because C:\ is absolute while C: is not. Effectively a no-op for Unix paths.
    private var withTrailingSlashIfRoot: Path {
        isRoot ? withTrailingSlash : self
    }

    /// Returns a/the root path of the filesystem.
    ///
    /// On POSIX platforms, this is simply `/`. On Windows, it's an absolute path corresponding to the current root with no non-root components (for example and in most cases, `C:\`). On either platform, the path is guaranteed to end with the path separator character.
    ///
    /// - note: It's not clear if relying on the working directory in this manner is a good idea, but there are some places we need an absolute root path.
    public static var root: Path {
        #if os(Windows)
        var fp = FilePath(FileManager.default.currentDirectoryPath)
        fp.components.removeAll()
        return Path(fp.string).withTrailingSlash
        #else
        // Performance optimization for Unix-like platforms, and because FileManager's currentDirectoryPath can crash if there is an error retrieving the current directory: https://github.com/swiftlang/swift-foundation/issues/946
        return Path("/")
        #endif
    }

    /// Check if the path is the root path.
    public var isRoot: Bool {
        if useLegacyImplementation {
            return self.str == Path.pathSeparatorString
        }
        return FilePath(root: _impl.root) == _impl
    }

    /// Check if the path is absolute.
    public var isAbsolute: Bool {
        if useLegacyImplementation {
            return !str.isEmpty && str.utf8[str.utf8.startIndex] == Path.pathSeparatorUTF8
        }
        return _impl.isAbsolute
    }

    /// Check if the path is empty.
    public var isEmpty: Bool {
        return str.isEmpty
    }

    /// Return the subpath of the receiver relative to the given path.  Both paths must be absolute.
    /// - returns: The relative subpath, or nil if path is not an ancestor of the receiver, or either path is not absolute.  If the receiver and the path are equal, then returns the empty string.
    public func relativeSubpath(from path: Path) -> String? {
        if useLegacyImplementation {
            guard self.isAbsolute, path.isAbsolute else { return nil }
            guard self != path else { return "" }

            func subpath(_ anc: Path, _ dec: Path) -> String? {
                guard !dec.isRoot else { return anc.isRoot ? "" : nil }
                guard anc != dec else { return "" }
                guard let sub = subpath(anc, dec.dirname) else { return nil }
                return sub.isEmpty ? dec.basename : sub + Path.pathSeparatorString + dec.basename
            }

            return subpath(path.normalize(), self.normalize())
        }
        var new = _impl
        return new.removePrefix(path._impl) ? new.string : nil
    }

    /// Check if the path is an ancestor of another path. Always false for relative paths. This does not resolve symlinks or otherwise access the file system.
    public func isAncestor(of path: Path) -> Bool {
        if useLegacyImplementation {
            guard self.isAbsolute, path.isAbsolute else { return false }

            func rec(_ lhs: Path, _ rhs: Path) -> Bool {
                guard !rhs.isRoot else { return false }
                return lhs == rhs.dirname || rec(lhs, rhs.dirname)
            }

            return rec(self.normalize(), path.normalize())
        }
        return self != path && path._impl.starts(with: _impl)
    }

    /// Check if the path is an ancestor of another path or the same path. Always false for relative paths, even if they are equal.
    public func isAncestorOrEqual(of path: Path) -> Bool {
        if useLegacyImplementation {
            guard self.isAbsolute, path.isAbsolute else { return false }
            let normalizedSelf = self.normalize()
            let normalizedPath = path.normalize()
            return normalizedSelf == normalizedPath || normalizedSelf.isAncestor(of: normalizedPath)
        }
        return path._impl.starts(with: _impl)
    }

    /// Split the path into a (head, tail) tuple, where the tail is the base name of the path and never contains the path separator.
    public func split() -> (Path, String) {
        if useLegacyImplementation {
            // Find the trailing separator.
            let utf8 = str.utf8
            if let idx = utf8.lastIndex(of: Path.pathSeparatorUTF8) {
                // If the last separator is the one at the start of the string, it should remain a part of the dirname.
                if idx == utf8.startIndex {
                    return (Path(String(str[...idx])), String(str[utf8.index(after: idx)...]))
                }

                return (Path(String(str[..<idx])), String(str[utf8.index(after: idx)...]))
            }

            // If there were no slashes, the entire path is the base name.
            return (Path(""), self.str)
        }
        return (Path(_impl.removingLastComponent()), _impl.lastComponent?.string ?? "")
    }

    /// Get the path's parent directory. This does not resolve symlinks or otherwise access the file system.
    public var dirname: Path {
        if useLegacyImplementation {
            // Find the trailing separator.
            let utf8 = str.utf8
            if let idx = utf8.lastIndex(of: Path.pathSeparatorUTF8) {
                // If the last separator is the one at the start of the string, it should remain a part of the directory name.
                if idx == utf8.startIndex {
                    return Path(String(str[...idx]))
                }

                return Path(String(str[..<idx]))
            }

            // If there were no slashes, the entire path is the directory name.
            return Path("")
        }
        return Path(_impl.removingLastComponent())
    }

    /// The base name of the path.  This is the last path component of the receiver.
    public var basename: String {
        if useLegacyImplementation {
            // Find the trailing separator.
            let utf8 = str.utf8
            if let idx = utf8.lastIndex(of: Path.pathSeparatorUTF8) {
                return String(str[utf8.index(after: idx)...])
            }

            // If there were no slashes, the entire path is the base name.
            return str
        }
        return _impl.lastComponent?.string ?? str
    }

    /// Split the path into a path prefix plus basename and an extension (the basename separated by '.').
    public func splitext() -> (String, String) {
        if useLegacyImplementation {
            let utf8 = str.utf8
            for idx in utf8.indices.reversed() {
                if utf8[idx] == UInt8(ascii: ".") {
                    // FIXME: It is unfortunate we have to convert back to String here, maybe we should just store the UTF8View and use that as our representation? Ultimately, I would like to move the internal representation for Path to be a ByteString.
                    return (String(str[..<idx]), String(str[idx...]))
                }
                if utf8[idx] == Path.pathSeparatorUTF8 {
                    break
                }
            }
            return (str, "")
        }
        let ext = _impl.extension
        var newPath = _impl
        newPath.extension = nil
        return (newPath.string, ext ?? "")
    }

    /// The path as a string with any suffix on the basename ('.' + extension) removed.
    public var withoutSuffix: String {
        if useLegacyImplementation {
            let utf8 = str.utf8
            for idx in utf8.indices.reversed() {
                if utf8[idx] == UInt8(ascii: ".") {
                    return String(str[..<idx])
                }
                if utf8[idx] == Path.pathSeparatorUTF8 {
                    break
                }
            }
            return str
        }
        var newPath = _impl
        newPath.extension = nil
        return newPath.string
    }

    /// The path's basename as a string with any extension removed.
    public var basenameWithoutSuffix: String {
        if useLegacyImplementation {
            var suffixIndex: String.UTF8View.Index = str.utf8.endIndex
            let utf8 = str.utf8
            for idx in utf8.indices.reversed() {
                if utf8[idx] == UInt8(ascii: ".") && suffixIndex == str.utf8.endIndex {
                    suffixIndex = idx
                } else if utf8[idx] == Path.pathSeparatorUTF8 {
                    return String(str[utf8.index(after: idx)..<suffixIndex])
                }
            }

            // If there were no slashes, the entire path is the base name.
            return String(str[..<suffixIndex])
        }
        return _impl.stem ?? str
    }

    /// The suffix of the path, i.e., the trailing '.' plus any extension, if present.
    public var fileSuffix: String {
        if useLegacyImplementation {
            let utf8 = str.utf8
            for idx in utf8.indices.reversed() {
                if utf8[idx] == UInt8(ascii: ".") {
                    return String(str[idx...])
                }
                if utf8[idx] == Path.pathSeparatorUTF8 {
                    break
                }
            }
            return ""
        }
        return _impl.extension.map { ".\($0)" } ?? ""
    }

    /// The extension on the path, not including any '.'.
    public var fileExtension: String {
        if useLegacyImplementation {
            let utf8 = str.utf8
            for idx in utf8.indices.reversed() {
                if utf8[idx] == UInt8(ascii: ".") {
                    return String(str[utf8.index(after: idx)...])
                }
                if utf8[idx] == Path.pathSeparatorUTF8 {
                    break
                }
            }
            return ""
        }
        return _impl.extension ?? ""
    }

    /// If the path represents an item inside a .lproj directory, then returns the prefix of the .lproj directory.  Otherwise returns nil.
    public var regionVariantName: String? {
        let dirComponent = self.dirname.basename
        if dirComponent.hasSuffix(".lproj") {
            return Path(dirComponent).withoutSuffix
        }
        return nil
    }

    /// Return true if the pathname is conformant to path restrictions on the platform.
    ///
    /// Check the Unicode string representation of the path for reserved characters that cannot be represented as a path.
    /// Windows has a very stringent set of reservations see: https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file#naming-conventions
    /// POSIX/GNU is extremely forgiving.
    public var isConformant: Bool {
        #if os(Windows)
        //FIXME: The legacy implementation of will not work for windows roots. By default on windows we never use the legacy implementation.
        precondition(!useLegacyImplementation)
        if let root = _impl.root?.string {
            if root.rangeOfCharacter(from: Path.reservedRootPathCharacters) != nil {
                return false
            }
        }
        #endif
        // Validate the non-root portion
        if useLegacyImplementation {
            for component in str.split(separator: Path.pathSeparator) {
                if component.rangeOfCharacter(from: Path.reservedPathCharacters) != nil {
                    return false
                }
            }
        } else {
            for component in _impl.components {
                if component.string.rangeOfCharacter(from: Path.reservedPathCharacters) != nil {
                    return false
                }
            }
        }
        return true
    }

    /// Produce a 'command' quoted version of the path.
    ///
    /// Quote and escape to produce a path that can be used as command line arguments or directly in response files.
    /// Note: External programs like swiftc/swift-frontend parse response files using llvm functions which expect platform specific representations, see:
    ///   llvm::cl::TokenizeWindowsCommandLine
    ///   llvm::cl::TokenizeGNUCommandLine
    public var commandQuoted: String? {
        guard isConformant else { return nil }
        #if os(Windows)
        return "\"\(str)\""
        #else
        return str.quotedStringListRepresentation
        #endif
    }

    /// Return the path that results by appending the given component.
    ///
    /// This respects the semantics of paths, which means that joining a new absolute path will replace the current path, unless `preserveRoot` is true.  If `normalize` is true, then the appended path will be normalized as it's being appended (the receiver is assumed to already be normalized).  If `normalize` is false, the appended path is appended verbatim (after adding a path separator to the receiver, if needed).
    public func join(_ rhs: Path?, preserveRoot: Bool = false, normalize: Bool = false) -> Path {
        guard let rhs else {
            return self
        }

        if useLegacyImplementation {
            if preserveRoot && !str.isEmpty && rhs.isAbsolute {
                // NOTE: We continue to pass preserveRoot to handle multiple leading slashes.
                return join(String(rhs.str.dropFirst()), preserveRoot: true, normalize: normalize)
            }

            if str.isEmpty || rhs.isAbsolute {
                return (normalize && !rhs._isNormalized) ? rhs.normalize() : rhs
            }
            if rhs.isEmpty {
                return self
            }

            if normalize && !rhs._isNormalized {
                // Go through the components of the subpath being added, treating `.` and `..` components specially.
                var result = self.withoutTrailingSlash()
                rhs.str.enumerateSplits(of: Path.pathSeparator) { component in
                    switch component {
                    case ".":
                        break
                    case "..":
                        if result.isEmpty || result.basename == ".." || result.basename == "." { fallthrough }
                        result = result.dirname
                    default:
                        result = result.str.isEmpty ? Path(component) : Path(result.str + "/" + component)
                    }
                }
                return result
            } else {
                // Join the two path strings without any normalization.
                if str[str.index(before: str.endIndex)] == Path.pathSeparator {
                    return Path(str + rhs.str)
                } else {
                    var str = self.str
                    str.reserveCapacity(str.utf8.count + 1 + rhs.str.utf8.count)
                    str += Path.pathSeparatorString
                    str += rhs.str
                    return Path(str)
                }
            }
        }

        if preserveRoot && !str.isEmpty && rhs.isAbsolute {
            // NOTE: We continue to pass preserveRoot to handle multiple leading slashes.
            return join(Path(rhs._impl.removingRoot()), preserveRoot: true, normalize: normalize)
        }

        if str.isEmpty || rhs.isAbsolute {
            return (normalize && !rhs._isNormalized) ? rhs.normalize() : rhs
        }

        if rhs.isEmpty {
            return self
        }

        let result = Path(_impl.appending(rhs._impl.components))
        return normalize ? result.normalize() : result
    }

    /// Return the path that results by appending the given component.
    ///
    /// This respects the semantics of paths, which means that joining a new absolute path will replace the current path, unless `preserveRoot` is true.
    public func join(_ rhs: String?, preserveRoot: Bool = false, normalize: Bool = false) -> Path {
        return join(rhs.map(Path.init), preserveRoot: preserveRoot, normalize: normalize)
    }

    /// Return the path that results by appending the given component.
    ///
    /// This respects the semantics of paths, which means that joining a new absolute path will replace the current path, unless `preserveRoot` is true.
    public func join(_ rhs: Substring?, preserveRoot: Bool = false, normalize: Bool = false) -> Path {
        return join(rhs.map(Path.init), preserveRoot: preserveRoot, normalize: normalize)
    }

    /// Converts `self` to an absolute path by resolving against the `base` path.
    ///
    /// - parameter base: Base path to resolve against. This should be an absolute path.
    /// - returns: `self` if the path is already absolute, `nil` if both `self` and `base` are relative, or the result of joining `base` with `self`.
    public func makeAbsolute(relativeTo base: Path) -> Path? {
        if isAbsolute {
            return self
        }

        if base.isAbsolute {
            return base.join(self)
        }

        // self and base are both relative
        return nil
    }

    /// Resolves all symlinks in the path and returns a new path containing no symlinks.
    public func resolveSymlink(fs: any FSProxy) throws -> Path {
        return try fs.realpath(self)
    }

    /// Return a normalized version of the path.
    ///
    /// This normalization removes cases of '..' and '.', where possible, but does not perform any normalizations that require access to the filesystem.  Nor does it expand '~'.
    ///
    /// - parameter removeDotDotFromRelativePath: If false, then '..' will not be removed from relative paths, akin to the behavior of `-[NSString stringByStandardizingPath]`.
    public func normalize(removeDotDotFromRelativePath: Bool = true) -> Path {
        if useLegacyImplementation {
            // If the path is just ".", we want to leave that alone.
            // This is important for search paths, where "." != "" semantically.
            if str == "." {
                return self
            }

            // Fast path, avoid processing if the string is already normalized. As
            // implement, this will scan the entire string, but it shouldn't need to
            // ever create temporary strings, so the cost of this should always be
            // dwarfed by the actual normalization (at least, as implemented below).
            if _isNormalized {
                return self
            }

            // FIXME: Optimize more.
            var result = isAbsolute ? Path("/") : Path("")
            let removeDotDot = (isAbsolute || removeDotDotFromRelativePath)
            str.enumerateSplits(of: Path.pathSeparator) { component in
                switch component {
                case "", ".":
                    break
                case "..":
                    // If we should and can remove the .., then we do so.  Otherwise we append it.
                    if removeDotDot && result.canTraverseUpward {
                        result = result.dirname
                    } else {
                        result = result.join(component)
                    }
                default:
                    result = result.join(component)
                }
            }
            return result
        }
        return Path(_impl.lexicallyNormalized())
    }

    /// Check if the path is currently normalized.
    private var _isNormalized: Bool {
        if useLegacyImplementation {
            var normalized = true
            _enumerateAllComponents {
                switch $0 {
                case "", ".", "..":
                    normalized = false
                default:
                    break
                }
            }
            return normalized
        }
        return _impl.isLexicallyNormal
    }

    /// Enumerate all "natural" components of the represented path (including empty ones).
    private func _enumerateAllComponents(_ body: (Substring) -> Void) {
        if useLegacyImplementation {
            var remainder: Substring
            if isAbsolute {
                remainder = str.dropFirst(1)
            } else {
                remainder = str[...]
            }
            while let idx = remainder.firstIndex(of: Path.pathSeparator) {
                body(remainder[..<idx])
                remainder = remainder[remainder.index(after: idx)...]
            }
            body(remainder)
            return
        }
        if let root = _impl.root?.string {
            body(Substring(root))
        }
        for component in _impl.components {
            body(Substring(component.string))
        }
    }

    private var canTraverseUpward: Bool {
        precondition(useLegacyImplementation)
        return !isEmpty && basename != ".."
    }

    public var withTrailingSlash: Path {
        str.hasSuffix(Path.pathSeparatorString) ? self : Path(str + Path.pathSeparatorString)
    }

    /// Return a version of the path that always has any spurious trailing slash removed.
    public func withoutTrailingSlash() -> Path {
        if !isRoot && (str.hasSuffix("/") || str.hasSuffix("\\")) {
            return Path(String(str.dropLast()))
        } else {
            return self
        }
    }

    /// Returns true if the receiver's last N path components match the path components of `path`.
    public func ends(with path: Path) -> Bool {
        if useLegacyImplementation {
            // If self is empty, then only return true if path is also empty.
            guard !self.isEmpty else { return path.isEmpty }
            // If path is empty, then always return true.
            guard !path.isEmpty else { return true }
            // If either self or path are "/", then only return true if both are "/", otherwise return false.
            guard self.str != "/", path.str != "/" else { return self == path }
            // If path is absolute, then return false if self is not also absolute.
            if path.isAbsolute, !self.isAbsolute { return false }

            // Remove trailing slashes.
            var base = self.str.hasSuffix("/") ? Path(self.str.withoutSuffix("/")) : self
            var pathBase = path.str.hasSuffix("/") ? Path(path.str.withoutSuffix("/")) : path

            // Iterate backwards over the path components.
            while !base.isEmpty {
                let (newBase, last) = base.split()
                let (newPathBase, pathLast) = pathBase.split()
                // If the last path components are not equal, then return false.
                guard last == pathLast else { return false }
                // If we reached the beginning of path, then everything matched so return true.
                guard !newPathBase.isEmpty else { return true }
                // Otherwise, continue with the new base paths.
                base = newBase
                pathBase = newPathBase
            }
            // If we got here, then we reached the beginning of self, so only return true if we also reached the beginning of path.
            return pathBase.isEmpty
        }
        return _impl.ends(with: path._impl)
    }

    public func ends(with path: String) -> Bool {
        return ends(with: Path(path))
    }

    /// Given a `fnmatch()`-style pattern, returns `true` if the receiver matches it.  `fnmatch()` is invoked using the `FNM_PATHNAME` flag ("Slash characters in `string` must be explicitly matched by slashes in `pattern`.").
    ///
    /// If `pattern` is an absolute path, then this method will do a straight match of `pattern` against the receiver.  If `pattern` is a relative path, then `pattern` will be matched against the *last N path components* of the receiver, where N is the number of path components in `pattern`.  If the receiver contains fewer path components than `pattern`, then `pattern` is considered not to match.
    public func matchesFilenamePattern(_ pattern: String) -> Bool {
        // An empty path doesn't match anything, even an empty pattern.
        guard !self.isEmpty else { return false }

        // If the pattern is absolute (or degenerate) then we match against the whole path.
        if pattern.isEmpty || pattern.hasPrefix("/") {
            do {
                return try fnmatch(pattern: pattern, input: self.str, options: .pathname)
            } catch {
                return false
            }
        }

        // Otherwise the pattern consists of one or more path components.  So we match the pattern against the end of the path.
        // Count the number of path components in the pattern.  We already know the pattern is relative since we handled the absolute case above.
        let numPathComponentsInPattern: Int = {
            var numComponents = 0
            var isInPathComponent = false
            var nextCharacterIsEscaped = false
            for idx in pattern.indices {
                // Skip over path separators, unless they're escaped.
                if pattern[idx] == Path.pathSeparator {
                    if !nextCharacterIsEscaped {
                        isInPathComponent = false
                    }
                }
                else {
                    // If we're not in a path component, then we found a new one.
                    if !isInPathComponent {
                        numComponents += 1
                    }
                    isInPathComponent = true
                }
                // Handle escape characters.
                if nextCharacterIsEscaped {
                    nextCharacterIsEscaped = false
                }
                else {
                    nextCharacterIsEscaped = (pattern[idx] == Character("\\"))
                }
            }
            return numComponents
        }()

        // We now know how many path components there are in the pattern.  Count out the same number of path components from the end of the path.  Note that the path *might* be absolute.
        var numPathComponentsInPath = 0
        var isInPathComponent = false
        var firstIdx: String.Index?
        for idx in self.str.indices.reversed() {
            // Skip over path separators.  We ignore backslashes here, since paths don't have escape characters.
            if self.str[idx] == Path.pathSeparator {
                isInPathComponent = false
                // If we've found the expected number of path components, then we stop, and record the index of the first character we want to match against.
                if numPathComponentsInPath == numPathComponentsInPattern {
                    if idx != self.str.endIndex {
                        firstIdx = self.str.index(after: idx)
                    }
                    break
                }
            }
            else if idx == self.str.startIndex {
                // If we didn't encounter a path separator, then the full string is the trailing subpath.
                firstIdx = idx
                break
            }
            else {
                // If we're not in a path component, then we found a new one.
                if !isInPathComponent {
                    numPathComponentsInPath += 1
                }
                isInPathComponent = true
            }
        }
        guard let first = firstIdx else {
            return false
        }

        // If we didn't find the right number of path components, then we can't match.
        guard numPathComponentsInPath == numPathComponentsInPattern else {
            return false
        }

        // Create a string from the first index we found to the end of the path.
        let trailingSubpath = String(self.str[first..<self.str.endIndex])

        // Match the pattern against the requisite number of trailing path components.
        do {
            return try fnmatch(pattern: pattern, input: trailingSubpath, options: .pathname)
        } catch {
            return false
        }
    }

    /// Given a list of `fnmatch()`-style pattern, returns `true` if the receiver matches any of them.
    ///
    /// See `matchesFilenamePattern()` for details on how the matching is performed for each pattern.
    public func isInFilenamePatternList(_ patterns: [String]) -> Bool {
        return firstMatchingPatternInFilenamePatternList(patterns) != nil
    }

    /// Given a list of `fnmatch()`-style pattern, returns the first pattern matched by the receiver.  Returns `nil` if no pattern matches the receiver.
    ///
    /// See `matchesFilenamePattern()` for details on how the matching is performed for each pattern.
    public func firstMatchingPatternInFilenamePatternList(_ patterns: [String]) -> String? {
        // An empty path never matches any patterns.
        guard !self.isEmpty else { return nil }

        // Iterate through the patterns looking for one which matches.
        for pattern in patterns {
            if self.matchesFilenamePattern(pattern) {
                return pattern
            }
        }
        return nil
    }

    /// Appends the given suffix to the file name, before file extension
    ///
    /// Example: Path("File.swift").appendingFileNameSuffix("-copy") -> Path("File-copy.swift")
    public func appendingFileNameSuffix(_ suffix: String) -> Path {
        let withoutExtension = self.withoutSuffix
        let fileSuffix = self.fileSuffix
        return Path(withoutExtension + suffix + fileSuffix)
    }

    // Serialization

    public func serialize<T: Serializer>(to serializer: T) {
        // We don't serialize Path as an aggregate since it only has one property.
        serializer.serialize(str)
    }

    public init(from deserializer: any Deserializer) throws {
        self._str = try deserializer.deserialize()
    }
}

extension Path: Hashable {
    public func hash(into hasher: inout Hasher) {
        return hasher.combine(str)
    }
}

extension Path: Equatable {
    public static func ==(lhs: Path, rhs: Path) -> Bool {
        return lhs.str == rhs.str
    }
}

extension Path: Comparable {
    public static func <(lhs: Path, rhs: Path) -> Bool {
        return lhs.str < rhs.str
    }
}

extension Path: Codable {
    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        self._str = try container.decode(String.self)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(str)
    }
}

extension Array where Element == Path {
    public var ancestors: Set<Path> {
        var ancestors: Set<Path> = Set()
        for path in self {
            var path = path
            if path.isEmpty || path.isRoot {
                continue
            }
            repeat {
                path = path.dirname
                ancestors.insert(path)
            } while !path.isRoot
        }
        return ancestors
    }
}

extension Path {
    public var frameworkPath: Path? {
        if fileExtension == "framework" {
            return self
        }

        if dirname.basename == "Versions" && dirname.dirname.fileExtension == "framework" {
            return dirname.dirname
        }

        return nil
    }
}

extension Path {
    /// Prepends `/private` to the path if it begins with one of the known symlinks of `/etc`, `/tmp`, or `/var`, _and_ the path specified by `otherPath` begins with `/private`.
    ///
    /// On macOS, `/{etc,tmp,var}` is a symlink to `/private/{etc,tmp,var}`. Some Apple build tools distributed with Xcode aggressively strip /private from the beginning of file paths, effectively de-canonicalizing them back to including a symlink component. Paths in the dependency graph are expected to be pre-normalized and not contain symlinks.
    ///
    /// The "if needed" part of the name of this function reflects its usage intent: this function should be called on paths retrieved from the output of build tools like `momc` and `intentbuilderc`, passing the in output directory which the build task originally passed to the tool as `otherPath`. This will result in the behavior where if the build task passes `/private/tmp` and receives paths beginning with `/tmp`, they'll be canonicalized back to beginning with `/private/tmp` by this function. However if the build task merely passed `/tmp`, this function would _not_ add `/private` to the returned paths. Thus, this function is intended to ensure that tools produce paths with the same prefix as the build task requested for the output directory.
    ///
    /// Note that this is mostly only relevant in unit tests, as most real builds don't have a build output directory under `/etc`, `/tmp`, or `/var`.
    public func prependingPrivatePrefixIfNeeded(otherPath: Path) -> Path {
        struct Static {
            static let `private` = Path("/private")
            static let prefixes = [Path("/etc"), Path("/tmp"), Path("/var")]
        }
        if Static.private.isAncestor(of: otherPath) && Static.prefixes.contains(where: { $0.isAncestor(of: self) }) {
            return Static.private.join(self, preserveRoot: true)
        }
        return self
    }

    /// Returns a string representation of the path which uses POSIX slashes even on Windows.
    ///
    /// This is necessary for some cases where tools may treat the `\` character as part of an escape sequence rather than a path separator even on Windows. Use sparingly.
    public var strWithPosixSlashes: String {
        #if os(Windows)
        str.replacingOccurrences(of: "\\", with: "/")
        #else
        str
        #endif
    }
}

/// A wrapper for a string which is used to identify an absolute path on the file system.
public struct AbsolutePath: Hashable, Equatable, Serializable, Sendable {
    public let path: Path

    public init?(_ path: Path) {
        if !path.isAbsolute {
            return nil
        }
        self.path = path
    }

    public init?(_ string: String) {
        self.init(Path(string))
    }

    public init(validating path: Path) throws {
        guard let path = Self(path) else {
            throw StubError.error("Path must be absolute: \(path.str)")
        }
        self = path
    }

    public init(validating string: String) throws {
        try self.init(validating: Path(string))
    }

    public init(from deserializer: any Deserializer) throws {
        try self.init(validating: Path(from: deserializer))
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        path.serialize(to: serializer)
    }

    public func hash(into hasher: inout Hasher) {
        path.hash(into: &hasher)
    }
}

/// A wrapper for a string which is used to identify a relative path on the file system.
public struct RelativePath: Hashable, Equatable, Serializable, Sendable {
    public let path: Path

    public init?(_ path: Path) {
        if path.isAbsolute {
            return nil
        }
        self.path = path
    }

    public init?(_ string: String) {
        self.init(Path(string))
    }

    public init(validating path: Path) throws {
        guard let path = Self(path) else {
            throw StubError.error("Path must be relative: \(path.str)")
        }
        self = path
    }

    public init(validating string: String) throws {
        try self.init(validating: Path(string))
    }

    public init(from deserializer: any Deserializer) throws {
        try self.init(validating: Path(from: deserializer))
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        path.serialize(to: serializer)
    }

    public func hash(into hasher: inout Hasher) {
        path.hash(into: &hasher)
    }
}

extension AbsolutePath {
    public var dirname: AbsolutePath {
        AbsolutePath(path.dirname)!
    }

    public func isAncestor(of other: AbsolutePath) -> Bool {
        path.isAncestor(of: other.path)
    }
}
