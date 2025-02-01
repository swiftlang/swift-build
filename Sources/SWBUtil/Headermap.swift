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

/// An in-memory representation of a "headermap" file.
///
/// Headermaps are a GCC-compatible compiler mechanism for providing an efficient mapping of textual header names to paths. They are provided to the compiler in the same manner as normal include search paths. When the compiler encounters a headermap during the header search process, it will look in the headermap for an entry matching the textual include as written by the user.
///
/// This mechanism is used to support several goals:
///  - It can be used to allow the user to import "any" header in a project or target, without regard to the file system location.
///  - It masks case-sensitivity in the file system. Searches are case-insensitive, but the table itself is case preserving.
///  - In cases where the compiler might find headers built into the output directory, it helps the compiler report diagnostics in terms of source files.
///
/// This mechanism has been extended in Clang to support "recursive" header map search: if an entry maps to a relative path, which is not found on disk, then the compiler will continue header search as if that header had been written instead of the original.
///
/// There are several subtle gotchas with headermaps as implemented in Clang. In particular, local header search bypasses the headermap, and will always find the local relative item if present.
///
/// Internally, the headermap is just a binary hash table which uses open addressing and linear probing.
public struct Headermap: Sendable {
    public enum Error: Swift.Error {
        /// Attempt to load an invalid headermap.
        case invalidHeadermap(String)
    }

    /// The contents of an individual bucket, as laid out in the serialized representation.
    ///
    /// Each bucket stores three indices into the string table; one index for the key, and two indices for the value which is conceptually the path concatenation of the strings at each index. Separating the value into two indices is an optimization which allows the common prefixes to be stored into a single string table entry.
    fileprivate struct Bucket {
        /// The string table index of the key.
        var keyIndex: Int32

        /// The string table index of the path prefix for the result.
        var prefixIndex: Int32

        /// The string table index of the path suffix for the result.
        var suffixIndex: Int32
    }

    /// The headermap header structure, as laid out in the serialized representation.
    private struct Header {
        /// The little endian headermap magic code ('hmap' in either endianness).
        static let magicLE: UInt32 = 0x686d6170
        static let magicBE: UInt32 = 0x70616d68

        /// The magic code.
        var magic: UInt32

        /// The headermap version, currently we only support "1".
        var version: UInt16

        /// A reserved field.
        var reserved: UInt16

        /// The file offset of the string table.
        var stringTableOffset: UInt32

        /// The number of entries in the table.
        var numEntries: UInt32

        /// The number of buckets (which will immediately follow the header).
        var numBuckets: UInt32

        /// The maximum length of any value.
        var maxValueLength: UInt32
    }

    /// The headermap hash function.
    private static func hashBytes(_ bytes: ArraySlice<UInt8>) -> Int {
        var result = 0
        for byte in bytes {
            result += Int(tolower(Int32(byte))) * 13
        }
        return result
    }

    /// The number of entries in the table.
    private var numEntries: Int

    /// The bucket in the table. We always use a power-of-two sized array.
    fileprivate var buckets: [Bucket]

    /// The string table, which is a sequence of C-strings. By definition, this is always '\0' terminated.
    private var stringTable: [UInt8]

    /// The maximum length of any value in the table.
    private var maxValueLength: Int

    /// The string to index mapping.
    private var stringIndexMap: [ByteString: Int32]

    /// Create an empty headermap.
    ///
    /// - capacity: The default capacity to use for the headermap hash table.
    public init(capacity: Int = 8) {
        precondition(capacity > 0)

        // Round the capacity up, to ensure a power-of-two sized table.
        let capacity = capacity.roundUpToPowerOfTwo()
        self.numEntries = 0
        self.buckets = [Bucket](repeating: Bucket(keyIndex: 0, prefixIndex: 0, suffixIndex: 0), count: capacity)
        self.stringTable = [0]
        self.stringIndexMap = [ByteString([]): 0]
        self.maxValueLength = 0
    }

    /// Create a headermap from a serialized representation.
    public init(bytes: [UInt8]) throws {
        precondition(Int(littleEndian: 1) == 1, "big-endian platform is unsupported")

        // Check the header.
        guard bytes.count >= MemoryLayout<Header>.size else {
            throw Error.invalidHeadermap("invalid header")
        }
        let header: Header = bytes.withUnsafeBufferPointer {
            return $0.baseAddress!.withMemoryRebound(to: Header.self, capacity: 1) {
                return $0.pointee
            }
        }
        guard header.magic == Header.magicLE && header.version == 1 && header.reserved == 0 else {
            throw Error.invalidHeadermap("invalid header")
        }
        guard header.numEntries < header.numBuckets else {
            throw Error.invalidHeadermap("invalid header (invalid entry count)")
        }
        let bucketsEnd = MemoryLayout<Header>.size + MemoryLayout<Bucket>.stride * Int(header.numBuckets)
        guard header.numBuckets > 0 && bucketsEnd <= Int(header.stringTableOffset) else {
            throw Error.invalidHeadermap("invalid header (invalid bucket count)")
        }
        guard header.stringTableOffset < UInt32(bytes.count) else {
            throw Error.invalidHeadermap("invalid header (invalid string table offset)")
        }

        // Ensure the string table is '\0' terminated.
        guard bytes.last! == 0 else {
            throw Error.invalidHeadermap("invalid header (missing string table terminator)")
        }

        self.numEntries = Int(header.numEntries)
        let numBuckets = Int(header.numBuckets)
        self.buckets = bytes.withUnsafeBufferPointer{
            let bucketsStart = $0.baseAddress! + MemoryLayout<Header>.size
            return bucketsStart.withMemoryRebound(to: Bucket.self, capacity: numBuckets) {
                return [Bucket](UnsafeBufferPointer(start: $0, count: numBuckets))
            }
        }
        self.stringTable = [UInt8](bytes.suffix(from: Int(header.stringTableOffset)))
        // We do not use the max value length, so we also do not validate it.
        self.maxValueLength = Int(header.maxValueLength)

        // Construct the string index map.
        self.stringIndexMap = [:]
        var index = 0
        while index < self.stringTable.count {
            let string = getString(Int32(index))
            self.stringIndexMap[ByteString([UInt8](string))] = Int32(index)
            index += string.count + 1
            assert(index <= self.stringTable.count)
        }

        // Validate each of the buckets.
        let stringTableSize = Int32(stringTable.count)
        for bucket in self.buckets {
            guard bucket.keyIndex  < stringTableSize && bucket.prefixIndex  < stringTableSize && bucket.suffixIndex  < stringTableSize else {
                throw Error.invalidHeadermap("invalid header (invalid bucket index)")
            }
        }
    }

    /// Insert an entry into the table.
    ///
    /// - parameter key: The key to insert.
    /// - parameter value: The value to insert.
    /// - parameter replace: If true, any existing mapping for key will be replaced by the new definition.
    public mutating func insert(_ key: Path, value: Path, replace: Bool = true) {
        // Grow the table, if necessary. We maintain a load factor of 2/3.
        if 3 * (numEntries + 1) > 2 * buckets.count {
            grow()
        }

        // Insert the new entry bucket.
        let key = [UInt8](key.str.utf8)
        let keyIndex = getStringIndex(key)
        let (dirname,basename) = value.split()
        let prefixIndex: Int32, suffixIndex: Int32
        if dirname.isEmpty {
            prefixIndex = 0
            suffixIndex = getStringIndex([UInt8](value.str.utf8))
        } else {
            prefixIndex = getStringIndex([UInt8](dirname.str.utf8) + [Path.pathSeparatorUTF8])
            suffixIndex = getStringIndex([UInt8](basename.utf8))
        }
        insertItem(key[0 ..< key.endIndex], keyIndex: keyIndex, prefixIndex: prefixIndex, suffixIndex: suffixIndex, replace: replace)
    }

    /// Return the serialized little-endian headermap representation.
    public func toBytes() -> ByteString {
        precondition(Int(littleEndian: 1) == 1, "big-endian platform is unsupported")
        let output = OutputByteStream()

        // Write the header.
        let stringTableOffset = UInt32(MemoryLayout<Header>.size + buckets.count * MemoryLayout<Bucket>.stride)
        var header = Header(magic: Header.magicLE, version: 1, reserved: 0, stringTableOffset: stringTableOffset, numEntries: UInt32(numEntries), numBuckets: UInt32(buckets.count), maxValueLength: UInt32(maxValueLength))
        withUnsafePointer(to: &header) { ptr in
            // FIXME: Make this efficient.
            //
            // FIXME: It is very risky to depend on the type layout like this.
            ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<Header>.size) {
                _ = output <<< UnsafeBufferPointer(start: $0, count: MemoryLayout<Header>.size)
            }
        }

        // Write all of the buckets.
        buckets.withUnsafeBufferPointer { bufferPtr in
            // FIXME: Make this efficient.
            //
            // FIXME: It is very risky to depend on the type layout like this.
            bufferPtr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<Bucket>.stride * bufferPtr.count) {
                _ = output <<< UnsafeBufferPointer(start: $0, count: MemoryLayout<Bucket>.stride * bufferPtr.count)
            }
        }

        // Write the string table.
        output <<< stringTable

        return output.bytes
    }

    /// Get the string at the given index in the string table.
    fileprivate func getString(_ index: Int32) -> ArraySlice<UInt8> {
        let index = Int(index)
        precondition(index < stringTable.count)

        // Find the end index.
        for i in index ..< stringTable.count {
            if stringTable[i] == 0 {
                return stringTable[index ..< i]
            }
        }

        // This shouldn't ever be reachable.
        fatalError()
    }

    /// Get the index for the given string, or add it to the table.
    private mutating func getStringIndex(_ bytes: [UInt8]) -> Int32 {
        // Check if we already have an entry.
        let wrapper = ByteString(bytes)
        if let index = stringIndexMap[wrapper] {
            return index
        }

        // If not, insert it.
        let index = Int32(stringTable.count)
        stringTable += bytes
        stringTable.append(0)
        stringIndexMap[wrapper] = index
        return index
    }

    /// Grow the table.
    private mutating func grow() {
        precondition(buckets.count.isPowerOfTwo())
        let oldBuckets = buckets
        self.buckets = [Bucket](repeating: Bucket(keyIndex: 0, prefixIndex: 0, suffixIndex: 0), count: self.buckets.count * 2)

        // Fill in all of the buckets.
        self.numEntries = 0
        for bucket in oldBuckets {
            insertItem(getString(bucket.keyIndex), keyIndex: bucket.keyIndex, prefixIndex: bucket.prefixIndex, suffixIndex: bucket.suffixIndex)
        }
    }

    /// Insert a single item into the table.
    private mutating func insertItem(_ key: ArraySlice<UInt8>, keyIndex: Int32, prefixIndex: Int32, suffixIndex: Int32, replace: Bool = true) {
        assert(buckets.count.isPowerOfTwo())
        let hash = Headermap.hashBytes(key)
        for i in 0 ..< buckets.count {
            let index = (hash + i) & (buckets.count - 1)

            // If we found a free bucket or one with the same key, insert.
            if buckets[index].keyIndex == 0 || isEqualKey(buckets[index].keyIndex, keyIndex) {
                if buckets[index].keyIndex == 0 {
                    self.numEntries += 1
                } else if !replace {
                    return
                }
                buckets[index].keyIndex = keyIndex
                buckets[index].prefixIndex = prefixIndex
                buckets[index].suffixIndex = suffixIndex
                return
            }
        }

        // This shouldn't ever be reachable.
        fatalError()
    }

    /// Check if the keys at two indices are equal.
    private func isEqualKey(_ lhs: Int32, _ rhs: Int32) -> Bool {
        // If the key indices are equal, they are equal.
        if lhs == rhs {
            return true
        }

        // Otherwise, compare without case sensitivity.
        for offset in 0 ..< stringTable.count {
            let lhsChar = tolower(Int32(stringTable[Int(lhs) + offset]))
            let rhsChar = tolower(Int32(stringTable[Int(rhs) + offset]))
            if lhsChar != rhsChar {
                return false
            }
            if lhsChar == 0 {
                return true
            }
        }

        // This shouldn't ever be reachable.
        fatalError()
    }
}

/// Conform to sequence type.
extension Headermap: Sequence {
    public typealias Element = ([UInt8], [UInt8])

    public typealias Iterator = AnyIterator<Element>

    /// Iterator over the keys and values in the headermap.
    public func makeIterator() -> Iterator {
        var index = 0
        return AnyIterator { () -> Element? in
            while index < self.buckets.count {
                let bucket = self.buckets[index]
                index += 1
                if bucket.keyIndex != 0 {
                    let key = [UInt8](self.getString(bucket.keyIndex))
                    // NOTE: This is not very efficient, but this method is only intended for non-performance critical use (mostly debugging and tests) in Swift Build.
                    let value = [UInt8](self.getString(bucket.prefixIndex)) + [UInt8](self.getString(bucket.suffixIndex))
                    return (key, value)
                }
            }
            return nil
        }
    }
}
